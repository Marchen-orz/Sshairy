import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../foundation/data_dir.dart';
import '../../../foundation/ids.dart' as ids;
import '../../../foundation/ids.dart' show HostId;
import '../../../foundation/json_file.dart';
import '../../credentials/api.dart';
import '../domain/host.dart';
import '../domain/host_library.dart';

/// Host metadata was deleted, but some host-owned credentials could not be removed.
class HostDeleteCleanupFailure implements Exception {
  const HostDeleteCleanupFailure();
}

/// The configuration is committed; retry only with this exact revision, never a later queued edit's revision.
class HostProxyCleanupFailure implements Exception {
  const HostProxyCleanupFailure(this.committedRevision);

  final int committedRevision;
}

final hostsProvider = NotifierProvider<HostsNotifier, List<Host>>(HostsNotifier.new);

/// Groups, identities and defaults beside the hosts; it changes whenever [hostsProvider] does.
final hostLibraryProvider = Provider<HostLibrary>((ref) {
  ref.watch(hostsProvider);
  return ref.read(hostsProvider.notifier).library;
});

/// Owns hosts.json (docs/HOST_INHERITANCE.md). The observed state is the list of hosts, each carrying its effective
/// values; [library] is the one immutable snapshot behind it, and every change replaces both together.
class HostsNotifier extends Notifier<List<Host>> {
  late final JsonFile _file = JsonFile(
    '${ref.read(dataDirProvider)}/hosts.json',
    backups: true,
    schemaVersion: 2,
    migrations: {1: HostLibrary.migrateV1},
    validate: _validate,
  );
  HostLibrary _library = HostLibrary();

  @override
  List<Host> build() {
    final json = _file.read();
    _library = json == null ? HostLibrary() : HostLibrary.fromJson(json).normalized();
    return _library.hosts;
  }

  HostLibrary get library {
    // A subclass that only supplies hosts (tests) has no library of its own yet.
    if (!identical(_library.hosts, state)) _library = HostLibrary.fromHosts(state);
    return _library;
  }

  static void _validate(Map<String, dynamic> json) {
    if (json['hosts'] is! List) throw const FormatException('hosts must be a list');
    HostLibrary.fromJson(json).validate();
  }

  static HostId newId() => HostId(ids.newId());
  static String newGroupId() => ids.newId();
  static String newIdentityId() => ids.newId();

  /// Completes once every write issued so far has landed, surfacing any unresolved disk failure.
  Future<void> get saved => _pending.then((_) => _file.idle);
  int get revision => _file.revision;

  Host? byId(HostId id) => state.where((h) => h.id == id).firstOrNull;

  Future<void> _pending = Future.value();

  Future<void> _change(Future<void> Function() action) {
    final next = _pending.then((_) => action());
    _pending = next.catchError((Object _) {});
    return next;
  }

  final _pendingProxyCleanup = <(HostId, String)>{};

  /// Validates and writes before publishing; post-commit credential cleanup can still fail after publication.
  /// [edit] returns null for "nothing to do". Unless [routes] is off, a change may not leave a host with a route
  /// that was not already broken: a missing jump host, a loop, or more than eight hops.
  Future<void> _apply(
    HostLibrary? Function(HostLibrary current) edit, {
    int? expectedRevision,
    bool routes = true,
    Future<void> Function(HostLibrary before)? after,
    Future<void> Function(Future<void> Function() commit)? aroundCommit,
    void Function(int revision)? onCommitted,
    HostId? retryProxyFor,
  }) => _change(() async {
    final current = library;
    final edited = edit(current);
    if (edited == null) return;
    edited.validate();
    final next = edited.normalized();
    if (routes && next.routeProblems().difference(current.routeProblems()).isNotEmpty) {
      throw ArgumentError('invalid route');
    }

    late int committedRevision;
    Future<void> commit() async {
      await _file.write(next.toJson(), expectedRevision: expectedRevision);
      committedRevision = _file.revision;
      _library = next;
      state = next.hosts;
      onCommitted?.call(committedRevision);
    }

    // A key must still exist when something starts to use it, and cannot be deleted while it is used.
    final keys = next.keyIds.difference(current.keyIds);
    Future<void> persist() => aroundCommit == null ? commit() : aroundCommit(commit);
    if (keys.isEmpty) {
      await persist();
    } else {
      await ref.read(keysProvider.notifier).withKeys(keys, persist);
    }

    // An import holds the credential queue around commit; re-enter it only after aroundCommit releases it.
    // Proxy credentials name their endpoint, so an orphan cannot be sent to the new proxy.
    final cleanupHosts = {?retryProxyFor};
    for (final host in next.hosts) {
      final before = current.hostById(host.id)?.proxy;
      if (before != null && before.key != host.proxy?.key) {
        _pendingProxyCleanup.add((host.id, before.key));
        cleanupHosts.add(host.id);
      }
    }
    var cleanupFailed = false;
    for (final entry in _pendingProxyCleanup.toList()) {
      final (id, proxyKey) = entry;
      if (!cleanupHosts.contains(id)) continue;
      // A later edit may put the same proxy back. It now owns its credential again.
      if (next.hostById(id)?.proxy?.key == proxyKey) {
        _pendingProxyCleanup.remove(entry);
        continue;
      }
      try {
        await ref.read(hostCredentialCleanupProvider).clearProxy(id, proxyKey);
        _pendingProxyCleanup.remove(entry);
      } on Object {
        cleanupFailed = true;
      }
    }
    await after?.call(current);
    if (cleanupFailed) throw HostProxyCleanupFailure(committedRevision);
  });

  Future<void> save(Host host, {int? expectedRevision}) =>
      _apply((library) => library.withHost(host), expectedRevision: expectedRevision, retryProxyFor: host.id);

  /// Form saves need the revision of their own commit, including when proxy cleanup later fails.
  Future<int> saveWithRevision(Host host, {required int expectedRevision}) async {
    late int committedRevision;
    await _apply(
      (library) => library.withHost(host),
      expectedRevision: expectedRevision,
      onCommitted: (revision) => committedRevision = revision,
      retryProxyFor: host.id,
    );
    return committedRevision;
  }

  Future<void> importDrafts(
    List<Host> additions, {
    required int expectedRevision,
    Future<void> Function(Future<void> Function() commit)? aroundCommit,
  }) => _apply(
    (library) {
      final known = {for (final host in library.hosts) host.id};
      final endpoints = {
        for (final host in library.hosts) (host.address.toLowerCase(), host.port, host.username, host.jumpHostId),
      };
      var next = library;
      for (final host in additions) {
        next = next.withHost(host);
        final added = next.hostById(host.id)!;
        if (!known.add(host.id) ||
            !endpoints.add((added.address.toLowerCase(), added.port, added.username, added.jumpHostId))) {
          throw ArgumentError('duplicate imported host');
        }
      }
      return next;
    },
    expectedRevision: expectedRevision,
    aroundCommit: aroundCommit,
  );

  Future<void> setPinned(Host host, bool pinned) => _update(host.id, (current) => current.copyWith(pinned: pinned));

  /// Puts every host in [ids] into group [groupId], or into no group when it is null, in one write. A missing host
  /// or group refuses the whole batch; the hosts keep their overrides and metadata and so follow the new group.
  Future<void> moveToGroup(Iterable<HostId> ids, String? groupId, {int? expectedRevision}) {
    final wanted = ids.toSet();
    return _apply((library) {
      if (groupId != null && library.groupById(groupId) == null) {
        throw ArgumentError.value(groupId, 'groupId', 'missing group');
      }
      final path = groupId == null ? '' : library.groupPath(groupId);
      var next = library;
      for (final id in wanted) {
        final host = library.hostById(id);
        if (host == null) throw ArgumentError.value(id.value, 'hostId', 'missing host');
        // The path goes with the ID: withHost files a host without an ID under the group its path names.
        if (host.groupId != groupId) next = next.withHost(host.copyWith(groupId: () => groupId, group: path));
      }
      return identical(next, library) ? null : next;
    }, expectedRevision: expectedRevision);
  }

  /// Creates a missing path and moves the hosts in the same revision; conflicts leave no empty group behind.
  Future<void> moveToGroupPath(Iterable<HostId> ids, String path, {int? expectedRevision}) {
    final wanted = ids.toSet();
    return _apply((library) {
      var (next, groupId) = library.withGroupPath(path);
      final normalized = groupId == null ? '' : next.groupPath(groupId);
      for (final id in wanted) {
        final host = next.hostById(id);
        if (host == null) throw ArgumentError.value(id.value, 'hostId', 'missing host');
        if (host.groupId != groupId) next = next.withHost(host.copyWith(groupId: () => groupId, group: normalized));
      }
      return identical(next, library) ? null : next;
    }, expectedRevision: expectedRevision);
  }

  /// Recorded when a session opens, for the "recent" order.
  Future<void> touch(HostId id) => _update(id, (current) => current.copyWith(lastUsed: DateTime.now()));

  Future<void> _update(HostId id, Host Function(Host) update) => _apply((library) {
    final current = library.hostById(id);
    return current == null ? null : library.withHost(update(current));
  }, routes: false);

  /// A copy under [label] that shares the key but not the remembered password.
  Future<Host> duplicate(Host host, String label) async {
    final copy = Host(
      id: newId(),
      label: label,
      address: host.address,
      port: host.port,
      username: host.username,
      auth: host.auth,
      keyPath: host.keyPath,
      keyId: host.keyId,
      group: host.group,
      tags: host.tags,
      jumpHostId: host.jumpHostId,
      proxy: host.proxy,
      legacy: host.legacy,
      groupId: host.groupId,
      overrides: host.overrides,
      authPolicy: host.authPolicy,
    );
    await save(copy);
    return copy;
  }

  /// Gives the group at path [from] the path [to] (parents are created); an empty [to] dissolves it and keeps what it
  /// held. A path that already names another group is refused.
  Future<void> renameGroup(String from, String to) => _apply((library) {
    final id = library.groupIdFor(normalizeGroup(from));
    if (id == null) return null;
    final path = normalizeGroup(to);
    return path.isEmpty ? library.withoutGroup(id) : library.withGroupMoved(id, path);
  });

  /// Creates the group at [path] and any missing parents.
  Future<void> addGroup(String path) => _apply((library) {
    final (next, _) = library.withGroupPath(path);
    return identical(next, library) ? null : next;
  });

  /// Creates the group at [path] with [defaults] in one write; a path that already names a group is refused.
  Future<String> createGroup(String path, {ConnectionOverrides defaults = const ConnectionOverrides()}) async {
    late String id;
    await _apply((library) {
      if (library.groupIdFor(normalizeGroup(path)) != null) throw ArgumentError.value(path, 'path', 'group exists');
      final (next, created) = library.withGroupPath(path);
      if (created == null) throw ArgumentError.value(path, 'path', 'empty path');
      id = created;
      return next.withGroup(next.groupById(created)!.copyWith(defaults: defaults));
    });
    return id;
  }

  /// Moves group [id] to [path] and/or replaces its [defaults] in one write; each is left alone when null.
  Future<void> updateGroup(String id, {String? path, ConnectionOverrides? defaults, int? expectedRevision}) =>
      _apply((library) {
        var next = library;
        if (library.groupById(id) == null) return null;
        if (path != null && normalizeGroup(path) != library.groupPath(id)) next = next.withGroupMoved(id, path);
        if (defaults != null) next = next.withGroup(next.groupById(id)!.copyWith(defaults: defaults));
        return identical(next, library) ? null : next;
      }, expectedRevision: expectedRevision);

  Future<void> saveGroup(HostGroup group, {int? expectedRevision}) =>
      _apply((library) => library.withGroup(group), expectedRevision: expectedRevision);

  /// Drops group [id] before its sibling [beforeId], or last when that is null, renumbering only those siblings in one
  /// write. A missing group or a [beforeId] under another parent is refused; a drop that changes nothing writes nothing.
  Future<void> reorderGroup(String id, String? beforeId, {int? expectedRevision}) => _apply(
    (library) {
      final next = library.withGroupBefore(id, beforeId);
      return identical(next, library) ? null : next;
    },
    expectedRevision: expectedRevision,
    routes: false,
  );

  /// Subgroups and hosts move to the parent; the group's own defaults are discarded.
  Future<void> deleteGroup(String id, {int? expectedRevision}) => _apply(
    (library) => library.groupById(id) == null ? null : library.withoutGroup(id),
    expectedRevision: expectedRevision,
  );

  Future<void> saveIdentity(HostIdentity identity, {int? expectedRevision}) => _apply((library) {
    final old = library.identityById(identity.id);
    return library.withIdentity(identity.copyWith(revision: old == null ? 0 : old.revision + 1));
  }, expectedRevision: expectedRevision);

  /// Throws [IdentityInUse] while a host, group or the defaults still use it.
  Future<void> deleteIdentity(String id, {int? expectedRevision}) => _apply(
    (library) => library.identityById(id) == null ? null : library.withoutIdentity(id),
    expectedRevision: expectedRevision,
  );

  Future<void> saveDefaults(ConnectionOverrides defaults, {int? expectedRevision}) =>
      _apply((library) => library.withDefaults(defaults), expectedRevision: expectedRevision);

  Future<void> setHostProxy(HostId id, OverrideValue<Proxy> proxy, {required int expectedRevision}) =>
      _apply((library) {
        final host = library.hostById(id);
        if (host == null) throw ArgumentError('missing host');
        final overrides = _withProxy(host.overrides ?? explicitConnection(host), proxy);
        return library.withHost(host.copyWith(overrides: () => overrides));
      }, expectedRevision: expectedRevision);

  Future<void> setGroupProxy(String id, OverrideValue<Proxy> proxy, {required int expectedRevision}) =>
      _apply((library) {
        final group = library.groupById(id);
        if (group == null) throw ArgumentError('missing group');
        return library.withGroup(group.copyWith(defaults: _withProxy(group.defaults, proxy)));
      }, expectedRevision: expectedRevision);

  Future<void> setDefaultProxy(OverrideValue<Proxy> proxy, {required int expectedRevision}) => _apply(
    (library) => library.withDefaults(_withProxy(library.defaults, proxy)),
    expectedRevision: expectedRevision,
  );

  static ConnectionOverrides _withProxy(ConnectionOverrides current, OverrideValue<Proxy> proxy) => ConnectionOverrides(
    port: current.port,
    authentication: current.authentication,
    jump: current.jump,
    proxy: proxy,
    legacy: current.legacy,
  );

  Future<void> deleteMany(Iterable<HostId> ids, {int? expectedRevision}) {
    final wanted = ids.toSet();
    if (wanted.isEmpty) return Future.value();
    return _apply(
      (library) => library.withoutHosts(wanted),
      expectedRevision: expectedRevision,
      routes: false,
      after: (before) async {
        var failed = false;
        for (final id in wanted) {
          try {
            await ref.read(hostCredentialCleanupProvider).clearHost(id, before.hostById(id)?.proxy?.key ?? '');
          } on Object {
            failed = true;
          }
        }
        if (failed) throw const HostDeleteCleanupFailure();
      },
    );
  }

  /// Throws [HostInUse] while another host, a group or the defaults still use it as their jump host.
  Future<void> delete(Host host, {int? expectedRevision}) => _apply(
    (library) => library.hostById(host.id) == null ? null : library.withoutHost(host.id),
    expectedRevision: expectedRevision,
    routes: false,
    after: (before) =>
        ref.read(hostCredentialCleanupProvider).clearHost(host.id, before.hostById(host.id)?.proxy?.key ?? ''),
  );

  /// Merges a non-secret [HostLibrary] synced from a paired desktop (docs/MOBILE.md §4.3).
  /// Existing local-only hosts/groups/identities are preserved; references to keys not present on this device
  /// fall back to password/interactive authentication so secrets never have to leave the desktop by default.
  Future<int> mergeSyncedLibrary(HostLibrary incoming) async {
    final availableKeys = {for (final k in ref.read(keysProvider)) k.id};
    var syncedHosts = 0;
    await _apply(
      (current) {
        final groups = {for (final g in current.groups) g.id: g};
        for (final g in incoming.groups) {
          groups[g.id] = g.copyWith(defaults: _sanitizeOverrides(g.defaults, availableKeys));
        }
        final identities = {for (final i in current.identities) i.id: i};
        for (final i in incoming.identities) {
          identities[i.id] = i.copyWith(policy: _sanitizePolicy(i.policy, availableKeys));
        }
        final hosts = {for (final h in current.hosts) h.id: h};
        for (final h in incoming.hosts) {
          final sanitized = _sanitizeHost(h, availableKeys);
          hosts[h.id] = sanitized;
          syncedHosts++;
        }
        return HostLibrary(
          hosts: hosts.values,
          groups: groups.values,
          identities: identities.values,
          defaults: current.defaults.isEmpty ? _sanitizeOverrides(incoming.defaults, availableKeys) : current.defaults,
        );
      },
      routes: false,
    );
    return syncedHosts;
  }

  static AuthPolicy _sanitizePolicy(AuthPolicy policy, Set<String> availableKeys) {
    if (!policy.usesKey) return policy;
    if (policy.keyId != null && availableKeys.contains(policy.keyId)) return policy;
    return AuthPolicy(methods: const [AuthKind.password], allowInteractive: policy.allowInteractive);
  }

  static ConnectionOverrides _sanitizeOverrides(ConnectionOverrides o, Set<String> availableKeys) {
    if (o.authentication.mode != OverrideMode.value) return o;
    final auth = o.authentication.value!;
    if (auth.identityId != null) return o;
    final sanitized = _sanitizePolicy(auth.policy!, availableKeys);
    return ConnectionOverrides(
      port: o.port,
      authentication: OverrideValue.value(Authentication.inline(auth.username!, sanitized)),
      jump: o.jump,
      proxy: o.proxy,
      legacy: o.legacy,
    );
  }

  static Host _sanitizeHost(Host h, Set<String> availableKeys) {
    final sanitizedOverrides = h.overrides == null ? null : _sanitizeOverrides(h.overrides!, availableKeys);
    final sanitizedPolicy = _sanitizePolicy(h.policy, availableKeys);
    return Host(
      id: h.id,
      label: h.label,
      address: h.address,
      port: h.port,
      username: h.username,
      auth: sanitizedPolicy.methods.first,
      keyId: sanitizedPolicy.keyId,
      keyPath: sanitizedPolicy.keyPath,
      group: h.group,
      tags: h.tags,
      pinned: h.pinned,
      lastUsed: h.lastUsed,
      jumpHostId: h.jumpHostId,
      proxy: h.proxy,
      legacy: h.legacy,
      groupId: h.groupId,
      overrides: sanitizedOverrides,
      authPolicy: sanitizedPolicy,
    );
  }
}

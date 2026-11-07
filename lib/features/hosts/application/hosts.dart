import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../foundation/data_dir.dart';
import '../../../foundation/ids.dart' as ids;
import '../../../foundation/ids.dart' show HostId;
import '../../../foundation/json_file.dart';
import '../../credentials/api.dart';
import '../domain/host.dart';
import '../domain/host_library.dart';

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

  /// Validates the edited snapshot, writes it, then publishes it; a failure at any step publishes nothing. [edit]
  /// returns null for "nothing to do". Unless [routes] is off, a change may not leave a host with a route that was
  /// not already broken: a missing jump host, a loop, or more than eight hops.
  Future<void> _apply(
    HostLibrary? Function(HostLibrary current) edit, {
    int? expectedRevision,
    bool routes = true,
    Future<void> Function(HostLibrary before)? after,
    Future<void> Function(Future<void> Function() commit)? aroundCommit,
  }) => _change(() async {
    final current = library;
    final edited = edit(current);
    if (edited == null) return;
    edited.validate();
    final next = edited.normalized();
    if (routes && next.routeProblems().difference(current.routeProblems()).isNotEmpty) {
      throw ArgumentError('invalid route');
    }

    Future<void> commit() async {
      await _file.write(next.toJson(), expectedRevision: expectedRevision);
      _library = next;
      state = next.hosts;
      // Proxy credentials name their endpoint, so an orphan cannot be sent to the new proxy.
      for (final host in next.hosts) {
        final before = current.hostById(host.id)?.proxy;
        if (before != null && before.key != host.proxy?.key) {
          await ref.read(hostCredentialCleanupProvider).clearProxy(host.id, before.key);
        }
      }
      await after?.call(current);
    }

    // A key must still exist when something starts to use it, and cannot be deleted while it is used.
    final keys = next.keyIds.difference(current.keyIds);
    Future<void> persist() => aroundCommit == null ? commit() : aroundCommit(commit);
    if (keys.isEmpty) {
      await persist();
    } else {
      await ref.read(keysProvider.notifier).withKeys(keys, persist);
    }
  });

  Future<void> save(Host host, {int? expectedRevision}) =>
      _apply((library) => library.withHost(host), expectedRevision: expectedRevision);

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

  /// Throws [HostInUse] while another host, a group or the defaults still use it as their jump host.
  Future<void> delete(Host host) => _apply(
    (library) => library.hostById(host.id) == null ? null : library.withoutHost(host.id),
    routes: false,
    after: (before) =>
        ref.read(hostCredentialCleanupProvider).clearHost(host.id, before.hostById(host.id)?.proxy?.key ?? ''),
  );
}

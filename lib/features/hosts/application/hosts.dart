import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../foundation/data_dir.dart';
import '../../../foundation/ids.dart' as ids;
import '../../../foundation/ids.dart' show HostId;
import '../../../foundation/json_file.dart';
import '../../credentials/api.dart';
import '../domain/host.dart';
import '../domain/host_validation.dart';

final hostsProvider = NotifierProvider<HostsNotifier, List<Host>>(HostsNotifier.new);

class HostsNotifier extends Notifier<List<Host>> {
  late final JsonFile _file = JsonFile('${ref.read(dataDirProvider)}/hosts.json', backups: true, validate: _validate);

  @override
  List<Host> build() {
    final list = _file.read()?['hosts'] as List<dynamic>? ?? const [];
    return [for (final j in list) Host.fromJson(j as Map<String, dynamic>)];
  }

  static void _validate(Map<String, dynamic> json) {
    final entries = json['hosts'];
    if (entries is! List) throw const FormatException('hosts must be a list');
    final ids = <HostId>{};
    for (final entry in entries) {
      final host = Host.fromJson((entry as Map).cast<String, dynamic>());
      validateHost(host);
      if (!ids.add(host.id)) throw const FormatException('duplicate host id');
    }
  }

  static HostId newId() => HostId(ids.newId());

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

  Future<void> save(Host host, {int? expectedRevision}) => _change(() async {
    validateHost(host);
    Future<void> commit() async {
      final old = byId(host.id);
      final i = state.indexWhere((h) => h.id == host.id);
      final next = i < 0 ? [...state, host] : ([...state]..[i] = host);
      await _write(next, expectedRevision: expectedRevision);
      state = next;
      // Proxy credentials name their endpoint, so an orphan cannot be sent to the new proxy.
      if (old != null && old.proxy?.key != host.proxy?.key) {
        await ref.read(hostCredentialCleanupProvider).clearProxy(host.id, old.proxy?.key ?? '');
      }
    }

    if (host.keyId case final id?) {
      await ref.read(keysProvider.notifier).withKeys([id], commit);
    } else {
      await commit();
    }
  });

  Future<void> importDrafts(List<Host> additions, {required int expectedRevision}) => _change(() async {
    final combined = [...state, ...additions];
    final ids = {for (final host in state) host.id};
    final endpoints = {
      for (final host in state) (host.address.toLowerCase(), host.port, host.username, host.jumpHostId),
    };
    for (final host in additions) {
      validateHost(host);
      if (!ids.add(host.id) ||
          !endpoints.add((host.address.toLowerCase(), host.port, host.username, host.jumpHostId))) {
        throw ArgumentError('duplicate imported host');
      }
    }
    final byId = {for (final host in combined) host.id: host};
    for (final host in additions) {
      final seen = <HostId>{};
      Host? hop = host;
      while (hop != null) {
        if (!seen.add(hop.id) || seen.length > 8) throw ArgumentError('invalid jump chain');
        final jump = hop.jumpHostId;
        if (jump == null) break;
        hop = byId[jump];
        if (hop == null) throw ArgumentError('missing jump host');
      }
    }
    await ref.read(keysProvider.notifier).withKeys(additions.map((h) => h.keyId).whereType<String>(), () async {
      await _write(combined, expectedRevision: expectedRevision);
      state = combined;
    });
  });

  Future<void> setPinned(Host host, bool pinned) => _update(host.id, (current) => current.copyWith(pinned: pinned));

  /// Recorded when a session opens, for the "recent" order.
  Future<void> touch(HostId id) => _update(id, (current) => current.copyWith(lastUsed: DateTime.now()));

  Future<void> _update(HostId id, Host Function(Host) update) => _change(() async {
    final i = state.indexWhere((h) => h.id == id);
    if (i < 0) return;
    final next = [...state];
    next[i] = update(state[i]);
    await _write(next);
    state = next;
  });

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
    );
    await save(copy);
    return copy;
  }

  /// Moves every host in [from] or below it under [to]; an empty [to] dissolves the group and keeps its subgroups.
  Future<void> renameGroup(String from, String to) => _change(() async {
    final next = [
      for (final h in state)
        h.group == from || h.group.startsWith('$from/')
            ? h.copyWith(group: normalizeGroup(to + h.group.substring(from.length)))
            : h,
    ];
    await _write(next);
    state = next;
  });

  Future<void> delete(Host host) => _change(() async {
    final current = byId(host.id);
    if (current == null) return;
    final next = state.where((h) => h.id != host.id).toList();
    await _write(next);
    state = next;
    await ref.read(hostCredentialCleanupProvider).clearHost(host.id, current.proxy?.key ?? '');
  });

  Future<void> _write(List<Host> hosts, {int? expectedRevision}) => _file.write({
    'schemaVersion': 1,
    'hosts': [for (final h in hosts) h.toJson()],
  }, expectedRevision: expectedRevision);
}

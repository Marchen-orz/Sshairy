import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../foundation/data_dir.dart';
import '../../../foundation/ids.dart' as ids;
import '../../../foundation/ids.dart' show HostId;
import '../../../foundation/json_file.dart';
import '../../credentials/api.dart';
import '../domain/host.dart';
import '../domain/host_validation.dart';

final hostsProvider = NotifierProvider<HostsNotifier, List<Host>>(
  HostsNotifier.new,
);

class HostsNotifier extends Notifier<List<Host>> {
  late final JsonFile _file = JsonFile(
    '${ref.read(dataDirProvider)}/hosts.json',
    backups: true,
  );

  @override
  List<Host> build() {
    final list = _file.read()?['hosts'] as List<dynamic>? ?? const [];
    return [for (final j in list) Host.fromJson(j as Map<String, dynamic>)];
  }

  static HostId newId() => HostId(ids.newId());

  /// Completes once every write issued so far has landed.
  Future<void> get saved => _pending;

  Host? byId(HostId id) => state.where((h) => h.id == id).firstOrNull;

  Future<void> _pending = Future.value();

  Future<void> _change(Future<void> Function() action) {
    final next = _pending.then((_) => action());
    _pending = next.catchError((Object _) {});
    return next;
  }

  Future<void> save(Host host) => _change(() async {
    validateHost(host);
    final old = byId(host.id);
    if (old != null && old.proxy?.key != host.proxy?.key) {
      await ref.read(secretStoreProvider).delete(host.proxyRef);
    }
    final i = state.indexWhere((h) => h.id == host.id);
    final next = i < 0 ? [...state, host] : ([...state]..[i] = host);
    await _write(next);
    state = next;
  });

  Future<void> setPinned(Host host, bool pinned) =>
      _update(host.id, (current) => current.copyWith(pinned: pinned));

  /// Recorded when a session opens, for the "recent" order.
  Future<void> touch(HostId id) =>
      _update(id, (current) => current.copyWith(lastUsed: DateTime.now()));

  Future<void> _update(HostId id, Host Function(Host) update) =>
      _change(() async {
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
            ? h.copyWith(
                group: normalizeGroup(to + h.group.substring(from.length)),
              )
            : h,
    ];
    await _write(next);
    state = next;
  });

  Future<void> delete(Host host) => _change(() async {
    final next = state.where((h) => h.id != host.id).toList();
    await _write(next);
    state = next;
    final secrets = ref.read(secretStoreProvider);
    await secrets.delete(host.passwordRef);
    await secrets.delete(host.passphraseRef);
    await secrets.delete(host.proxyRef);
  });

  Future<void> _write(List<Host> hosts) => _file.write({
    'schemaVersion': 1,
    'hosts': [for (final h in hosts) h.toJson()],
  });
}

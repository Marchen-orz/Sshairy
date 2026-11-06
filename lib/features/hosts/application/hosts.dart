import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../foundation/data_dir.dart';
import '../../../foundation/ids.dart' as ids;
import '../../../foundation/ids.dart' show HostId;
import '../../../foundation/json_file.dart';
import '../../credentials/api.dart';
import '../domain/host.dart';

final hostsProvider = NotifierProvider<HostsNotifier, List<Host>>(HostsNotifier.new);

class HostsNotifier extends Notifier<List<Host>> {
  late final JsonFile _file = JsonFile('${ref.read(dataDirProvider)}/hosts.json');

  @override
  List<Host> build() {
    final list = _file.read()?['hosts'] as List<dynamic>? ?? const [];
    return [for (final j in list) Host.fromJson(j as Map<String, dynamic>)];
  }

  static HostId newId() => HostId(ids.newId());

  /// Completes once every write issued so far has landed.
  Future<void> get saved => _file.idle;

  Host? byId(HostId id) => state.where((h) => h.id == id).firstOrNull;

  Future<void> save(Host host) {
    final i = state.indexWhere((h) => h.id == host.id);
    state = i < 0 ? [...state, host] : ([...state]..[i] = host);
    return _persist();
  }

  Future<void> setPinned(Host host, bool pinned) => save(host.copyWith(pinned: pinned));

  /// Recorded when a session opens, for the "recent" order.
  Future<void> touch(HostId id) async {
    final host = byId(id);
    if (host != null) await save(host.copyWith(lastUsed: DateTime.now()));
  }

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
    );
    await save(copy);
    return copy;
  }

  /// Moves every host in [from] or below it under [to]; an empty [to] dissolves the group and keeps its subgroups.
  Future<void> renameGroup(String from, String to) {
    state = [
      for (final h in state)
        h.group == from || h.group.startsWith('$from/')
            ? h.copyWith(group: normalizeGroup(to + h.group.substring(from.length)))
            : h,
    ];
    return _persist();
  }

  Future<void> delete(Host host) async {
    state = state.where((h) => h.id != host.id).toList();
    await _persist();
    final secrets = ref.read(secretStoreProvider);
    await secrets.delete(host.passwordRef);
    await secrets.delete(host.passphraseRef);
  }

  Future<void> _persist() => _file.write({'schemaVersion': 1, 'hosts': [for (final h in state) h.toJson()]});
}

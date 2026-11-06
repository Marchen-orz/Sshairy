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

  Host? byId(HostId id) => state.where((h) => h.id == id).firstOrNull;

  Future<void> save(Host host) {
    final i = state.indexWhere((h) => h.id == host.id);
    state = i < 0 ? [...state, host] : ([...state]..[i] = host);
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

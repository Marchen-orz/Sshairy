import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../foundation/data_dir.dart';
import '../../credentials/api.dart';
import '../../hosts/api.dart';
import '../../settings/api.dart';
import '../adapters/ssh.dart';
import 'connection_manager.dart';
import 'host_trust.dart';

final hostTrustProvider = Provider<HostTrustService>((ref) => HostTrustService(ref.read(dataDirProvider)));

final connectionManagerProvider = Provider<ConnectionManager>((ref) {
  ({Duration timeout, Duration? keepAlive}) options() {
    final s = ref.read(settingsProvider);
    final keepAlive = s.get(SettingKeys.keepAlive);
    return (
      timeout: Duration(seconds: s.get(SettingKeys.connectTimeout)),
      keepAlive: keepAlive == 0 ? null : Duration(seconds: keepAlive),
    );
  }

  late final ConnectionManager manager;
  final dialer = SshDialer(
    ref.read(hostTrustProvider),
    ref.read(secretStoreProvider),
    options,
    (id) => ref.read(keysProvider.notifier).byId(id),
    (route, prompts, cancel) => manager.acquireRoute(route, prompts, cancel: cancel),
  );
  manager = ConnectionManager.routed(
    dialer.dial,
    (id) => ref.read(hostsProvider.notifier).byId(id),
    park: Duration(seconds: ref.read(settingsProvider).get(SettingKeys.idleTtl)),
  );
  ref.listen(settingsProvider.select((s) => s.get(SettingKeys.idleTtl)), (_, v) => manager.park = Duration(seconds: v));
  ref.onDispose(manager.closeAll);
  return manager;
});

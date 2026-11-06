import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../foundation/data_dir.dart';
import '../credentials/api.dart';
import 'adapters/ssh.dart';
import 'application/connection_manager.dart';
import 'application/host_trust.dart';

export 'application/connection_manager.dart' show ConnectionManager, LeasePurpose, TransportLease;
export 'application/host_trust.dart' show HostTrustService;
export 'domain/prompts.dart' show ConnectError, ConnectFailure, ConnectPrompts;
export 'domain/transport.dart' show ExecResult, ShellChannel;
export 'presentation/dialog_prompts.dart';

final hostTrustProvider = Provider<HostTrustService>((ref) => HostTrustService(ref.read(dataDirProvider)));

final connectionManagerProvider = Provider<ConnectionManager>((ref) {
  final dialer = SshDialer(ref.read(hostTrustProvider), ref.read(secretStoreProvider));
  final manager = ConnectionManager(dialer.dial);
  ref.onDispose(manager.closeAll);
  return manager;
});

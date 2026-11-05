import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../foundation/data_dir.dart';
import '../credentials/api.dart';
import 'adapters/ssh.dart';

export 'adapters/ssh.dart' show Connector, SshShell;
export 'domain/prompts.dart' show ConnectError, ConnectFailure, ConnectPrompts;
export 'presentation/dialog_prompts.dart';

final connectorProvider = Provider<Connector>(
  (ref) => Connector(TrustStore(ref.read(dataDirProvider)), ref.read(secretStoreProvider)),
);

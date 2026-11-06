import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/insertion.dart';

/// The window supplies confirmation; business callers never retain a BuildContext.
class TerminalInsertUi {
  ConfirmInsert? confirm;
}

final terminalInsertUiProvider = Provider<TerminalInsertUi>((_) => TerminalInsertUi());

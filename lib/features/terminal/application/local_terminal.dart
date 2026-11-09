import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../adapters/local_shells.dart';
import '../adapters/windows_pty.dart';
import '../domain/local_pty.dart';
import '../domain/terminal_target.dart';

final localShellsProvider = Provider<List<LocalShell>>((_) => discoverLocalShells());
final localPtyProvider = Provider<LocalPtyFactory>((_) => const WindowsPtyFactory());

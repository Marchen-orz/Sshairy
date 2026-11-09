import 'dart:typed_data';

import '../../../foundation/cancellation.dart';
import 'terminal_target.dart';

/// A local process in a real pseudoterminal, separate from SSH transport ownership.
abstract interface class LocalPty {
  Stream<Uint8List> get output;
  Future<int> get exitCode;
  void write(Uint8List data);
  void resize(int cols, int rows);
  void close();
}

abstract interface class LocalPtyFactory {
  Future<LocalPty> start(LocalShell shell, {required int cols, required int rows, CancellationToken? cancel});
}

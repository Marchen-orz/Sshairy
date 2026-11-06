import 'dart:typed_data';

/// One authenticated SSH connection. Callers reach it only through a lease (docs/CONTRACTS.md §2).
abstract interface class Transport {
  /// Completes when the connection is gone, whoever closed it.
  Future<void> get done;
  bool get isClosed;

  Future<ShellChannel> openShell({required int cols, required int rows});

  /// Runs [command] without a terminal and collects at most [limit] bytes of each stream.
  Future<ExecResult> exec(String command, {int limit});

  void close();
}

abstract interface class ShellChannel {
  Stream<Uint8List> get stdout;
  Stream<Uint8List> get stderr;
  Future<void> get done;
  void write(Uint8List data);
  void resize(int cols, int rows);
  void close();
}

class ExecResult {
  const ExecResult(this.stdout, this.stderr, this.exitCode, {this.truncated = false});

  final Uint8List stdout, stderr;

  /// Null when the server sent no exit status, which is not the same as success.
  final int? exitCode;
  final bool truncated;
}

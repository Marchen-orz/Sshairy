import 'dart:async';
import 'dart:typed_data';

import '../../../foundation/file_system.dart';

/// One authenticated SSH connection. Callers reach it only through a lease (docs/CONTRACTS.md §2).
abstract interface class Transport {
  /// Completes when the connection is gone, whoever closed it.
  Future<void> get done;
  bool get isClosed;

  /// [environment] goes with the pty request; a server that refuses it gets the shell without it.
  Future<ShellChannel> openShell({required int cols, required int rows, Map<String, String> environment});

  /// An SFTP channel of its own; closing it leaves the transport and its other channels alone.
  Future<FileSystem> openFiles();

  /// Runs [command] without a terminal and collects at most [limit] bytes of each stream.
  Future<ExecResult> exec(String command, {int limit});

  /// A TCP connection from the server to [host]:[port] (direct-tcpip): local and dynamic forwards, jump hops.
  Future<Tunnel> connectTo(String host, int port);

  /// Asks the server to listen on [host]:[port] and hand each connection over (tcpip-forward); port 0 lets the
  /// server pick. Throws [ConnectError] when the server refuses.
  Future<RemoteListener> listen(String host, int port);

  void close();
}

abstract interface class ShellChannel {
  Stream<Uint8List> get stdout;
  Stream<Uint8List> get stderr;
  Future<void> get done;
  void write(Uint8List data);
  void resize(int cols, int rows);

  /// Ends the channel in both directions at once, so the server hangs up the shell. Closing only our side would
  /// leave a login shell running (a pty does not end on EOF) and the channel registered until the connection ends.
  void close();
}

/// A byte stream carried in an SSH channel.
abstract interface class Tunnel {
  Stream<Uint8List> get stream;
  StreamSink<List<int>> get sink;
  Future<void> get done;

  /// Ends our side; data still in flight from the other side may arrive.
  Future<void> close();
  Future<void> flush();
  void destroy();
}

/// A port the server listens on for us.
abstract interface class RemoteListener {
  /// The port the server bound, which differs from the request when that was 0.
  int get port;
  Stream<Tunnel> get connections;

  /// True once the server confirmed it stopped listening; false when it refused or the connection is gone, so
  /// the port may still be open.
  Future<bool> close();
}

class ExecResult {
  const ExecResult(this.stdout, this.stderr, this.exitCode, {this.truncated = false});

  final Uint8List stdout, stderr;

  /// Null when the server sent no exit status, which is not the same as success.
  final int? exitCode;
  final bool truncated;
}

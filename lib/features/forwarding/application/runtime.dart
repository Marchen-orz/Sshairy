import 'dart:async';
import 'dart:typed_data';

import '../../../foundation/cancellation.dart';

/// A TCP connection on this computer.
abstract interface class LocalConnection {
  Stream<Uint8List> get stream;
  StreamSink<List<int>> get sink;
  Future<void> get done;
  Future<void> flush();
  void destroy();
}

abstract interface class LocalListener {
  /// The port bound, which differs from the request when that was 0.
  int get port;
  Stream<LocalConnection> get connections;

  /// Completes once the port is released; throws when that could not be confirmed.
  Future<void> close();
}

/// The local network, so the manager runs without sockets in tests.
abstract interface class ForwardRuntime {
  /// Throws [ForwardError] with addressInUse, permissionDenied, addressUnavailable or bindFailed.
  Future<LocalListener> listen(String address, int port);

  /// Throws [ForwardError] with timeout or targetFailed. Cancelling abandons the attempt.
  Future<LocalConnection> connect(
    String host,
    int port, {
    required Duration timeout,
    required CancellationToken cancel,
  });
}

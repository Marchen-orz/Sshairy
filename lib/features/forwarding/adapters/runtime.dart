import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../../../foundation/cancellation.dart';
import '../application/runtime.dart';
import '../domain/forward.dart';

/// Sockets from dart:io.
class IoForwardRuntime implements ForwardRuntime {
  const IoForwardRuntime();

  @override
  Future<LocalListener> listen(String address, int port) async {
    try {
      return _Listener(await ServerSocket.bind(address, port));
    } on SocketException catch (e) {
      // Linux, macOS and Windows number the same causes differently.
      final code = switch (e.osError?.errorCode) {
        98 || 48 || 10048 => ForwardErrors.addressInUse,
        13 || 10013 => ForwardErrors.permissionDenied,
        99 || 49 || 10049 => ForwardErrors.addressUnavailable,
        _ => ForwardErrors.bindFailed,
      };
      throw ForwardError(code, e.message);
    }
  }

  @override
  Future<LocalConnection> connect(
    String host,
    int port, {
    required Duration timeout,
    required CancellationToken cancel,
  }) async {
    var timedOut = false, settled = false;
    Timer? timer;
    try {
      final task = await Socket.startConnect(host, port);
      timer = Timer(timeout, () {
        timedOut = true;
        task.cancel();
      });
      cancel.whenCancelled.then((_) {
        if (!settled) task.cancel();
      }).ignore();
      return _Connection(await task.socket);
    } on SocketException catch (e) {
      throw ForwardError(timedOut ? ForwardErrors.timeout : ForwardErrors.targetFailed, e.message);
    } finally {
      settled = true;
      timer?.cancel();
    }
  }
}

class _Listener implements LocalListener {
  _Listener(this._server);
  final ServerSocket _server;

  @override
  int get port => _server.port;

  @override
  Stream<LocalConnection> get connections => _server.map(_Connection.new);

  @override
  Future<void> close() async {
    await _server.close();
  }
}

class _Connection implements LocalConnection {
  _Connection(this._socket) {
    _socket.setOption(SocketOption.tcpNoDelay, true);
    // A write error also fails `done`; the relay watches it, nobody else needs to.
    _socket.done.ignore();
  }
  final Socket _socket;

  @override
  Stream<Uint8List> get stream => _socket;
  @override
  StreamSink<List<int>> get sink => _socket;
  @override
  Future<void> get done => _socket.done;
  @override
  Future<void> flush() => _socket.flush();
  @override
  void destroy() => _socket.destroy();
}

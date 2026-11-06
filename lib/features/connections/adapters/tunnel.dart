import 'dart:async';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import '../domain/transport.dart';

class SshTunnel implements Tunnel {
  SshTunnel(this._channel);
  final SSHForwardChannel _channel;

  @override
  Stream<Uint8List> get stream => _channel.stream;
  @override
  StreamSink<List<int>> get sink => _channel.sink;
  @override
  Future<void> get done => _channel.done;
  @override
  Future<void> close() => _channel.close();
  @override
  Future<void> flush() => _channel.flush();
  @override
  void destroy() => _channel.destroy();
}

class TunnelSocket implements SSHSocket {
  TunnelSocket(this._tunnel);
  final Tunnel _tunnel;

  @override
  Stream<Uint8List> get stream => _tunnel.stream;
  @override
  StreamSink<List<int>> get sink => _tunnel.sink;
  @override
  Future<void> get done => _tunnel.done;
  @override
  Future<void> close() => _tunnel.close();
  @override
  Future<void> flush() => _tunnel.flush();
  @override
  void destroy() => _tunnel.destroy();
}

class SshRemoteListener implements RemoteListener {
  SshRemoteListener(this._client, this._forward);
  final SSHClient _client;
  final SSHRemoteForward _forward;
  Future<bool>? _closing;

  @override
  int get port => _forward.port;
  @override
  Stream<Tunnel> get connections => _forward.connections.map(SshTunnel.new);

  @override
  Future<bool> close() => _closing ??= _close();

  Future<bool> _close() async {
    try {
      final stopped = await _client.cancelForwardRemote(_forward).timeout(const Duration(seconds: 15));
      if (stopped) _forward.close();
      return stopped;
    } on Object {
      return false;
    }
  }
}

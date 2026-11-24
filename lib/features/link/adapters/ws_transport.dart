import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../domain/protocol.dart';
import '../domain/transport.dart';

/// Direct WebSocket transport over LAN, Tailscale, or WireGuard.
class DirectWsLinkTransport implements LinkTransport {
  DirectWsLinkTransport(this._socket, this.remoteLabel) {
    _socket.pingInterval = const Duration(seconds: 10);
    _sub = _socket.listen(
      (event) {
        if (_messages.isClosed) return;
        final Uint8List bytes;
        if (event is Uint8List) {
          bytes = event;
        } else if (event is List<int>) {
          bytes = Uint8List.fromList(event);
        } else if (event is String) {
          bytes = Uint8List.fromList(utf8.encode(event));
        } else {
          return;
        }
        if (bytes.length > linkMaxFrameBytes + 128) {
          unawaited(close());
          return;
        }
        _messages.add(bytes);
      },
      onError: (Object e, StackTrace st) {
        if (!_messages.isClosed) _messages.addError(e, st);
        _finish();
      },
      onDone: _finish,
      cancelOnError: false,
    );
  }

  final WebSocket _socket;
  @override
  final String remoteLabel;
  final _messages = StreamController<Uint8List>();
  final _done = Completer<void>();
  StreamSubscription<dynamic>? _sub;
  var _closed = false;

  void _finish() {
    _closed = true;
    if (!_done.isCompleted) _done.complete();
    if (!_messages.isClosed) unawaited(_messages.close());
  }

  @override
  Stream<Uint8List> get messages => _messages.stream;

  @override
  Future<void> get done => _done.future;

  @override
  bool get isClosed => _closed || _socket.readyState != WebSocket.open;

  @override
  Future<void> send(Uint8List frame) async {
    if (isClosed) throw const LinkException(LinkErrorKind.network, 'websocket closed');
    _socket.add(frame);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await _socket.close(WebSocketStatus.normalClosure);
    } on Object {
      // already gone
    }
    await _sub?.cancel();
    _finish();
  }

  static Future<DirectWsLinkTransport> connect(
    String host,
    int port, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final uri = Uri(scheme: 'ws', host: host.trim(), port: port, path: '/link');
    try {
      final socket = await WebSocket.connect(uri.toString()).timeout(timeout);
      return DirectWsLinkTransport(socket, '$host:$port');
    } on Object catch (e) {
      throw LinkException(LinkErrorKind.network, '$e');
    }
  }
}

/// Direct HTTP/WebSocket listener bound on the desktop side when Sshairy Link is enabled.
class DirectWsLinkListener implements LinkListener {
  DirectWsLinkListener._(this._server) {
    _server.listen((request) {
      unawaited(_handle(request));
    }, onError: (Object _) {});
  }

  final HttpServer _server;
  final _connections = StreamController<LinkTransport>.broadcast();
  var _closed = false;

  @override
  Stream<LinkTransport> get connections => _connections.stream;

  @override
  int get port => _server.port;

  static Future<DirectWsLinkListener> bind(int port, {InternetAddress? address}) async {
    final server = await HttpServer.bind(address ?? InternetAddress.anyIPv4, port);
    return DirectWsLinkListener._(server);
  }

  Future<void> _handle(HttpRequest request) async {
    if (_closed || request.uri.path != '/link' || !WebSocketTransformer.isUpgradeRequest(request)) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    final remote = request.connectionInfo?.remoteAddress.address ?? 'unknown';
    final remotePort = request.connectionInfo?.remotePort ?? 0;
    try {
      final ws = await WebSocketTransformer.upgrade(request);
      if (_closed) {
        await ws.close();
        return;
      }
      _connections.add(DirectWsLinkTransport(ws, '$remote:$remotePort'));
    } on Object {
      // malformed upgrade dropped quietly
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _server.close(force: true);
    if (!_connections.isClosed) await _connections.close();
  }
}

/// Lists non-loopback IPv4 addresses on this machine for display in desktop Link settings and pairing URIs.
Future<List<String>> localLinkAddresses() async {
  try {
    final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4, includeLoopback: false);
    final result = <String>[];
    for (final iface in interfaces) {
      for (final addr in iface.addresses) {
        if (!addr.isLoopback && !addr.address.startsWith('169.254.')) {
          result.add(addr.address);
        }
      }
    }
    return result;
  } on Object {
    return const [];
  }
}

const _discoveryProbeMagic = 'sshairy-link-probe-v1';

/// Responds to LAN UDP discovery probes with non-sensitive desktop identity and WebSocket port only.
class LanDiscoveryResponder {
  LanDiscoveryResponder._(this._socket);

  final RawDatagramSocket _socket;

  static Future<LanDiscoveryResponder?> start({
    required String Function() deviceId,
    required String Function() deviceName,
    required int Function() wsPort,
    int discoveryPort = linkDiscoveryPort,
  }) async {
    try {
      final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, discoveryPort, reuseAddress: true);
      socket.broadcastEnabled = true;
      socket.listen((event) {
        if (event != RawSocketEvent.read) return;
        final dg = socket.receive();
        if (dg == null || dg.data.length > 256) return;
        final text = utf8.decode(dg.data, allowMalformed: true).trim();
        if (text != _discoveryProbeMagic) return;
        final reply = utf8.encode(
          jsonEncode({
            'magic': 'sshairy-link-here-v1',
            'protocol': linkProtocolVersion,
            'deviceId': deviceId(),
            'deviceName': deviceName(),
            'port': wsPort(),
          }),
        );
        try {
          socket.send(reply, dg.address, dg.port);
        } on Object {
          // best effort
        }
      }, onError: (Object _) {});
      return LanDiscoveryResponder._(socket);
    } on Object {
      return null;
    }
  }

  void close() => _socket.close();
}

/// Sends a LAN UDP broadcast probe from mobile to discover nearby desktops running Sshairy Link.
Future<List<DiscoveredDesktop>> discoverLanDesktops({
  int discoveryPort = linkDiscoveryPort,
  Duration wait = const Duration(milliseconds: 750),
}) async {
  RawDatagramSocket? socket;
  try {
    socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0, reuseAddress: true);
    socket.broadcastEnabled = true;
    final found = <String, DiscoveredDesktop>{};
    socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final dg = socket!.receive();
      if (dg == null || dg.data.length > 1024) return;
      try {
        final raw = jsonDecode(utf8.decode(dg.data));
        if (raw is! Map || raw['magic'] != 'sshairy-link-here-v1') return;
        if (raw['protocol'] != linkProtocolVersion) return;
        final id = raw['deviceId'] as String? ?? '';
        final name = raw['deviceName'] as String? ?? dg.address.address;
        final port = (raw['port'] as num?)?.toInt() ?? 0;
        if (id.isEmpty || port < 1 || port > 65535) return;
        found[id] = DiscoveredDesktop(
          deviceId: id,
          name: name,
          address: dg.address.address,
          port: port,
          discoveredAt: DateTime.now(),
        );
      } on Object {
        // ignore malformed packets
      }
    }, onError: (Object _) {});
    final probe = utf8.encode(_discoveryProbeMagic);
    final addresses = await localLinkAddresses();
    void sendProbe() {
      try {
        socket!.send(probe, InternetAddress('255.255.255.255'), discoveryPort);
      } on Object {
        // broadcast may be blocked on some interfaces
      }
      // The limited broadcast leaves through one interface only; each local /24 also gets a directed broadcast.
      for (final address in addresses) {
        try {
          socket!.send(probe, InternetAddress('${address.substring(0, address.lastIndexOf('.'))}.255'), discoveryPort);
        } on Object {
          // an interface may refuse broadcasts
        }
      }
      try {
        socket!.send(probe, InternetAddress.loopbackIPv4, discoveryPort);
      } on Object {
        // loopback probe helps local preview/testing
      }
    }

    sendProbe();
    final retryDelay = wait > const Duration(milliseconds: 300) ? const Duration(milliseconds: 220) : Duration.zero;
    if (retryDelay > Duration.zero) {
      await Future<void>.delayed(retryDelay);
      sendProbe();
      await Future<void>.delayed(wait - retryDelay);
    } else {
      await Future<void>.delayed(wait);
    }
    return found.values.toList();
  } on Object {
    return const [];
  } finally {
    socket?.close();
  }
}

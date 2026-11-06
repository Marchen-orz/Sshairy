import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import '../../../foundation/secret.dart';
import '../../../foundation/cancellation.dart';
import '../../hosts/api.dart';
import '../domain/prompts.dart';

/// Opens a TCP connection to [host]:[port] through [proxy] (docs/MODULES.md §2). [password] is called only when
/// the proxy needs one; null means the user cancelled.
Future<SSHSocket> connectViaProxy(
  Proxy proxy,
  String host,
  int port, {
  required Duration timeout,
  required CancellationToken cancel,
  required Future<Secret?> Function() password,
}) async {
  if (host.isEmpty || RegExp(r'[\s\x00-\x1f\x7f]').hasMatch(host) || port < 1 || port > 65535) {
    throw const ConnectError(ConnectFailure.route, 'invalidTarget');
  }
  final Socket socket;
  try {
    socket = await Socket.connect(proxy.address, proxy.port, timeout: timeout);
  } on Object catch (e) {
    throw ConnectError(ConnectFailure.network, 'proxy: $e');
  }
  if (cancel.isCancelled) {
    socket.destroy();
    throw const ConnectError(ConnectFailure.cancelled);
  }
  cancel.whenCancelled.then((_) => socket.destroy()).ignore();
  final reader = _Reader(socket);
  try {
    // The user may take a while to type the password; only the proxy's own replies are timed.
    await switch (proxy.kind) {
      ProxyKind.socks5 => _socks5(socket, reader, proxy.username, host, port, timeout, password),
      ProxyKind.http => _http(socket, reader, proxy.username, host, port, timeout, password),
    };
  } on Object catch (e) {
    socket.destroy();
    if (cancel.isCancelled) throw const ConnectError(ConnectFailure.cancelled);
    if (e is ConnectError) rethrow;
    throw ConnectError(ConnectFailure.network, 'proxy: $e');
  }
  return _ProxiedSocket(socket, reader.detach());
}

Future<void> _socks5(
  Socket socket,
  _Reader r,
  String user,
  String host,
  int port,
  Duration timeout,
  Future<Secret?> Function() password,
) async {
  socket.add([
    5,
    if (user.isEmpty) ...[1, 0] else ...[2, 0, 2],
  ]);
  final choice = await r.take(2).timeout(timeout);
  if (choice[0] != 5) throw const ConnectError(ConnectFailure.network, 'proxy: not a SOCKS5 server');
  switch (choice[1]) {
    case 0:
      break;
    case 2 when user.isNotEmpty:
      final secret = await password();
      if (secret == null) throw const ConnectError(ConnectFailure.cancelled);
      final u = utf8.encode(user), p = utf8.encode(secret.reveal());
      if (u.length > 255 || p.length > 255) throw const ConnectError(ConnectFailure.auth, proxyAuthDetail);
      socket.add([1, u.length, ...u, p.length, ...p]);
      final status = await r.take(2).timeout(timeout);
      if (status[0] != 1 || status[1] != 0) throw const ConnectError(ConnectFailure.auth, proxyAuthDetail);
    default:
      // 0xFF: none of the offered methods; without a username that means the proxy wants one.
      throw const ConnectError(ConnectFailure.auth, proxyAuthDetail);
  }
  socket.add([5, 1, 0, ..._socksAddress(host), port >> 8, port & 0xFF]);
  final head = await r.take(4).timeout(timeout);
  if (head[0] != 5 || head[2] != 0) throw const ConnectError(ConnectFailure.network, 'proxy: bad SOCKS5 reply');
  if (head[1] != 0) throw ConnectError(ConnectFailure.network, 'proxy: ${_socksError(head[1])}');
  final length = switch (head[3]) {
    1 => 4,
    4 => 16,
    3 => (await r.take(1).timeout(timeout))[0],
    _ => throw const ConnectError(ConnectFailure.network, 'proxy: bad SOCKS5 reply'),
  };
  await r.take(length + 2).timeout(timeout);
}

/// IP literals go as addresses; names go as names, so the proxy resolves them.
List<int> _socksAddress(String host) {
  final ip = InternetAddress.tryParse(host);
  if (ip != null) return [ip.type == InternetAddressType.IPv6 ? 4 : 1, ...ip.rawAddress];
  final name = utf8.encode(host);
  if (name.length > 255) throw const ConnectError(ConnectFailure.network, 'proxy: host name too long');
  return [3, name.length, ...name];
}

String _socksError(int code) => switch (code) {
  1 => 'general failure',
  2 => 'not allowed by ruleset',
  3 => 'network unreachable',
  4 => 'host unreachable',
  5 => 'connection refused',
  6 => 'TTL expired',
  7 => 'command not supported',
  8 => 'address type not supported',
  _ => 'SOCKS5 error $code',
};

Future<void> _http(
  Socket socket,
  _Reader r,
  String user,
  String host,
  int port,
  Duration timeout,
  Future<Secret?> Function() password,
) async {
  if (user.contains(':')) throw const ConnectError(ConnectFailure.auth, proxyAuthDetail);
  final target = host.contains(':') ? '[$host]:$port' : '$host:$port';
  var auth = '';
  if (user.isNotEmpty) {
    final secret = await password();
    if (secret == null) throw const ConnectError(ConnectFailure.cancelled);
    auth = 'Proxy-Authorization: Basic ${base64.encode(utf8.encode('$user:${secret.reveal()}'))}\r\n';
  }
  socket.add(utf8.encode('CONNECT $target HTTP/1.1\r\nHost: $target\r\n$auth\r\n'));
  final head = await r.headers().timeout(timeout);
  final status = RegExp(r'^HTTP/1\.[01] (\d{3})').firstMatch(head);
  if (status == null) throw const ConnectError(ConnectFailure.network, 'proxy: bad HTTP reply');
  final code = int.parse(status[1]!);
  if (code == 407) throw const ConnectError(ConnectFailure.auth, proxyAuthDetail);
  if (code ~/ 100 != 2) throw ConnectError(ConnectFailure.network, 'proxy: HTTP $code');
}

/// Reads the proxy's replies, then hands everything after them, such as the SSH banner, to [detach].
class _Reader {
  _Reader(Socket socket) {
    _sub = socket.listen(
      (d) {
        _buffer.addAll(d);
        if (_buffer.length > 64 << 10) {
          _error = const ConnectError(ConnectFailure.network, 'proxy: reply too long');
          socket.destroy();
        }
        _wake();
      },
      onError: (Object e) {
        _error = e;
        _wake();
      },
      onDone: () {
        _closed = true;
        _wake();
      },
    );
  }

  late final StreamSubscription<Uint8List> _sub;
  final _buffer = <int>[];
  Completer<void>? _more;
  Object? _error;
  var _closed = false;

  void _wake() {
    _more?.complete();
    _more = null;
  }

  Future<void> _wait() {
    if (_error != null) throw ConnectError(ConnectFailure.network, 'proxy: $_error');
    if (_closed) throw const ConnectError(ConnectFailure.network, 'proxy closed the connection');
    return (_more ??= Completer<void>()).future;
  }

  Future<Uint8List> take(int n) async {
    if (_error != null) throw _error!;
    while (_buffer.length < n) {
      await _wait();
    }
    final out = Uint8List.fromList(_buffer.sublist(0, n));
    _buffer.removeRange(0, n);
    return out;
  }

  /// An HTTP response head, at most 16 KiB.
  Future<String> headers() async {
    const end = [13, 10, 13, 10];
    for (;;) {
      for (var i = 0; i + 4 <= _buffer.length; i++) {
        if (_buffer[i] == end[0] && _buffer[i + 1] == end[1] && _buffer[i + 2] == end[2] && _buffer[i + 3] == end[3]) {
          if (i + 4 > 16 << 10) throw const ConnectError(ConnectFailure.network, 'proxy: reply too long');
          return latin1.decode(await take(i + 4));
        }
      }
      if (_buffer.length > 16 << 10) throw const ConnectError(ConnectFailure.network, 'proxy: reply too long');
      await _wait();
    }
  }

  Stream<Uint8List> detach() {
    _sub.pause();
    final out = StreamController<Uint8List>(
      onListen: _sub.resume,
      onPause: _sub.pause,
      onResume: _sub.resume,
      onCancel: _sub.cancel,
    );
    if (_buffer.isNotEmpty) out.add(Uint8List.fromList(_buffer));
    _buffer.clear();
    _sub
      ..onData(out.add)
      ..onError(out.addError)
      ..onDone(out.close);
    if (_error != null) out.addError(_error!);
    if (_closed) out.close();
    return out.stream;
  }
}

class _ProxiedSocket implements SSHSocket {
  _ProxiedSocket(this._socket, this.stream);

  final Socket _socket;

  @override
  final Stream<Uint8List> stream;

  @override
  StreamSink<List<int>> get sink => _socket;

  @override
  Future<void> get done => _socket.done;

  @override
  Future<void> close() => _socket.close();

  @override
  void destroy() => _socket.destroy();

  @override
  Future<void> flush() => _socket.flush();
}

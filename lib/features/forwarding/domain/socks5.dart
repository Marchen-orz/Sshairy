import 'dart:typed_data';

/// Where a SOCKS5 client asked to go.
class Socks5Request {
  const Socks5Request(this.host, this.port);
  final String host;
  final int port;
}

/// Reply codes of RFC 1928 §6 that this server sends.
abstract final class Socks5Reply {
  static const succeeded = 0;
  static const failure = 1;
  static const hostUnreachable = 4;
  static const refused = 5;
  static const commandUnsupported = 7;
  static const addressUnsupported = 8;

  static Uint8List of(int code) => Uint8List.fromList([5, code, 0, 1, 0, 0, 0, 0, 0, 0]);
}

/// The client did not ask for CONNECT without authentication. [reply] is what to send before closing, if anything.
class Socks5Error implements Exception {
  const Socks5Error([this.reply]);
  final Uint8List? reply;
}

/// The server half of a SOCKS5 CONNECT exchange (RFC 1928): no authentication; domain, IPv4 and IPv6 targets.
/// Feed it what the client sends; once [request] is set the success or failure reply is the caller's to send.
class Socks5Handshake {
  static const _maxBytes = 600;

  final _buffer = <int>[];
  var _greeted = false;

  /// Set when the client's CONNECT request is complete.
  Socks5Request? request;

  /// What the client sent after the request.
  Uint8List rest = Uint8List(0);

  /// Returns the method-selection reply once the greeting is complete, otherwise null.
  /// Throws [Socks5Error] for anything this server does not serve.
  Uint8List? feed(List<int> data) {
    _buffer.addAll(data);
    Uint8List? reply;
    if (!_greeted) {
      if (_buffer.isNotEmpty && _buffer[0] != 5) throw const Socks5Error();
      if (_buffer.length < 2) return null;
      final end = 2 + _buffer[1];
      if (_buffer.length < end) return null;
      if (!_buffer.sublist(2, end).contains(0)) throw Socks5Error(Uint8List.fromList([5, 0xff]));
      _buffer.removeRange(0, end);
      _greeted = true;
      reply = Uint8List.fromList([5, 0]);
    }
    _parseRequest();
    if (request == null && _buffer.length > _maxBytes) throw const Socks5Error();
    return reply;
  }

  void _parseRequest() {
    final b = _buffer;
    if (b.length < 4) return;
    if (b[0] != 5) throw const Socks5Error();
    if (b[1] != 1) throw Socks5Error(Socks5Reply.of(Socks5Reply.commandUnsupported));
    var start = 4;
    final int length;
    switch (b[3]) {
      case 1:
        length = 4;
      case 4:
        length = 16;
      case 3:
        if (b.length < 5) return;
        start = 5;
        length = b[4];
      default:
        throw Socks5Error(Socks5Reply.of(Socks5Reply.addressUnsupported));
    }
    final end = start + length + 2;
    if (b.length < end) return;
    final bytes = b.sublist(start, start + length);
    final port = (b[end - 2] << 8) | b[end - 1];
    final host = switch (b[3]) {
      1 => bytes.join('.'),
      4 => [for (var i = 0; i < 16; i += 2) ((bytes[i] << 8) | bytes[i + 1]).toRadixString(16)].join(':'),
      _ => String.fromCharCodes(bytes),
    };
    final invalid = port == 0 || host.isEmpty || RegExp(r'[\s\x00-\x1f\x7f]').hasMatch(host);
    if (invalid) throw Socks5Error(Socks5Reply.of(Socks5Reply.failure));
    request = Socks5Request(host, port);
    rest = Uint8List.fromList(b.sublist(end));
    b.clear();
  }
}

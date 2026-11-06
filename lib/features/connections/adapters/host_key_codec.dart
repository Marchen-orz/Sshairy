import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

typedef HostKeyInfo = ({String type, String fingerprint});

/// Reads the public host keys of known_hosts lines: SSH wire format, nothing that needs the network.
abstract final class HostKeyCodec {
  static const _maxBlob = 16 * 1024;

  /// The key type and `SHA256:` fingerprint of [base64Data], or null when it is not canonical base64, is not
  /// well formed for its algorithm, or is not of the [declared] type written next to it.
  static HostKeyInfo? inspect(String declared, String base64Data) {
    final Uint8List blob;
    try {
      blob = base64.decode(base64Data);
    } on FormatException {
      return null;
    }
    if (blob.isEmpty || blob.length > _maxBlob || base64.encode(blob) != base64Data) return null;
    final reader = _Reader(blob);
    final type = reader.text();
    if (type == null || type != declared || !_wellFormed(type, reader) || !reader.done) return null;
    return (type: type, fingerprint: fingerprintOf(blob));
  }

  /// As `ssh-keygen -l` prints it: `SHA256:` and unpadded base64.
  static String fingerprintOf(Uint8List blob) =>
      'SHA256:${base64.encode(sha256.convert(blob).bytes).replaceAll('=', '')}';

  static bool _wellFormed(String type, _Reader r) {
    switch (type) {
      case 'ssh-ed25519':
        return r.bytes()?.length == 32;
      case 'ssh-rsa':
        final (e, n) = (r.bytes(), r.bytes());
        return e != null && n != null && _positive(e) && _positive(n) && e.length <= n.length && n.length <= 2049;
      case 'ecdsa-sha2-nistp256' || 'ecdsa-sha2-nistp384' || 'ecdsa-sha2-nistp521':
        final curve = r.text();
        final point = r.bytes();
        final size = switch (type) {
          'ecdsa-sha2-nistp256' => 65,
          'ecdsa-sha2-nistp384' => 97,
          _ => 133,
        };
        // An uncompressed point: 0x04, then x and y.
        return curve == type.substring('ecdsa-sha2-'.length) && point != null && point.length == size && point[0] == 4;
      default:
        return false;
    }
  }

  /// An SSH mpint holding a positive number: not empty, high bit clear, and no needless leading zero.
  static bool _positive(Uint8List m) => m.isNotEmpty && m[0] < 0x80 && (m[0] != 0 || (m.length > 1 && m[1] >= 0x80));
}

/// Recognises hashed `|1|salt|hash` names without reading them back.
abstract final class HashedHostMatcher {
  /// Whether [hash] is the HMAC-SHA1 of [name] keyed with [salt], as `ssh-keygen -H` writes it.
  static bool matches(List<int> salt, List<int> hash, String name) {
    final mac = Hmac(sha1, salt).convert(utf8.encode(name)).bytes;
    if (mac.length != hash.length) return false;
    var diff = 0;
    for (var i = 0; i < mac.length; i++) {
      diff |= mac[i] ^ hash[i];
    }
    return diff == 0;
  }

  /// What OpenSSH hashes for a host: the bare name on port 22, `[name]:port` otherwise.
  static String nameFor(String address, int port) => port == 22 ? address : '[$address]:$port';
}

class _Reader {
  _Reader(this._data);

  final Uint8List _data;
  var _at = 0;

  bool get done => _at == _data.length;

  /// A length-prefixed string; null when it does not fit in what is left.
  Uint8List? bytes() {
    if (_data.length - _at < 4) return null;
    final length = ByteData.sublistView(_data).getUint32(_at);
    _at += 4;
    if (length > _data.length - _at) return null;
    final value = Uint8List.sublistView(_data, _at, _at + length);
    _at += length;
    return value;
  }

  String? text() {
    final value = bytes();
    if (value == null) return null;
    try {
      return utf8.decode(value);
    } on FormatException {
      return null;
    }
  }
}

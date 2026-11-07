import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pointycastle/api.dart';
import 'package:pointycastle/block/desede_engine.dart';

import '../../../foundation/secret.dart';
import '../domain/host_import.dart';
import '../domain/ssh_config.dart';
import 'host_import_files.dart' show decodeImportText;

/// A selected source changed after preview; never attach its password to the old endpoint.
class ImportSourceChanged implements Exception {
  const ImportSourceChanged();
  @override
  String toString() => 'ImportSourceChanged';
}

/// Only user-selected FinalShell records enter this adapter. Results are short-lived, never provider state.
class FinalShellLogin {
  const FinalShellLogin();

  Future<Map<String, Secret>> load(String path, List<SshConfigHost> sources, {bool strict = false}) async {
    final result = <String, Secret>{};
    if (sources.isEmpty) return result;
    final folder = await FileSystemEntity.isDirectory(path);
    String root;
    try {
      root = folder ? await Directory(path).resolveSymbolicLinks() : await File(path).parent.resolveSymbolicLinks();
    } on FileSystemException {
      if (strict) throw const ImportSourceChanged();
      return result;
    }
    var bytesRead = 0;
    for (final source in sources) {
      try {
        final parts = source.file.split(RegExp(r'[/\\]'));
        if (folder && parts.any((p) => p.isEmpty || p == '..' || p == '.' || p.contains(':'))) {
          throw const ImportSourceChanged();
        }
        final file = File(folder ? '$root/${parts.join('/')}' : path);
        if (await FileSystemEntity.type(file.path, followLinks: false) != FileSystemEntityType.file) {
          throw const ImportSourceChanged();
        }
        final resolved = await file.resolveSymbolicLinks();
        if (!resolved.startsWith('$root${Platform.pathSeparator}')) throw const ImportSourceChanged();
        final size = await file.length();
        bytesRead += size;
        if (size > importMaxFileBytes || bytesRead > importMaxBytes) throw const ImportSourceChanged();
        final text = decodeImportText(await file.readAsBytes());
        final config = parseFinalShell([ImportText(source.file, text)], defaultUser: source.username);
        final current = config.hosts.singleOrNull;
        if (current == null ||
            current.blocked ||
            current.alias != source.alias ||
            current.address != source.address ||
            current.port != source.port ||
            current.username != source.username) {
          throw const ImportSourceChanged();
        }
        final data = jsonDecode(text) as Map;
        // A key reference may coexist with a stale account password; that is never a key passphrase.
        if ((data['secret_key_id']?.toString() ?? '').isNotEmpty ||
            (data['authentication_type'] != null && data['authentication_type'] != 1)) {
          continue;
        }
        final encoded = data['password'];
        if (encoded is String) {
          final password = decodeFinalShellPassword(encoded);
          if (password != null) result[source.key] = password;
        }
      } on Object {
        if (strict) throw const ImportSourceChanged();
      }
    }
    return result;
  }
}

/// Legacy FinalShell format: 8 signed header bytes, Java Random-derived MD5 key, DES/ECB/PKCS5Padding.
/// This is read compatibility only, never a format for new secrets (docs/HOST_IMPORT.md).
Secret? decodeFinalShellPassword(String encoded) {
  if (encoded.isEmpty || encoded.length > 65536) return null;
  try {
    final data = base64.decode(encoded);
    if (data.length < 16 || data.length % 8 != 0) return null;
    int signed(int i) => data[i] < 128 ? data[i] : data[i] - 256;
    final divisor = _JavaRandom(signed(5)).nextInt127();
    if (divisor == 0) return null;
    final random = _JavaRandom(3680984568597093857 ~/ divisor);
    for (var i = 0; i < signed(0); i++) {
      random.nextLong();
    }
    final second = _JavaRandom(random.nextLong());
    final material = ByteData(64);
    final values = [
      signed(4),
      second.nextLong(),
      signed(7),
      signed(3),
      second.nextLong(),
      signed(1),
      random.nextLong(),
      signed(2),
    ];
    for (var i = 0; i < values.length; i++) {
      material.setInt64(i * 8, values[i]);
    }
    final key = md5.convert(material.buffer.asUint8List()).bytes.take(8).toList();
    // EDE with two identical DES keys reduces to single DES, supplied by the maintained cipher library.
    final cipher = DESedeEngine()..init(false, KeyParameter(Uint8List.fromList([...key, ...key])));
    final plain = Uint8List(data.length - 8);
    try {
      for (var offset = 8; offset < data.length; offset += 8) {
        cipher.processBlock(data, offset, plain, offset - 8);
      }
      final padding = plain.last;
      if (padding < 1 || padding > 8 || plain.skip(plain.length - padding).any((b) => b != padding)) return null;
      final value = utf8.decode(plain.sublist(0, plain.length - padding));
      return value.isEmpty ? null : Secret(value);
    } finally {
      plain.fillRange(0, plain.length, 0);
    }
  } on Object {
    return null;
  }
}

class _JavaRandom {
  _JavaRandom(int seed) : _seed = (seed ^ 0x5deece66d) & _mask;
  static const _mask = (1 << 48) - 1;
  int _seed;
  int _next(int bits) {
    _seed = (_seed * 0x5deece66d + 11) & _mask;
    return _seed >> (48 - bits);
  }

  int nextInt127() {
    while (true) {
      final bits = _next(31), value = bits % 127;
      if (bits - value + 126 < 0x80000000) return value;
    }
  }

  int nextLong() {
    int signed32(int n) => n < 0x80000000 ? n : n - 0x100000000;
    return (signed32(_next(32)) << 32) + signed32(_next(32));
  }
}

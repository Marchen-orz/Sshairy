import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:pinenacl/ed25519.dart' as ed25519;

enum KeyProblem { unsupported, needsPassphrase, wrongPassphrase }

class KeyCodecException implements Exception {
  const KeyCodecException(this.problem, [this.detail = '']);

  final KeyProblem problem;
  final String detail;

  @override
  String toString() => 'KeyCodecException(${problem.name})';
}

/// What a private key reveals once opened: never the private part.
typedef KeyInfo = ({String algorithm, String publicKey, String fingerprint, bool encrypted});

/// OpenSSH, PKCS#1 RSA and SEC1 EC keys as dartssh2 reads them; nothing else is claimed.
abstract final class KeyCodec {
  static bool isEncrypted(String pem) {
    try {
      return SSHKeyPair.isEncryptedPem(pem);
    } on Object catch (e) {
      throw KeyCodecException(KeyProblem.unsupported, '$e');
    }
  }

  /// Opens [pem] to read its public half; an encrypted key needs [passphrase].
  static KeyInfo inspect(String pem, {String? passphrase, String comment = ''}) {
    final encrypted = isEncrypted(pem);
    if (encrypted && (passphrase == null || passphrase.isEmpty)) throw const KeyCodecException(KeyProblem.needsPassphrase);
    final List<SSHKeyPair> pairs;
    try {
      pairs = SSHKeyPair.fromPem(pem, encrypted ? passphrase : null);
    } on Object catch (e) {
      throw KeyCodecException(encrypted ? KeyProblem.wrongPassphrase : KeyProblem.unsupported, '$e');
    }
    if (pairs.isEmpty) throw const KeyCodecException(KeyProblem.unsupported);
    final pair = pairs.first;
    final blob = pair.toPublicKey().encode();
    return (
      algorithm: pair.name,
      publicKey: [pair.name, base64.encode(blob), if (comment.isNotEmpty) comment].join(' '),
      fingerprint: fingerprintOf(blob),
      encrypted: encrypted,
    );
  }

  /// `SHA256:` and unpadded base64, as `ssh-keygen -l` prints it.
  static String fingerprintOf(Uint8List blob) => 'SHA256:${base64.encode(sha256.convert(blob).bytes).replaceAll('=', '')}';

  /// A new Ed25519 key in OpenSSH format, unencrypted: the secure store is what protects it.
  static String generateEd25519({String comment = ''}) {
    final random = Random.secure();
    final seed = Uint8List.fromList(List.generate(32, (_) => random.nextInt(256)));
    final key = ed25519.SigningKey.fromSeed(seed);
    final pair = OpenSSHEd25519KeyPair(
      Uint8List.fromList(key.verifyKey.asTypedList),
      Uint8List.fromList(key.asTypedList),
      comment,
    );
    return pair.toPem();
  }
}

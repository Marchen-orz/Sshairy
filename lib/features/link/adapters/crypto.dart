import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pinenacl/ed25519.dart' as ed;
import 'package:pinenacl/x25519.dart' as x25519;

import '../domain/protocol.dart';
import '../domain/transport.dart';

/// Persistent Ed25519 device identity for Sshairy Link. The 32-byte seed lives only in OS secure storage.
class LinkIdentity {
  LinkIdentity._(this._signingKey, this.seedBase64)
    : publicKeyBytes = Uint8List.fromList(_signingKey.verifyKey.asTypedList),
      publicKeyBase64 = base64UrlEncode(_signingKey.verifyKey.asTypedList),
      deviceId = _deriveDeviceId(_signingKey.verifyKey.asTypedList);

  factory LinkIdentity.generate() {
    final random = Random.secure();
    final seed = Uint8List.fromList(List<int>.generate(32, (_) => random.nextInt(256)));
    return LinkIdentity.fromSeed(seed);
  }

  factory LinkIdentity.fromSeed(Uint8List seed) {
    if (seed.length != 32) throw ArgumentError('Ed25519 seed must be 32 bytes');
    return LinkIdentity._(ed.SigningKey.fromSeed(seed), base64UrlEncode(seed));
  }

  factory LinkIdentity.fromSeedBase64(String encoded) => LinkIdentity.fromSeed(base64Url.decode(encoded));

  final ed.SigningKey _signingKey;
  final String seedBase64;
  final Uint8List publicKeyBytes;
  final String publicKeyBase64;
  final String deviceId;

  static String _deriveDeviceId(List<int> pubKey) => base64UrlEncode(sha256.convert(pubKey).bytes.sublist(0, 16));

  Uint8List sign(Uint8List message) {
    final signed = _signingKey.sign(message);
    return Uint8List.fromList(signed.signature.asTypedList);
  }

  static bool verify(Uint8List publicKey, Uint8List message, Uint8List signature) {
    if (publicKey.length != 32 || signature.length != 64) return false;
    try {
      final key = ed.VerifyKey(publicKey);
      return key.verify(signature: ed.Signature(signature), message: message);
    } on Object {
      return false;
    }
  }
}

/// Authenticated and encrypted bidirectional JSON frame session using directional XSalsa20-Poly1305 SecretBox
/// with strict monotonic 64-bit sequence nonces to prevent replay, reordering, or tampering.
class LinkCipherSession {
  LinkCipherSession._({
    required this._transport,
    required Uint8List sendKey,
    required Uint8List recvKey,
    required this._sendDirTag,
    required this._recvDirTag,
    required this.peerDeviceId,
    required this.peerName,
    required this.peerPublicKey,
  }) : _sendBox = x25519.SecretBox(sendKey),
       _recvBox = x25519.SecretBox(recvKey);

  final LinkTransport _transport;
  final x25519.SecretBox _sendBox;
  final x25519.SecretBox _recvBox;
  final Uint8List _sendDirTag;
  final Uint8List _recvDirTag;

  final String peerDeviceId;
  final String peerName;
  final String peerPublicKey;

  int _sendSeq = 0;
  int _recvSeq = 0;
  Future<void> _sendChain = Future.value();
  bool _closed = false;

  bool get isClosed => _closed || _transport.isClosed;
  Future<void> get done => _transport.done;
  String get remoteLabel => _transport.remoteLabel;

  static Uint8List _nonce(Uint8List dirTag, int seq) {
    final out = Uint8List(24);
    out.setRange(0, 8, dirTag);
    final bd = ByteData.sublistView(out);
    bd.setUint64(8, seq, Endian.big);
    return out;
  }

  Future<void> sendMessage(Map<String, Object?> payload) {
    final next = _sendChain.then((_) async {
      if (isClosed) throw const LinkException(LinkErrorKind.network, 'session closed');
      final plain = Uint8List.fromList(utf8.encode(jsonEncode(payload)));
      if (plain.length > linkMaxFrameBytes) {
        throw const LinkException(LinkErrorKind.protocolError, 'frame exceeds max size');
      }
      final seq = _sendSeq++;
      final nonce = _nonce(_sendDirTag, seq);
      final encrypted = _sendBox.encrypt(plain, nonce: nonce);
      // Wire format: [8B seq BE][cipherText + 16B Poly1305 MAC]
      final frame = Uint8List(8 + encrypted.cipherText.length);
      ByteData.sublistView(frame).setUint64(0, seq, Endian.big);
      frame.setRange(8, frame.length, encrypted.cipherText);
      await _transport.send(frame);
    });
    _sendChain = next.catchError((Object _) {});
    return next;
  }

  Map<String, dynamic> decryptFrame(Uint8List frame) {
    if (frame.length < 8 + 16 || frame.length > linkMaxFrameBytes + 64) {
      throw const LinkException(LinkErrorKind.protocolError, 'invalid encrypted frame length');
    }
    final seq = ByteData.sublistView(frame).getUint64(0, Endian.big);
    if (seq != _recvSeq) {
      throw const LinkException(LinkErrorKind.protocolError, 'unexpected sequence number (replay/reorder)');
    }
    _recvSeq++;
    final nonce = _nonce(_recvDirTag, seq);
    final cipher = Uint8List.sublistView(frame, 8);
    final Uint8List plain;
    try {
      plain = _recvBox.decrypt(x25519.EncryptedMessage(nonce: nonce, cipherText: cipher));
    } on Object {
      throw const LinkException(LinkErrorKind.authFailed, 'frame authentication failed');
    }
    final decoded = jsonDecode(utf8.decode(plain));
    if (decoded is! Map) throw const LinkException(LinkErrorKind.protocolError, 'frame payload must be object');
    return decoded.cast<String, dynamic>();
  }

  Future<void> close() async {
    _closed = true;
    await _transport.close();
  }
}

final _c2sTag = Uint8List.fromList(utf8.encode('LNK1_C2S'));
final _s2cTag = Uint8List.fromList(utf8.encode('LNK1_S2C'));

Uint8List _randomBytes(int count) {
  final r = Random.secure();
  return Uint8List.fromList(List<int>.generate(count, (_) => r.nextInt(256)));
}

Uint8List _deriveKey(String label, Uint8List sharedSecret, Uint8List transcriptHash) {
  final data = BytesBuilder(copy: false)
    ..add(utf8.encode(label))
    ..add(sharedSecret)
    ..add(transcriptHash);
  return Uint8List.fromList(sha256.convert(data.toBytes()).bytes);
}

Uint8List _computeTranscriptHash({
  required String mode,
  required String clientDeviceId,
  required String clientPub,
  required String clientEphPub,
  required String clientNonce,
  required String serverDeviceId,
  required String serverPub,
  required String serverEphPub,
  required String serverNonce,
}) {
  final canonical = jsonEncode([
    linkProtocolVersion,
    mode,
    clientDeviceId,
    clientPub,
    clientEphPub,
    clientNonce,
    serverDeviceId,
    serverPub,
    serverEphPub,
    serverNonce,
  ]);
  return Uint8List.fromList(sha256.convert(utf8.encode(canonical)).bytes);
}

Uint8List computePairingProof(String pairingCode, Uint8List transcriptHash) =>
    Uint8List.fromList(Hmac(sha256, utf8.encode(pairingCode.trim())).convert(transcriptHash).bytes);

bool constantTimeEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

/// Computes a 32-byte X25519 shared secret via NaCl scalar multiplication.
Uint8List _x25519Shared(x25519.PrivateKey mine, Uint8List theirs) {
  final box = x25519.Box(myPrivateKey: mine, theirPublicKey: x25519.PublicKey(theirs));
  return Uint8List.fromList(box.sharedKey.asTypedList);
}

typedef ServerPeerVerifier =
    Future<({bool accepted, LinkErrorKind? error, bool newlyPaired})> Function({
      required String mode,
      required String clientDeviceId,
      required String clientName,
      required String clientPublicKey,
      required Uint8List transcriptHash,
      required Uint8List? pairProof,
    });

/// Runs the authenticated E2EE client handshake over [transport] and returns the active session + remaining stream.
Future<({LinkCipherSession session, Stream<Map<String, dynamic>> incoming, Map<String, dynamic> ready})>
performLinkClientHandshake({
  required LinkTransport transport,
  required LinkIdentity identity,
  required String deviceName,
  required bool pairing,
  String? pairingCode,
  String? expectedServerPublicKey,
  Duration timeout = const Duration(seconds: 12),
}) async {
  final mode = pairing ? 'pair' : 'connect';
  final ephPriv = x25519.PrivateKey.generate();
  final ephPubB64 = base64UrlEncode(ephPriv.publicKey.asTypedList);
  final clientNonce = base64UrlEncode(_randomBytes(32));

  final controller = StreamController<Uint8List>();
  final sub = transport.messages.listen(
    controller.add,
    onError: controller.addError,
    onDone: controller.close,
    cancelOnError: false,
  );
  final iterator = StreamIterator(controller.stream);

  Future<Uint8List> nextRaw() async {
    final hasNext = await iterator.moveNext().timeout(timeout);
    if (!hasNext) throw const LinkException(LinkErrorKind.network, 'connection closed during handshake');
    return iterator.current;
  }

  try {
    // 1. Send client hello
    await transport.send(
      Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'type': 'hello',
            'protocol': linkProtocolVersion,
            'mode': mode,
            'deviceId': identity.deviceId,
            'deviceName': deviceName,
            'publicKey': identity.publicKeyBase64,
            'ephPublicKey': ephPubB64,
            'nonce': clientNonce,
          }),
        ),
      ),
    );

    // 2. Receive server challenge
    final rawChallenge = await nextRaw();
    final challenge = (jsonDecode(utf8.decode(rawChallenge)) as Map).cast<String, dynamic>();
    if (challenge['type'] == 'error') {
      final code = challenge['code'] as String? ?? '';
      throw LinkException(
        LinkErrorKind.values.asNameMap()[code] ?? LinkErrorKind.authFailed,
        challenge['message'] as String? ?? '',
      );
    }
    if (challenge['type'] != 'challenge' || challenge['protocol'] != linkProtocolVersion) {
      throw const LinkException(LinkErrorKind.protocolError, 'expected challenge');
    }
    final serverDeviceId = challenge['deviceId'] as String? ?? '';
    final serverName = challenge['deviceName'] as String? ?? serverDeviceId;
    final serverPubB64 = challenge['publicKey'] as String? ?? '';
    final serverEphB64 = challenge['ephPublicKey'] as String? ?? '';
    final serverNonce = challenge['nonce'] as String? ?? '';
    final serverSigB64 = challenge['signature'] as String? ?? '';

    if (expectedServerPublicKey != null &&
        expectedServerPublicKey.isNotEmpty &&
        serverPubB64 != expectedServerPublicKey) {
      throw const LinkException(LinkErrorKind.authFailed, 'server public key mismatch');
    }
    final serverPubBytes = base64Url.decode(serverPubB64);
    if (LinkIdentity._deriveDeviceId(serverPubBytes) != serverDeviceId) {
      throw const LinkException(LinkErrorKind.authFailed, 'server deviceId mismatch');
    }

    final transcriptHash = _computeTranscriptHash(
      mode: mode,
      clientDeviceId: identity.deviceId,
      clientPub: identity.publicKeyBase64,
      clientEphPub: ephPubB64,
      clientNonce: clientNonce,
      serverDeviceId: serverDeviceId,
      serverPub: serverPubB64,
      serverEphPub: serverEphB64,
      serverNonce: serverNonce,
    );

    if (!LinkIdentity.verify(serverPubBytes, transcriptHash, base64Url.decode(serverSigB64))) {
      throw const LinkException(LinkErrorKind.authFailed, 'invalid server signature');
    }

    // 3. Derive directional session keys
    final shared = _x25519Shared(ephPriv, base64Url.decode(serverEphB64));
    final c2sKey = _deriveKey('sshairy-link-v1-c2s', shared, transcriptHash);
    final s2cKey = _deriveKey('sshairy-link-v1-s2c', shared, transcriptHash);

    final session = LinkCipherSession._(
      transport: transport,
      sendKey: c2sKey,
      recvKey: s2cKey,
      sendDirTag: _c2sTag,
      recvDirTag: _s2cTag,
      peerDeviceId: serverDeviceId,
      peerName: serverName,
      peerPublicKey: serverPubB64,
    );

    // 4. Send encrypted auth frame
    final sig = base64UrlEncode(identity.sign(transcriptHash));
    final proof = pairing && pairingCode != null ? base64UrlEncode(computePairingProof(pairingCode, transcriptHash)) : null;
    await session.sendMessage({
      'type': 'auth',
      'signature': sig,
      'pairProof': ?proof,
    });

    // 5. Receive encrypted ready frame
    final readyFrame = await nextRaw();
    final ready = session.decryptFrame(readyFrame);
    if (ready['type'] == 'error') {
      final code = ready['code'] as String? ?? '';
      throw LinkException(
        LinkErrorKind.values.asNameMap()[code] ?? LinkErrorKind.authFailed,
        ready['message'] as String? ?? '',
      );
    }
    if (ready['type'] != 'ready' || ready['accepted'] != true) {
      throw const LinkException(LinkErrorKind.authFailed, 'server rejected session');
    }

    // Forward remaining frames through session decryption
    final out = StreamController<Map<String, dynamic>>();
    unawaited(() async {
      try {
        while (await iterator.moveNext()) {
          if (out.isClosed) break;
          out.add(session.decryptFrame(iterator.current));
        }
      } on Object catch (e, st) {
        if (!out.isClosed) out.addError(e, st);
        await session.close();
      } finally {
        await sub.cancel();
        if (!out.isClosed) await out.close();
      }
    }());

    return (session: session, incoming: out.stream, ready: ready);
  } on Object {
    await iterator.cancel();
    await sub.cancel();
    await transport.close();
    rethrow;
  }
}

/// Runs the authenticated E2EE server handshake over [transport].
Future<({LinkCipherSession session, Stream<Map<String, dynamic>> incoming, bool newlyPaired})>
performLinkServerHandshake({
  required LinkTransport transport,
  required LinkIdentity identity,
  required String deviceName,
  required ServerPeerVerifier verifyPeer,
  Duration timeout = const Duration(seconds: 12),
}) async {
  final controller = StreamController<Uint8List>();
  final sub = transport.messages.listen(
    controller.add,
    onError: controller.addError,
    onDone: controller.close,
    cancelOnError: false,
  );
  final iterator = StreamIterator(controller.stream);

  Future<Uint8List> nextRaw() async {
    final hasNext = await iterator.moveNext().timeout(timeout);
    if (!hasNext) throw const LinkException(LinkErrorKind.network, 'client disconnected during handshake');
    return iterator.current;
  }

  Future<void> sendPlainError(LinkErrorKind kind, String message) async {
    try {
      await transport.send(
        Uint8List.fromList(utf8.encode(jsonEncode({'type': 'error', 'code': kind.name, 'message': message}))),
      );
    } on Object {
      // ignore send failure on teardown
    }
  }

  try {
    // 1. Read client hello
    final rawHello = await nextRaw();
    final hello = (jsonDecode(utf8.decode(rawHello)) as Map).cast<String, dynamic>();
    if (hello['type'] != 'hello' || hello['protocol'] != linkProtocolVersion) {
      await sendPlainError(LinkErrorKind.protocolError, 'unsupported protocol');
      throw const LinkException(LinkErrorKind.protocolError, 'unsupported protocol');
    }
    final mode = hello['mode'] as String? ?? '';
    if (mode != 'pair' && mode != 'connect') {
      await sendPlainError(LinkErrorKind.protocolError, 'invalid mode');
      throw const LinkException(LinkErrorKind.protocolError, 'invalid mode');
    }
    final clientDeviceId = hello['deviceId'] as String? ?? '';
    final clientName = (hello['deviceName'] as String? ?? clientDeviceId).trim();
    final clientPubB64 = hello['publicKey'] as String? ?? '';
    final clientEphB64 = hello['ephPublicKey'] as String? ?? '';
    final clientNonce = hello['nonce'] as String? ?? '';
    final clientPubBytes = base64Url.decode(clientPubB64);
    if (clientPubBytes.length != 32 || LinkIdentity._deriveDeviceId(clientPubBytes) != clientDeviceId) {
      await sendPlainError(LinkErrorKind.authFailed, 'invalid client identity');
      throw const LinkException(LinkErrorKind.authFailed, 'invalid client identity');
    }

    // 2. Generate ephemeral key and send signed challenge
    final ephPriv = x25519.PrivateKey.generate();
    final serverEphB64 = base64UrlEncode(ephPriv.publicKey.asTypedList);
    final serverNonce = base64UrlEncode(_randomBytes(32));

    final transcriptHash = _computeTranscriptHash(
      mode: mode,
      clientDeviceId: clientDeviceId,
      clientPub: clientPubB64,
      clientEphPub: clientEphB64,
      clientNonce: clientNonce,
      serverDeviceId: identity.deviceId,
      serverPub: identity.publicKeyBase64,
      serverEphPub: serverEphB64,
      serverNonce: serverNonce,
    );

    final serverSig = base64UrlEncode(identity.sign(transcriptHash));
    await transport.send(
      Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'type': 'challenge',
            'protocol': linkProtocolVersion,
            'deviceId': identity.deviceId,
            'deviceName': deviceName,
            'publicKey': identity.publicKeyBase64,
            'ephPublicKey': serverEphB64,
            'nonce': serverNonce,
            'signature': serverSig,
          }),
        ),
      ),
    );

    // 3. Derive directional session keys
    final shared = _x25519Shared(ephPriv, base64Url.decode(clientEphB64));
    final c2sKey = _deriveKey('sshairy-link-v1-c2s', shared, transcriptHash);
    final s2cKey = _deriveKey('sshairy-link-v1-s2c', shared, transcriptHash);

    final session = LinkCipherSession._(
      transport: transport,
      sendKey: s2cKey,
      recvKey: c2sKey,
      sendDirTag: _s2cTag,
      recvDirTag: _c2sTag,
      peerDeviceId: clientDeviceId,
      peerName: clientName.isEmpty ? clientDeviceId : clientName,
      peerPublicKey: clientPubB64,
    );

    // 4. Read & verify encrypted auth frame
    final authFrame = await nextRaw();
    final auth = session.decryptFrame(authFrame);
    if (auth['type'] != 'auth') {
      throw const LinkException(LinkErrorKind.protocolError, 'expected auth');
    }
    final clientSig = base64Url.decode(auth['signature'] as String? ?? '');
    if (!LinkIdentity.verify(clientPubBytes, transcriptHash, clientSig)) {
      await session.sendMessage({'type': 'error', 'code': LinkErrorKind.authFailed.name, 'message': 'bad signature'});
      throw const LinkException(LinkErrorKind.authFailed, 'invalid client signature');
    }
    final pairProof = auth['pairProof'] is String ? base64Url.decode(auth['pairProof'] as String) : null;

    final verdict = await verifyPeer(
      mode: mode,
      clientDeviceId: clientDeviceId,
      clientName: clientName.isEmpty ? clientDeviceId : clientName,
      clientPublicKey: clientPubB64,
      transcriptHash: transcriptHash,
      pairProof: pairProof,
    );
    if (!verdict.accepted) {
      final err = verdict.error ?? LinkErrorKind.authFailed;
      await session.sendMessage({'type': 'error', 'code': err.name, 'message': err.name});
      throw LinkException(err);
    }

    // 5. Send encrypted ready frame
    await session.sendMessage({
      'type': 'ready',
      'accepted': true,
      'deviceId': identity.deviceId,
      'deviceName': deviceName,
      'protocol': linkProtocolVersion,
    });

    final out = StreamController<Map<String, dynamic>>();
    unawaited(() async {
      try {
        while (await iterator.moveNext()) {
          if (out.isClosed) break;
          out.add(session.decryptFrame(iterator.current));
        }
      } on Object catch (e, st) {
        if (!out.isClosed) out.addError(e, st);
        await session.close();
      } finally {
        await sub.cancel();
        if (!out.isClosed) await out.close();
      }
    }());

    return (session: session, incoming: out.stream, newlyPaired: verdict.newlyPaired);
  } on Object {
    await iterator.cancel();
    await sub.cancel();
    await transport.close();
    rethrow;
  }
}

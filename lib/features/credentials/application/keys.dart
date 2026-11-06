import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../foundation/data_dir.dart';
import '../../../foundation/ids.dart';
import '../../../foundation/json_file.dart';
import '../../../foundation/result.dart';
import '../../../foundation/secret.dart';
import '../adapters/key_codec.dart';
import '../adapters/secure_store.dart';
import '../domain/ssh_key.dart';

final secretStoreProvider = Provider<SecretStore>((_) => const SecretStore());

final keysProvider = NotifierProvider<KeysNotifier, List<SshKey>>(KeysNotifier.new);

/// Private keys in the secure store, their metadata in keys.json (docs/SECURITY.md §2).
class KeysNotifier extends Notifier<List<SshKey>> {
  late final JsonFile _file = JsonFile('${ref.read(dataDirProvider)}/keys.json');
  SecretStore get _secrets => ref.read(secretStoreProvider);

  @override
  List<SshKey> build() => [
        for (final j in _file.read()?['keys'] as List<dynamic>? ?? const [])
          if (j is Map<String, dynamic>) SshKey.fromJson(j),
      ];

  SshKey? byId(String id) => state.where((k) => k.id == id).firstOrNull;

  /// Imports a PEM, or the file it names. An encrypted key stays encrypted; its [passphrase] is only checked,
  /// and kept when [remember] is set.
  Future<Result<SshKey>> import(String label, String pemOrPath, {Secret? passphrase, bool remember = false}) async {
    var pem = pemOrPath.trim();
    if (!pem.startsWith('-----')) {
      try {
        pem = await File(_expandHome(pem)).readAsString();
      } on Object catch (e) {
        return Err(AppError('keyUnreadable', detail: '$e'));
      }
    }
    final KeyInfo info;
    try {
      info = KeyCodec.inspect(pem, passphrase: passphrase?.reveal(), comment: label);
    } on KeyCodecException catch (e) {
      return Err(AppError(switch (e.problem) {
        KeyProblem.unsupported => 'keyUnsupported',
        KeyProblem.needsPassphrase => 'keyNeedsPassphrase',
        KeyProblem.wrongPassphrase => 'keyWrongPassphrase',
      }));
    }
    final same = state.where((k) => k.fingerprint == info.fingerprint).firstOrNull;
    if (same != null) return Err(AppError('keyDuplicate', detail: same.label));
    final key = _key(label, info, KeySource.imported);
    await _secrets.write(key.privateRef, Secret(pem.endsWith('\n') ? pem : '$pem\n'));
    if (info.encrypted && remember && passphrase != null) await _secrets.write(key.passphraseRef, passphrase);
    await _add(key);
    return Ok(key);
  }

  Future<SshKey> generate(String label) async {
    final pem = KeyCodec.generateEd25519(comment: label);
    final key = _key(label, KeyCodec.inspect(pem, comment: label), KeySource.generated);
    await _secrets.write(key.privateRef, Secret(pem));
    await _add(key);
    return key;
  }

  Future<void> rename(SshKey key, String label) async {
    state = [for (final k in state) k.id == key.id ? _key(label, _infoOf(k), k.source, k) : k];
    await _persist();
  }

  /// Metadata first, then the secret, so a failure leaves an orphan rather than a dangling reference.
  Future<void> delete(SshKey key) async {
    state = state.where((k) => k.id != key.id).toList();
    await _persist();
    await _secrets.delete(key.privateRef);
    await _secrets.delete(key.passphraseRef);
  }

  SshKey _key(String label, KeyInfo info, KeySource source, [SshKey? existing]) => SshKey(
        id: existing?.id ?? newId(),
        label: label.trim().isEmpty ? info.algorithm : label.trim(),
        algorithm: info.algorithm,
        fingerprint: info.fingerprint,
        publicKey: info.publicKey,
        created: existing?.created ?? DateTime.now(),
        source: source,
        encrypted: info.encrypted,
      );

  KeyInfo _infoOf(SshKey k) =>
      (algorithm: k.algorithm, publicKey: k.publicKey, fingerprint: k.fingerprint, encrypted: k.encrypted);

  Future<void> _add(SshKey key) {
    state = [...state, key];
    return _persist();
  }

  Future<void> _persist() => _file.write({'schemaVersion': 1, 'keys': [for (final k in state) k.toJson()]});
}

String _expandHome(String path) => path.startsWith('~')
    ? (Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'] ?? '') + path.substring(1)
    : path;

import 'dart:io';

import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../foundation/data_dir.dart';
import '../../../foundation/ids.dart';
import '../../../foundation/json_file.dart';
import '../../../foundation/result.dart';
import '../../../foundation/secret.dart';
import '../../../platform/local_paths.dart';
import '../adapters/key_codec.dart';
import '../adapters/secure_store.dart';
import '../domain/ssh_key.dart';
import 'credential_access.dart';

/// The composition root supplies the host-reference query; absent wiring must not permit deletion.
final keyReferencesProvider = Provider<List<String> Function(String)>(
  (_) =>
      (_) => throw StateError('key references unavailable'),
);
final keysProvider = NotifierProvider<KeysNotifier, List<SshKey>>(KeysNotifier.new);

class KeyInUse implements Exception {
  const KeyInUse(this.hosts);
  final List<String> hosts;
}

/// Private keys in the secure store, their metadata in keys.json (docs/SECURITY.md §2).
class KeysNotifier extends Notifier<List<SshKey>> {
  late final JsonFile _file = JsonFile('${ref.read(dataDirProvider)}/keys.json', backups: true, validate: _validate);
  SecretStore get _secrets => ref.read(secretStoreProvider);
  Future<void> _pending = Future.value();

  @override
  List<SshKey> build() => [
    for (final j in _file.read()?['keys'] as List<dynamic>? ?? const []) SshKey.fromJson(j as Map<String, dynamic>),
  ];

  static void _validate(Map<String, dynamic> json) {
    final entries = json['keys'];
    if (entries is! List) throw const FormatException('keys must be a list');
    final ids = <String>{};
    for (final entry in entries) {
      final key = SshKey.fromJson((entry as Map).cast<String, dynamic>());
      if (key.id.isEmpty ||
          !ids.add(key.id) ||
          key.algorithm.isEmpty ||
          key.fingerprint.isEmpty ||
          key.publicKey.isEmpty) {
        throw const FormatException('invalid key metadata');
      }
    }
  }

  Future<void> get saved => _pending.then((_) => _file.idle);
  SshKey? byId(String id) => state.where((k) => k.id == id).firstOrNull;

  Future<T> _change<T>(Future<T> Function() action) {
    final next = _pending.then((_) => action());
    _pending = next.then<void>((_) {}, onError: (Object _) {});
    return next;
  }

  /// Host-reference commits share the deletion queue, so a check cannot race a new reference.
  Future<T> withKeys<T>(Iterable<String> ids, Future<T> Function() action) => _change(() async {
    for (final id in ids) {
      if (byId(id) == null) throw StateError('key no longer exists');
    }
    return action();
  });

  /// Imports a PEM, or the file it names. An encrypted key stays encrypted; its passphrase is checked and is kept
  /// only when requested.
  Future<Result<SshKey>> import(String label, String pemOrPath, {Secret? passphrase, bool remember = false}) =>
      _change(() async {
        var pem = pemOrPath.trim();
        if (!pem.startsWith('-----')) {
          try {
            pem = await File(_expandHome(unquoteWindowsPath(pem))).readAsString();
          } on Object catch (e) {
            return Err(AppError('keyUnreadable', detail: _describe(e)));
          }
        }
        final KeyInfo info;
        try {
          info = KeyCodec.inspect(pem, passphrase: passphrase?.reveal(), comment: label);
        } on KeyCodecException catch (e) {
          return Err(
            AppError(switch (e.problem) {
              KeyProblem.unsupported => 'keyUnsupported',
              KeyProblem.needsPassphrase => 'keyNeedsPassphrase',
              KeyProblem.wrongPassphrase => 'keyWrongPassphrase',
            }),
          );
        }
        final same = state.where((k) => k.fingerprint == info.fingerprint).firstOrNull;
        if (same != null) return Err(AppError('keyDuplicate', detail: same.label));
        final key = _key(label, info, KeySource.imported);
        try {
          await _secrets.write(key.privateRef, Secret(pem.endsWith('\n') ? pem : '$pem\n'));
          if (info.encrypted && remember && passphrase != null) await _secrets.write(key.passphraseRef, passphrase);
          await _commit([...state, key]);
        } on Object catch (e) {
          // A secret written before the failure has no metadata pointing at it (docs/SECURITY.md §2).
          return Err(AppError('keyStoreFailed', detail: _describe(e)));
        }
        return Ok(key);
      });

  Future<SshKey> generate(String label) => _change(() async {
    final pem = KeyCodec.generateEd25519(comment: label);
    final key = _key(label, KeyCodec.inspect(pem, comment: label), KeySource.generated);
    await _secrets.write(key.privateRef, Secret(pem));
    await _commit([...state, key]);
    return key;
  });

  Future<void> rename(SshKey key, String label) => _change(() async {
    final current = byId(key.id);
    if (current == null) return;
    await _commit([for (final k in state) k.id == key.id ? _key(label, _infoOf(current), current.source, current) : k]);
  });

  /// Rechecked in the shared queue immediately before committing; UI enablement is only a convenience.
  Future<void> delete(SshKey key) => _change(() async {
    final current = byId(key.id);
    if (current == null) return;
    final references = ref.read(keyReferencesProvider)(key.id);
    if (references.isNotEmpty) throw KeyInUse(List.unmodifiable(references));
    await _commit(state.where((k) => k.id != key.id).toList());
    await _secrets.delete(current.privateRef);
    await _secrets.delete(current.passphraseRef);
  });

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

  Future<void> _commit(List<SshKey> next) async {
    await _file.write({
      'schemaVersion': 1,
      'keys': [for (final k in next) k.toJson()],
    });
    state = next;
    ref.read(credentialRevisionProvider).changed();
  }
}

/// The system's reason alone; the exception text around it adds nothing the user can act on.
String _describe(Object error) => switch (error) {
  FileSystemException(:final osError?) => osError.message,
  FileSystemException(:final message) => message,
  PlatformException(:final message?) => message,
  _ => '$error',
};

String _expandHome(String path) => path.startsWith('~')
    ? (Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'] ?? '') + path.substring(1)
    : path;

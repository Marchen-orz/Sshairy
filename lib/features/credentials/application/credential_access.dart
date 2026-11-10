import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../foundation/ids.dart';
import '../../../foundation/json_file.dart';
import '../../../foundation/secret.dart';
import '../adapters/secure_store.dart';

/// SSH can resolve credentials and remember challenge answers, but cannot replace private keys.
abstract interface class ConnectionCredentials {
  int get revision;
  Future<Secret?> read(SecretRef ref);
  Future<void> remember(SecretRef ref, Secret value);
}

/// Settings use [has] for presence; only the translation engine reads values, never capabilities or AI.
abstract interface class TranslationCredentials {
  Future<bool> has(String identity);
  Future<void> save(String identity, Secret value);
  Future<void> clear(String identity);
  Future<Secret?> read(String identity);
}

/// AI settings query presence; only the selected model adapter reads a destination's API key.
abstract interface class AiCredentials {
  Stream<void> get changes;
  Future<bool> has(String identity);
  Future<void> save(String identity, Secret value);
  Future<void> clear(String identity);
  Future<Secret?> read(String identity);
}

/// The user-owned host form can edit only its host's password, never private keys or other credential kinds.
/// Values stay in the form's transient draft; this port is not exposed through capabilities or AI.
abstract interface class HostPasswordEditor {
  Future<Secret?> readPassword(HostId id);
  Future<void> savePassword(HostId id, Secret value);
  Future<void> clearPassword(HostId id);
}

/// Local migration fills missing passwords, then persists host metadata while the credential queue is held.
/// The commit callback must not call these credential ports again.
abstract interface class HostPasswordImport {
  Future<int> importMissing(Map<HostId, Secret> passwords, Future<void> Function() commit);
}

class CredentialImportFailure implements Exception {
  const CredentialImportFailure({this.rollbackIncomplete = false});

  final bool rollbackIncomplete;

  @override
  String toString() => 'CredentialImportFailure(rollbackIncomplete: $rollbackIncomplete)';
}

/// Host removal never receives permission to read or delete shared private keys.
abstract interface class HostCredentialCleanup {
  Future<void> clearHost(HostId id, String proxyIdentity);
  Future<void> clearProxy(HostId id, String proxyIdentity);
}

// Internal adapter injection; business features receive the narrower ports below.
final secretStoreProvider = Provider<SecretStore>((_) => const SecretStore());
final credentialRevisionProvider = Provider<CredentialRevision>((_) => CredentialRevision());
final _credentialsProvider = Provider<_StoredCredentials>(
  (ref) => _StoredCredentials(ref.read(secretStoreProvider), ref.read(credentialRevisionProvider)),
);
final connectionCredentialsProvider = Provider<ConnectionCredentials>((ref) => ref.read(_credentialsProvider));
final hostCredentialCleanupProvider = Provider<HostCredentialCleanup>((ref) => ref.read(_credentialsProvider));
final hostPasswordImportProvider = Provider<HostPasswordImport>((ref) => ref.read(_credentialsProvider));
final hostPasswordEditorProvider = Provider<HostPasswordEditor>((ref) => ref.read(_credentialsProvider));
final translationCredentialsProvider = Provider<TranslationCredentials>(
  (ref) => _TranslationCredentials(ref.read(_credentialsProvider)),
);

final aiCredentialsProvider = Provider<AiCredentials>((ref) {
  final credentials = _AiCredentials(ref.read(_credentialsProvider));
  ref.onDispose(credentials.close);
  return credentials;
});

class _AiCredentials implements AiCredentials {
  _AiCredentials(this._credentials);
  final _StoredCredentials _credentials;
  final _changes = StreamController<void>.broadcast(sync: true);

  @override
  Stream<void> get changes => _changes.stream;

  void _changed() {
    if (!_changes.isClosed) _changes.add(null);
  }

  void close() => unawaited(_changes.close());

  @override
  Future<bool> has(String identity) => _credentials.hasAi(identity);

  @override
  Future<void> save(String identity, Secret value) => _credentials.saveAi(identity, value, changed: _changed);

  @override
  Future<void> clear(String identity) => _credentials.clearAi(identity, changed: _changed);

  @override
  Future<Secret?> read(String identity) => _credentials.readAi(identity);
}

class CredentialRevision {
  int value = 0;
  void changed() => value++;
}

class _TranslationCredentials implements TranslationCredentials {
  _TranslationCredentials(this._credentials);
  final _StoredCredentials _credentials;

  @override
  Future<bool> has(String identity) => _credentials.hasTranslation(identity);

  @override
  Future<void> save(String identity, Secret value) => _credentials.saveTranslation(identity, value);

  @override
  Future<void> clear(String identity) => _credentials.clearTranslation(identity);

  @override
  Future<Secret?> read(String identity) => _credentials.readTranslation(identity);
}

class _StoredCredentials
    implements ConnectionCredentials, HostCredentialCleanup, HostPasswordImport, HostPasswordEditor {
  _StoredCredentials(this._store, this._revision);
  final SecretStore _store;
  final CredentialRevision _revision;
  Future<void> _pending = Future.value();

  Future<T> _serial<T>(Future<T> Function() action) {
    final next = _pending.then((_) => action());
    _pending = next.then<void>((_) {}, onError: (Object _) {});
    return next;
  }

  @override
  int get revision => _revision.value;

  @override
  Future<Secret?> read(SecretRef ref) => _serial(() => _store.read(ref));

  @override
  Future<Secret?> readPassword(HostId id) => read(SecretRef.hostPassword(id));

  @override
  Future<void> savePassword(HostId id, Secret value) {
    // An empty draft keeps the old secret; removal is a separate explicit action.
    if (value.reveal().isEmpty) return Future.value();
    return _serial(() async {
      final ref = SecretRef.hostPassword(id);
      final old = await _store.read(ref);
      if (old?.reveal() == value.reveal()) return;
      try {
        await _store.write(ref, value);
      } finally {
        // A platform write may fail after writing. Do not reuse a pool snapshot with uncertain credentials.
        _revision.changed();
      }
    });
  }

  @override
  Future<void> clearPassword(HostId id) => _serial(() async {
    try {
      await _store.delete(SecretRef.hostPassword(id));
    } finally {
      _revision.changed();
    }
  });

  Future<bool> hasTranslation(String identity) =>
      _serial(() async => await _store.read(SecretRef.translation(identity)) != null);

  Future<void> saveTranslation(String identity, Secret value) => _serial(() async {
    final ref = SecretRef.translation(identity);
    _validateTranslationKey(value);
    await _store.write(ref, value);
  });

  Future<void> clearTranslation(String identity) => _serial(() => _store.delete(SecretRef.translation(identity)));

  Future<Secret?> readTranslation(String identity) => _serial(() async {
    final value = await _store.read(SecretRef.translation(identity));
    if (value != null) _validateTranslationKey(value);
    return value;
  });

  static void _validateTranslationKey(Secret value) {
    final key = value.reveal();
    if (key.trim().isEmpty || key.length > 8192 || RegExp(r'[\x00-\x1f\x7f-\x9f]').hasMatch(key)) {
      throw ArgumentError('invalid translation API key');
    }
  }

  Future<bool> hasAi(String identity) => _serial(() async => await _store.read(SecretRef.ai(identity)) != null);

  Future<void> saveAi(String identity, Secret value, {required void Function() changed}) => _serial(() async {
    final ref = SecretRef.ai(identity);
    _validateAiKey(value);
    try {
      await _store.write(ref, value);
    } finally {
      // A failed platform write may already have changed the key. Revoke active requests either way.
      changed();
    }
  });

  Future<void> clearAi(String identity, {required void Function() changed}) => _serial(() async {
    final ref = SecretRef.ai(identity);
    try {
      await _store.delete(ref);
    } finally {
      changed();
    }
  });

  Future<Secret?> readAi(String identity) => _serial(() async {
    final value = await _store.read(SecretRef.ai(identity));
    if (value != null) _validateAiKey(value);
    return value;
  });

  static void _validateAiKey(Secret value) {
    final key = value.reveal();
    if (key.trim().isEmpty || key.length > 8192 || RegExp(r'[\x00-\x1f\x7f-\x9f]').hasMatch(key)) {
      throw ArgumentError('invalid AI API key');
    }
  }

  @override
  Future<void> remember(SecretRef ref, Secret value) => _serial(() async {
    if (!ref.canRemember) throw ArgumentError('private keys are managed by the key store');
    // A first save takes nothing away and happens in the very dial whose connection would otherwise never be
    // reused; only replacing a different value counts as a change of credential.
    final old = await _store.read(ref);
    await _store.write(ref, value);
    if (old != null && old.reveal() != value.reveal()) _revision.changed();
  });

  @override
  Future<void> clearProxy(HostId id, String proxyIdentity) =>
      _serial(() => _delete(SecretRef.hostProxy(id, proxyIdentity)));

  @override
  Future<void> clearHost(HostId id, String proxyIdentity) => _serial(() async {
    await _delete(SecretRef.hostPassword(id));
    await _delete(SecretRef.hostPassphrase(id));
    await _delete(SecretRef.hostProxy(id, proxyIdentity));
  });

  @override
  Future<int> importMissing(Map<HostId, Secret> passwords, Future<void> Function() commit) {
    final entries = Map.of(passwords);
    return _serial(() async {
      final created = <SecretRef>[];
      var committing = false;
      try {
        for (final entry in entries.entries) {
          final ref = SecretRef.hostPassword(entry.key);
          if (await _store.read(ref) != null) continue;
          // A platform write can fail after saving, so include the attempted reference in rollback.
          created.add(ref);
          await _store.write(ref, entry.value);
        }
        committing = true;
        await commit();
        return created.length;
      } on Object catch (error, stack) {
        var incomplete = false;
        for (final ref in created.reversed) {
          try {
            await _store.delete(ref);
          } on Object {
            incomplete = true;
          } finally {
            _revision.changed();
          }
        }
        if (!incomplete && committing && error is JsonFileError) Error.throwWithStackTrace(error, stack);
        throw CredentialImportFailure(rollbackIncomplete: incomplete);
      }
    });
  }

  Future<void> _delete(SecretRef ref) async {
    await _store.delete(ref);
    _revision.changed();
  }
}

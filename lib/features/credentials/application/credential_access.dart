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

class CredentialRevision {
  int value = 0;
  void changed() => value++;
}

class _StoredCredentials implements ConnectionCredentials, HostCredentialCleanup, HostPasswordImport {
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

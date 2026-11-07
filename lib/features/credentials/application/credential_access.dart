import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../foundation/ids.dart';
import '../../../foundation/secret.dart';
import '../adapters/secure_store.dart';

/// SSH can resolve credentials and remember challenge answers, but cannot replace private keys.
abstract interface class ConnectionCredentials {
  int get revision;
  Future<Secret?> read(SecretRef ref);
  Future<void> remember(SecretRef ref, Secret value);
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

class CredentialRevision {
  int value = 0;
  void changed() => value++;
}

class _StoredCredentials implements ConnectionCredentials, HostCredentialCleanup {
  _StoredCredentials(this._store, this._revision);
  final SecretStore _store;
  final CredentialRevision _revision;

  @override
  int get revision => _revision.value;

  @override
  Future<Secret?> read(SecretRef ref) => _store.read(ref);

  @override
  Future<void> remember(SecretRef ref, Secret value) async {
    if (!ref.canRemember) throw ArgumentError('private keys are managed by the key store');
    // A first save takes nothing away and happens in the very dial whose connection would otherwise never be
    // reused; only replacing a different value counts as a change of credential.
    final old = await _store.read(ref);
    await _store.write(ref, value);
    if (old != null && old.reveal() != value.reveal()) _revision.changed();
  }

  @override
  Future<void> clearProxy(HostId id, String proxyIdentity) => _delete(SecretRef.hostProxy(id, proxyIdentity));

  @override
  Future<void> clearHost(HostId id, String proxyIdentity) async {
    await _delete(SecretRef.hostPassword(id));
    await _delete(SecretRef.hostPassphrase(id));
    await clearProxy(id, proxyIdentity);
  }

  Future<void> _delete(SecretRef ref) async {
    await _store.delete(ref);
    _revision.changed();
  }
}

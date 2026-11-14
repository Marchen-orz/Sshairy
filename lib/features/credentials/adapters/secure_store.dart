import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../../foundation/secret.dart';

/// Secrets live only in the OS store; there is no plaintext fallback (docs/SECURITY.md §2).
class SecretStore {
  const SecretStore();

  // The login keychain works for local macOS builds without a provisioning profile or sharing group.
  static const _storage = FlutterSecureStorage(mOptions: MacOsOptions(usesDataProtectionKeychain: false));

  Future<Secret?> read(SecretRef ref) async {
    final value = await _storage.read(key: ref.storageKey);
    return value == null ? null : Secret(value);
  }

  Future<void> write(SecretRef ref, Secret value) => _storage.write(key: ref.storageKey, value: value.reveal());
  Future<void> delete(SecretRef ref) => _storage.delete(key: ref.storageKey);
}

import 'dart:io' show Platform;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../../foundation/secret.dart';
import 'windows_secret_file.dart';

/// Secrets live only in the OS store; there is no plaintext fallback (docs/SECURITY.md §2).
class SecretStore {
  const SecretStore();

  // The login keychain works for local macOS builds without a provisioning profile or sharing group.
  static const _storage = FlutterSecureStorage(mOptions: MacOsOptions(usesDataProtectionKeychain: false));
  static final _windows = Platform.isWindows ? WindowsSecretFile.shared() : null;

  Future<Secret?> read(SecretRef ref) async {
    final value = await (_windows?.read(ref.storageKey) ?? _storage.read(key: ref.storageKey));
    return value == null ? null : Secret(value);
  }

  Future<void> write(SecretRef ref, Secret value) =>
      _windows?.write(ref.storageKey, value.reveal()) ?? _storage.write(key: ref.storageKey, value: value.reveal());
  Future<void> delete(SecretRef ref) => _windows?.delete(ref.storageKey) ?? _storage.delete(key: ref.storageKey);
}

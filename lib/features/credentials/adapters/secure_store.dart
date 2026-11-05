import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../../foundation/secret.dart';

/// Secrets live only in the OS store; there is no plaintext fallback (docs/SECURITY.md §2).
class SecretStore {
  const SecretStore();

  static const _storage = FlutterSecureStorage();

  Future<Secret?> read(String ref) async {
    final value = await _storage.read(key: ref);
    return value == null ? null : Secret(value);
  }

  Future<void> write(String ref, Secret value) => _storage.write(key: ref, value: value.reveal());
  Future<void> delete(String ref) => _storage.delete(key: ref);
}

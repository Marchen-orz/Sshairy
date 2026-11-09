import 'package:sshairy/features/credentials/adapters/secure_store.dart';
import 'package:sshairy/foundation/secret.dart';

/// Real-server tests must never read the author's OS store or persist the supplied test password.
class EphemeralSecretStore extends SecretStore {
  final _values = <SecretRef, Secret>{};

  @override
  Future<Secret?> read(SecretRef ref) async => _values[ref];

  @override
  Future<void> write(SecretRef ref, Secret value) async {
    _values[ref] = value;
  }

  @override
  Future<void> delete(SecretRef ref) async {
    _values.remove(ref);
  }
}

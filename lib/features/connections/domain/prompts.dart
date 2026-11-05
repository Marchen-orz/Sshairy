import '../../../foundation/secret.dart';
import 'known_keys.dart';

enum TrustChoice { reject, once, save }

class HostKeyPrompt {
  const HostKeyPrompt(this.endpoint, this.type, this.fingerprint, this.check);
  final String endpoint, type, fingerprint;
  final KeyCheck check;
}

enum SecretKind { password, passphrase, challenge }

class SecretRequest {
  const SecretRequest(this.kind, {this.text = '', this.echo = false, this.canRemember = false});
  final SecretKind kind;
  final String text;
  final bool echo, canRemember;
}

class SecretAnswer {
  const SecretAnswer(this.value, {this.remember = false});
  final Secret value;
  final bool remember;
}

/// User decisions a connection attempt waits for; returning null means the user cancelled.
abstract interface class ConnectPrompts {
  Future<TrustChoice> hostKey(HostKeyPrompt prompt);
  Future<SecretAnswer?> secret(SecretRequest request);
}

enum ConnectFailure { network, auth, hostKeyRejected, keyFile, cancelled }

class ConnectError implements Exception {
  const ConnectError(this.kind, [this.detail = '']);
  final ConnectFailure kind;
  final String detail;

  @override
  String toString() => 'ConnectError(${kind.name}, $detail)';
}

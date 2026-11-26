import '../../../foundation/secret.dart';
import 'known_keys.dart';

enum TrustChoice { reject, once, save }

class HostKeyPrompt {
  const HostKeyPrompt(this.endpoint, this.type, this.fingerprint, this.check);
  final String endpoint, type, fingerprint;
  final KeyCheck check;
}

enum SecretKind { password, passphrase, challenge, proxyPassword }

class SecretRequest {
  const SecretRequest(this.kind, {this.text = '', this.echo = false, this.canRemember = false, this.target = ''});
  final SecretKind kind;
  final String text;

  /// Who is asking, such as `user@host`; with jump hosts and proxies one attempt asks several.
  final String target;
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

/// [agent] carries the reason the system agent could not be used; an empty detail means it holds no key.
enum ConnectFailure { network, auth, hostKeyRejected, keyFile, cancelled, route, agent }

/// [ConnectError.detail] for [ConnectFailure.auth] when the proxy, not the server, refused.
const proxyAuthDetail = 'proxy';

/// [ConnectError.detail] values for [ConnectFailure.route].
const routeLoop = 'loop', routeMissing = 'missing', routeTooLong = 'tooLong';

class ConnectError implements Exception {
  const ConnectError(this.kind, [this.detail = '']);
  final ConnectFailure kind;
  final String detail;

  @override
  String toString() => 'ConnectError(${kind.name}, $detail)';
}

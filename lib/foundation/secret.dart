import 'ids.dart';

/// Keeps a password or passphrase out of logs and string interpolation; only [reveal] returns the value.
class Secret {
  const Secret(this._value);

  final String _value;

  String reveal() => _value;

  @override
  String toString() => 'Secret(***)';
}

/// Only the credential locations supported by the application can be addressed.
final class SecretRef {
  const SecretRef._(this.storageKey, {this.canRemember = true});

  factory SecretRef.hostPassword(HostId id) => SecretRef._('host/${id.value}/password');
  factory SecretRef.hostPassphrase(HostId id) => SecretRef._('host/${id.value}/passphrase');
  factory SecretRef.hostProxy(HostId id, String identity) =>
      SecretRef._('host/${id.value}/proxy/${Uri.encodeComponent(identity)}');
  factory SecretRef.privateKey(String id) => SecretRef._('key/$id/private', canRemember: false);
  factory SecretRef.keyPassphrase(String id) => SecretRef._('key/$id/passphrase');
  factory SecretRef.translation(String identity) {
    if (identity.trim().isEmpty || identity.length > 2048 || RegExp(r'[\x00-\x1f\x7f-\x9f]').hasMatch(identity)) {
      throw ArgumentError('invalid translation credential identity');
    }
    return SecretRef._('translation/${Uri.encodeComponent(identity)}/apiKey');
  }

  factory SecretRef.ai(String identity) {
    if (identity.trim().isEmpty || identity.length > 4096 || RegExp(r'[\x00-\x1f\x7f-\x9f]').hasMatch(identity)) {
      throw ArgumentError('invalid AI credential identity');
    }
    return SecretRef._('ai/${Uri.encodeComponent(identity)}/apiKey');
  }

  factory SecretRef.mcp(String client) => SecretRef._('mcp/${Uri.encodeComponent(client)}/token', canRemember: false);

  final String storageKey;
  final bool canRemember;

  @override
  bool operator ==(Object other) => other is SecretRef && storageKey == other.storageKey;
  @override
  int get hashCode => storageKey.hashCode;
  @override
  String toString() => 'SecretRef($storageKey)';
}

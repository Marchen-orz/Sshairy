import '../../../foundation/ids.dart';

/// [agent] signs with keys held by the system's SSH agent.
enum AuthKind { password, key, agent }

enum ProxyKind { socks5, http }

class Proxy {
  const Proxy(this.kind, this.address, this.port, {this.username = ''});
  final ProxyKind kind;
  final String address, username;
  final int port;
  String get key => '${kind.name}://$username@$address:$port';
  factory Proxy.fromJson(Map<String, dynamic> j) => Proxy(
    ProxyKind.values.byName(j['kind'] as String),
    j['address'] as String,
    j['port'] as int,
    username: j['username'] as String? ?? '',
  );
  Map<String, dynamic> toJson() => {
    'kind': kind.name,
    'address': address,
    'port': port,
    if (username.isNotEmpty) 'username': username,
  };
}

enum OverrideMode { inherit, disabled, value }

class OverrideValue<T> {
  const OverrideValue.inherit() : mode = OverrideMode.inherit, value = null;
  const OverrideValue.disabled() : mode = OverrideMode.disabled, value = null;
  const OverrideValue.value(T this.value) : mode = OverrideMode.value;
  final OverrideMode mode;
  final T? value;

  Map<String, Object?> toJson(Object? Function(T) encode) => {
    'mode': mode.name,
    if (mode == OverrideMode.value) 'value': encode(value as T),
  };
  static OverrideValue<T> fromJson<T>(Object? raw, T Function(Object?) decode) {
    if (raw == null) return OverrideValue<T>.inherit();
    final j = (raw as Map).cast<String, dynamic>();
    return switch (OverrideMode.values.byName(j['mode'] as String)) {
      OverrideMode.inherit => OverrideValue<T>.inherit(),
      OverrideMode.disabled => OverrideValue<T>.disabled(),
      OverrideMode.value => OverrideValue<T>.value(decode(j['value'])),
    };
  }
}

/// Authentication is replaced as a unit; private keys and passwords never enter this value.
class AuthPolicy {
  const AuthPolicy({
    this.methods = const [AuthKind.password],
    this.keyId,
    this.keyPath,
    this.allowInteractive = true,
    this.forwardAgent = false,
  });
  final List<AuthKind> methods;
  final String? keyId, keyPath;
  final bool allowInteractive;

  /// Lets the server use the system agent's keys for the session (docs/DESIGN.md ADR-17).
  final bool forwardAgent;
  bool get usesKey => methods.contains(AuthKind.key);
  bool get usesAgent => methods.contains(AuthKind.agent);
  bool get usesPassword => methods.contains(AuthKind.password);

  void validate() {
    if (methods.isEmpty ||
        methods.toSet().length != methods.length ||
        // One public key way, optionally followed by the password.
        methods.length > 2 ||
        (methods.length == 2 && (methods.first == AuthKind.password || methods.last != AuthKind.password)) ||
        (usesKey && (keyId == null && (keyPath == null || keyPath!.trim().isEmpty))) ||
        (keyId != null && keyPath != null) ||
        (keyId != null && keyId!.isEmpty) ||
        (!usesKey && (keyId != null || keyPath != null))) {
      throw ArgumentError('invalid authentication policy');
    }
  }

  factory AuthPolicy.fromJson(Map<String, dynamic> j) => AuthPolicy(
    methods: [for (final method in j['methods'] as List) AuthKind.values.byName(method as String)],
    keyId: j['keyId'] as String?,
    keyPath: j['keyPath'] as String?,
    allowInteractive: j['allowInteractive'] as bool? ?? true,
    forwardAgent: j['forwardAgent'] as bool? ?? false,
  );
  Map<String, Object?> toJson() => {
    'methods': [for (final method in methods) method.name],
    if (keyId != null) 'keyId': keyId,
    if (keyPath != null) 'keyPath': keyPath,
    'allowInteractive': allowInteractive,
    if (forwardAgent) 'forwardAgent': true,
  };
}

class Authentication {
  const Authentication.identity(String this.identityId) : username = null, policy = null;
  const Authentication.inline(String this.username, AuthPolicy this.policy) : identityId = null;
  final String? identityId, username;
  final AuthPolicy? policy;

  factory Authentication.fromJson(Map<String, dynamic> j) => j['identityId'] != null
      ? Authentication.identity(j['identityId'] as String)
      : Authentication.inline(j['username'] as String, AuthPolicy.fromJson((j['policy'] as Map).cast()));
  Map<String, Object?> toJson() =>
      identityId != null ? {'identityId': identityId} : {'username': username, 'policy': policy!.toJson()};
}

class ConnectionOverrides {
  const ConnectionOverrides({
    this.port = const OverrideValue.inherit(),
    this.authentication = const OverrideValue.inherit(),
    this.jump = const OverrideValue.inherit(),
    this.proxy = const OverrideValue.inherit(),
    this.legacy = const OverrideValue.inherit(),
  });
  final OverrideValue<int> port;
  final OverrideValue<Authentication> authentication;
  final OverrideValue<HostId> jump;
  final OverrideValue<Proxy> proxy;
  final OverrideValue<bool> legacy;

  /// True when every field is inherited, so the layer changes nothing.
  bool get isEmpty =>
      port.mode == OverrideMode.inherit &&
      authentication.mode == OverrideMode.inherit &&
      jump.mode == OverrideMode.inherit &&
      proxy.mode == OverrideMode.inherit &&
      legacy.mode == OverrideMode.inherit;

  factory ConnectionOverrides.fromJson(Map<String, dynamic> j) => ConnectionOverrides(
    port: OverrideValue.fromJson(j['port'], (v) => v as int),
    authentication: OverrideValue.fromJson(j['authentication'], (v) => Authentication.fromJson((v as Map).cast())),
    jump: OverrideValue.fromJson(j['jump'], (v) => HostId(v as String)),
    proxy: OverrideValue.fromJson(j['proxy'], (v) => Proxy.fromJson((v as Map).cast())),
    legacy: OverrideValue.fromJson(j['legacy'], (v) => v as bool),
  );
  Map<String, Object?> toJson() => {
    'port': port.toJson((v) => v),
    'authentication': authentication.toJson((v) => v.toJson()),
    'jump': jump.toJson((v) => v.value),
    'proxy': proxy.toJson((v) => v.toJson()),
    'legacy': legacy.toJson((v) => v),
  };
}

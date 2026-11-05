enum AuthKind { password, key }

/// Saved connection target. Secrets are never fields; they are looked up by [passwordRef]/[passphraseRef].
class Host {
  const Host({
    required this.id,
    required this.label,
    required this.address,
    this.port = 22,
    required this.username,
    this.auth = AuthKind.password,
    this.keyPath,
  });

  final String id, label, address, username;
  final int port;
  final AuthKind auth;
  final String? keyPath;

  /// Quick-connect hosts are not saved, so nothing about them is remembered.
  bool get transient => id.isEmpty;
  String get title => label.isEmpty ? address : label;
  String get target => port == 22 ? '$username@$address' : '$username@$address:$port';
  String get passwordRef => 'host/$id/password';
  String get passphraseRef => 'host/$id/passphrase';

  factory Host.fromJson(Map<String, dynamic> j) => Host(
        id: j['id'] as String,
        label: j['label'] as String? ?? '',
        address: j['address'] as String,
        port: j['port'] as int? ?? 22,
        username: j['username'] as String,
        auth: AuthKind.values.byName(j['auth'] as String? ?? 'password'),
        keyPath: j['keyPath'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'address': address,
        'port': port,
        'username': username,
        'auth': auth.name,
        if (keyPath != null) 'keyPath': keyPath,
      };
}

/// Parses `user@host`, `user@host:port`, `user@[v6]:port` and `ssh [-p N] user@host`.
Host? parseQuickConnect(String input) {
  var parts = input.trim().split(RegExp(r'\s+'));
  int? port;
  if (parts.first == 'ssh') {
    parts = parts.sublist(1);
    if (parts.length == 3 && parts[0] == '-p') {
      port = int.tryParse(parts[1]);
      if (port == null) return null;
      parts = parts.sublist(2);
    }
  }
  if (parts.length != 1) return null;
  final m = RegExp(r'^([^@\s]+)@(\[[0-9a-fA-F:.]+\]|[^@\s:\[\]]+)(?::(\d+))?$').firstMatch(parts.single);
  if (m == null) return null;
  if (m[3] != null) {
    if (port != null) return null;
    port = int.parse(m[3]!);
  }
  port ??= 22;
  if (port < 1 || port > 65535) return null;
  final address = m[2]!.startsWith('[') ? m[2]!.substring(1, m[2]!.length - 1) : m[2]!;
  return Host(id: '', label: '', address: address, port: port, username: m[1]!);
}

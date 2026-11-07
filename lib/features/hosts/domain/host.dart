import '../../../foundation/ids.dart';
import '../../../foundation/secret.dart';
import 'connection_options.dart';

export 'connection_options.dart';

/// Saved connection target. Secrets are never fields; they are looked up by [passwordRef]/[passphraseRef], and an
/// imported key by [keyId].
class Host {
  const Host({
    required this.id,
    required this.label,
    required this.address,
    this.port = 22,
    required this.username,
    this.auth = AuthKind.password,
    this.keyPath,
    this.keyId,
    this.group = '',
    this.tags = const [],
    this.pinned = false,
    this.lastUsed,
    this.jumpHostId,
    this.proxy,
    this.legacy = false,
    this.groupId,
    this.overrides,
    this.authPolicy,
  });

  final HostId id;
  final String label, address, username;
  final int port;
  final AuthKind auth;

  /// A key file on disk; [keyId] wins when both are set.
  final String? keyPath;

  /// A key imported into the key store.
  final String? keyId;

  /// `/`-separated path such as `prod/web`; empty for none.
  final String group;
  final List<String> tags;
  final bool pinned;
  final DateTime? lastUsed;

  /// A saved host this one is reached through; that host may have a jump host of its own.
  final HostId? jumpHostId;

  /// Used only when this host is the first hop.
  final Proxy? proxy;

  /// Allows SHA-1 key exchange and host key signatures and CBC ciphers, for this host only.
  final bool legacy;
  final String? groupId;
  final ConnectionOverrides? overrides;

  /// A resolved policy, or the explicit legacy method for a standalone host.
  final AuthPolicy? authPolicy;
  AuthPolicy get policy =>
      authPolicy ??
      AuthPolicy(
        methods: [auth],
        keyId: auth == AuthKind.key ? keyId : null,
        keyPath: auth == AuthKind.key && keyId == null ? keyPath : null,
      );

  /// Quick-connect hosts are not saved, so nothing about them is remembered.
  bool get transient => id.value.isEmpty;
  String get title => label.isEmpty ? address : label;
  String get target => port == 22 ? '$username@$address' : '$username@$address:$port';
  SecretRef get passwordRef => SecretRef.hostPassword(id);
  SecretRef get passphraseRef => SecretRef.hostPassphrase(id);
  SecretRef get proxyRef => SecretRef.hostProxy(id, proxy?.key ?? '');

  Host copyWith({
    bool? pinned,
    DateTime? lastUsed,
    String? group,
    HostId? id,
    String? label,
    String? Function()? groupId,
    ConnectionOverrides? Function()? overrides,
  }) => Host(
    id: id ?? this.id,
    label: label ?? this.label,
    address: address,
    port: port,
    username: username,
    auth: auth,
    keyPath: keyPath,
    keyId: keyId,
    group: group ?? this.group,
    tags: tags,
    pinned: pinned ?? this.pinned,
    lastUsed: lastUsed ?? this.lastUsed,
    jumpHostId: jumpHostId,
    proxy: proxy,
    legacy: legacy,
    groupId: groupId == null ? this.groupId : groupId(),
    overrides: overrides == null ? this.overrides : overrides(),
    authPolicy: authPolicy,
  );

  factory Host.fromJson(Map<String, dynamic> j) => Host(
    id: HostId(j['id'] as String),
    label: j['label'] as String? ?? '',
    address: j['address'] as String,
    port: j['port'] as int? ?? 22,
    username: j['username'] as String,
    auth: AuthKind.values.asNameMap()[j['auth']] ?? AuthKind.password,
    keyPath: j['keyPath'] as String?,
    keyId: j['keyId'] as String?,
    group: normalizeGroup(j['group'] as String? ?? ''),
    tags: [
      for (final t in j['tags'] as List<dynamic>? ?? const [])
        if (t is String) t,
    ],
    pinned: j['pinned'] as bool? ?? false,
    lastUsed: DateTime.tryParse(j['lastUsed'] as String? ?? ''),
    jumpHostId: switch (j['jumpHostId']) {
      final String id when id.isNotEmpty => HostId(id),
      _ => null,
    },
    proxy: j['proxy'] is Map<String, dynamic> ? Proxy.fromJson(j['proxy'] as Map<String, dynamic>) : null,
    legacy: j['legacy'] as bool? ?? false,
    groupId: j['groupId'] as String?,
    overrides: j['overrides'] == null ? null : ConnectionOverrides.fromJson((j['overrides'] as Map).cast()),
    authPolicy: j['authPolicy'] == null ? null : AuthPolicy.fromJson((j['authPolicy'] as Map).cast()),
  );

  Map<String, dynamic> toJson() => {
    'id': id.value,
    'label': label,
    'address': address,
    'port': port,
    'username': username,
    'auth': auth.name,
    if (keyPath != null) 'keyPath': keyPath,
    if (keyId != null) 'keyId': keyId,
    if (group.isNotEmpty) 'group': group,
    if (tags.isNotEmpty) 'tags': tags,
    if (pinned) 'pinned': true,
    if (lastUsed != null) 'lastUsed': lastUsed!.toUtc().toIso8601String(),
    if (jumpHostId != null) 'jumpHostId': jumpHostId!.value,
    if (proxy != null) 'proxy': proxy!.toJson(),
    if (legacy) 'legacy': true,
    if (groupId != null) 'groupId': groupId,
    if (overrides != null) 'overrides': overrides!.toJson(),
    if (authPolicy != null) 'authPolicy': authPolicy!.toJson(),
  };
}

/// Trims each segment and drops empty ones: ` prod / /web ` is `prod/web`.
String normalizeGroup(String path) => path.split('/').map((s) => s.trim()).where((s) => s.isNotEmpty).join('/');

/// Comma or whitespace separated, without duplicates, in the order given.
List<String> parseTags(String text) => {
  for (final t in text.split(RegExp(r'[,\s]+')))
    if (t.isNotEmpty) t,
}.toList();

/// The vault's order: pinned first, then most recent when [recent], then by name so the order is stable.
List<Host> sortHosts(Iterable<Host> hosts, {bool recent = false}) {
  int byName(Host a, Host b) => a.title.toLowerCase().compareTo(b.title.toLowerCase());
  int byRecent(Host a, Host b) {
    final x = a.lastUsed, y = b.lastUsed;
    if (x == y) return 0;
    if (x == null) return 1;
    if (y == null) return -1;
    return y.compareTo(x);
  }

  return hosts.toList()..sort((a, b) {
    if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
    final c = recent ? byRecent(a, b) : 0;
    return c != 0 ? c : byName(a, b);
  });
}

/// Search across name, target, group and tags; every word must match somewhere.
bool hostMatches(Host h, String query) {
  final hay = '${h.title} ${h.target} ${h.group} ${h.tags.join(' ')}'.toLowerCase();
  return query.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).every(hay.contains);
}

/// Hosts in [group] or below it; an empty group is everything.
bool inGroup(Host h, String group) => group.isEmpty || h.group == group || h.group.startsWith('$group/');

/// Every group path and its parents, sorted.
List<String> allGroups(Iterable<Host> hosts) {
  final out = <String>{};
  for (final h in hosts) {
    final parts = h.group.split('/');
    for (var i = 1; i <= parts.length; i++) {
      final p = parts.take(i).join('/');
      if (p.isNotEmpty) out.add(p);
    }
  }
  return out.toList()..sort();
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
  return Host(id: const HostId(''), label: '', address: address, port: port, username: m[1]!);
}

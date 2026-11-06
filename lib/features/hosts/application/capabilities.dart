import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../foundation/ids.dart';
import '../../../foundation/result.dart';
import '../../capabilities/api.dart';
import '../../credentials/api.dart';
import '../domain/host.dart';
import 'hosts.dart';

/// Host metadata for callers outside the vault: no secret references, no key paths.
Map<String, Object?> hostDto(Host h) => {
  'id': h.id.value,
  'label': h.label,
  'address': h.address,
  'port': h.port,
  'username': h.username,
  'auth': h.auth.name,
  if (h.keyId != null) 'keyId': h.keyId,
  'group': h.group,
  'tags': h.tags,
  'pinned': h.pinned,
  if (h.jumpHostId != null) 'jumpHostId': h.jumpHostId!.value,
  if (h.proxy != null) 'proxy': h.proxy!.toJson(),
  'legacy': h.legacy,
  if (h.lastUsed != null) 'lastUsed': h.lastUsed!.toUtc().toIso8601String(),
};

const _hostFields = {
  'label': {'type': 'string'},
  'address': {'type': 'string'},
  'port': {'type': 'integer', 'minimum': 1, 'maximum': 65535},
  'username': {'type': 'string'},
  'auth': {
    'type': 'string',
    'enum': ['password', 'key'],
  },
  'keyPath': {'type': 'string'},
  'keyId': {'type': 'string', 'description': 'An imported key from key.list; used instead of keyPath.'},
  'group': {'type': 'string', 'description': 'Slash-separated path such as prod/web; empty for none.'},
  'tags': {
    'type': 'array',
    'items': {'type': 'string'},
  },
  'pinned': {'type': 'boolean'},
  'jumpHostId': {'type': 'string', 'description': 'Saved jump host ID; empty clears it.'},
  'proxy': {
    'type': ['object', 'null'],
    'properties': {
      'kind': {
        'type': 'string',
        'enum': ['socks5', 'http'],
      },
      'address': {'type': 'string'},
      'port': {'type': 'integer', 'minimum': 1, 'maximum': 65535},
      'username': {'type': 'string'},
    },
    'required': ['kind', 'address', 'port'],
    'additionalProperties': false,
  },
  'legacy': {'type': 'boolean'},
};

List<Capability> hostCapabilities(Ref ref) {
  HostsNotifier hosts() => ref.read(hostsProvider.notifier);

  Result<Host> build(Args a, Host? existing) {
    final address = a.optional<String>('address')?.trim() ?? existing?.address ?? '';
    final username = a.optional<String>('username')?.trim() ?? existing?.username ?? '';
    final port = a.optional<int>('port') ?? existing?.port ?? 22;
    if (address.isEmpty || username.isEmpty) return const Err(AppError('invalidArgument', detail: 'address, username'));
    if (port < 1 || port > 65535) return const Err(AppError('invalidArgument', detail: 'port'));
    final auth = AuthKind.values.asNameMap()[a.optional<String>('auth')] ?? existing?.auth ?? AuthKind.password;
    var keyPath = a.optional<String>('keyPath') ?? existing?.keyPath;
    var keyId = a.optional<String>('keyId') ?? existing?.keyId;
    // Naming one way to find the key drops the other.
    if (a.raw.containsKey('keyPath')) keyId = null;
    if (a.raw.containsKey('keyId')) keyPath = null;
    if (keyId != null && ref.read(keysProvider.notifier).byId(keyId) == null) {
      return const Err(AppError('notFound', detail: 'keyId'));
    }
    if (auth == AuthKind.key && keyId == null && (keyPath == null || keyPath.trim().isEmpty)) {
      return const Err(AppError('invalidArgument', detail: 'keyPath'));
    }
    final tags = a.raw['tags'];
    if (tags != null && (tags is! List || tags.any((t) => t is! String))) {
      return const Err(AppError('invalidArgument', detail: 'tags'));
    }
    final jumpValue = a.optional<String>('jumpHostId');
    final jump = jumpValue == null
        ? existing?.jumpHostId
        : jumpValue.isEmpty
        ? null
        : HostId(jumpValue);
    if (jump != null && (hosts().byId(jump) == null || jump == existing?.id)) {
      return const Err(AppError('invalidArgument', detail: 'jumpHostId'));
    }
    Proxy? proxy = existing?.proxy;
    if (a.has('proxy')) {
      final raw = a.raw['proxy'];
      if (raw == null) {
        proxy = null;
      } else if (raw is Map &&
          raw['kind'] is String &&
          raw['address'] is String &&
          raw['port'] is int &&
          (raw['username'] == null || raw['username'] is String)) {
        final kind = ProxyKind.values.asNameMap()[raw['kind']];
        final address = (raw['address'] as String).trim();
        final port = raw['port'] as int;
        if (kind == null || address.isEmpty || port < 1 || port > 65535) {
          return const Err(AppError('invalidArgument', detail: 'proxy'));
        }
        proxy = Proxy(kind, address, port, username: raw['username'] as String? ?? '');
      } else {
        return const Err(AppError('invalidArgument', detail: 'proxy'));
      }
    }
    return Ok(
      Host(
        id: existing?.id ?? HostsNotifier.newId(),
        label: a.optional<String>('label')?.trim() ?? existing?.label ?? '',
        address: address,
        port: port,
        username: username,
        auth: auth,
        keyPath: auth == AuthKind.key && keyId == null ? keyPath!.trim() : null,
        keyId: auth == AuthKind.key ? keyId : null,
        group: normalizeGroup(a.optional<String>('group') ?? existing?.group ?? ''),
        tags: tags == null ? existing?.tags ?? const [] : parseTags((tags as List).join(',')),
        pinned: a.optional<bool>('pinned') ?? existing?.pinned ?? false,
        lastUsed: existing?.lastUsed,
        jumpHostId: jump,
        proxy: proxy,
        legacy: a.optional<bool>('legacy') ?? existing?.legacy ?? false,
      ),
    );
  }

  Result<Host> find(Args a) {
    final host = hosts().byId(HostId(a.require<String>('hostId')));
    return host == null ? const Err(AppError('notFound', detail: 'host')) : Ok(host);
  }

  return [
    FunctionCapability(
      'host.list',
      Effect.query,
      (_, _) async => Ok([for (final h in ref.read(hostsProvider)) hostDto(h)]),
    ),
    FunctionCapability(
      'host.create',
      Effect.localChange,
      inputSchema: const {
        'type': 'object',
        'properties': _hostFields,
        'required': ['address', 'username'],
      },
      (a, _) async {
        final host = build(a, null);
        if (host is Ok<Host>) await hosts().save(host.value);
        return host is Ok<Host> ? Ok(hostDto(host.value)) : host;
      },
    ),
    FunctionCapability(
      'host.update',
      Effect.localChange,
      inputSchema: const {
        'type': 'object',
        'properties': {
          'hostId': {'type': 'string'},
          ..._hostFields,
        },
        'required': ['hostId'],
      },
      (a, _) async {
        final existing = find(a);
        if (existing is! Ok<Host>) return existing;
        final host = build(a, existing.value);
        if (host is Ok<Host>) await hosts().save(host.value);
        return host is Ok<Host> ? Ok(hostDto(host.value)) : host;
      },
    ),
    FunctionCapability(
      'host.delete',
      Effect.localChange,
      inputSchema: const {
        'type': 'object',
        'properties': {
          'hostId': {'type': 'string'},
        },
        'required': ['hostId'],
      },
      (a, _) async {
        final existing = find(a);
        if (existing is! Ok<Host>) return existing;
        await hosts().delete(existing.value);
        return const Ok(null);
      },
    ),
  ];
}

List<PaletteEntry> hostPaletteEntries(PaletteContext c) => [
  for (final h in sortHosts(c.ref.read(hostsProvider), recent: true))
    PaletteEntry(
      section: PaletteSection.hosts,
      title: h.title,
      subtitle: h.group.isEmpty ? h.target : '${h.target} · ${h.group}',
      icon: Icons.dns_outlined,
      run: () => c.dispatch('session.open', {'hostId': h.id.value}),
    ),
];

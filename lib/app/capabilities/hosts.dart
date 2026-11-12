import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../foundation/ids.dart';
import '../../foundation/json_file.dart';
import '../../features/capabilities/api.dart';
import '../../features/hosts/api.dart';
import 'host_library.dart';

/// Host metadata for callers outside the vault: effective values, no secret references, no key paths.
Map<String, Object?> hostDto(Host h) => {
  'id': h.id.value,
  'label': h.label,
  'address': h.address,
  'port': h.port,
  'username': h.username,
  'auth': h.auth.name,
  ...policyDto(h.policy),
  'identityId': ?h.overrides?.authentication.value?.identityId,
  'group': h.group,
  'groupId': ?h.groupId,
  'tags': h.tags,
  'pinned': h.pinned,
  'jumpHostId': ?h.jumpHostId?.value,
  'proxy': ?h.proxy?.toJson(),
  'legacy': h.legacy,
  if (h.overrides != null) 'inherit': inheritedFields(h.overrides!),
  if (h.lastUsed != null) 'lastUsed': h.lastUsed!.toUtc().toIso8601String(),
};

/// What the agent may see about a saved host: no address, login, proxy or key metadata.
Map<String, Object?> agentHostDto(Host h) => {
  'id': h.id.value,
  'label': h.label,
  'group': h.group,
  'groupId': ?h.groupId,
  'tags': h.tags,
  'pinned': h.pinned,
};

const _hostFields = {
  'label': {'type': 'string'},
  'address': {'type': 'string'},
  'group': {'type': 'string', 'description': 'Slash-separated path such as prod/web; empty for none.'},
  'tags': {
    'type': 'array',
    'items': {'type': 'string'},
  },
  'pinned': {'type': 'boolean'},
  ...connectionFields,
};

List<Capability> hostCapabilities(Ref ref) {
  HostsNotifier hosts() => ref.read(hostsProvider.notifier);

  /// The host the call describes. Fields that are not given keep what [existing] has, and a new host inherits
  /// whatever its group and the global defaults provide.
  Host build(Args a, Host? existing) {
    final address = a.optional<String>('address')?.trim() ?? existing?.address ?? '';
    if (address.isEmpty) throw const Rejected('invalidArgument', 'address');
    final tags = a.raw['tags'];
    if (tags != null && (tags is! List || tags.any((t) => t is! String))) {
      throw const Rejected('invalidArgument', 'tags');
    }
    final base = existing == null ? const ConnectionOverrides() : existing.overrides ?? explicitConnection(existing);
    final overrides = patchConnection(
      ref,
      a,
      base,
      login: existing == null ? null : (username: existing.username, policy: existing.policy),
      self: existing?.id,
    );
    // Naming a group path moves the host there, creating the group if needed.
    final path = a.optional<String>('group');
    final moved = path != null && normalizeGroup(path) != (existing?.group ?? '');
    return Host(
      id: existing?.id ?? HostsNotifier.newId(),
      label: a.optional<String>('label')?.trim() ?? existing?.label ?? '',
      address: address,
      // Placeholders: the library resolves every connection setting from [overrides].
      username: existing?.username ?? '',
      group: moved ? normalizeGroup(path) : existing?.group ?? '',
      groupId: moved ? null : existing?.groupId,
      tags: tags == null ? existing?.tags ?? const [] : parseTags((tags as List).join(',')),
      pinned: a.optional<bool>('pinned') ?? existing?.pinned ?? false,
      lastUsed: existing?.lastUsed,
      overrides: overrides,
    );
  }

  Host find(Args a) => hosts().byId(HostId(a.require<String>('hostId'))) ?? (throw const Rejected('notFound', 'host'));

  Future<T> persist<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on JsonFileError catch (error) {
      throw Rejected(error.kind.name);
    }
  }

  Future<Object?> save(Host host, Origin origin) async {
    await persist(() => hosts().save(host, expectedRevision: hosts().revision));
    final saved = hosts().byId(host.id)!;
    return origin == Origin.agent ? agentHostDto(saved) : hostDto(saved);
  }

  return [
    FunctionCapability(
      'host.list',
      Effect.query,
      guarded((_) async => [for (final h in ref.read(hostsProvider)) hostDto(h)]),
    ),
    FunctionCapability(
      'host.create',
      Effect.localChange,
      inputSchema: const {
        'type': 'object',
        'properties': _hostFields,
        'required': ['address'],
      },
      agentExposed: true,
      guardedWithContext((a, c) => save(build(a, null), c.origin)),
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
      agentExposed: true,
      guardedWithContext((a, c) => save(build(a, find(a)), c.origin)),
    ),
    FunctionCapability(
      'host.move',
      Effect.localChange,
      inputSchema: const {
        'type': 'object',
        'properties': {
          'hostIds': {
            'type': 'array',
            'items': {'type': 'string'},
            'minItems': 1,
          },
          'groupId': {
            'type': ['string', 'null'],
            'description': 'A group from group.list; absent or null means no group.',
          },
          'group': {
            'type': 'string',
            'description': 'Slash-separated group path such as prod/web; created when missing.',
          },
        },
        'required': ['hostIds'],
      },
      agentExposed: true,
      guardedWithContext((a, c) async {
        final raw = a.raw['hostIds'];
        if (raw is! List || raw.isEmpty || raw.any((id) => id is! String || id.isEmpty)) {
          throw const Rejected('invalidArgument', 'hostIds');
        }
        final ids = [for (final id in raw) HostId(id as String)];
        final groupId = a.optional<String>('groupId');
        final path = a.optional<String>('group');
        if (path != null && groupId != null) throw const Rejected('invalidArgument', 'group');
        if (groupId != null && hosts().library.groupById(groupId) == null) throw const Rejected('notFound', 'group');
        if (ids.any((id) => hosts().byId(id) == null)) throw const Rejected('notFound', 'host');
        final revision = hosts().revision;
        await persist(
          () => path == null
              ? hosts().moveToGroup(ids, groupId, expectedRevision: revision)
              : hosts().moveToGroupPath(ids, normalizeGroup(path), expectedRevision: revision),
        );
        return [
          for (final id in ids.toSet())
            c.origin == Origin.agent ? agentHostDto(hosts().byId(id)!) : hostDto(hosts().byId(id)!),
        ];
      }),
    ),
    FunctionCapability(
      'host.deleteMany',
      Effect.localChange,
      inputSchema: const {
        'type': 'object',
        'properties': {
          'hostIds': {
            'type': 'array',
            'items': {'type': 'string'},
            'minItems': 1,
          },
        },
        'required': ['hostIds'],
      },
      guarded((a) async {
        final raw = a.raw['hostIds'];
        if (raw is! List || raw.isEmpty || raw.any((id) => id is! String || id.isEmpty)) {
          throw const Rejected('invalidArgument', 'hostIds');
        }
        final ids = [for (final id in raw) HostId(id as String)];
        if (ids.any((id) => hosts().byId(id) == null)) throw const Rejected('notFound', 'host');
        try {
          await hosts().deleteMany(ids);
        } on HostDeleteCleanupFailure {
          throw const Rejected('cleanupFailed');
        }
        return null;
      }),
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
      agentExposed: true,
      guarded((a) async {
        final host = find(a), revision = hosts().revision;
        await persist(() => hosts().delete(host, expectedRevision: revision));
        return null;
      }),
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

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../foundation/ids.dart';
import '../../../foundation/result.dart';
import '../../capabilities/api.dart';
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
    final keyPath = a.optional<String>('keyPath') ?? existing?.keyPath;
    if (auth == AuthKind.key && (keyPath == null || keyPath.trim().isEmpty)) {
      return const Err(AppError('invalidArgument', detail: 'keyPath'));
    }
    return Ok(Host(
      id: existing?.id ?? HostsNotifier.newId(),
      label: a.optional<String>('label')?.trim() ?? existing?.label ?? '',
      address: address,
      port: port,
      username: username,
      auth: auth,
      keyPath: auth == AuthKind.key ? keyPath!.trim() : null,
    ));
  }

  Result<Host> find(Args a) {
    final host = hosts().byId(HostId(a.require<String>('hostId')));
    return host == null ? const Err(AppError('notFound', detail: 'host')) : Ok(host);
  }

  return [
    FunctionCapability('host.list', Effect.query, (_, _) async => Ok([for (final h in ref.read(hostsProvider)) hostDto(h)])),
    FunctionCapability(
      'host.create',
      Effect.localChange,
      inputSchema: const {'type': 'object', 'properties': _hostFields, 'required': ['address', 'username']},
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
        'properties': {'hostId': {'type': 'string'}, ..._hostFields},
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
        'properties': {'hostId': {'type': 'string'}},
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
      for (final h in c.ref.read(hostsProvider))
        PaletteEntry(
          section: PaletteSection.hosts,
          title: h.title,
          subtitle: h.target,
          icon: Icons.dns_outlined,
          run: () => c.dispatch('session.open', {'hostId': h.id.value}),
        ),
    ];

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../foundation/ids.dart';
import '../../foundation/result.dart';
import '../../features/capabilities/api.dart';
import '../../features/forwarding/api.dart';

const _ruleSchema = {
  'id': {'type': 'string'},
  'hostId': {'type': 'string'},
  'label': {'type': 'string'},
  'kind': {
    'type': 'string',
    'enum': ['local', 'remote', 'dynamic'],
  },
  'listenAddress': {'type': 'string'},
  'listenPort': {'type': 'integer'},
  'destinationAddress': {'type': 'string'},
  'destinationPort': {'type': 'integer'},
  'autoStart': {'type': 'boolean'},
  'autoReconnect': {'type': 'boolean'},
  'confirmExposed': {'type': 'boolean'},
};

const _idSchema = {
  'type': 'object',
  'properties': {
    'id': {'type': 'string'},
  },
  'required': ['id'],
};

/// Forwarding is never offered to the AI: it opens network paths into and out of this computer.
List<Capability> forwardCapabilities(Ref ref) {
  Forwards forwards() => ref.read(forwardsProvider.notifier);

  Future<Result<Object?>> guarded(Future<Result<Object?>> Function() action) async {
    try {
      return await action();
    } on ForwardError catch (e) {
      return Err(AppError(e.code, detail: e.detail));
    }
  }

  Result<Object?> outcome(ForwardState s) => switch (s.phase) {
    ForwardPhase.running || ForwardPhase.stopped || ForwardPhase.reconnecting => Ok(s.toJson()),
    _ => Err(AppError(s.error ?? s.phase.name, detail: s.detail)),
  };

  return [
    FunctionCapability(
      'forward.list',
      Effect.query,
      (a, context) async => Ok([for (final s in ref.read(forwardsProvider)) s.toJson()]),
    ),
    FunctionCapability(
      'forward.save',
      Effect.localChange,
      (a, context) => guarded(() async {
        final rule = ForwardRule(
          id: ForwardId(a.optional<String>('id') ?? newId()),
          hostId: HostId(a.require<String>('hostId')),
          label: a.optional<String>('label') ?? '',
          kind: ForwardKind.values.byName(a.require<String>('kind')),
          listenAddress: a.optional<String>('listenAddress') ?? '127.0.0.1',
          listenPort: a.require<int>('listenPort'),
          destinationAddress: a.optional<String>('destinationAddress') ?? '127.0.0.1',
          destinationPort: a.optional<int>('destinationPort') ?? 0,
          autoStart: a.optional<bool>('autoStart') ?? false,
          autoReconnect: a.optional<bool>('autoReconnect') ?? false,
        );
        await forwards().save(rule, exposureConfirmed: a.optional<bool>('confirmExposed') ?? false);
        return Ok(rule.toJson());
      }),
      inputSchema: const {
        'type': 'object',
        'properties': _ruleSchema,
        'required': ['hostId', 'kind', 'listenPort'],
      },
    ),
    FunctionCapability(
      'forward.delete',
      Effect.localChange,
      (a, context) => guarded(() async {
        await forwards().delete(ForwardId(a.require<String>('id')));
        return const Ok(null);
      }),
      inputSchema: _idSchema,
    ),
    FunctionCapability(
      'forward.start',
      Effect.connect,
      (a, context) => guarded(() async => outcome(await forwards().start(ForwardId(a.require<String>('id'))))),
      inputSchema: _idSchema,
    ),
    FunctionCapability(
      'forward.stop',
      Effect.localChange,
      (a, context) => guarded(() async => outcome(await forwards().stop(ForwardId(a.require<String>('id'))))),
      inputSchema: _idSchema,
    ),
  ];
}

List<PaletteEntry> forwardPaletteEntries(PaletteContext c) => [
  for (final s in c.ref.read(forwardsProvider))
    if (s.phase != ForwardPhase.stopping)
      PaletteEntry(
        section: PaletteSection.actions,
        title: '${s.active ? c.l.stop : c.l.fwStart} · ${s.rule.title}',
        subtitle: s.rule.kind == ForwardKind.dynamic ? s.rule.endpoint : '${s.rule.endpoint} → ${s.rule.destination}',
        icon: Icons.swap_horiz,
        run: () => c.dispatch(s.active ? 'forward.stop' : 'forward.start', {'id': s.rule.id.value}),
      ),
];

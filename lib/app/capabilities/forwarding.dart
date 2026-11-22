import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../foundation/ids.dart';
import '../../foundation/result.dart';
import '../../features/capabilities/api.dart';
import '../../features/forwarding/api.dart';
import '../mcp/controller.dart';

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

/// Forwarding opens network paths into and out of this computer; the agent gets it only with per-host approval.
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
      agentExposed: true,
      externalAgentExposed: true,
      (a, context) async => Ok([
        for (final s in ref.read(forwardsProvider))
          if (context.authority is! McpCall || (context.authority as McpCall).canSeeHost(s.rule.hostId)) s.toJson(),
      ]),
    ),
    FunctionCapability(
      'forward.save',
      Effect.localChange,
      agentExposed: true,
      externalAgentExposed: true,
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
        final expected = forwards().byId(rule.id)?.rule;
        await forwards().save(
          rule,
          exposureConfirmed: context.origin != Origin.externalAgent && a.optional<bool>('confirmExposed') == true,
          checkExpected: context.origin.isAgent,
          expected: expected,
        );
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
      agentExposed: true,
      externalAgentExposed: true,
      (a, context) => guarded(() async {
        final id = ForwardId(a.require<String>('id'));
        await forwards().delete(id, checkExpected: context.origin.isAgent, expected: forwards().byId(id)?.rule);
        return const Ok(null);
      }),
      inputSchema: _idSchema,
    ),
    FunctionCapability(
      'forward.start',
      Effect.connect,
      agentExposed: true,
      externalAgentExposed: true,
      (a, context) => guarded(() async {
        final id = ForwardId(a.require<String>('id'));
        final known = forwards().byId(id) ?? (throw const ForwardError(ForwardErrors.unknown));
        final host = a.optional<String>('hostId');
        if (host != null && known.rule.hostId != HostId(host)) {
          throw const ForwardError(ForwardErrors.unknown);
        }
        return outcome(
          await forwards().start(
            id,
            cancel: context.cancellation,
            deadline: context.deadline,
            isCurrent: () => context.isCurrent,
          ),
        );
      }),
      inputSchema: const {
        'type': 'object',
        'properties': {
          'id': {'type': 'string'},
          'hostId': {'type': 'string', 'description': 'the saved host the rule belongs to'},
        },
        'required': ['id'],
      },
    ),
    FunctionCapability(
      'forward.stop',
      Effect.localChange,
      agentExposed: true,
      externalAgentExposed: true,
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

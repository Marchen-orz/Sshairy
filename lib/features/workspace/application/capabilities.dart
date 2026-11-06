import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../foundation/ids.dart';
import '../../../foundation/result.dart';
import '../../capabilities/api.dart';
import '../../hosts/api.dart';
import '../domain/layout.dart';
import 'workspace.dart';

List<Capability> workspaceCapabilities(Ref ref) {
  Workspace workspace() => ref.read(workspaceProvider.notifier);

  return [
    FunctionCapability(
      'session.open',
      Effect.connect,
      inputSchema: const {
        'type': 'object',
        'properties': {'hostId': {'type': 'string'}},
        'required': ['hostId'],
      },
      (a, _) async {
        final host = ref.read(hostsProvider.notifier).byId(HostId(a.require<String>('hostId')));
        if (host == null) return const Err(AppError('notFound', detail: 'host'));
        return Ok({'tabId': workspace().openHost(host).value});
      },
    ),
    FunctionCapability(
      'session.close',
      Effect.localChange,
      inputSchema: const {
        'type': 'object',
        'properties': {'tabId': {'type': 'string'}},
      },
      (a, _) async {
        final id = a.optional<String>('tabId');
        id == null ? workspace().closeFocused() : workspace().closeTab(TabId(id));
        return const Ok(null);
      },
    ),
    FunctionCapability(
      'workspace.focus',
      Effect.localChange,
      inputSchema: const {
        'type': 'object',
        'properties': {'tabId': {'type': 'string', 'description': 'omit for the host vault'}},
      },
      (a, _) async {
        final id = a.optional<String>('tabId');
        id == null ? workspace().showVault() : workspace().activate(TabId(id));
        return const Ok(null);
      },
    ),
    FunctionCapability(
      'workspace.split',
      Effect.connect,
      inputSchema: const {
        'type': 'object',
        'properties': {
          'axis': {
            'type': 'string',
            'enum': ['horizontal', 'vertical'],
          },
        },
        'required': ['axis'],
      },
      (a, _) async {
        final axis = SplitAxis.values.asNameMap()[a.require<String>('axis')];
        if (axis == null) return const Err(AppError('invalidArgument', detail: 'axis'));
        return workspace().split(axis) ? const Ok(null) : const Err(AppError('cannotSplit'));
      },
    ),
  ];
}

List<PaletteEntry> workspacePaletteEntries(PaletteContext c) {
  final l = c.l;
  final state = c.ref.read(workspaceProvider);
  final workspace = c.ref.read(workspaceProvider.notifier);
  return [
    for (final t in state.tabs)
      if (workspace.session(t.layout.focusedLeaf.session) case final s?)
        PaletteEntry(
          section: PaletteSection.sessions,
          title: s.host.title,
          subtitle: s.host.target,
          icon: Icons.terminal,
          run: () => c.dispatch('workspace.focus', {'tabId': t.id.value}),
        ),
    PaletteEntry(
      section: PaletteSection.actions,
      title: l.newConnection,
      icon: Icons.add,
      run: () => c.dispatch('workspace.focus'),
    ),
    if (state.activeTab != null) ...[
      PaletteEntry(
        section: PaletteSection.actions,
        title: l.splitRight,
        icon: Icons.vertical_split_outlined,
        run: () => c.dispatch('workspace.split', {'axis': 'horizontal'}),
      ),
      PaletteEntry(
        section: PaletteSection.actions,
        title: l.splitDown,
        icon: Icons.horizontal_split_outlined,
        run: () => c.dispatch('workspace.split', {'axis': 'vertical'}),
      ),
      PaletteEntry(
        section: PaletteSection.actions,
        title: l.closePane,
        icon: Icons.close,
        run: () => c.dispatch('session.close'),
      ),
    ],
  ];
}

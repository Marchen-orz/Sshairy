import 'dart:async';

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
        'properties': {
          'tabId': {'type': 'string', 'description': 'omit for the host vault or the view'},
          'view': {
            'type': 'string',
            'enum': ['vault', 'files'],
            'description': 'a page that is not a tab; ignored with tabId',
          },
        },
      },
      (a, _) async {
        final id = a.optional<String>('tabId');
        if (id != null) {
          if (_tab(ref, TabId(id)) == null) return const Err(AppError('notFound', detail: 'tab'));
          workspace().activate(TabId(id));
        } else if (a.optional<String>('view') == 'files') {
          workspace().showFiles();
        } else {
          workspace().showVault();
        }
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
    FunctionCapability(
      'session.reconnect',
      Effect.connect,
      inputSchema: const {
        'type': 'object',
        'properties': {'tabId': {'type': 'string', 'description': 'omit for the active tab'}},
      },
      (a, _) async {
        final id = a.optional<String>('tabId');
        final tab = id == null ? ref.read(workspaceProvider).activeTab : _tab(ref, TabId(id));
        final s = tab == null ? null : workspace().session(tab.layout.focusedLeaf.session);
        if (s == null) return const Err(AppError('notFound', detail: 'tab'));
        if (!s.canReconnect) return const Err(AppError('cannotReconnect'));
        unawaited(s.connect());
        return const Ok(null);
      },
    ),
    FunctionCapability(
      'workspace.renameTab',
      Effect.localChange,
      inputSchema: const {
        'type': 'object',
        'properties': {
          'tabId': {'type': 'string'},
          'title': {
            'type': ['string', 'null'],
            'description': 'null or empty goes back to the host name',
          },
        },
        'required': ['tabId'],
      },
      (a, _) async {
        final id = TabId(a.require<String>('tabId'));
        if (_tab(ref, id) == null) return const Err(AppError('notFound', detail: 'tab'));
        workspace().rename(id, a.optional<String>('title'));
        return const Ok(null);
      },
    ),
    FunctionCapability(
      'workspace.duplicateTab',
      Effect.connect,
      inputSchema: const {
        'type': 'object',
        'properties': {'tabId': {'type': 'string', 'description': 'omit for the active tab'}},
      },
      (a, _) async {
        final id = a.optional<String>('tabId');
        final tab = id == null ? ref.read(workspaceProvider).activeTab : _tab(ref, TabId(id));
        final copy = tab == null ? null : workspace().duplicate(tab.id);
        return copy == null ? const Err(AppError('notFound', detail: 'tab')) : Ok({'tabId': copy.value});
      },
    ),
  ];
}

WorkspaceTab? _tab(Ref ref, TabId id) => ref.read(workspaceProvider).tabs.where((t) => t.id == id).firstOrNull;

List<PaletteEntry> workspacePaletteEntries(PaletteContext c) {
  final l = c.l;
  final state = c.ref.read(workspaceProvider);
  final workspace = c.ref.read(workspaceProvider.notifier);
  return [
    for (final t in state.tabs)
      if (workspace.session(t.layout.focusedLeaf.session) case final s?)
        PaletteEntry(
          section: PaletteSection.sessions,
          title: t.title ?? s.host.title,
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
      PaletteEntry(
        section: PaletteSection.actions,
        title: l.duplicate,
        icon: Icons.copy_all_outlined,
        run: () => c.dispatch('workspace.duplicateTab'),
      ),
      if (workspace.focusedSession?.canReconnect ?? false)
        PaletteEntry(
          section: PaletteSection.actions,
          title: l.retry,
          icon: Icons.refresh,
          run: () => c.dispatch('session.reconnect'),
        ),
    ],
  ];
}

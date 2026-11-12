import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../foundation/ids.dart';
import '../../foundation/result.dart';
import '../../features/capabilities/api.dart';
import '../../features/hosts/api.dart';
import '../../features/terminal/api.dart';
import '../../features/workspace/api.dart';

List<Capability> workspaceCapabilities(Ref ref) {
  Workspace workspace() => ref.read(workspaceProvider.notifier);

  return [
    FunctionCapability(
      'session.open',
      Effect.connect,
      inputSchema: const {
        'type': 'object',
        'properties': {
          'hostId': {'type': 'string'},
        },
        'required': ['hostId'],
      },
      agentExposed: true,
      (a, _) async {
        final host = ref.read(hostsProvider.notifier).byId(HostId(a.require<String>('hostId')));
        if (host == null) return const Err(AppError('notFound', detail: 'host'));
        return Ok({'tabId': workspace().openHost(host).value});
      },
    ),
    FunctionCapability(
      'session.openLocal',
      Effect.connect,
      inputSchema: const {
        'type': 'object',
        'properties': {
          'executable': {'type': 'string'},
        },
        'required': ['executable'],
      },
      (a, _) async {
        final executable = a.require<String>('executable');
        final shell = ref.read(localShellsProvider).where((s) => s.executable == executable).firstOrNull;
        if (shell == null) return const Err(AppError('notFound', detail: 'localShell'));
        return Ok({'tabId': workspace().openLocal(shell).value});
      },
    ),
    FunctionCapability(
      'session.close',
      Effect.localChange,
      inputSchema: const {
        'type': 'object',
        'properties': {
          'tabId': {'type': 'string'},
        },
      },
      agentExposed: true,
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
      agentExposed: true,
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
          'tabId': {'type': 'string'},
          'paneId': {'type': 'string'},
          'side': {
            'type': 'string',
            'enum': ['left', 'right', 'top', 'bottom'],
          },
        },
      },
      agentExposed: true,
      (a, _) async {
        final rawAxis = a.optional<String>('axis'), rawSide = a.optional<String>('side');
        final axis = SplitAxis.values.asNameMap()[rawAxis], side = PaneSide.values.asNameMap()[rawSide];
        if ((rawAxis != null && axis == null) || (rawSide == null && axis == null)) {
          return const Err(AppError('invalidArgument', detail: 'axis'));
        }
        if (rawSide != null && side == null) return const Err(AppError('invalidArgument', detail: 'side'));
        final id = a.optional<String>('tabId');
        final tab = id == null ? ref.read(workspaceProvider).activeTab : _tab(ref, TabId(id));
        if (tab == null) return const Err(AppError('cannotSplit'));
        final pane = a.optional<String>('paneId');
        final added = workspace().splitPane(
          tab.id,
          pane == null ? tab.layout.focused : PaneId(pane),
          side ?? (axis == SplitAxis.horizontal ? PaneSide.right : PaneSide.bottom),
        );
        return added == null ? const Err(AppError('cannotSplit')) : const Ok(null);
      },
    ),
    FunctionCapability(
      'workspace.moveTerminal',
      Effect.localChange,
      inputSchema: const {
        'type': 'object',
        'properties': {
          'sourceTabId': {'type': 'string'},
          'sourcePaneId': {'type': 'string'},
          'targetTabId': {'type': 'string'},
          'targetPaneId': {'type': 'string'},
          'side': {
            'type': 'string',
            'enum': ['left', 'right', 'top', 'bottom'],
          },
        },
        'required': ['sourceTabId', 'targetTabId', 'targetPaneId', 'side'],
      },
      (a, _) async {
        final side = PaneSide.values.asNameMap()[a.require<String>('side')];
        if (side == null) return const Err(AppError('invalidArgument', detail: 'side'));
        final source = a.optional<String>('sourcePaneId');
        final moved = workspace().moveTerminal(
          sourceTabId: TabId(a.require<String>('sourceTabId')),
          sourcePaneId: source == null ? null : PaneId(source),
          targetTabId: TabId(a.require<String>('targetTabId')),
          targetPaneId: PaneId(a.require<String>('targetPaneId')),
          side: side,
        );
        return moved ? const Ok(null) : const Err(AppError('cannotMoveTerminal'));
      },
    ),
    FunctionCapability(
      'workspace.detachPane',
      Effect.localChange,
      inputSchema: const {
        'type': 'object',
        'properties': {
          'tabId': {'type': 'string'},
          'paneId': {'type': 'string'},
          'index': {'type': 'integer', 'minimum': 0},
        },
        'required': ['tabId', 'paneId', 'index'],
      },
      (a, _) async {
        final tab = workspace().detachPane(
          TabId(a.require<String>('tabId')),
          PaneId(a.require<String>('paneId')),
          a.require<int>('index'),
        );
        return tab == null ? const Err(AppError('cannotMoveTerminal')) : Ok({'tabId': tab.value});
      },
    ),
    FunctionCapability(
      'session.reconnect',
      Effect.connect,
      inputSchema: const {
        'type': 'object',
        'properties': {
          'tabId': {'type': 'string', 'description': 'omit for the active tab'},
        },
      },
      agentExposed: true,
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
      agentExposed: true,
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
        'properties': {
          'tabId': {'type': 'string', 'description': 'omit for the active tab'},
        },
      },
      (a, _) async {
        final id = a.optional<String>('tabId');
        final tab = id == null ? ref.read(workspaceProvider).activeTab : _tab(ref, TabId(id));
        final copy = tab == null ? null : workspace().duplicate(tab.id);
        return copy == null ? const Err(AppError('notFound', detail: 'tab')) : Ok({'tabId': copy.value});
      },
    ),
    FunctionCapability(
      'workspace.closeTabs',
      Effect.localChange,
      inputSchema: const {
        'type': 'object',
        'properties': {
          'tabId': {'type': 'string', 'description': 'the tab that stays open'},
          'scope': {
            'type': 'string',
            'enum': ['left', 'right', 'others'],
          },
        },
        'required': ['tabId', 'scope'],
      },
      agentExposed: true,
      (a, _) async {
        final id = TabId(a.require<String>('tabId'));
        final scope = TabCloseScope.values.asNameMap()[a.require<String>('scope')];
        if (scope == null) return const Err(AppError('invalidArgument', detail: 'scope'));
        if (_tab(ref, id) == null) return const Err(AppError('notFound', detail: 'tab'));
        return Ok({'closed': workspace().closeTabs(id, scope)});
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
          title: t.title ?? s.title,
          subtitle: s.targetLabel,
          icon: Icons.terminal,
          run: () => c.dispatch('workspace.focus', {'tabId': t.id.value}),
        ),
    PaletteEntry(
      section: PaletteSection.actions,
      title: l.newConnection,
      icon: Icons.add,
      run: () => c.dispatch('workspace.focus'),
    ),
    for (final shell in c.ref.read(localShellsProvider))
      PaletteEntry(
        section: PaletteSection.actions,
        title: shell.name,
        subtitle: shell.executable,
        icon: Icons.terminal,
        run: () => c.dispatch('session.openLocal', {'executable': shell.executable}),
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

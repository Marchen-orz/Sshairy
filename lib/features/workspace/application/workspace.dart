import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../foundation/data_dir.dart';
import '../../../foundation/file_system.dart';
import '../../../foundation/ids.dart';
import '../../../foundation/json_file.dart';
import '../../connections/api.dart' show ShellChannel;
import '../../hosts/api.dart';
import '../../terminal/api.dart';
import '../domain/layout.dart';

class WorkspaceTab {
  const WorkspaceTab(this.id, this.layout, {this.title});

  final TabId id;
  final Layout layout;

  /// Set by the user; null shows the host's name.
  final String? title;

  WorkspaceTab withLayout(Layout layout) => WorkspaceTab(id, layout, title: title);
}

/// Which tabs to close around a reference tab, which itself stays open.
enum TabCloseScope { left, right, others }

class WorkspaceState {
  const WorkspaceState({this.tabs = const [], this.active, this.files = false});

  final List<WorkspaceTab> tabs;

  /// null shows the host vault, or the SFTP page when [files] is set.
  final TabId? active;
  final bool files;

  /// The same view with other tabs.
  WorkspaceState withTabs(List<WorkspaceTab> tabs, {TabId? active}) {
    final a = active ?? this.active;
    return WorkspaceState(tabs: tabs, active: a, files: files && a == null);
  }

  WorkspaceTab? get activeTab => tabs.where((t) => t.id == active).firstOrNull;

  /// The tabs [scope] closes around [id], in tab order. Empty when that side has none or [id] is not open.
  List<WorkspaceTab> tabsToClose(TabId id, TabCloseScope scope) {
    final i = tabs.indexWhere((t) => t.id == id);
    if (i < 0) return const [];
    return switch (scope) {
      TabCloseScope.left => tabs.sublist(0, i),
      TabCloseScope.right => tabs.sublist(i + 1),
      TabCloseScope.others => [...tabs.sublist(0, i), ...tabs.sublist(i + 1)],
    };
  }
}

final workspaceProvider = NotifierProvider<Workspace, WorkspaceState>(Workspace.new);

/// Tabs and their split layouts. Sessions belong to [terminalSessionsProvider]; layouts only refer to them.
/// Saved hosts in the layout are written to workspace.json and come back as unconnected tabs (docs/MODULES.md §3).
class Workspace extends Notifier<WorkspaceState> {
  late final JsonFile _file = JsonFile(
    '${ref.read(dataDirProvider)}/workspace.json',
    schemaVersion: 2,
    migrations: {
      1: (json) => {...json, 'schemaVersion': 2},
    },
  );

  TerminalSessions get _sessions => ref.read(terminalSessionsProvider.notifier);

  @override
  WorkspaceState build() => _restore();

  /// Completes once the layout is on disk.
  Future<void> get saved => _file.idle;

  TerminalSession? session(SessionId id) => ref.read(terminalSessionsProvider)[id];

  /// The session in the focused pane of the active tab.
  TerminalSession? get focusedSession {
    final tab = state.activeTab;
    return tab == null ? null : session(tab.layout.focusedLeaf.session);
  }

  TabId openHost(Host host, {bool Function()? authorizeInitialConnection}) {
    if (!host.transient) ref.read(hostsProvider.notifier).touch(host.id).ignore();
    final s = _sessions.open(host, authorizeInitialConnection: authorizeInitialConnection);
    final tab = WorkspaceTab(TabId(newId()), Layout.single(PaneId(newId()), s.id));
    _set(WorkspaceState(tabs: [...state.tabs, tab], active: tab.id));
    return tab.id;
  }

  TabId openLocal(LocalShell shell) {
    final s = _sessions.openLocal(shell);
    final tab = WorkspaceTab(TabId(newId()), Layout.single(PaneId(newId()), s.id));
    _set(WorkspaceState(tabs: [...state.tabs, tab], active: tab.id));
    return tab.id;
  }

  /// A desktop session has one mirror window: a live one is brought forward, a dead one is replaced.
  TabId openRemote(
    LinkTerminalTarget target,
    Future<ShellChannel> Function(int cols, int rows) openChannel, {
    Future<FileSystem> Function()? files,
  }) {
    if (target.kind == LinkTerminalKind.mirror) {
      for (final tab in state.tabs) {
        final mirror = session(tab.layout.focusedLeaf.session);
        final open = mirror?.linkTarget;
        if (open == null ||
            open.kind != LinkTerminalKind.mirror ||
            open.peerId != target.peerId ||
            open.remoteId != target.remoteId) {
          continue;
        }
        if (mirror!.status != SessionStatus.failed && mirror.status != SessionStatus.disconnected) {
          activate(tab.id);
          return tab.id;
        }
        closeTab(tab.id);
        break;
      }
    }
    final s = _sessions.openRemote(target, openChannel, files: files);
    final tab = WorkspaceTab(TabId(newId()), Layout.single(PaneId(newId()), s.id));
    _set(WorkspaceState(tabs: [...state.tabs, tab], active: tab.id));
    return tab.id;
  }

  TerminalSession? _copySession(TerminalSession session, bool Function()? authorizeInitialConnection) =>
      switch (session.target) {
        LocalTerminalTarget(:final shell) => _sessions.openLocal(shell),
        SshTerminalTarget() => _sessions.open(session.host, authorizeInitialConnection: authorizeInitialConnection),
        LinkTerminalTarget() => null,
      };

  /// A new tab with a fresh shell on the same target as [id]'s focused pane; the running process is not copied.
  TabId? duplicate(TabId id) {
    final tab = _tab(id);
    final s = tab == null ? null : session(tab.layout.focusedLeaf.session);
    if (s == null || s.isRemote) return null;
    return switch (s.localShell) {
      final shell? => openLocal(shell),
      null => openHost(s.host),
    };
  }

  /// An empty or blank [title] goes back to the host's name.
  void rename(TabId id, String? title) {
    final t = title?.trim();
    _set(
      state.withTabs([
        for (final tab in state.tabs)
          tab.id == id ? WorkspaceTab(id, tab.layout, title: t == null || t.isEmpty ? null : t) : tab,
      ]),
    );
  }

  void showVault() => _set(WorkspaceState(tabs: state.tabs));

  void showFiles() => _set(WorkspaceState(tabs: state.tabs, files: true));

  void activate(TabId id) {
    if (state.tabs.any((t) => t.id == id)) _set(WorkspaceState(tabs: state.tabs, active: id));
  }

  /// Activates the next or previous tab; the vault sits before the first tab.
  void cycle(int delta) {
    final ids = <TabId?>[null, ...state.tabs.map((t) => t.id)];
    final i = ids.indexOf(state.active);
    _set(WorkspaceState(tabs: state.tabs, active: ids[(i + delta) % ids.length]));
  }

  void moveTab(int from, int to) {
    final tabs = [...state.tabs];
    tabs.insert(to.clamp(0, tabs.length - 1), tabs.removeAt(from));
    _set(state.withTabs(tabs));
  }

  void closeTab(TabId id) {
    final i = state.tabs.indexWhere((t) => t.id == id);
    if (i < 0) return;
    _closeSessions(state.tabs[i]);
    final tabs = [...state.tabs]..removeAt(i);
    if (state.active != id) return _set(state.withTabs(tabs));
    _set(WorkspaceState(tabs: tabs, active: tabs.isEmpty ? null : tabs[i.clamp(0, tabs.length - 1)].id));
  }

  /// Closes the tabs [scope] picks around [id] with one layout write; [id] stays open. The active tab stays too,
  /// unless it is among those closed, then [id] takes over. Returns how many tabs were closed, 0 when [id] is gone.
  int closeTabs(TabId id, TabCloseScope scope) {
    final targets = state.tabsToClose(id, scope);
    if (targets.isEmpty) return 0;
    targets.forEach(_closeSessions);
    final closing = {for (final t in targets) t.id};
    final tabs = [
      for (final t in state.tabs)
        if (!closing.contains(t.id)) t,
    ];
    _set(closing.contains(state.active) ? WorkspaceState(tabs: tabs, active: id) : state.withTabs(tabs));
    return targets.length;
  }

  void closePane(TabId tabId, PaneId pane) {
    final tab = _tab(tabId);
    if (tab == null) return;
    final leaf = tab.layout.leaves.where((l) => l.pane == pane).firstOrNull;
    if (leaf == null) return;
    final next = tab.layout.remove(pane);
    if (next == null) return closeTab(tabId);
    _sessions.close(leaf.session);
    _replace(tabId, next);
  }

  /// Closes the focused pane, or the tab when it has one pane.
  void closeFocused() {
    final tab = state.activeTab;
    if (tab != null) closePane(tab.id, tab.layout.focused);
  }

  /// Opens another shell beside the focused pane, sharing the same target rather than its process.
  bool split(SplitAxis axis) {
    final tab = state.activeTab;
    return tab != null &&
        splitPane(tab.id, tab.layout.focused, axis == SplitAxis.horizontal ? PaneSide.right : PaneSide.bottom) != null;
  }

  bool canSplitPane(TabId tabId, PaneId pane, {Layout? expectedLayout}) {
    final tab = _tab(tabId);
    return tab != null &&
        (expectedLayout == null || identical(tab.layout, expectedLayout)) &&
        tab.layout.leaves.length < Layout.maxPanes &&
        tab.layout.leaves.any((leaf) => leaf.pane == pane && session(leaf.session) != null);
  }

  PaneId? splitPane(
    TabId tabId,
    PaneId pane,
    PaneSide side, {
    Layout? expectedLayout,
    bool Function()? authorizeInitialConnection,
  }) {
    if (!canSplitPane(tabId, pane, expectedLayout: expectedLayout)) return null;
    final tab = _tab(tabId)!;
    final current = session(tab.layout.leaves.firstWhere((leaf) => leaf.pane == pane).session)!;
    final added = PaneId(newId());
    final s = _copySession(current, authorizeInitialConnection);
    if (s == null) return null;
    final next = tab.layout.insert(pane, side, Layout.single(added, s.id));
    if (next == null) {
      _sessions.close(s.id);
      return null;
    }
    _set(WorkspaceState(tabs: [for (final t in state.tabs) t.id == tabId ? t.withLayout(next) : t], active: tabId));
    return added;
  }

  bool canMoveTerminal({
    required TabId sourceTabId,
    PaneId? sourcePaneId,
    required TabId targetTabId,
    required PaneId targetPaneId,
    required PaneSide side,
    Layout? expectedSource,
    Layout? expectedTarget,
  }) =>
      _terminalMove(
        sourceTabId: sourceTabId,
        sourcePaneId: sourcePaneId,
        targetTabId: targetTabId,
        targetPaneId: targetPaneId,
        side: side,
        expectedSource: expectedSource,
        expectedTarget: expectedTarget,
      ) !=
      null;

  /// Reparents layout references only: running sessions remain owned by the terminal manager.
  bool moveTerminal({
    required TabId sourceTabId,
    PaneId? sourcePaneId,
    required TabId targetTabId,
    required PaneId targetPaneId,
    required PaneSide side,
    Layout? expectedSource,
    Layout? expectedTarget,
  }) {
    final next = _terminalMove(
      sourceTabId: sourceTabId,
      sourcePaneId: sourcePaneId,
      targetTabId: targetTabId,
      targetPaneId: targetPaneId,
      side: side,
      expectedSource: expectedSource,
      expectedTarget: expectedTarget,
    );
    if (next == null) return false;
    _set(next);
    return true;
  }

  WorkspaceState? _terminalMove({
    required TabId sourceTabId,
    PaneId? sourcePaneId,
    required TabId targetTabId,
    required PaneId targetPaneId,
    required PaneSide side,
    Layout? expectedSource,
    Layout? expectedTarget,
  }) {
    final source = _tab(sourceTabId), target = _tab(targetTabId);
    if (source == null ||
        target == null ||
        (expectedSource != null && !identical(source.layout, expectedSource)) ||
        (expectedTarget != null && !identical(target.layout, expectedTarget))) {
      return null;
    }
    final same = sourceTabId == targetTabId;
    if (same && (sourcePaneId == null || sourcePaneId == targetPaneId)) return null;
    final leaf = sourcePaneId == null ? null : source.layout.leaves.where((l) => l.pane == sourcePaneId).firstOrNull;
    if (sourcePaneId != null && leaf == null) return null;
    if ([...source.layout.leaves, ...target.layout.leaves].any((l) => session(l.session) == null)) return null;
    final incoming = leaf == null ? source.layout : Layout.single(leaf.pane, leaf.session);
    final remaining = sourcePaneId == null ? null : source.layout.remove(sourcePaneId);
    final destination = same ? remaining : target.layout;
    final moved = destination?.insert(targetPaneId, side, incoming);
    if (moved == null) return null;
    return WorkspaceState(
      tabs: [
        for (final tab in state.tabs)
          if (tab.id == targetTabId)
            tab.withLayout(moved)
          else if (tab.id == sourceTabId) ...[
            if (remaining != null) tab.withLayout(remaining),
          ] else
            tab,
      ],
      active: targetTabId,
    );
  }

  bool canDetachPane(TabId tabId, PaneId pane, int index, {Layout? expectedSource}) {
    final source = _tab(tabId);
    return source != null &&
        index >= 0 &&
        index <= state.tabs.length &&
        (expectedSource == null || identical(source.layout, expectedSource)) &&
        source.layout.leaves.any((l) => l.pane == pane && session(l.session) != null);
  }

  /// A single-pane tab just changes position; splitting a pane out never starts a new shell.
  TabId? detachPane(TabId tabId, PaneId pane, int index, {Layout? expectedSource}) {
    if (!canDetachPane(tabId, pane, index, expectedSource: expectedSource)) return null;
    final source = _tab(tabId)!;
    final leaf = source.layout.leaves.firstWhere((l) => l.pane == pane);
    final remaining = source.layout.remove(pane);
    final id = remaining == null ? tabId : TabId(newId());
    final detached = remaining == null ? source : WorkspaceTab(id, Layout.single(pane, leaf.session));
    final tabs = [
      for (final tab in state.tabs)
        if (tab.id != tabId) tab else if (remaining != null) tab.withLayout(remaining),
    ];
    tabs.insert(index.clamp(0, tabs.length), detached);
    _set(WorkspaceState(tabs: tabs, active: id));
    return id;
  }

  void focusPane(TabId tabId, PaneId pane) {
    final tab = _tab(tabId);
    if (tab != null && tab.layout.focused != pane) _replace(tabId, tab.layout.focus(pane));
  }

  /// Moves focus to the previous or next pane of the active tab, in reading order.
  void cyclePane(int delta) {
    final tab = state.activeTab;
    if (tab == null) return;
    final panes = tab.layout.leaves.map((l) => l.pane).toList();
    final i = panes.indexOf(tab.layout.focused);
    _replace(tab.id, tab.layout.focus(panes[(i + delta) % panes.length]));
  }

  void resize(TabId tabId, List<int> path, List<double> ratios) {
    final tab = _tab(tabId);
    if (tab != null) _replace(tabId, tab.layout.resize(path, ratios));
  }

  WorkspaceTab? _tab(TabId id) => state.tabs.where((t) => t.id == id).firstOrNull;

  void _closeSessions(WorkspaceTab tab) {
    for (final leaf in tab.layout.leaves) {
      _sessions.close(leaf.session);
    }
  }

  void _replace(TabId id, Layout layout) =>
      _set(state.withTabs([for (final t in state.tabs) t.id == id ? t.withLayout(layout) : t]));

  void _set(WorkspaceState next) {
    state = next;
    _save();
  }

  void _save() {
    final sessions = ref.read(terminalSessionsProvider);
    final kept = [
      for (final t in state.tabs)
        if (t.layout.leaves.every((l) {
          final s = sessions[l.session];
          return s != null && !s.isRemote && (s.isLocal || !s.host.transient);
        }))
          t,
    ];
    final active = kept.indexWhere((t) => t.id == state.active);
    _file.write({
      'schemaVersion': 2,
      'tabs': [
        for (final t in kept)
          {
            'layout': t.layout.toJson(),
            'targets': {
              for (final l in t.layout.leaves)
                l.session.value: switch (sessions[l.session]!.target) {
                  SshTerminalTarget(:final hostId) => {'type': 'ssh', 'host': hostId.value},
                  LocalTerminalTarget(:final shell) => {'type': 'local', 'shell': shell.toJson()},
                  LinkTerminalTarget() => throw StateError('remote sessions are not persisted'),
                },
            },
            if (t.title != null) 'title': t.title,
          },
      ],
      if (active >= 0) 'active': active,
    });
  }

  /// Tabs whose hosts were deleted, or whose layout no longer parses, are dropped rather than failing the start.
  WorkspaceState _restore() {
    final hosts = ref.read(hostsProvider.notifier);
    final json = _file.read();
    final saved = json?['tabs'] as List<dynamic>? ?? const [];
    final tabs = <WorkspaceTab>[];
    TabId? active;
    final pending = <SessionId, Object>{};
    for (final (i, t) in saved.indexed) {
      try {
        final layout = Layout.fromJson(((t as Map)['layout'] as Map).cast());
        final resolved = <SessionId, Object?>{};
        final targets = t['targets'] as Map?;
        for (final leaf in layout.leaves) {
          if (targets == null) {
            final hostIds = (t['hosts'] as Map).cast<String, String>();
            resolved[leaf.session] = hosts.byId(HostId(hostIds[leaf.session.value]!));
          } else {
            final target = targets[leaf.session.value] as Map;
            resolved[leaf.session] = switch (target['type']) {
              'ssh' => hosts.byId(HostId(target['host'] as String)),
              'local' => LocalShell.fromJson((target['shell'] as Map).cast()),
              _ => null,
            };
          }
        }
        if (resolved.values.contains(null)) continue;
        // Fresh session IDs: a restored shell is a new process, not the old one.
        var restored = layout;
        for (final MapEntry(key: old, value: host) in resolved.entries) {
          final id = SessionId(newId());
          pending[id] = host!;
          restored = _rebind(restored, old, id);
        }
        tabs.add(WorkspaceTab(TabId(newId()), restored, title: t['title'] as String?));
        if (json?['active'] == i) active = tabs.last.id;
      } on Object {
        continue;
      }
    }
    // Providers may not change each other while building; panes show nothing for the moment in between.
    Future.microtask(() {
      if (!ref.mounted) return;
      for (final MapEntry(key: id, value: target) in pending.entries) {
        switch (target) {
          case Host():
            _sessions.open(target, id: id, autoConnect: false);
          case LocalShell():
            _sessions.openLocal(target, id: id, autoConnect: false);
        }
      }
    });
    return WorkspaceState(tabs: tabs, active: active);
  }

  static Layout _rebind(Layout layout, SessionId from, SessionId to) {
    PaneNode visit(PaneNode n) => switch (n) {
      Leaf(:final pane, :final session) => Leaf(pane, session == from ? to : session),
      PaneSplit(:final axis, :final children, :final ratios) => PaneSplit(axis, [
        for (final c in children) visit(c),
      ], ratios),
    };
    return Layout.fromJson({'root': visit(layout.root).toJson(), 'focused': layout.focused.value});
  }
}

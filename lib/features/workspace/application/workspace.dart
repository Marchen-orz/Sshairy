import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../foundation/data_dir.dart';
import '../../../foundation/ids.dart';
import '../../../foundation/json_file.dart';
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

class WorkspaceState {
  const WorkspaceState({this.tabs = const [], this.active});

  final List<WorkspaceTab> tabs;

  /// null shows the host vault.
  final TabId? active;

  WorkspaceTab? get activeTab => tabs.where((t) => t.id == active).firstOrNull;
}

final workspaceProvider = NotifierProvider<Workspace, WorkspaceState>(Workspace.new);

/// Tabs and their split layouts. Sessions belong to [terminalSessionsProvider]; layouts only refer to them.
/// Saved hosts in the layout are written to workspace.json and come back as unconnected tabs (docs/MODULES.md §3).
class Workspace extends Notifier<WorkspaceState> {
  late final JsonFile _file = JsonFile('${ref.read(dataDirProvider)}/workspace.json');

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

  TabId openHost(Host host) {
    if (!host.transient) ref.read(hostsProvider.notifier).touch(host.id).ignore();
    final s = _sessions.open(host);
    final tab = WorkspaceTab(TabId(newId()), Layout.single(PaneId(newId()), s.id));
    _set(WorkspaceState(tabs: [...state.tabs, tab], active: tab.id));
    return tab.id;
  }

  /// A new tab with a fresh shell on the same host as [id]'s focused pane; the running process is not copied.
  TabId? duplicate(TabId id) {
    final tab = _tab(id);
    final s = tab == null ? null : session(tab.layout.focusedLeaf.session);
    return s == null ? null : openHost(s.host);
  }

  /// An empty or blank [title] goes back to the host's name.
  void rename(TabId id, String? title) {
    final t = title?.trim();
    _set(WorkspaceState(
      tabs: [
        for (final tab in state.tabs)
          tab.id == id ? WorkspaceTab(id, tab.layout, title: t == null || t.isEmpty ? null : t) : tab,
      ],
      active: state.active,
    ));
  }

  void showVault() => _set(WorkspaceState(tabs: state.tabs));

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
    _set(WorkspaceState(tabs: tabs, active: state.active));
  }

  void closeTab(TabId id) {
    final i = state.tabs.indexWhere((t) => t.id == id);
    if (i < 0) return;
    for (final leaf in state.tabs[i].layout.leaves) {
      _sessions.close(leaf.session);
    }
    final tabs = [...state.tabs]..removeAt(i);
    final active = state.active != id ? state.active : (tabs.isEmpty ? null : tabs[i.clamp(0, tabs.length - 1)].id);
    _set(WorkspaceState(tabs: tabs, active: active));
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

  /// Opens another shell on the focused pane's host beside it. False when there is nothing to split or no room.
  bool split(SplitAxis axis) {
    final tab = state.activeTab;
    final current = focusedSession;
    if (tab == null || current == null) return false;
    final s = _sessions.open(current.host);
    final next = tab.layout.split(tab.layout.focused, axis, PaneId(newId()), s.id);
    if (next == null) {
      _sessions.close(s.id);
      return false;
    }
    _replace(tab.id, next);
    return true;
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

  void _replace(TabId id, Layout layout) => _set(WorkspaceState(
        tabs: [for (final t in state.tabs) t.id == id ? t.withLayout(layout) : t],
        active: state.active,
      ));

  void _set(WorkspaceState next) {
    state = next;
    _save();
  }

  void _save() {
    final sessions = ref.read(terminalSessionsProvider);
    final kept = [
      for (final t in state.tabs)
        if (t.layout.leaves.every((l) => !(sessions[l.session]?.host.transient ?? true))) t,
    ];
    final active = kept.indexWhere((t) => t.id == state.active);
    _file.write({
      'schemaVersion': 1,
      'tabs': [
        for (final t in kept)
          {
            'layout': t.layout.toJson(),
            'hosts': {for (final l in t.layout.leaves) l.session.value: sessions[l.session]!.host.id.value},
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
    final pending = <SessionId, Host>{};
    for (final (i, t) in saved.indexed) {
      try {
        final layout = Layout.fromJson(((t as Map)['layout'] as Map).cast());
        final hostIds = (t['hosts'] as Map).cast<String, String>();
        final resolved = {for (final l in layout.leaves) l.session: hosts.byId(HostId(hostIds[l.session.value]!))};
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
      for (final MapEntry(key: id, value: host) in pending.entries) {
        _sessions.open(host, id: id, autoConnect: false);
      }
    });
    return WorkspaceState(tabs: tabs, active: active);
  }

  static Layout _rebind(Layout layout, SessionId from, SessionId to) {
    PaneNode visit(PaneNode n) => switch (n) {
          Leaf(:final pane, :final session) => Leaf(pane, session == from ? to : session),
          PaneSplit(:final axis, :final children, :final ratios) => PaneSplit(axis, [for (final c in children) visit(c)], ratios),
        };
    return Layout.fromJson({'root': visit(layout.root).toJson(), 'focused': layout.focused.value});
  }
}

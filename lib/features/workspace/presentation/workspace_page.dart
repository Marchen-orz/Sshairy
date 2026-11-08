import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../design/brand.dart';
import '../../../design/dialog.dart';
import '../../../design/dock_panel.dart';
import '../../../design/double_click.dart';
import '../../../design/icon_rail.dart';
import '../../../design/menu.dart';
import '../../../design/popup.dart';
import '../../../design/side_drawer.dart';
import '../../../design/sidebar_frame.dart';
import '../../../design/text_prompt.dart';
import '../../../design/theme.dart';
import '../../../design/window_chrome.dart';
import '../../../foundation/ids.dart';
import '../../../l10n/app_localizations.dart';
import '../../connections/api.dart';
import '../../files/api.dart';
import '../../forwarding/api.dart';
import '../../hosts/api.dart';
import '../../logs/api.dart';
import '../../monitor/api.dart';
import '../../settings/api.dart';
import '../../snippets/api.dart';
import '../../terminal/api.dart';
import '../application/workspace.dart';
import '../domain/layout.dart';
import 'split_view.dart';

/// The window (docs/WORKSPACE_LAYOUT.md): icon rail, title bar with tabs, and the page or terminal tab below.
class WorkspacePage extends ConsumerStatefulWidget {
  const WorkspacePage({super.key, required this.openPalette});

  final Future<void> Function(BuildContext context) openPalette;

  @override
  ConsumerState<WorkspacePage> createState() => _WorkspacePageState();
}

class _WorkspacePageState extends ConsumerState<WorkspacePage> {
  /// Keeps each pane's state (focus, selection) when a split moves it to another place in the tree.
  final _paneKeys = <PaneId, GlobalKey>{};
  final _paneFocus = <PaneId, FocusNode>{};
  var _overlayOpen = false;

  /// Tabs showing the files panel beside their terminals.
  final _sideFiles = <TabId>{};

  /// The SFTP page connects nothing until first shown, then stays alive like a tab.
  var _filesBuilt = false;

  /// Shown at once and saved behind, like the files dock; a change through settings.patch is followed.
  late var _navigationExpanded = ref.read(settingsProvider).get(SettingKeys.navigationExpanded);
  late var _navigationWidth = ref.read(settingsProvider).get(SettingKeys.navigationWidth);
  late var _monitorWidth = ref.read(settingsProvider).get(SettingKeys.monitorWidth);
  final _surfaceKey = GlobalKey();

  BuildContext get _surfaceContext => _surfaceKey.currentContext ?? context;

  @override
  void initState() {
    super.initState();
    // Queued transfers and edits ask from whichever page is showing.
    ref.read(transfersProvider.notifier).ui = DialogTransferUi(context);
    _insertUi.confirm = _confirmInsert;
    // Rules marked to start with the app ask their host key and password questions from here.
    final forwards = ref.read(forwardsProvider.notifier);
    forwards.prompts = DialogPrompts(context);
    forwards.autoStart().ignore();
  }

  late final _insertUi = ref.read(terminalInsertUiProvider);
  late final ConfirmInsert _confirmInsert = _showInsertConfirmation;

  Future<bool> _showInsertConfirmation(InsertPreview preview) => confirmTerminalInsert(context, preview);

  Workspace get _workspace => ref.read(workspaceProvider.notifier);

  Future<void> _overlay(Future<void> Function() open) async {
    if (_overlayOpen) return;
    _overlayOpen = true;
    try {
      await open();
    } finally {
      _overlayOpen = false;
    }
  }

  void _flyout(WidgetBuilder builder, {double width = WorkspaceSize.flyout}) =>
      _overlay(() => showFlyout<void>(_surfaceContext, builder, width: width));

  void _openSettings() => _flyout((_) => const SettingsPanel(), width: WorkspaceSize.flyoutWide);
  void _openSnippets() => _flyout((_) => const SnippetsPanel());
  void _openForwarding() => _flyout((_) => const ForwardingPanel());
  void _openProxies() => _flyout((_) => const ProxyPanel());
  void _openLogs() => _flyout((_) => const LogsPanel());
  void _openPalette() => _overlay(() => widget.openPalette(_surfaceContext));
  void _openKeys() => _flyout((_) => const KeysPanel());
  void _openTrust() => _flyout((context) => SingleChildScrollView(child: trustSettingsSection.build(context)));

  /// Status of every session on [host], for the quick-connect list.
  Widget _hostStatus(Host host, Map<SessionId, TerminalSession> sessions) {
    final matching = sessions.values.where((s) => s.host.id == host.id).toList();
    return ListenableBuilder(
      listenable: Listenable.merge(matching),
      builder: (_, _) => SessionStatusIcon(
        matching.any((s) => s.status == SessionStatus.connected)
            ? SessionStatus.connected
            : matching.firstOrNull?.status ?? SessionStatus.idle,
      ),
    );
  }

  Future<void> _quickConnect(BuildContext button) async {
    final l = AppLocalizations.of(context);
    final picked = await showAnchoredPopup<Host>(
      context: button,
      anchor: anchorOf(button),
      width: 300,
      maxHeight: 480,
      builder: (context) => PopupSurface(
        padding: const EdgeInsets.all(Space.xs),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: 380,
              child: Consumer(
                builder: (context, ref, _) => HostTree(
                  onConnect: (host) => Navigator.pop(context, host),
                  status: (host) => _hostStatus(host, ref.watch(terminalSessionsProvider)),
                ),
              ),
            ),
            const Divider(height: Space.sm),
            PopupRow(
              onTap: () {
                Navigator.pop(context);
                _workspace.showVault();
              },
              child: Row(
                children: [
                  const Icon(Icons.dns_outlined, size: 16),
                  const SizedBox(width: Space.sm),
                  Text(l.hosts),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    if (picked != null && mounted) _workspace.openHost(picked);
  }

  late final _bindings = <SingleActivator, VoidCallback>{
    const SingleActivator(LogicalKeyboardKey.keyN, control: true, shift: true): () => _workspace.showVault(),
    const SingleActivator(LogicalKeyboardKey.keyW, control: true, shift: true): () => _workspace.closeFocused(),
    const SingleActivator(LogicalKeyboardKey.keyP, control: true, shift: true): _openPalette,
    const SingleActivator(LogicalKeyboardKey.comma, control: true): _openSettings,
    const SingleActivator(LogicalKeyboardKey.tab, control: true): () => _workspace.cycle(1),
    const SingleActivator(LogicalKeyboardKey.tab, control: true, shift: true): () => _workspace.cycle(-1),
    const SingleActivator(LogicalKeyboardKey.arrowLeft, alt: true): () => _workspace.cyclePane(-1),
    const SingleActivator(LogicalKeyboardKey.arrowUp, alt: true): () => _workspace.cyclePane(-1),
    const SingleActivator(LogicalKeyboardKey.arrowRight, alt: true): () => _workspace.cyclePane(1),
    const SingleActivator(LogicalKeyboardKey.arrowDown, alt: true): () => _workspace.cyclePane(1),
  };

  KeyEventResult _onKey(FocusNode _, KeyEvent event) {
    for (final e in _bindings.entries) {
      if (e.key.accepts(event, HardwareKeyboard.instance)) {
        e.value();
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  void _splitAt(WorkspaceTab tab, Leaf leaf, SplitAxis axis) {
    _workspace.focusPane(tab.id, leaf.pane);
    _workspace.split(axis);
  }

  Future<void> _rename(WorkspaceTab tab, String current) async {
    final title = await showAppDialog<String>(
      context: context,
      builder: (_) => TextPromptDialog(title: AppLocalizations.of(context).rename, initial: current),
    );
    if (title != null) _workspace.rename(tab.id, title);
  }

  Future<void> _tabMenu(WorkspaceTab tab, String name, Offset p) async {
    final l = AppLocalizations.of(context);
    final state = ref.read(workspaceProvider);
    AppMenuItem<VoidCallback> closing(TabCloseScope scope, String label, IconData icon) => AppMenuItem(
      value: () => _workspace.closeTabs(tab.id, scope),
      label: label,
      icon: icon,
      enabled: state.tabsToClose(tab.id, scope).isNotEmpty,
    );
    final run = await showAppMenu<VoidCallback>(
      context: context,
      anchor: anchorAt(p),
      items: [
        AppMenuItem(value: () => _rename(tab, name), label: l.rename, icon: Icons.edit_outlined),
        AppMenuItem(value: () => _workspace.duplicate(tab.id), label: l.duplicate, icon: Icons.copy_all_outlined),
        const AppMenuDivider(),
        AppMenuItem(value: () => _workspace.closeTab(tab.id), label: l.close, icon: Icons.close),
        closing(TabCloseScope.left, l.closeTabsLeft, Icons.keyboard_double_arrow_left),
        closing(TabCloseScope.right, l.closeTabsRight, Icons.keyboard_double_arrow_right),
        closing(TabCloseScope.others, l.closeOtherTabs, Icons.tab_unselected),
      ],
    );
    run?.call();
  }

  void _setNavigation({bool? expanded, double? width}) {
    setState(() {
      _navigationExpanded = expanded ?? _navigationExpanded;
      _navigationWidth = width ?? _navigationWidth;
    });
    final settings = ref.read(settingsProvider.notifier);
    if (expanded != null) settings.set(SettingKeys.navigationExpanded, expanded);
    if (width != null) settings.set(SettingKeys.navigationWidth, width);
  }

  void _setMonitorWidth(double width) {
    setState(() => _monitorWidth = width);
    ref.read(settingsProvider.notifier).set(SettingKeys.monitorWidth, width);
  }

  void _toggleFiles(TabId id) => setState(() => _sideFiles.contains(id) ? _sideFiles.remove(id) : _sideFiles.add(id));

  void _refocus(TabId tabId, PaneId pane) {
    final focused = ref.read(workspaceProvider).tabs.where((t) => t.id == tabId).firstOrNull?.layout.focused;
    if (focused == null || focused == pane) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => _paneFocus[focused]?.requestFocus());
  }

  @override
  void dispose() {
    if (identical(_insertUi.confirm, _confirmInsert)) _insertUi.confirm = null;
    for (final node in _paneFocus.values) {
      node.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final state = ref.watch(workspaceProvider);
    final sessions = ref.watch(terminalSessionsProvider);
    final settings = ref.watch(settingsProvider);
    final scheme = Theme.of(context).colorScheme;
    final live = {for (final t in state.tabs) ...t.layout.leaves.map((l) => l.pane)};
    _paneKeys.removeWhere((pane, _) => !live.contains(pane));
    _paneFocus.removeWhere((pane, node) {
      if (live.contains(pane)) return false;
      node.dispose();
      return true;
    });
    _sideFiles.removeWhere((id) => !state.tabs.any((t) => t.id == id));
    final vault = state.active == null && !state.files;
    _filesBuilt |= state.files;
    final wide = MediaQuery.sizeOf(context).width >= WorkspaceSize.wideBreakpoint;
    final showMonitor = settings.get(SettingKeys.showMonitor);
    final dock = settings.get(SettingKeys.filesDock);
    final settingsNotifier = ref.read(settingsProvider.notifier);
    ref.listen(settingsProvider, (before, now) {
      final (expanded, width) = (now.get(SettingKeys.navigationExpanded), now.get(SettingKeys.navigationWidth));
      if (before?.get(SettingKeys.navigationExpanded) != expanded ||
          before?.get(SettingKeys.navigationWidth) != width) {
        setState(() {
          _navigationExpanded = expanded;
          _navigationWidth = width;
        });
      }
      final monitorWidth = now.get(SettingKeys.monitorWidth);
      if (before?.get(SettingKeys.monitorWidth) != monitorWidth) setState(() => _monitorWidth = monitorWidth);
    });
    final navigationExpanded = _navigationExpanded, navigationWidth = _navigationWidth;

    Widget leaf(WorkspaceTab tab, Leaf leaf) {
      final session = sessions[leaf.session];
      if (session == null) return const SizedBox.shrink();
      final focused = tab.layout.focused == leaf.pane;
      final split = tab.layout.leaves.length > 1;
      return KeyedSubtree(
        key: _paneKeys.putIfAbsent(leaf.pane, GlobalKey.new),
        // The layout decides which pane has focus. A click moves it there first; focus that lands elsewhere by
        // itself, such as a closing dialog handing it back to the pane it came from, is sent back.
        child: Listener(
          onPointerDown: (_) => _workspace.focusPane(tab.id, leaf.pane),
          child: Focus(
            canRequestFocus: false,
            skipTraversal: true,
            onFocusChange: (f) {
              if (f) _refocus(tab.id, leaf.pane);
            },
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (split)
                  _PaneHeader(
                    session: session,
                    focused: focused,
                    onTap: () => _workspace.focusPane(tab.id, leaf.pane),
                    onClose: () => _workspace.closePane(tab.id, leaf.pane),
                  ),
                Expanded(
                  child: ColoredBox(
                    color: scheme.surfaceContainerLowest,
                    child: TerminalPane(
                      session,
                      active: state.active == tab.id && focused,
                      visible: state.active == tab.id,
                      onKeyEvent: _onKey,
                      focusNode: _paneFocus.putIfAbsent(leaf.pane, FocusNode.new),
                      actions: [
                        PaneAction(
                          l.splitRight,
                          Icons.vertical_split_outlined,
                          () => _splitAt(tab, leaf, SplitAxis.horizontal),
                        ),
                        PaneAction(
                          l.splitDown,
                          Icons.horizontal_split_outlined,
                          () => _splitAt(tab, leaf, SplitAxis.vertical),
                        ),
                        PaneAction(l.duplicate, Icons.copy_all_outlined, () => _workspace.duplicate(tab.id)),
                        PaneAction(l.closePane, Icons.close, () => _workspace.closePane(tab.id, leaf.pane)),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    Widget tabBody(WorkspaceTab tab) {
      final session = sessions[tab.layout.focusedLeaf.session];
      return SidebarFrame(
        width: _monitorWidth,
        onResize: _setMonitorWidth,
        resizeLabel: l.resizeMonitor,
        sidebar: session != null && showMonitor && wide
            ? MonitorPanel(key: ValueKey('monitor-${tab.id.value}'), host: session.host, active: state.active == tab.id)
            : null,
        child: DockPanel(
          open: _sideFiles.contains(tab.id) && session != null,
          side: switch (dock) {
            FilesDock.left => DockSide.left,
            FilesDock.right => DockSide.right,
            FilesDock.bottom => DockSide.bottom,
          },
          onClose: () => setState(() => _sideFiles.remove(tab.id)),
          closeLabel: l.closePane,
          resizeLabel: l.resizeToolPanel,
          showHeader: false,
          panel: session != null
              ? SideFilesPanel(
                  host: session.host,
                  active: state.active == tab.id,
                  tree: dock == FilesDock.bottom,
                  directory: session.directory,
                  toolbarActions: [
                    AppMenuButton<FilesDock>(
                      tooltip: l.dockPosition,
                      icon: const Icon(Icons.space_dashboard_outlined, size: 16),
                      minWidth: 0,
                      items: () => [
                        for (final (side, shape, label) in [
                          (FilesDock.left, DockSide.left, l.dockLeft),
                          (FilesDock.right, DockSide.right, l.dockRight),
                          (FilesDock.bottom, DockSide.bottom, l.dockBottom),
                        ])
                          AppMenuItem(value: side, label: label, glyph: DockSideIcon(shape), checked: side == dock),
                      ],
                      onSelected: (v) => ref.read(settingsProvider.notifier).set(SettingKeys.filesDock, v),
                    ),
                    IconButton(
                      tooltip: l.closePane,
                      onPressed: () => setState(() => _sideFiles.remove(tab.id)),
                      icon: const Icon(Icons.close, size: 16),
                    ),
                  ],
                )
              : const SizedBox.shrink(),
          child: LayoutView(
            root: tab.layout.root,
            leaf: (l) => leaf(tab, l),
            onResize: (path, ratios) => _workspace.resize(tab.id, path, ratios),
          ),
        ),
      );
    }

    final activeTab = state.activeTab;
    final titleBar = Container(
      height: WorkspaceSize.titleBar,
      padding: const EdgeInsets.fromLTRB(Space.xs, Space.xs, 0, Space.xs),
      color: scheme.surfaceContainerLow,
      child: Row(
        children: [
          Expanded(
            // The drag region sits behind the tabs rather than around them: wrapped, every click would wait out
            // its double-click timer before reaching a tab or button.
            child: Stack(
              fit: StackFit.expand,
              children: [
                const Positioned.fill(child: DesktopDragRegion(child: SizedBox.expand())),
                Row(
                  children: [
                    Flexible(
                      child: ReorderableListView.builder(
                        scrollDirection: Axis.horizontal,
                        shrinkWrap: true,
                        buildDefaultDragHandles: false,
                        itemCount: state.tabs.length,
                        onReorderItem: _workspace.moveTab,
                        proxyDecorator: (child, _, _) => Material(color: Colors.transparent, child: child),
                        itemBuilder: (context, i) {
                          final tab = state.tabs[i];
                          final session = sessions[tab.layout.focusedLeaf.session];
                          final all = [for (final l in tab.layout.leaves) ?sessions[l.session]];
                          final count = tab.layout.leaves.length;
                          return ReorderableDragStartListener(
                            key: ValueKey(tab.id),
                            index: i,
                            child: session == null
                                ? const SizedBox.shrink()
                                : ListenableBuilder(
                                    listenable: Listenable.merge(all),
                                    builder: (context, _) {
                                      final name = tab.title ?? session.host.title;
                                      return _Tab(
                                        selected: state.active == tab.id,
                                        onTap: () => _workspace.activate(tab.id),
                                        onDoubleTap: () => _rename(tab, name),
                                        onSecondaryTap: (p) => _tabMenu(tab, name, p),
                                        leading: SessionStatusIcon(session.status, unread: all.any((s) => s.unread)),
                                        title: count > 1 ? '$name · $count' : name,
                                        onClose: () => _workspace.closeTab(tab.id),
                                      );
                                    },
                                  ),
                          );
                        },
                      ),
                    ),
                    Builder(
                      builder: (button) => IconButton(
                        tooltip: l.newConnection,
                        onPressed: () => _quickConnect(button),
                        icon: const Icon(Icons.add, size: 18),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          // A small gap keeps neighbouring selected buttons apart, like the window controls.
          Row(
            spacing: Space.xs / 2,
            children: [
              if (activeTab != null) ...[
                if (wide)
                  _BarToggle(
                    tooltip: l.monitor,
                    icon: Icons.monitor_heart_outlined,
                    selected: showMonitor,
                    onPressed: () => settingsNotifier.set(SettingKeys.showMonitor, !showMonitor),
                  ),
                _BarToggle(
                  tooltip: l.files,
                  icon: Icons.folder_outlined,
                  selected: _sideFiles.contains(activeTab.id),
                  onPressed: () => _toggleFiles(activeTab.id),
                ),
                AppMenuButton<SplitAxis>(
                  tooltip: l.split,
                  icon: const Icon(Icons.vertical_split_outlined, size: 18),
                  onSelected: _workspace.split,
                  items: () => [
                    AppMenuItem(value: SplitAxis.horizontal, label: l.splitRight, icon: Icons.vertical_split_outlined),
                    AppMenuItem(value: SplitAxis.vertical, label: l.splitDown, icon: Icons.horizontal_split_outlined),
                  ],
                ),
              ],
              const TransfersButton(),
            ],
          ),
          const SizedBox(width: Space.xs),
          WindowControls(
            minimizeLabel: l.windowMinimize,
            maximizeLabel: l.windowMaximize,
            restoreLabel: l.windowRestore,
            closeLabel: l.windowClose,
          ),
        ],
      ),
    );

    return SidePanelAnchor(
      navigationWidth: navigationExpanded ? navigationWidth : WorkspaceSize.rail,
      child: Scaffold(
        key: _surfaceKey,
        body: Focus(
          onKeyEvent: _onKey,
          child: NavigationFrame(
            expanded: navigationExpanded,
            width: navigationWidth,
            resizeLabel: l.resizeNavigation,
            onResize: (width) => _setNavigation(width: width),
            navigation: IconRail(
              header: const DesktopDragRegion(child: Center(child: BrandMark())),
              expandedHeader: DesktopDragRegion(
                child: Center(child: BrandLogo(width: min(BrandLogo.maxWidth, navigationWidth - Space.lg * 2))),
              ),
              expanded: navigationExpanded,
              width: navigationWidth,
              toggleLabel: navigationExpanded ? l.navigationCollapse : l.navigationExpand,
              onToggle: () => _setNavigation(expanded: !navigationExpanded),
              groups: [
                [
                  RailItem(icon: Icons.dns_outlined, label: l.hosts, selected: vault, onTap: _workspace.showVault),
                  RailItem(
                    icon: Icons.folder_copy_outlined,
                    label: l.sftp,
                    selected: state.files,
                    onTap: _workspace.showFiles,
                  ),
                ],
                [
                  RailItem(icon: Icons.key_outlined, label: l.keys, onTap: _openKeys),
                  RailItem(icon: Icons.lan_outlined, label: l.proxy, onTap: _openProxies),
                  RailItem(icon: Icons.route_outlined, label: l.portForwarding, onTap: _openForwarding),
                  RailItem(icon: Icons.code, label: l.snippets, onTap: _openSnippets),
                  RailItem(icon: Icons.verified_user_outlined, label: l.hostKeys, onTap: _openTrust),
                  RailItem(icon: Icons.receipt_long_outlined, label: l.logs, onTap: _openLogs),
                ],
              ],
              bottom: [
                RailItem(icon: Icons.search, label: l.commandPalette, onTap: _openPalette),
                RailItem(icon: Icons.settings_outlined, label: l.settings, onTap: _openSettings),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                titleBar,
                const Divider(height: WorkspaceSize.divider),
                Expanded(
                  key: const ValueKey('workspace-content'),
                  // Not IndexedStack: its wrappers are unkeyed, so closing a middle tab would rebuild the panes
                  // after it.
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      const BackgroundImageView(slot: BackgroundSlot.app),
                      Visibility.maintain(
                        key: const ValueKey('vault'),
                        visible: vault,
                        child: ExcludeFocus(
                          excluding: !vault,
                          child: VaultPage(active: vault, onConnect: _workspace.openHost),
                        ),
                      ),
                      if (_filesBuilt)
                        Visibility.maintain(
                          key: const ValueKey('files'),
                          visible: state.files,
                          child: IgnorePointer(
                            ignoring: !state.files,
                            child: ExcludeFocus(
                              excluding: !state.files,
                              child: FilesPage(active: state.files),
                            ),
                          ),
                        ),
                      for (final tab in state.tabs)
                        Visibility.maintain(
                          key: ValueKey(tab.id),
                          visible: state.active == tab.id,
                          child: IgnorePointer(
                            ignoring: state.active != tab.id,
                            child: ExcludeFocus(excluding: state.active != tab.id, child: tabBody(tab)),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A title-bar button for something that stays on or off, such as a panel.
class _BarToggle extends StatelessWidget {
  const _BarToggle({required this.tooltip, required this.icon, required this.selected, required this.onPressed});

  final String tooltip;
  final IconData icon;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      toggled: selected,
      child: IconButton(
        tooltip: tooltip,
        onPressed: onPressed,
        style: selected
            ? IconButton.styleFrom(
                backgroundColor: scheme.primary.withValues(alpha: .12),
                foregroundColor: scheme.primary,
              )
            : null,
        icon: Icon(icon, size: 18),
      ),
    );
  }
}

class SessionStatusIcon extends StatelessWidget {
  const SessionStatusIcon(this.status, {super.key, this.unread = false});

  final SessionStatus status;

  /// New output in a tab nobody is looking at: the dot gets a ring.
  final bool unread;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return switch (status) {
      SessionStatus.connecting => const SizedBox.square(
        dimension: 11,
        child: CircularProgressIndicator(strokeWidth: 1.5),
      ),
      SessionStatus.connected when unread => Container(
        width: 11,
        height: 11,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: scheme.primary, width: 2),
        ),
        alignment: Alignment.center,
        child: Icon(Icons.circle, size: 4, color: scheme.primary),
      ),
      SessionStatus.connected => Icon(Icons.circle, size: 8, color: scheme.primary),
      SessionStatus.idle => Icon(Icons.circle_outlined, size: 8, color: scheme.onSurfaceVariant),
      SessionStatus.failed || SessionStatus.disconnected => Icon(Icons.link_off, size: 13, color: scheme.error),
    };
  }
}

/// Only shown in split tabs, where it tells panes apart; the focused one carries the accent.
class _PaneHeader extends StatelessWidget {
  const _PaneHeader({required this.session, required this.focused, required this.onTap, required this.onClose});

  final TerminalSession session;
  final bool focused;
  final VoidCallback onTap, onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Material(
      color: scheme.surfaceContainerLow,
      child: InkWell(
        onTap: onTap,
        child: Container(
          height: 24,
          padding: const EdgeInsets.only(left: Space.sm, right: Space.xs),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: focused ? scheme.primary : scheme.outlineVariant, width: focused ? 2 : 1),
            ),
          ),
          child: ListenableBuilder(
            listenable: session,
            builder: (context, _) => Row(
              children: [
                SizedBox.square(dimension: 14, child: Center(child: SessionStatusIcon(session.status))),
                const SizedBox(width: Space.sm),
                // Expanded, not Flexible beside a Spacer: the two would split the free width, and a short label
                // would leave the close button part-way along the header.
                Expanded(
                  child: Text(
                    session.host.target,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: focused ? scheme.onSurface : scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: AppLocalizations.of(context).closePane,
                  onPressed: onClose,
                  constraints: const BoxConstraints.tightFor(width: 22, height: 22),
                  style: IconButton.styleFrom(minimumSize: const Size(22, 22), padding: EdgeInsets.zero),
                  icon: const Icon(Icons.close, size: 13),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Tab extends StatefulWidget {
  const _Tab({
    required this.selected,
    required this.onTap,
    required this.leading,
    required this.title,
    this.onClose,
    this.onDoubleTap,
    this.onSecondaryTap,
  });

  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onDoubleTap;
  final void Function(Offset globalPosition)? onSecondaryTap;
  final Widget leading;
  final String title;
  final VoidCallback? onClose;

  @override
  State<_Tab> createState() => _TabState();
}

class _TabState extends State<_Tab> {
  final _clicks = DoubleClick();
  var _hovered = false;

  void _tap() {
    widget.onTap();
    if (widget.onDoubleTap != null && _clicks.hit) widget.onDoubleTap!();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final selected = widget.selected;
    return Padding(
      padding: const EdgeInsets.only(right: Space.xs),
      child: Center(
        child: MouseRegion(
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: AnimatedContainer(
            duration: Motion.quick,
            decoration: BoxDecoration(
              color: selected
                  ? scheme.surface
                  : _hovered
                  ? scheme.onSurface.withValues(alpha: .05)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(Radii.control),
              border: Border.all(color: selected ? scheme.outlineVariant : Colors.transparent),
              boxShadow: selected
                  ? [BoxShadow(color: scheme.shadow.withValues(alpha: .06), blurRadius: 4, offset: const Offset(0, 1))]
                  : null,
            ),
            child: Material(
              type: MaterialType.transparency,
              child: InkWell(
                borderRadius: BorderRadius.circular(Radii.control),
                onTap: _tap,
                onSecondaryTapUp: widget.onSecondaryTap == null
                    ? null
                    : (d) => widget.onSecondaryTap!(d.globalPosition),
                // Sized to the title within the limits; a short title leaves its room before the close button, which
                // keeps to the right edge.
                child: IntrinsicWidth(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minWidth: WorkspaceSize.tabMin, maxWidth: WorkspaceSize.tabMax),
                    child: SizedBox(
                      height: WorkspaceSize.tabHeight,
                      child: Padding(
                        padding: const EdgeInsets.only(left: Space.sm, right: Space.xs),
                        child: Row(
                          children: [
                            SizedBox.square(dimension: 14, child: Center(child: widget.leading)),
                            const SizedBox(width: Space.sm),
                            Expanded(
                              child: Text(
                                widget.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(color: selected ? scheme.onSurface : scheme.onSurfaceVariant),
                              ),
                            ),
                            if (widget.onClose != null) ...[
                              const SizedBox(width: Space.xs),
                              // The close button shows on the current tab and on hover, so idle tabs read cleanly.
                              Opacity(
                                opacity: selected || _hovered ? 1 : 0,
                                child: IconButton(
                                  tooltip: AppLocalizations.of(context).close,
                                  onPressed: widget.onClose,
                                  constraints: const BoxConstraints.tightFor(width: 20, height: 20),
                                  style: IconButton.styleFrom(
                                    minimumSize: const Size(20, 20),
                                    padding: EdgeInsets.zero,
                                  ),
                                  icon: const Icon(Icons.close, size: 13),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

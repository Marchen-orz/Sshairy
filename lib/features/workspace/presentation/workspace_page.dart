import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../design/side_drawer.dart';
import '../../../design/text_prompt.dart';
import '../../../design/theme.dart';
import '../../../foundation/ids.dart';
import '../../../l10n/app_localizations.dart';
import '../../capabilities/api.dart';
import '../../files/api.dart';
import '../../hosts/api.dart';
import '../../settings/api.dart';
import '../../terminal/api.dart';
import '../application/workspace.dart';
import '../domain/layout.dart';
import 'split_view.dart';

class WorkspacePage extends ConsumerStatefulWidget {
  const WorkspacePage({super.key});

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

  @override
  void initState() {
    super.initState();
    // Queued transfers and edits ask from whichever page is showing.
    ref.read(transfersProvider.notifier).ui = DialogTransferUi(context);
  }

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

  void _openSettings() => _overlay(() => showSideDrawer<void>(context, (_) => const SettingsPanel()));
  void _openPalette() => _overlay(() => showCommandPalette(context));

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
    final title = await showDialog<String>(
      context: context,
      builder: (_) => TextPromptDialog(title: AppLocalizations.of(context).rename, initial: current),
    );
    if (title != null) _workspace.rename(tab.id, title);
  }

  Future<void> _tabMenu(WorkspaceTab tab, String name, Offset p) async {
    final l = AppLocalizations.of(context);
    PopupMenuItem<VoidCallback> item(String label, IconData icon, VoidCallback run) => PopupMenuItem(
          value: run,
          height: 36,
          child: Row(children: [Icon(icon, size: 16), const SizedBox(width: Space.md), Text(label)]),
        );
    final run = await showMenu<VoidCallback>(
      context: context,
      position: RelativeRect.fromLTRB(p.dx, p.dy, p.dx, p.dy),
      items: [
        item(l.rename, Icons.edit_outlined, () => _rename(tab, name)),
        item(l.duplicate, Icons.copy_all_outlined, () => _workspace.duplicate(tab.id)),
        item(l.close, Icons.close, () => _workspace.closeTab(tab.id)),
      ],
    );
    run?.call();
  }

  void _refocus(TabId tabId, PaneId pane) {
    final focused = ref.read(workspaceProvider).tabs.where((t) => t.id == tabId).firstOrNull?.layout.focused;
    if (focused == null || focused == pane) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => _paneFocus[focused]?.requestFocus());
  }

  @override
  void dispose() {
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
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
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
                    onKeyEvent: _onKey,
                    focusNode: _paneFocus.putIfAbsent(leaf.pane, FocusNode.new),
                    actions: [
                      PaneAction(l.splitRight, Icons.vertical_split_outlined, () => _splitAt(tab, leaf, SplitAxis.horizontal)),
                      PaneAction(l.splitDown, Icons.horizontal_split_outlined, () => _splitAt(tab, leaf, SplitAxis.vertical)),
                      PaneAction(l.duplicate, Icons.copy_all_outlined, () => _workspace.duplicate(tab.id)),
                      PaneAction(l.closePane, Icons.close, () => _workspace.closePane(tab.id, leaf.pane)),
                    ],
                  ),
                ),
              ),
            ]),
          ),
        ),
      );
    }

    return Scaffold(
      body: Focus(
        onKeyEvent: _onKey,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Container(
            height: 40,
            padding: const EdgeInsets.symmetric(horizontal: Space.xs),
            color: scheme.surfaceContainerLow,
            child: Row(children: [
              _Tab(
                selected: vault,
                onTap: _workspace.showVault,
                leading: const Icon(Icons.dns_outlined, size: 16),
                title: l.hosts,
              ),
              _Tab(
                selected: state.files,
                onTap: _workspace.showFiles,
                leading: const Icon(Icons.folder_copy_outlined, size: 16),
                title: l.sftp,
              ),
              Expanded(
                child: Row(children: [
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
                  IconButton(
                    tooltip: l.newConnection,
                    onPressed: _workspace.showVault,
                    icon: const Icon(Icons.add, size: 18),
                  ),
                ]),
              ),
              if (state.activeTab case final tab?)
                IconButton(
                  tooltip: l.files,
                  isSelected: _sideFiles.contains(tab.id),
                  onPressed: () => setState(() => _sideFiles.contains(tab.id) ? _sideFiles.remove(tab.id) : _sideFiles.add(tab.id)),
                  icon: const Icon(Icons.folder_outlined, size: 18),
                  selectedIcon: const Icon(Icons.folder, size: 18),
                ),
              if (state.activeTab != null)
                PopupMenuButton<SplitAxis>(
                  tooltip: l.split,
                  icon: const Icon(Icons.vertical_split_outlined, size: 18),
                  onSelected: _workspace.split,
                  itemBuilder: (_) => [
                    PopupMenuItem(value: SplitAxis.horizontal, child: Text(l.splitRight)),
                    PopupMenuItem(value: SplitAxis.vertical, child: Text(l.splitDown)),
                  ],
                ),
              const TransfersButton(),
              IconButton(
                tooltip: l.commandPalette,
                onPressed: _openPalette,
                icon: const Icon(Icons.search, size: 18),
              ),
              IconButton(
                tooltip: l.settings,
                onPressed: _openSettings,
                icon: const Icon(Icons.settings_outlined, size: 18),
              ),
            ]),
          ),
          const Divider(),
          Expanded(
            // Not IndexedStack: its wrappers are unkeyed, so closing a middle tab would rebuild the panes after it.
            child: Stack(fit: StackFit.expand, children: [
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
                    child: ExcludeFocus(excluding: !state.files, child: const FilesPage()),
                  ),
                ),
              for (final tab in state.tabs)
                Visibility.maintain(
                  key: ValueKey(tab.id),
                  visible: state.active == tab.id,
                  child: IgnorePointer(
                    ignoring: state.active != tab.id,
                    child: ExcludeFocus(
                      excluding: state.active != tab.id,
                      child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        Expanded(
                          child: LayoutView(
                            root: tab.layout.root,
                            leaf: (l) => leaf(tab, l),
                            onResize: (path, ratios) => _workspace.resize(tab.id, path, ratios),
                          ),
                        ),
                        if (_sideFiles.contains(tab.id) ? sessions[tab.layout.focusedLeaf.session] : null case final s?) ...[
                          const VerticalDivider(width: 1),
                          SizedBox(width: 360, child: SideFilesPanel(host: s.host)),
                        ],
                      ]),
                    ),
                  ),
                ),
            ]),
          ),
        ]),
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
      SessionStatus.connecting => const SizedBox.square(dimension: 12, child: CircularProgressIndicator(strokeWidth: 2)),
      SessionStatus.connected when unread => Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: scheme.primary, width: 2)),
          alignment: Alignment.center,
          child: Icon(Icons.circle, size: 4, color: scheme.primary),
        ),
      SessionStatus.connected => Icon(Icons.circle, size: 8, color: scheme.primary),
      SessionStatus.idle => Icon(Icons.circle_outlined, size: 8, color: scheme.onSurfaceVariant),
      SessionStatus.failed || SessionStatus.disconnected => Icon(Icons.link_off, size: 14, color: scheme.error),
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
          height: 28,
          padding: const EdgeInsets.only(left: Space.sm),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: focused ? scheme.primary : scheme.outlineVariant, width: focused ? 2 : 1)),
          ),
          child: ListenableBuilder(
            listenable: session,
            builder: (context, _) => Row(children: [
              SizedBox.square(dimension: 16, child: Center(child: SessionStatusIcon(session.status))),
              const SizedBox(width: Space.sm),
              Flexible(
                child: Text(
                  session.host.target,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(color: focused ? scheme.onSurface : scheme.onSurfaceVariant),
                ),
              ),
              const Spacer(),
              IconButton(
                tooltip: AppLocalizations.of(context).closePane,
                onPressed: onClose,
                constraints: const BoxConstraints.tightFor(width: 24, height: 24),
                style: IconButton.styleFrom(minimumSize: const Size(24, 24), padding: EdgeInsets.zero),
                icon: const Icon(Icons.close, size: 14),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

class _Tab extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(right: Space.xs),
      child: Center(
        child: Material(
          color: selected ? scheme.surface : Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Radii.control),
            side: selected ? BorderSide(color: scheme.outlineVariant) : BorderSide.none,
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            onDoubleTap: onDoubleTap,
            onSecondaryTapUp: onSecondaryTap == null ? null : (d) => onSecondaryTap!(d.globalPosition),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 96, maxWidth: 220),
              child: SizedBox(
                height: 30,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Space.sm),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    SizedBox.square(dimension: 16, child: Center(child: leading)),
                    const SizedBox(width: Space.sm),
                    Flexible(child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis)),
                    if (onClose != null) ...[
                      const SizedBox(width: Space.xs),
                      IconButton(
                        tooltip: AppLocalizations.of(context).close,
                        onPressed: onClose,
                        constraints: const BoxConstraints.tightFor(width: 22, height: 22),
                        style: IconButton.styleFrom(minimumSize: const Size(22, 22), padding: EdgeInsets.zero),
                        icon: const Icon(Icons.close, size: 14),
                      ),
                    ],
                  ]),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

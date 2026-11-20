import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../design/theme.dart';
import '../../../foundation/ids.dart';
import '../../../l10n/app_localizations.dart';
import '../../../platform/device_form_factor.dart';
import '../../connections/api.dart';
import '../../files/api.dart';
import '../../forwarding/api.dart';
import '../../hosts/api.dart';
import '../../link/api.dart';
import '../../logs/api.dart';
import '../../monitor/api.dart';
import '../../settings/api.dart';
import '../../snippets/api.dart';
import '../../terminal/api.dart';
import '../application/workspace.dart';
import 'workspace_page.dart' show SessionStatusIcon;

enum _MobileNavTab { hosts, terminal, link, files }

/// Touch-first 4-tab workspace shell shown on Android/iOS under the 720dp tablet breakpoint (docs/MOBILE.md §2-3).
class MobileWorkspace extends ConsumerStatefulWidget {
  const MobileWorkspace({super.key});

  @override
  ConsumerState<MobileWorkspace> createState() => _MobileWorkspaceState();
}

class _MobileWorkspaceState extends ConsumerState<MobileWorkspace> {
  _MobileNavTab _tab = _MobileNavTab.hosts;
  var _filesBuilt = false;
  final _paneFocus = <PaneId, FocusNode>{};

  Workspace get _workspace => ref.read(workspaceProvider.notifier);

  @override
  void dispose() {
    for (final node in _paneFocus.values) {
      node.dispose();
    }
    super.dispose();
  }

  void _openHost(Host host) {
    _workspace.openHost(host);
    setState(() => _tab = _MobileNavTab.terminal);
  }

  void _openLocal(LocalShell shell) {
    _workspace.openLocal(shell);
    setState(() => _tab = _MobileNavTab.terminal);
  }

  Future<void> _showSheet(Widget child, {double heightFactor = 0.78}) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (context) => FractionallySizedBox(heightFactor: heightFactor, child: child),
  );

  void _openSnippetsSheet() => _showSheet(const SnippetsPanel());

  void _openQuickConnectSheet() {
    final l = AppLocalizations.of(context);
    final shells = isDesktopPlatform ? ref.read(localShellsProvider) : const <LocalShell>[];
    _showSheet(
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.md, 0, Space.md, Space.sm),
            child: Text(l.newConnection, style: Theme.of(context).textTheme.titleMedium),
          ),
          Expanded(
            child: HostTree(
              onConnect: (host) {
                Navigator.pop(context);
                _openHost(host);
              },
            ),
          ),
          if (shells.isNotEmpty) ...[
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(Space.sm),
              child: Wrap(
                spacing: Space.xs,
                runSpacing: Space.xs,
                children: [
                  for (final shell in shells)
                    ActionChip(
                      avatar: const Icon(Icons.terminal, size: 16),
                      label: Text(shell.name),
                      onPressed: () {
                        Navigator.pop(context);
                        _openLocal(shell);
                      },
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  void _openSessionsSheet(WorkspaceState state, Map<SessionId, TerminalSession> sessions) {
    final l = AppLocalizations.of(context);
    _showSheet(
      heightFactor: 0.55,
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.md, 0, Space.md, Space.sm),
            child: Row(
              children: [
                Text(l.mobileSessions, style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                IconButton(
                  tooltip: l.newConnection,
                  icon: const Icon(Icons.add),
                  onPressed: () {
                    Navigator.pop(context);
                    _openQuickConnectSheet();
                  },
                ),
              ],
            ),
          ),
          Expanded(
            child: state.tabs.isEmpty
                ? Center(child: Text(l.mobileNoActiveTerminal))
                : ListView.builder(
                    itemCount: state.tabs.length,
                    itemBuilder: (context, index) {
                      final tab = state.tabs[index];
                      final session = sessions[tab.layout.focusedLeaf.session];
                      final selected = state.active == tab.id;
                      final target = session?.linkTarget;
                      return ListTile(
                        selected: selected,
                        leading: session == null
                            ? const Icon(Icons.terminal)
                            : ListenableBuilder(
                                listenable: session,
                                builder: (_, _) => SessionStatusIcon(session.status),
                              ),
                        title: Text(session?.title ?? tab.id.value, overflow: TextOverflow.ellipsis),
                        subtitle: Text(
                          target == null
                              ? (session?.targetLabel ?? '')
                              : '${target.kind == LinkTerminalKind.mirror ? l.linkMirrorTag : l.linkProxyTag} · ${target.targetLabel}',
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: IconButton(
                          tooltip: l.closePane,
                          icon: const Icon(Icons.close, size: 18),
                          onPressed: () {
                            _workspace.closeTab(tab.id);
                            if (state.tabs.length <= 1) Navigator.pop(context);
                          },
                        ),
                        onTap: () {
                          _workspace.activate(tab.id);
                          setState(() => _tab = _MobileNavTab.terminal);
                          Navigator.pop(context);
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  void _openToolsSheet(TerminalSession? activeSession) {
    final l = AppLocalizations.of(context);
    final host = activeSession?.sshHost;
    _showSheet(
      heightFactor: 0.62,
      ListView(
        padding: const EdgeInsets.symmetric(horizontal: Space.sm),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.sm, 0, Space.sm, Space.sm),
            child: Text(l.mobileTools, style: Theme.of(context).textTheme.titleMedium),
          ),
          if (host != null)
            ListTile(
              leading: const Icon(Icons.monitor_heart_outlined),
              title: Text(l.monitor),
              onTap: () {
                Navigator.pop(context);
                _showSheet(MonitorPanel(host: host, active: true));
              },
            ),
          ListTile(
            leading: const Icon(Icons.code_outlined),
            title: Text(l.snippets),
            onTap: () {
              Navigator.pop(context);
              _openSnippetsSheet();
            },
          ),
          ListTile(
            leading: const Icon(Icons.key_outlined),
            title: Text(l.keys),
            onTap: () {
              Navigator.pop(context);
              _showSheet(const KeysPanel());
            },
          ),
          ListTile(
            leading: const Icon(Icons.swap_horiz_outlined),
            title: Text(l.portForwarding),
            onTap: () {
              Navigator.pop(context);
              _showSheet(const ForwardingPanel());
            },
          ),
          ListTile(
            leading: const Icon(Icons.alt_route_outlined),
            title: Text(l.proxies),
            onTap: () {
              Navigator.pop(context);
              _showSheet(const ProxyPanel());
            },
          ),
          ListTile(
            leading: const Icon(Icons.verified_user_outlined),
            title: Text(l.trustedKeys),
            onTap: () {
              Navigator.pop(context);
              _showSheet(
                SingleChildScrollView(
                  padding: const EdgeInsets.all(Space.md),
                  child: trustSettingsSection.build(context),
                ),
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.receipt_long_outlined),
            title: Text(l.logs),
            onTap: () {
              Navigator.pop(context);
              _showSheet(const LogsPanel());
            },
          ),
          ListTile(
            leading: const Icon(Icons.settings_outlined),
            title: Text(l.settings),
            onTap: () {
              Navigator.pop(context);
              showSettingsDialog(context);
            },
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final state = ref.watch(workspaceProvider);
    final sessions = ref.watch(terminalSessionsProvider);
    final linkClient = ref.watch(linkClientControllerProvider);

    final livePanes = {for (final t in state.tabs) ...t.layout.leaves.map((leaf) => leaf.pane)};
    _paneFocus.removeWhere((pane, node) {
      if (livePanes.contains(pane)) return false;
      node.dispose();
      return true;
    });

    if (_tab == _MobileNavTab.files) _filesBuilt = true;

    final activeTab = state.activeTab ?? state.tabs.firstOrNull;
    final activeLeaf = activeTab?.layout.focusedLeaf;
    final activeSession = activeLeaf == null ? null : sessions[activeLeaf.session];

    Widget terminalBody() {
      if (activeTab == null || activeLeaf == null || activeSession == null) {
        return Center(
          key: const ValueKey('mobile-terminal-empty'),
          child: Padding(
            padding: const EdgeInsets.all(Space.lg),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.terminal, size: 40, color: scheme.onSurfaceVariant),
                const SizedBox(height: Space.sm),
                Text(
                  l.mobileNoActiveTerminal,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                ),
                const SizedBox(height: Space.md),
                Wrap(
                  spacing: Space.sm,
                  runSpacing: Space.sm,
                  alignment: WrapAlignment.center,
                  children: [
                    FilledButton.icon(
                      onPressed: () => setState(() => _tab = _MobileNavTab.hosts),
                      icon: const Icon(Icons.dns_outlined, size: 18),
                      label: Text(l.hosts),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => setState(() => _tab = _MobileNavTab.link),
                      icon: const Icon(Icons.phonelink_outlined, size: 18),
                      label: Text(l.linkTitle),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      }
      return ColoredBox(
        color: scheme.surfaceContainerLowest,
        child: TerminalPane(
          activeSession,
          key: ValueKey('mobile-pane-${activeLeaf.pane.value}'),
          active: _tab == _MobileNavTab.terminal,
          visible: _tab == _MobileNavTab.terminal,
          compact: true,
          focusNode: _paneFocus.putIfAbsent(activeLeaf.pane, FocusNode.new),
          onOpenSnippets: _openSnippetsSheet,
        ),
      );
    }

    Widget topBarTitle() {
      if (_tab != _MobileNavTab.terminal) {
        final title = switch (_tab) {
          _MobileNavTab.hosts => l.hosts,
          _MobileNavTab.link => l.linkTitle,
          _MobileNavTab.files => l.files,
          _MobileNavTab.terminal => l.terminal,
        };
        return Text(title, style: Theme.of(context).textTheme.titleMedium, overflow: TextOverflow.ellipsis);
      }
      if (activeSession == null) {
        return Text(l.terminal, style: Theme.of(context).textTheme.titleMedium);
      }
      return InkWell(
        key: const ValueKey('mobile-session-switcher'),
        borderRadius: BorderRadius.circular(Radii.control),
        onTap: () => _openSessionsSheet(state, sessions),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Space.xs, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListenableBuilder(listenable: activeSession, builder: (_, _) => SessionStatusIcon(activeSession.status)),
              const SizedBox(width: Space.xs),
              Flexible(
                child: Text(
                  activeSession.title,
                  style: Theme.of(context).textTheme.titleSmall,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (activeSession.linkTarget != null) ...[
                const SizedBox(width: Space.xs),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    color: scheme.primary.withValues(alpha: .16),
                    borderRadius: BorderRadius.circular(Radii.pill),
                  ),
                  child: Text(
                    activeSession.linkTarget!.kind == LinkTerminalKind.mirror ? l.linkMirrorTag : l.linkProxyTag,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(color: scheme.primary),
                  ),
                ),
              ],
              const SizedBox(width: 2),
              Icon(Icons.expand_more, size: 18, color: scheme.onSurfaceVariant),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      key: const ValueKey('mobile-workspace'),
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            Container(
              height: 48,
              padding: const EdgeInsets.symmetric(horizontal: Space.md),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerLow,
                border: Border(bottom: BorderSide(color: scheme.outlineVariant.withValues(alpha: .35))),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Align(alignment: Alignment.centerLeft, child: topBarTitle()),
                  ),
                  if (_tab == _MobileNavTab.terminal || _tab == _MobileNavTab.hosts)
                    IconButton(
                      tooltip: l.newConnection,
                      icon: const Icon(Icons.add, size: 20),
                      onPressed: _openQuickConnectSheet,
                    ),
                  IconButton(
                    key: const ValueKey('mobile-tools-button'),
                    tooltip: l.mobileTools,
                    icon: const Icon(Icons.tune_outlined, size: 20),
                    onPressed: () => _openToolsSheet(activeSession),
                  ),
                  IconButton(
                    key: const ValueKey('mobile-settings-button'),
                    tooltip: l.settings,
                    icon: const Icon(Icons.settings_outlined, size: 20),
                    onPressed: () => showSettingsDialog(context),
                  ),
                ],
              ),
            ),
            Expanded(
              child: IndexedStack(
                index: _tab.index,
                children: [
                  VaultPage(active: _tab == _MobileNavTab.hosts, onConnect: _openHost),
                  terminalBody(),
                  MobileLinkPage(onOpenedTerminal: () => setState(() => _tab = _MobileNavTab.terminal)),
                  if (_filesBuilt) FilesPage(active: _tab == _MobileNavTab.files) else const SizedBox.shrink(),
                ],
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: ListenableBuilder(
        listenable: linkClient,
        builder: (context, _) {
          final approvals = linkClient.pendingApprovals.length;
          return NavigationBar(
            key: const ValueKey('mobile-bottom-nav'),
            height: 62,
            selectedIndex: _tab.index,
            onDestinationSelected: (index) => setState(() => _tab = _MobileNavTab.values[index]),
            destinations: [
              NavigationDestination(
                icon: const Icon(Icons.dns_outlined),
                selectedIcon: const Icon(Icons.dns),
                label: l.hosts,
              ),
              NavigationDestination(
                icon: Badge(
                  isLabelVisible: state.tabs.isNotEmpty,
                  label: Text('${state.tabs.length}'),
                  child: const Icon(Icons.terminal),
                ),
                label: l.terminal,
              ),
              NavigationDestination(
                icon: Badge(
                  isLabelVisible: approvals > 0 || linkClient.connected,
                  backgroundColor: approvals > 0 ? scheme.error : scheme.primary,
                  label: approvals > 0 ? Text('$approvals') : null,
                  child: const Icon(Icons.phonelink_outlined),
                ),
                selectedIcon: Badge(
                  isLabelVisible: approvals > 0 || linkClient.connected,
                  backgroundColor: approvals > 0 ? scheme.error : scheme.primary,
                  label: approvals > 0 ? Text('$approvals') : null,
                  child: const Icon(Icons.phonelink),
                ),
                label: l.linkTab,
              ),
              NavigationDestination(
                icon: const Icon(Icons.folder_outlined),
                selectedIcon: const Icon(Icons.folder),
                label: l.files,
              ),
            ],
          );
        },
      ),
    );
  }
}

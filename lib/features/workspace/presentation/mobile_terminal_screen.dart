import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../design/dock_panel.dart';
import '../../../design/menu.dart';
import '../../../design/sidebar_frame.dart';
import '../../../design/theme.dart';
import '../../../foundation/ids.dart';
import '../../../l10n/app_localizations.dart';
import '../../../platform/mobile_platform.dart';
import '../../ai/api.dart';
import '../../connections/api.dart';
import '../../files/api.dart';
import '../../hosts/api.dart';
import '../../link/api.dart';
import '../../monitor/api.dart';
import '../../settings/api.dart';
import '../../snippets/api.dart';
import '../../terminal/api.dart';
import '../application/workspace.dart';
import 'workspace_page.dart' show SessionStatusIcon;

/// Global compact banner shown at the top of mobile views whenever Desktop Airy Agent or MCP awaits remote approval.
class MobileApprovalBanner extends ConsumerStatefulWidget {
  const MobileApprovalBanner({super.key});

  @override
  ConsumerState<MobileApprovalBanner> createState() => _MobileApprovalBannerState();
}

class _MobileApprovalBannerState extends ConsumerState<MobileApprovalBanner> {
  String? _lastAlertId;

  @override
  Widget build(BuildContext context) {
    final link = ref.watch(linkClientControllerProvider);
    final haptics = ref.watch(settingsProvider).get(SettingKeys.mobileHaptics);

    return ListenableBuilder(
      listenable: link,
      builder: (context, _) {
        final pending = link.pendingApprovals;
        if (pending.isEmpty) {
          _lastAlertId = null;
          return const SizedBox.shrink();
        }
        final item = pending.first;
        if (_lastAlertId != item.approvalId) {
          _lastAlertId = item.approvalId;
          if (haptics) unawaited(HapticFeedback.mediumImpact());
        }
        final l = AppLocalizations.of(context);
        final scheme = Theme.of(context).colorScheme;
        return Container(
          key: ValueKey('mobile-approval-banner-${item.approvalId}'),
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(Space.lg, Space.sm, Space.lg, Space.sm),
          decoration: BoxDecoration(
            color: scheme.errorContainer,
            border: Border(bottom: BorderSide(color: scheme.error.withValues(alpha: .35))),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Icon(Icons.shield_outlined, size: 16, color: scheme.onErrorContainer),
                  const SizedBox(width: Space.xs),
                  Expanded(
                    child: Text(
                      item.target.isEmpty ? item.title : '${item.title} · ${item.target}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(color: scheme.onErrorContainer),
                    ),
                  ),
                  if (pending.length > 1)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                      decoration: BoxDecoration(color: scheme.error, borderRadius: BorderRadius.circular(Radii.pill)),
                      child: Text(
                        '+${pending.length - 1}',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(color: scheme.onError),
                      ),
                    ),
                ],
              ),
              if (item.command.isNotEmpty) ...[
                const SizedBox(height: Space.xs),
                Text(
                  item.command,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: mono(context, Theme.of(context).textTheme.bodySmall).copyWith(color: scheme.onErrorContainer),
                ),
              ],
              const SizedBox(height: Space.xs),
              if (item.actionable)
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      key: ValueKey('banner-deny-${item.approvalId}'),
                      style: TextButton.styleFrom(
                        foregroundColor: scheme.onErrorContainer,
                        visualDensity: VisualDensity.compact,
                      ),
                      onPressed: () => unawaited(link.decideApproval(item.approvalId, false)),
                      child: Text(l.linkDeny),
                    ),
                    const SizedBox(width: Space.xs),
                    FilledButton(
                      key: ValueKey('banner-allow-${item.approvalId}'),
                      style: FilledButton.styleFrom(
                        backgroundColor: scheme.error,
                        foregroundColor: scheme.onError,
                        visualDensity: VisualDensity.compact,
                      ),
                      onPressed: () => unawaited(link.decideApproval(item.approvalId, true)),
                      child: Text(l.linkAllow),
                    ),
                  ],
                )
              else
                Text(
                  l.linkDesktopOnlyAction,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(color: scheme.onErrorContainer),
                ),
            ],
          ),
        );
      },
    );
  }
}

enum _TabletSidePanel { airy, snippets }

/// Full-screen immersive terminal route pushed from the mobile shell (docs/MOBILE.md §3.1-3.2).
/// Keeps sessions alive in the background when popped; collapses header to a floating pill on short landscape phones
/// and switches to a desktop-style tab bar with dockable side panels on wide tablets.
class MobileTerminalScreen extends ConsumerStatefulWidget {
  const MobileTerminalScreen({super.key});

  @override
  ConsumerState<MobileTerminalScreen> createState() => _MobileTerminalScreenState();
}

class _MobileTerminalScreenState extends ConsumerState<MobileTerminalScreen> {
  final _paneFocus = <PaneId, FocusNode>{};
  final _tabScroll = ScrollController();
  StreamSubscription<void>? _linkReconnectedSub;
  var _landscapeBarExpanded = false;
  var _monitorOpen = false;
  _TabletSidePanel? _rightPanel;

  Workspace get _workspace => ref.read(workspaceProvider.notifier);

  @override
  void initState() {
    super.initState();
    _applyKeepAwake();
    _linkReconnectedSub = ref.read(linkClientControllerProvider).reconnected.listen((_) => _reattachLinkedSessions());
  }

  @override
  void dispose() {
    unawaited(_linkReconnectedSub?.cancel());
    unawaited(MobilePlatform.setKeepScreenOn(false));
    _tabScroll.dispose();
    for (final node in _paneFocus.values) {
      node.dispose();
    }
    super.dispose();
  }

  void _reattachLinkedSessions() {
    if (!mounted) return;
    final link = ref.read(linkClientControllerProvider);
    final peerId = link.connectedDesktopId;
    if (!link.connected || peerId == null) return;
    final sessions = ref.read(terminalSessionsProvider);
    for (final session in sessions.values) {
      final target = session.linkTarget;
      if (target != null &&
          target.peerId == peerId &&
          (session.status == SessionStatus.disconnected || session.status == SessionStatus.failed)) {
        unawaited(session.connect(const NoPrompts()).catchError((Object _) {}));
      }
    }
  }

  void _applyKeepAwake() {
    final keepAwake = ref.read(settingsProvider).get(SettingKeys.mobileKeepScreenOn);
    unawaited(MobilePlatform.setKeepScreenOn(keepAwake));
  }

  Future<void> _showSheet(Widget child, {double heightFactor = 0.78}) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (context) => FractionallySizedBox(
      heightFactor: heightFactor,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Space.xs),
        child: child,
      ),
    ),
  );

  void _seedAiry(String? seed) {
    if (seed != null && seed.trim().isNotEmpty) {
      final draft = ref.read(agentComposerProvider);
      final composer = ref.read(agentComposerProvider.notifier);
      composer.setGoal(draft.goal.isEmpty ? seed : '${draft.goal}\n$seed');
    }
  }

  void _openAirySheet({String? seed}) {
    _seedAiry(seed);
    unawaited(_showSheet(heightFactor: 0.72, AgentPanel(onClose: () => Navigator.of(context).pop())));
  }

  void _openSnippetsSheet() => unawaited(_showSheet(heightFactor: 0.62, const SnippetsPanel()));

  void _openMonitorSheet(Host host) =>
      unawaited(_showSheet(heightFactor: 0.72, MonitorPanel(host: host, active: true)));

  void _closeTab(TabId id) {
    _workspace.closeTab(id);
    if (ref.read(workspaceProvider).tabs.isEmpty && mounted && Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
  }

  void _openQuickConnectSheet() {
    final l = AppLocalizations.of(context);
    final hosts = ref.read(hostsProvider).where((h) => !h.transient).toList();
    final link = ref.read(linkClientControllerProvider);
    final desktopSessions = link.connected ? link.desktopSessions : const <LinkSessionSummary>[];
    unawaited(
      _showSheet(
        heightFactor: 0.62,
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(Space.lg, 0, Space.lg, Space.sm),
              child: Text(l.newConnection, style: Theme.of(context).textTheme.titleMedium),
            ),
            Expanded(
              child: ListView(
                children: [
                  if (desktopSessions.isNotEmpty) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(Space.lg, Space.xs, Space.lg, Space.xs),
                      child: Text(l.linkDesktopTerminals, style: Theme.of(context).textTheme.labelMedium),
                    ),
                    for (final entry in desktopSessions)
                      ListTile(
                        leading: Icon(entry.isLocal ? Icons.computer_rounded : Icons.desktop_windows_outlined),
                        title: Text(entry.title, overflow: TextOverflow.ellipsis),
                        subtitle: Text(
                          entry.targetLabel,
                          style: mono(context, Theme.of(context).textTheme.bodySmall),
                          overflow: TextOverflow.ellipsis,
                        ),
                        onTap: () {
                          Navigator.of(context).pop();
                          link.openMirroredSessionInWorkspace(entry);
                        },
                      ),
                    if (hosts.isNotEmpty) const Divider(),
                  ],
                  for (final host in hosts)
                    ListTile(
                      leading: const Icon(Icons.dns_outlined),
                      title: Text(host.title, overflow: TextOverflow.ellipsis),
                      subtitle: Text(
                        '${host.username}@${host.address}',
                        style: mono(context, Theme.of(context).textTheme.bodySmall),
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: () {
                        Navigator.of(context).pop();
                        _workspace.openHost(host);
                      },
                    ),
                  if (hosts.isEmpty && desktopSessions.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(Space.xl),
                      child: Center(child: Text(l.noHosts)),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _openFilesPage(TerminalSession session, {Host? host, FileLocation? location}) {
    unawaited(
      Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (routeContext) => MobileFilesPage(
            host: host,
            location: location,
            onSendPathToTerminal: (path) {
              Navigator.of(routeContext).pop();
              final escaped = path.contains(' ') ? "'${path.replaceAll("'", "'\\''")}'" : path;
              unawaited(session.insert(escaped, run: false, confirm: (_) async => true, confirmMultiline: false));
            },
            onAskAiry: location != null
                ? null
                : (prompt) {
                    Navigator.of(routeContext).pop();
                    _openAirySheet(seed: prompt);
                  },
          ),
        ),
      ),
    );
  }

  /// A linked terminal's files as a [FileLocation]; null while that channel has none.
  FileLocation? _linkFilesLocation(TerminalSession session, LinkClientController link) {
    final channel = session.linkShellChannel;
    final target = session.linkTarget;
    if (channel == null || target == null || !link.terminalFilesAvailable(channel)) return null;
    final local =
        target.isLocal ||
        (target.kind == LinkTerminalKind.mirror &&
            link.desktopSessions.any((entry) => entry.sessionId == target.remoteId && entry.isLocal));
    return FileLocation(
      id: 'link:terminal:${session.id.value}:${session.shellGeneration}',
      label: local ? target.peerName : session.title,
      kind: local ? FileLocationKind.computer : FileLocationKind.server,
      open: () => link.openTerminalFiles(channel),
      isCurrent: () => identical(session.linkShellChannel, channel) && link.terminalFilesAvailable(channel),
    );
  }

  Widget _terminalTools(
    TerminalSession session,
    LinkClientController link, {
    bool dockMonitor = false,
    bool dockFiles = false,
  }) => ListenableBuilder(
    listenable: Listenable.merge([session, link]),
    builder: (context, _) {
      final l = AppLocalizations.of(context);
      final palette = BrandPalette.of(context);
      final host = session.sshHost, channel = session.linkShellChannel;
      final remoteMonitor = link.terminalMonitor(channel);
      final remoteFiles = _linkFilesLocation(session, link);
      final monitorActive = dockMonitor && _monitorOpen;
      final filesActive = dockFiles && ref.read(settingsProvider).get(SettingKeys.mobileTabletFilesOpen);
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (host != null || remoteFiles != null)
            IconButton(
              key: const ValueKey('mobile-terminal-files'),
              visualDensity: VisualDensity.compact,
              tooltip: l.files,
              style: filesActive ? IconButton.styleFrom(backgroundColor: palette.primary.withValues(alpha: .14)) : null,
              icon: Icon(Icons.folder_outlined, size: 19, color: filesActive ? palette.primary : null),
              onPressed: () {
                if (dockFiles) {
                  ref.read(settingsProvider.notifier).set(SettingKeys.mobileTabletFilesOpen, !filesActive);
                  return;
                }
                if (host != null) {
                  _openFilesPage(session, host: host);
                  return;
                }
                _openFilesPage(session, location: remoteFiles);
              },
            ),
          if (host != null || remoteMonitor != null)
            IconButton(
              key: const ValueKey('mobile-terminal-monitor'),
              visualDensity: VisualDensity.compact,
              tooltip: l.monitor,
              style: monitorActive
                  ? IconButton.styleFrom(backgroundColor: palette.primary.withValues(alpha: .14))
                  : null,
              icon: Icon(Icons.monitor_heart_outlined, size: 19, color: monitorActive ? palette.primary : null),
              onPressed: () {
                if (dockMonitor) {
                  setState(() => _monitorOpen = !_monitorOpen);
                  return;
                }
                if (host != null) {
                  _openMonitorSheet(host);
                  return;
                }
                unawaited(
                  _showSheet(
                    heightFactor: .72,
                    MonitorPanel.remote(remote: remoteMonitor!, remoteName: session.title, active: true),
                  ),
                );
              },
            ),
        ],
      );
    },
  );

  Future<void> _handoffHost(Host host) async {
    final l = AppLocalizations.of(context);
    final ok = await ref.read(linkClientControllerProvider).handoffHostToDesktop(host.id.value);
    if (!mounted) return;
    if (ok) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.mobileHandoffSent)));
    }
  }

  /// Closes from the sessions sheet, leaving the terminal screen once nothing is open.
  void _closeFromSheet(BuildContext sheet, VoidCallback close, {bool popParent = true}) {
    close();
    if (popParent) Navigator.of(sheet).pop();
    if (ref.read(workspaceProvider).tabs.isEmpty && mounted && Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
  }

  Future<void> _mirrorProxySessionOnDesktop(LinkTerminalTarget target) async {
    final l = AppLocalizations.of(context);
    final link = ref.read(linkClientControllerProvider);
    final summary = target.isLocal
        ? await link.openLocalOnDesktopForMirror(target.remoteId)
        : await link.openHostOnDesktopForMirror(target.remoteId);
    if (!mounted) return;
    if (summary == null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.linkDesktopOpenFailed)));
      return;
    }
    link.openMirroredSessionInWorkspace(summary);
  }

  void _openSessionActions(BuildContext sheet, WorkspaceState state, WorkspaceTab tab, {bool popParent = true}) {
    final l = AppLocalizations.of(context);
    final target = ref.read(terminalSessionsProvider)[tab.layout.focusedLeaf.session]?.linkTarget;
    unawaited(
      showModalBottomSheet<void>(
        context: sheet,
        useSafeArea: true,
        showDragHandle: true,
        builder: (actions) {
          Widget closing(TabCloseScope scope, String label, IconData icon) => ListTile(
            leading: Icon(icon),
            title: Text(label),
            enabled: state.tabsToClose(tab.id, scope).isNotEmpty,
            onTap: () {
              Navigator.of(actions).pop();
              _closeFromSheet(sheet, () => _workspace.closeTabs(tab.id, scope), popParent: popParent);
            },
          );
          return SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (target != null && target.kind == LinkTerminalKind.proxy)
                  ListTile(
                    key: const ValueKey('mobile-session-desktop-mirror'),
                    leading: const Icon(Icons.desktop_windows_outlined),
                    title: Text(l.linkOpenOnDesktopMirrored),
                    onTap: () {
                      Navigator.of(actions).pop();
                      if (popParent) Navigator.of(sheet).pop();
                      unawaited(_mirrorProxySessionOnDesktop(target));
                    },
                  ),
                ListTile(
                  leading: const Icon(Icons.close),
                  title: Text(l.close),
                  onTap: () {
                    Navigator.of(actions).pop();
                    _closeFromSheet(sheet, () => _workspace.closeTab(tab.id), popParent: popParent);
                  },
                ),
                closing(TabCloseScope.left, popParent ? l.closeAbove : l.closeTabsLeft, Icons.vertical_align_top),
                closing(TabCloseScope.right, popParent ? l.closeBelow : l.closeTabsRight, Icons.vertical_align_bottom),
              ],
            ),
          );
        },
      ),
    );
  }

  void _openSessionsSheet(WorkspaceState state, Map<SessionId, TerminalSession> sessions) {
    final l = AppLocalizations.of(context);
    unawaited(
      _showSheet(
        heightFactor: 0.56,
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(Space.lg, 0, Space.md, Space.sm),
              child: Row(
                children: [
                  Expanded(child: Text(l.mobileSessions, style: Theme.of(context).textTheme.titleMedium)),
                  Builder(
                    builder: (sheet) => TextButton(
                      key: const ValueKey('mobile-sessions-close-all'),
                      onPressed: () => _closeFromSheet(sheet, () {
                        for (final tab in ref.read(workspaceProvider).tabs) {
                          _workspace.closeTab(tab.id);
                        }
                      }),
                      child: Text(l.closeAll),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: state.tabs.length,
                itemBuilder: (context, index) {
                  final tab = state.tabs[index];
                  final leaf = tab.layout.focusedLeaf;
                  final session = sessions[leaf.session];
                  final selected = tab.id == state.active;
                  final tag = session?.linkTarget == null
                      ? l.mobileDirectTag
                      : session!.linkTarget!.kind == LinkTerminalKind.mirror
                      ? l.linkMirrorTag
                      : l.linkProxyTag;
                  return ListTile(
                    selected: selected,
                    leading: session == null
                        ? const Icon(Icons.terminal)
                        : ListenableBuilder(listenable: session, builder: (_, _) => SessionStatusIcon(session.status)),
                    title: Text(session?.title ?? tab.title ?? l.terminal, overflow: TextOverflow.ellipsis),
                    subtitle: Text(
                      '${session?.targetLabel ?? ''} · $tag',
                      style: mono(context, Theme.of(context).textTheme.bodySmall),
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: IconButton(
                      tooltip: l.close,
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: () => _closeFromSheet(context, () => _workspace.closeTab(tab.id)),
                    ),
                    onLongPress: () => _openSessionActions(context, state, tab),
                    onTap: () {
                      _workspace.activate(tab.id);
                      Navigator.of(context).pop();
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _moreMenu(WorkspaceTab activeTab, TerminalSession activeSession, LinkClientController link) {
    final l = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final host = activeSession.sshHost;
    return PopupMenuButton<String>(
      key: const ValueKey('mobile-terminal-more'),
      icon: const Icon(Icons.more_vert_rounded, size: 19),
      padding: EdgeInsets.zero,
      onSelected: (action) {
        switch (action) {
          case 'handoff':
            if (host != null) unawaited(_handoffHost(host));
          case 'reconnect':
            unawaited(activeSession.connect(DialogPrompts(context)));
          case 'close':
            _closeTab(activeTab.id);
        }
      },
      itemBuilder: (_) => [
        if (link.connected && host != null && !host.transient)
          PopupMenuItem(
            value: 'handoff',
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.desktop_windows_outlined, size: 18),
              title: Text(l.mobileHandoffToDesktop),
            ),
          ),
        PopupMenuItem(
          value: 'reconnect',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.refresh_rounded, size: 18),
            title: Text(l.retry),
          ),
        ),
        PopupMenuItem(
          value: 'close',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.close_rounded, size: 18, color: scheme.error),
            title: Text(l.close, style: TextStyle(color: scheme.error)),
          ),
        ),
      ],
    );
  }

  Widget _tabletTabBar({
    required BuildContext context,
    required WorkspaceState state,
    required Map<SessionId, TerminalSession> sessions,
    required WorkspaceTab activeTab,
    required TerminalSession activeSession,
  }) {
    final l = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final palette = BrandPalette.of(context);
    final link = ref.watch(linkClientControllerProvider);
    final airyOpen = _rightPanel == _TabletSidePanel.airy;
    final snippetsOpen = _rightPanel == _TabletSidePanel.snippets;

    return Container(
      height: WorkspaceSize.titleBar,
      padding: const EdgeInsets.symmetric(horizontal: Space.xs),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        border: Border(bottom: BorderSide(color: scheme.outlineVariant.withValues(alpha: .35))),
      ),
      child: Row(
        children: [
          IconButton(
            key: const ValueKey('mobile-terminal-back'),
            visualDensity: VisualDensity.compact,
            tooltip: l.close,
            icon: const Icon(Icons.arrow_back_rounded, size: 20),
            onPressed: () => Navigator.of(context).pop(),
          ),
          const SizedBox(width: Space.xs),
          Expanded(
            child: Row(
              children: [
                Flexible(
                  child: SingleChildScrollView(
                    key: const ValueKey('tablet-terminal-tab-strip'),
                    controller: _tabScroll,
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (final tab in state.tabs)
                          if (sessions[tab.layout.focusedLeaf.session] case final session?)
                            _TabletTabChip(
                              key: ValueKey('tablet-tab-${tab.id.value}'),
                              tab: tab,
                              session: session,
                              selected: tab.id == activeTab.id,
                              onTap: () => _workspace.activate(tab.id),
                              onLongPress: () => _openSessionActions(context, state, tab, popParent: false),
                              onClose: () => _closeTab(tab.id),
                            ),
                      ],
                    ),
                  ),
                ),
                IconButton(
                  key: const ValueKey('tablet-terminal-add-tab'),
                  visualDensity: VisualDensity.compact,
                  tooltip: l.newConnection,
                  icon: const Icon(Icons.add_rounded, size: 20),
                  onPressed: _openQuickConnectSheet,
                ),
              ],
            ),
          ),
          IconButton(
            key: const ValueKey('mobile-terminal-airy'),
            visualDensity: VisualDensity.compact,
            tooltip: l.mobileAskAiry,
            style: airyOpen ? IconButton.styleFrom(backgroundColor: palette.primary.withValues(alpha: .14)) : null,
            icon: Icon(Icons.auto_awesome_rounded, size: 19, color: palette.primary),
            onPressed: () => setState(() => _rightPanel = airyOpen ? null : _TabletSidePanel.airy),
          ),
          IconButton(
            key: const ValueKey('tablet-terminal-snippets'),
            visualDensity: VisualDensity.compact,
            tooltip: l.snippets,
            style: snippetsOpen ? IconButton.styleFrom(backgroundColor: palette.primary.withValues(alpha: .14)) : null,
            icon: Icon(Icons.code_rounded, size: 19, color: snippetsOpen ? palette.primary : null),
            onPressed: () => setState(() => _rightPanel = snippetsOpen ? null : _TabletSidePanel.snippets),
          ),
          _terminalTools(activeSession, link, dockMonitor: true, dockFiles: true),
          _moreMenu(activeTab, activeSession, link),
        ],
      ),
    );
  }

  Widget _sessionHeader({
    required BuildContext context,
    required WorkspaceState state,
    required Map<SessionId, TerminalSession> sessions,
    required WorkspaceTab activeTab,
    required TerminalSession activeSession,
    required bool compactPill,
  }) {
    final l = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final palette = BrandPalette.of(context);
    final link = ref.watch(linkClientControllerProvider);
    final tag = activeSession.linkTarget == null
        ? l.mobileDirectTag
        : activeSession.linkTarget!.kind == LinkTerminalKind.mirror
        ? l.linkMirrorTag
        : l.linkProxyTag;

    final row = Row(
      mainAxisSize: compactPill ? MainAxisSize.min : MainAxisSize.max,
      children: [
        IconButton(
          key: const ValueKey('mobile-terminal-back'),
          visualDensity: VisualDensity.compact,
          tooltip: l.close,
          icon: const Icon(Icons.arrow_back_rounded, size: 20),
          onPressed: () => Navigator.of(context).pop(),
        ),
        if (compactPill)
          InkWell(
            onTap: () => _openSessionsSheet(state, sessions),
            borderRadius: BorderRadius.circular(Radii.control),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: Space.xs, vertical: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ListenableBuilder(
                    listenable: activeSession,
                    builder: (_, _) => SessionStatusIcon(activeSession.status),
                  ),
                  const SizedBox(width: Space.xs),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 140),
                    child: Text(
                      activeSession.title,
                      style: Theme.of(context).textTheme.labelLarge,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          )
        else
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onHorizontalDragEnd: (details) {
                final vx = details.primaryVelocity ?? 0;
                if (state.tabs.length > 1 && vx.abs() > 160) {
                  _workspace.cycle(vx < 0 ? 1 : -1);
                }
              },
              onTap: () => _openSessionsSheet(state, sessions),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: Space.xs, vertical: 6),
                child: Row(
                  children: [
                    ListenableBuilder(
                      listenable: activeSession,
                      builder: (_, _) => SessionStatusIcon(activeSession.status),
                    ),
                    const SizedBox(width: Space.xs),
                    Flexible(
                      child: Text(
                        activeSession.title,
                        style: Theme.of(context).textTheme.titleSmall,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: Space.xs),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                      decoration: BoxDecoration(
                        color: palette.primary.withValues(alpha: .15),
                        borderRadius: BorderRadius.circular(Radii.pill),
                      ),
                      child: Text(tag, style: Theme.of(context).textTheme.labelSmall?.copyWith(color: palette.primary)),
                    ),
                    if (state.tabs.length > 1) ...[
                      const SizedBox(width: 4),
                      Text(
                        '${state.tabs.length}',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ],
                    Icon(Icons.expand_more_rounded, size: 16, color: scheme.onSurfaceVariant),
                  ],
                ),
              ),
            ),
          ),
        IconButton(
          key: const ValueKey('mobile-terminal-airy'),
          visualDensity: VisualDensity.compact,
          tooltip: l.mobileAskAiry,
          icon: Icon(Icons.auto_awesome_rounded, size: 19, color: palette.primary),
          onPressed: _openAirySheet,
        ),
        _terminalTools(activeSession, link),
        _moreMenu(activeTab, activeSession, link),
        if (compactPill)
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.keyboard_arrow_up_rounded, size: 18),
            onPressed: () => setState(() => _landscapeBarExpanded = false),
          ),
      ],
    );

    if (compactPill) {
      return Material(
        elevation: 3,
        color: palette.surface.withValues(alpha: .94),
        borderRadius: BorderRadius.circular(Radii.pill),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Space.xs),
          child: row,
        ),
      );
    }
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: Space.sm),
      decoration: BoxDecoration(
        color: palette.surface,
        border: Border(bottom: BorderSide(color: scheme.outlineVariant.withValues(alpha: .35))),
      ),
      child: row,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final palette = BrandPalette.of(context);
    final state = ref.watch(workspaceProvider);
    final sessions = ref.watch(terminalSessionsProvider);
    final settings = ref.watch(settingsProvider);
    final keepAwake = settings.get(SettingKeys.mobileKeepScreenOn);
    unawaited(MobilePlatform.setKeepScreenOn(keepAwake));

    final livePanes = {for (final t in state.tabs) ...t.layout.leaves.map((leaf) => leaf.pane)};
    _paneFocus.removeWhere((pane, node) {
      if (livePanes.contains(pane)) return false;
      node.dispose();
      return true;
    });

    final activeTab = state.activeTab ?? state.tabs.firstOrNull;
    final activeLeaf = activeTab?.layout.focusedLeaf;
    final activeSession = activeLeaf == null ? null : sessions[activeLeaf.session];

    if (activeTab == null || activeLeaf == null || activeSession == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && Navigator.of(context).canPop()) Navigator.of(context).pop();
      });
      return const Scaffold(body: SizedBox.shrink());
    }

    final size = MediaQuery.sizeOf(context);
    final isLandscape = size.width > size.height && size.height < 520;
    final isTabletWide = !isLandscape && size.width >= MobileSize.railBreakpoint;

    final pane = ColoredBox(
      color: scheme.surfaceContainerLowest,
      child: TerminalPane(
        activeSession,
        key: ValueKey('mobile-pane-${activeLeaf.pane.value}'),
        active: true,
        visible: true,
        compact: true,
        focusNode: _paneFocus.putIfAbsent(activeLeaf.pane, FocusNode.new),
        onOpenSnippets: isTabletWide
            ? () => setState(
                () => _rightPanel = _rightPanel == _TabletSidePanel.snippets ? null : _TabletSidePanel.snippets,
              )
            : _openSnippetsSheet,
        onAskAgent: isTabletWide
            ? (excerpt) {
                _seedAiry(excerpt);
                setState(() => _rightPanel = _TabletSidePanel.airy);
              }
            : (excerpt) => _openAirySheet(seed: excerpt),
      ),
    );

    if (isLandscape) {
      return Scaffold(
        key: const ValueKey('mobile-terminal-screen'),
        backgroundColor: scheme.surfaceContainerLowest,
        body: SafeArea(
          child: Stack(
            children: [
              Column(
                children: [
                  const MobileApprovalBanner(),
                  Expanded(child: pane),
                ],
              ),
              Positioned(
                top: Space.xs,
                right: Space.sm,
                child: _landscapeBarExpanded
                    ? _sessionHeader(
                        context: context,
                        state: state,
                        sessions: sessions,
                        activeTab: activeTab,
                        activeSession: activeSession,
                        compactPill: true,
                      )
                    : Material(
                        elevation: 2,
                        color: palette.surface.withValues(alpha: .86),
                        borderRadius: BorderRadius.circular(Radii.pill),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(Radii.pill),
                          onTap: () => setState(() => _landscapeBarExpanded = true),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: Space.sm, vertical: 6),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                ListenableBuilder(
                                  listenable: activeSession,
                                  builder: (_, _) => SessionStatusIcon(activeSession.status),
                                ),
                                const SizedBox(width: Space.xs),
                                Text(activeSession.title, style: Theme.of(context).textTheme.labelMedium),
                                const SizedBox(width: 2),
                                const Icon(Icons.expand_more_rounded, size: 16),
                              ],
                            ),
                          ),
                        ),
                      ),
              ),
            ],
          ),
        ),
      );
    }

    if (isTabletWide) {
      final l = AppLocalizations.of(context);
      final link = ref.watch(linkClientControllerProvider);
      final host = activeSession.sshHost;
      final remoteMonitor = link.terminalMonitor(activeSession.linkShellChannel);
      final showMonitor = _monitorOpen && (host != null || remoteMonitor != null);
      final filesLocation = _linkFilesLocation(activeSession, link);
      final filesAvailable = host != null || filesLocation != null;
      final showFiles =
          filesAvailable &&
          activeSession.status == SessionStatus.connected &&
          settings.get(SettingKeys.mobileTabletFilesOpen);
      final monitorWidth = settings.get(SettingKeys.monitorWidth);
      final dock = settings.get(SettingKeys.filesDock);
      final rightPanel = _rightPanel;

      void setFilesOpen(bool open) => ref.read(settingsProvider.notifier).set(SettingKeys.mobileTabletFilesOpen, open);
      void closeRightPanel() => setState(() => _rightPanel = null);

      final paneWithFiles = DockPanel(
        key: const ValueKey('tablet-files-dock'),
        open: showFiles,
        side: switch (dock) {
          FilesDock.left => DockSide.left,
          FilesDock.right => DockSide.right,
          FilesDock.bottom => DockSide.bottom,
        },
        onClose: () => setFilesOpen(false),
        closeLabel: l.closePane,
        resizeLabel: l.resizeToolPanel,
        showHeader: false,
        panel: filesAvailable
            ? SideFilesPanel(
                key: const ValueKey('tablet-files-panel'),
                host: filesLocation == null ? host : null,
                location: filesLocation,
                active: true,
                tree: dock == FilesDock.bottom,
                directory: activeSession.directory,
                listing: activeSession.listingTicks,
                toolbarActions: [
                  AppMenuButton<FilesDock>(
                    key: const ValueKey('tablet-files-dock-menu'),
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
                    onSelected: (value) => ref.read(settingsProvider.notifier).set(SettingKeys.filesDock, value),
                  ),
                  IconButton(
                    key: const ValueKey('tablet-files-expand'),
                    tooltip: l.mobileFilesExpand,
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.open_in_full_rounded, size: 16),
                    onPressed: () => _openFilesPage(
                      activeSession,
                      host: filesLocation == null ? host : null,
                      location: filesLocation,
                    ),
                  ),
                  IconButton(
                    tooltip: l.closePane,
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.close, size: 16),
                    onPressed: () => setFilesOpen(false),
                  ),
                ],
              )
            : const SizedBox.shrink(),
        child: pane,
      );

      return Scaffold(
        key: const ValueKey('mobile-terminal-screen'),
        backgroundColor: scheme.surfaceContainerLowest,
        body: SafeArea(
          child: Column(
            children: [
              _tabletTabBar(
                context: context,
                state: state,
                sessions: sessions,
                activeTab: activeTab,
                activeSession: activeSession,
              ),
              const MobileApprovalBanner(),
              Expanded(
                child: DockPanel(
                  open: rightPanel != null,
                  onClose: closeRightPanel,
                  closeLabel: l.close,
                  resizeLabel: l.aiAgentTitle,
                  showHeader: false,
                  initialWidth: math.min(WorkspaceSize.toolPanel, size.width * .4),
                  panel: switch (rightPanel) {
                    _TabletSidePanel.airy => KeyedSubtree(
                      key: const ValueKey('tablet-side-airy'),
                      child: AgentPanel(onClose: closeRightPanel),
                    ),
                    _TabletSidePanel.snippets => KeyedSubtree(
                      key: const ValueKey('tablet-side-snippets'),
                      child: Column(
                        children: [
                          Container(
                            height: 40,
                            padding: const EdgeInsets.only(left: Space.md, right: Space.xs),
                            decoration: BoxDecoration(
                              border: Border(bottom: BorderSide(color: scheme.outlineVariant.withValues(alpha: .3))),
                            ),
                            child: Row(
                              children: [
                                Expanded(child: Text(l.snippets, style: Theme.of(context).textTheme.titleSmall)),
                                IconButton(
                                  tooltip: l.close,
                                  visualDensity: VisualDensity.compact,
                                  icon: const Icon(Icons.close_rounded, size: 18),
                                  onPressed: closeRightPanel,
                                ),
                              ],
                            ),
                          ),
                          const Expanded(child: SnippetsPanel()),
                        ],
                      ),
                    ),
                    null => const SizedBox.shrink(),
                  },
                  child: SidebarFrame(
                    key: const ValueKey('tablet-monitor-frame'),
                    width: monitorWidth,
                    onResize: (width) => ref.read(settingsProvider.notifier).set(SettingKeys.monitorWidth, width),
                    resizeLabel: l.resizeMonitor,
                    sidebar: showMonitor
                        ? ColoredBox(
                            key: const ValueKey('tablet-side-monitor'),
                            color: palette.surface,
                            child: host != null
                                ? MonitorPanel(
                                    key: ValueKey('tablet-monitor-${activeTab.id.value}'),
                                    host: host,
                                    active: true,
                                  )
                                : MonitorPanel.remote(
                                    key: ValueKey('tablet-monitor-${activeTab.id.value}'),
                                    remote: remoteMonitor!,
                                    remoteName: activeSession.title,
                                    active: true,
                                  ),
                          )
                        : null,
                    child: paneWithFiles,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      key: const ValueKey('mobile-terminal-screen'),
      backgroundColor: scheme.surfaceContainerLowest,
      body: SafeArea(
        child: Column(
          children: [
            _sessionHeader(
              context: context,
              state: state,
              sessions: sessions,
              activeTab: activeTab,
              activeSession: activeSession,
              compactPill: false,
            ),
            const MobileApprovalBanner(),
            Expanded(child: pane),
          ],
        ),
      ),
    );
  }
}

/// Desktop-style rounded session tab rendered in the tablet landscape terminal top bar.
class _TabletTabChip extends StatelessWidget {
  const _TabletTabChip({
    super.key,
    required this.tab,
    required this.session,
    required this.selected,
    required this.onTap,
    required this.onLongPress,
    required this.onClose,
  });

  final WorkspaceTab tab;
  final TerminalSession session;
  final bool selected;
  final VoidCallback onTap, onLongPress, onClose;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final title = tab.title ?? session.title;
    return Padding(
      padding: const EdgeInsets.only(right: Space.xs),
      child: Center(
        child: AnimatedContainer(
          duration: Motion.of(context, Motion.quick),
          decoration: BoxDecoration(
            color: selected ? scheme.surface : Colors.transparent,
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
              onTap: onTap,
              onLongPress: onLongPress,
              child: IntrinsicWidth(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minWidth: WorkspaceSize.tabMin, maxWidth: WorkspaceSize.tabMax),
                  child: SizedBox(
                    height: 32,
                    child: Padding(
                      padding: const EdgeInsets.only(left: Space.sm, right: Space.xs),
                      child: Row(
                        children: [
                          SizedBox.square(
                            dimension: 14,
                            child: Center(
                              child: ListenableBuilder(
                                listenable: session,
                                builder: (_, _) => SessionStatusIcon(session.status, unread: session.unread),
                              ),
                            ),
                          ),
                          const SizedBox(width: Space.sm),
                          Expanded(
                            child: Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                                color: selected ? scheme.onSurface : scheme.onSurfaceVariant,
                                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                              ),
                            ),
                          ),
                          const SizedBox(width: Space.xs),
                          SizedBox.square(
                            dimension: 24,
                            child: IconButton(
                              key: ValueKey('tablet-tab-close-${tab.id.value}'),
                              tooltip: l.close,
                              padding: EdgeInsets.zero,
                              iconSize: 14,
                              color: scheme.onSurfaceVariant,
                              onPressed: onClose,
                              icon: const Icon(Icons.close_rounded),
                            ),
                          ),
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
    );
  }
}

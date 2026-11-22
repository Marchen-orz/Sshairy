import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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

/// Full-screen immersive terminal route pushed from the mobile shell (docs/MOBILE.md §3.1-3.2).
/// Keeps sessions alive in the background when popped; collapses header to a floating pill in landscape.
class MobileTerminalScreen extends ConsumerStatefulWidget {
  const MobileTerminalScreen({super.key});

  @override
  ConsumerState<MobileTerminalScreen> createState() => _MobileTerminalScreenState();
}

class _MobileTerminalScreenState extends ConsumerState<MobileTerminalScreen> {
  final _paneFocus = <PaneId, FocusNode>{};
  var _landscapeBarExpanded = false;

  Workspace get _workspace => ref.read(workspaceProvider.notifier);

  @override
  void initState() {
    super.initState();
    _applyKeepAwake();
  }

  @override
  void dispose() {
    unawaited(MobilePlatform.setKeepScreenOn(false));
    for (final node in _paneFocus.values) {
      node.dispose();
    }
    super.dispose();
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

  void _openAirySheet({String? seed}) {
    if (seed != null && seed.trim().isNotEmpty) {
      final draft = ref.read(agentComposerProvider);
      final composer = ref.read(agentComposerProvider.notifier);
      composer.setGoal(draft.goal.isEmpty ? seed : '${draft.goal}\n$seed');
    }
    unawaited(_showSheet(heightFactor: 0.72, AgentPanel(onClose: () => Navigator.of(context).pop())));
  }

  void _openSnippetsSheet() => unawaited(_showSheet(heightFactor: 0.62, const SnippetsPanel()));

  void _openMonitorSheet(Host host) =>
      unawaited(_showSheet(heightFactor: 0.72, MonitorPanel(host: host, active: true)));

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

  Widget _terminalTools(TerminalSession session, LinkClientController link) => ListenableBuilder(
    listenable: Listenable.merge([session, link]),
    builder: (context, _) {
      final l = AppLocalizations.of(context);
      final host = session.sshHost, channel = session.linkShellChannel;
      final remoteMonitor = link.terminalMonitor(channel);
      final remoteFiles = channel != null && link.terminalFilesAvailable(channel);
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (host != null || remoteFiles)
            IconButton(
              key: const ValueKey('mobile-terminal-files'),
              visualDensity: VisualDensity.compact,
              tooltip: l.files,
              icon: const Icon(Icons.folder_outlined, size: 19),
              onPressed: () {
                if (host != null) {
                  _openFilesPage(session, host: host);
                  return;
                }
                final target = session.linkTarget!;
                final local =
                    target.kind == LinkTerminalKind.mirror &&
                    link.desktopSessions.any((entry) => entry.sessionId == target.remoteId && entry.isLocal);
                _openFilesPage(
                  session,
                  location: FileLocation(
                    id: 'link:terminal:${session.id.value}:${session.shellGeneration}',
                    label: local ? target.peerName : session.title,
                    kind: local ? FileLocationKind.computer : FileLocationKind.server,
                    open: () => link.openTerminalFiles(channel!),
                    isCurrent: () =>
                        identical(session.linkShellChannel, channel) && link.terminalFilesAvailable(channel),
                  ),
                );
              },
            ),
          if (host != null || remoteMonitor != null)
            IconButton(
              key: const ValueKey('mobile-terminal-monitor'),
              visualDensity: VisualDensity.compact,
              tooltip: l.monitor,
              icon: const Icon(Icons.monitor_heart_outlined, size: 19),
              onPressed: () {
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
  void _closeFromSheet(BuildContext sheet, VoidCallback close) {
    close();
    Navigator.of(sheet).pop();
    if (ref.read(workspaceProvider).tabs.isEmpty && mounted) Navigator.of(context).pop();
  }

  void _openSessionActions(BuildContext sheet, WorkspaceState state, WorkspaceTab tab) {
    final l = AppLocalizations.of(context);
    Widget closing(TabCloseScope scope, String label, IconData icon) => ListTile(
      leading: Icon(icon),
      title: Text(label),
      enabled: state.tabsToClose(tab.id, scope).isNotEmpty,
      onTap: () {
        Navigator.of(sheet).pop();
        _closeFromSheet(sheet, () => _workspace.closeTabs(tab.id, scope));
      },
    );
    unawaited(
      showModalBottomSheet<void>(
        context: sheet,
        useSafeArea: true,
        showDragHandle: true,
        builder: (actions) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.close),
                title: Text(l.close),
                onTap: () {
                  Navigator.of(actions).pop();
                  _closeFromSheet(sheet, () => _workspace.closeTab(tab.id));
                },
              ),
              closing(TabCloseScope.left, l.closeAbove, Icons.vertical_align_top),
              closing(TabCloseScope.right, l.closeBelow, Icons.vertical_align_bottom),
            ],
          ),
        ),
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
    final host = activeSession.sshHost;
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
        PopupMenuButton<String>(
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
                _workspace.closeTab(activeTab.id);
                if (ref.read(workspaceProvider).tabs.isEmpty && mounted) {
                  Navigator.of(context).pop();
                }
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
        ),
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
    final keepAwake = ref.watch(settingsProvider).get(SettingKeys.mobileKeepScreenOn);
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

    final pane = ColoredBox(
      color: scheme.surfaceContainerLowest,
      child: TerminalPane(
        activeSession,
        key: ValueKey('mobile-pane-${activeLeaf.pane.value}'),
        active: true,
        visible: true,
        compact: true,
        focusNode: _paneFocus.putIfAbsent(activeLeaf.pane, FocusNode.new),
        onOpenSnippets: _openSnippetsSheet,
        onAskAgent: (excerpt) => _openAirySheet(seed: excerpt),
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

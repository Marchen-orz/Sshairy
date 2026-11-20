import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../design/brand.dart';
import '../../../design/dialog.dart';
import '../../../design/theme.dart';
import '../../../foundation/app_info.dart';
import '../../../l10n/app_localizations.dart';
import '../../../platform/device_form_factor.dart';
import '../../../platform/mobile_platform.dart';
import '../../ai/api.dart';
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
import 'mobile_terminal_screen.dart';
import 'workspace_page.dart' show SessionStatusIcon;

enum _MobileNavTab { hosts, airy, link, me }

/// Pure mobile 4-tab workspace shell (Hosts / Airy / Link / Me) with full-screen immersive terminal routes,
/// floating active-session capsule, global remote approval banner, native keep-alive, and biometric app lock
/// (docs/MOBILE.md §3).
class MobileWorkspace extends ConsumerStatefulWidget {
  const MobileWorkspace({super.key});

  @override
  ConsumerState<MobileWorkspace> createState() => _MobileWorkspaceState();
}

class _MobileWorkspaceState extends ConsumerState<MobileWorkspace> with WidgetsBindingObserver {
  _MobileNavTab _tab = _MobileNavTab.hosts;
  var _airyBuilt = false;
  var _terminalRouteOpen = false;
  var _locked = false;
  var _authenticating = false;
  var _pausedForLock = false;
  (bool, int)? _lastKeepAlive;

  Workspace get _workspace => ref.read(workspaceProvider.notifier);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (isMobilePlatform && ref.read(settingsProvider).get(SettingKeys.mobileBiometricLock)) {
      _locked = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _locked) unawaited(_authenticate());
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_lastKeepAlive?.$1 == true) {
      unawaited(MobilePlatform.stopKeepAlive());
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!isMobilePlatform) return;
    final biometricEnabled = ref.read(settingsProvider).get(SettingKeys.mobileBiometricLock);
    if (!biometricEnabled) return;
    if (state == AppLifecycleState.paused) {
      _pausedForLock = true;
    } else if (state == AppLifecycleState.resumed && _pausedForLock) {
      _pausedForLock = false;
      if (!_locked) {
        setState(() => _locked = true);
        unawaited(_authenticate());
      }
    }
  }

  Future<void> _authenticate() async {
    if (_authenticating || !mounted) return;
    _authenticating = true;
    try {
      final l = AppLocalizations.of(context);
      final ok = await MobilePlatform.authenticateBiometric(title: l.mobileUnlockPrompt);
      if (mounted && ok) {
        setState(() => _locked = false);
      }
    } finally {
      _authenticating = false;
    }
  }

  void _syncKeepAlive(BuildContext context, int activeCount, bool enabled) {
    if (!isMobilePlatform) return;
    final shouldRun = enabled && activeCount > 0;
    final next = (shouldRun, activeCount);
    if (_lastKeepAlive == next) return;
    _lastKeepAlive = next;
    if (shouldRun) {
      final l = AppLocalizations.of(context);
      unawaited(
        MobilePlatform.startKeepAlive(title: l.mobileKeepAliveTitle, subtitle: l.mobileKeepAliveSubtitle(activeCount)),
      );
    } else {
      unawaited(MobilePlatform.stopKeepAlive());
    }
  }

  void _openTerminalScreen() {
    if (_terminalRouteOpen || !mounted) return;
    _terminalRouteOpen = true;
    unawaited(
      Navigator.of(context)
          .push<void>(MaterialPageRoute<void>(builder: (_) => const MobileTerminalScreen()))
          .whenComplete(() => _terminalRouteOpen = false),
    );
  }

  void _openHost(Host host) {
    _workspace.openHost(host);
    _openTerminalScreen();
  }

  void _askAiry(String seed) {
    if (seed.trim().isNotEmpty) {
      final draft = ref.read(agentComposerProvider);
      final composer = ref.read(agentComposerProvider.notifier);
      composer.setGoal(draft.goal.isEmpty ? seed : '${draft.goal}\n$seed');
    }
    setState(() => _tab = _MobileNavTab.airy);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final palette = BrandPalette.of(context);
    final state = ref.watch(workspaceProvider);
    final sessions = ref.watch(terminalSessionsProvider);
    final linkClient = ref.watch(linkClientControllerProvider);
    if (_tab == _MobileNavTab.airy) _airyBuilt = true;
    final agentRuntime = _airyBuilt ? ref.watch(agentRuntimeProvider) : null;
    final keepAliveEnabled = ref.watch(settingsProvider).get(SettingKeys.mobileKeepAlive);

    final activeTab = state.activeTab ?? state.tabs.firstOrNull;
    final activeLeaf = activeTab?.layout.focusedLeaf;
    final activeSession = activeLeaf == null ? null : sessions[activeLeaf.session];

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final totalActive = state.tabs.length + (linkClient.connected ? 1 : 0);
      _syncKeepAlive(context, totalActive, keepAliveEnabled);
    });

    final hasAppBg = ref.watch(settingsProvider.select((s) => s.get(imageSetting(BackgroundSlot.app)) != null));

    final shell = Stack(
      children: [
        Positioned.fill(
          child: BackgroundImageView(slot: BackgroundSlot.app, baseColor: palette.background),
        ),
        Scaffold(
          key: const ValueKey('mobile-workspace'),
          backgroundColor: Colors.transparent,
          body: SafeArea(
            bottom: false,
            child: Column(
              children: [
                const MobileApprovalBanner(),
                Expanded(
                  child: IndexedStack(
                    index: _tab.index,
                    children: [
                      _MobileHostsTab(
                        active: _tab == _MobileNavTab.hosts,
                        onOpenHost: _openHost,
                        onOpenedTerminal: _openTerminalScreen,
                        onGoLink: () => setState(() => _tab = _MobileNavTab.link),
                        onAskAiry: _askAiry,
                      ),
                      if (_airyBuilt)
                        _MobileAiryTab(onGoLink: () => setState(() => _tab = _MobileNavTab.link))
                      else
                        const SizedBox.shrink(),
                      Column(
                        children: [
                          _MobileTabHeader(title: l.linkTitle),
                          Expanded(child: MobileLinkPage(onOpenedTerminal: _openTerminalScreen)),
                        ],
                      ),
                      const _MobileMeTab(),
                    ],
                  ),
                ),
                if (activeTab != null && activeSession != null)
                  _ActiveSessionCapsule(
                    tab: activeTab,
                    session: activeSession,
                    totalCount: state.tabs.length,
                    onTap: _openTerminalScreen,
                    onCycle: _workspace.cycle,
                    onClose: () => _workspace.closeTab(activeTab.id),
                  ),
              ],
            ),
          ),
          bottomNavigationBar: ListenableBuilder(
            listenable: Listenable.merge([linkClient, ?agentRuntime]),
            builder: (context, _) {
              final approvals = linkClient.pendingApprovals.length;
              final airyAlert =
                  agentRuntime != null &&
                  (agentRuntime.busy || agentRuntime.approval != null || agentRuntime.hostApproval != null);
              return NavigationBar(
                key: const ValueKey('mobile-bottom-nav'),
                height: 64,
                backgroundColor: hasAppBg ? palette.surface.withValues(alpha: .88) : palette.surface,
                indicatorColor: palette.primary.withValues(alpha: .16),
                selectedIndex: _tab.index,
                onDestinationSelected: (index) => setState(() => _tab = _MobileNavTab.values[index]),
                destinations: [
                  NavigationDestination(
                    icon: const Icon(Icons.dns_outlined),
                    selectedIcon: Icon(Icons.dns, color: palette.primary),
                    label: l.hosts,
                  ),
                  NavigationDestination(
                    icon: Badge(
                      isLabelVisible: airyAlert,
                      backgroundColor: palette.primary,
                      child: const Icon(Icons.auto_awesome_outlined),
                    ),
                    selectedIcon: Badge(
                      isLabelVisible: airyAlert,
                      backgroundColor: palette.primary,
                      child: Icon(Icons.auto_awesome_rounded, color: palette.primary),
                    ),
                    label: l.mobileTabAiry,
                  ),
                  NavigationDestination(
                    icon: Badge(
                      isLabelVisible: approvals > 0 || linkClient.connected,
                      backgroundColor: approvals > 0 ? scheme.error : palette.primary,
                      label: approvals > 0 ? Text('$approvals') : null,
                      child: const Icon(Icons.phonelink_outlined),
                    ),
                    selectedIcon: Badge(
                      isLabelVisible: approvals > 0 || linkClient.connected,
                      backgroundColor: approvals > 0 ? scheme.error : palette.primary,
                      label: approvals > 0 ? Text('$approvals') : null,
                      child: Icon(Icons.phonelink, color: palette.primary),
                    ),
                    label: l.linkTab,
                  ),
                  NavigationDestination(
                    icon: const Icon(Icons.person_outline_rounded),
                    selectedIcon: Icon(Icons.person_rounded, color: palette.primary),
                    label: l.mobileTabMe,
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );

    if (!_locked) return shell;
    return Stack(
      children: [
        shell,
        Positioned.fill(
          child: Material(
            color: palette.background,
            child: SafeArea(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(Space.xl),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const BrandIllustration(pose: BrandPose.security, size: 132),
                      const SizedBox(height: Space.lg),
                      Text(l.mobileUnlockPrompt, style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: Space.lg),
                      FilledButton.icon(
                        style: FilledButton.styleFrom(minimumSize: const Size(180, 48)),
                        onPressed: _authenticate,
                        icon: const Icon(Icons.fingerprint_rounded),
                        label: Text(l.mobileUnlockAction),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _MobileTabHeader extends StatelessWidget {
  const _MobileTabHeader({required this.title, this.leading, this.trailing});

  final String title;
  final Widget? leading;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final palette = BrandPalette.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Container(
      height: 52,
      padding: const EdgeInsets.symmetric(horizontal: Space.lg),
      decoration: BoxDecoration(
        color: palette.background.withValues(alpha: .82),
        border: Border(bottom: BorderSide(color: scheme.outlineVariant.withValues(alpha: .28))),
      ),
      child: Row(
        children: [
          if (leading != null) ...[leading!, const SizedBox(width: Space.sm)],
          Expanded(
            child: Text(
              title,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// Floating active-session pill hovering above the bottom navigation bar; tap to jump back to terminal,
/// swipe horizontally to cycle open sessions.
class _ActiveSessionCapsule extends StatelessWidget {
  const _ActiveSessionCapsule({
    required this.tab,
    required this.session,
    required this.totalCount,
    required this.onTap,
    required this.onCycle,
    required this.onClose,
  });

  final WorkspaceTab tab;
  final TerminalSession session;
  final int totalCount;
  final VoidCallback onTap;
  final ValueChanged<int> onCycle;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final palette = BrandPalette.of(context);
    final scheme = Theme.of(context).colorScheme;
    final tag = session.linkTarget == null
        ? l.mobileDirectTag
        : session.linkTarget!.kind == LinkTerminalKind.mirror
        ? l.linkMirrorTag
        : l.linkProxyTag;

    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.lg, Space.xs, Space.lg, Space.sm),
      child: GestureDetector(
        onHorizontalDragEnd: (details) {
          final vx = details.primaryVelocity ?? 0;
          if (totalCount > 1 && vx.abs() > 140) {
            onCycle(vx < 0 ? 1 : -1);
          }
        },
        child: Material(
          key: const ValueKey('mobile-session-capsule'),
          color: palette.raised,
          elevation: 2,
          borderRadius: BorderRadius.circular(16),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(16),
            child: Container(
              height: 48,
              padding: const EdgeInsets.only(left: Space.md, right: Space.xs),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: palette.primary.withValues(alpha: .35)),
              ),
              child: Row(
                children: [
                  ListenableBuilder(listenable: session, builder: (_, _) => SessionStatusIcon(session.status)),
                  const SizedBox(width: Space.sm),
                  Expanded(
                    child: Text(
                      session.title,
                      style: Theme.of(context).textTheme.titleSmall,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: palette.primary.withValues(alpha: .14),
                      borderRadius: BorderRadius.circular(Radii.pill),
                    ),
                    child: Text(
                      totalCount > 1 ? '$tag · $totalCount' : tag,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(color: palette.primary),
                    ),
                  ),
                  IconButton(
                    tooltip: l.close,
                    visualDensity: VisualDensity.compact,
                    icon: Icon(Icons.close_rounded, size: 18, color: scheme.onSurfaceVariant),
                    onPressed: onClose,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Tab 0: Mobile-native Hosts view (live desktop mirror strip + quick-connect + groups + touch host cards).
class _MobileHostsTab extends ConsumerStatefulWidget {
  const _MobileHostsTab({
    required this.active,
    required this.onOpenHost,
    required this.onOpenedTerminal,
    required this.onGoLink,
    required this.onAskAiry,
  });

  final bool active;
  final ValueChanged<Host> onOpenHost;
  final VoidCallback onOpenedTerminal;
  final VoidCallback onGoLink;
  final ValueChanged<String> onAskAiry;

  @override
  ConsumerState<_MobileHostsTab> createState() => _MobileHostsTabState();
}

class _MobileHostsTabState extends ConsumerState<_MobileHostsTab> {
  final _search = TextEditingController();
  var _group = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _openHostEditor([Host? host]) {
    unawaited(
      Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => Scaffold(
            body: SafeArea(
              child: HostForm(host: host, group: _group),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _deleteHost(Host host) async {
    final l = AppLocalizations.of(context);
    final hosts = ref.read(hostsProvider.notifier);
    final revision = hosts.revision;
    final ok = await showAppDialog<bool>(
      context: context,
      builder: (context) => AppDialog(
        content: Text(l.deleteHost(host.title)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(l.cancel)),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.pop(context, true),
            child: Text(l.delete),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await hosts.delete(host, expectedRevision: revision);
    } on HostInUse catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.hostInUse(e.references.join(', ')))));
      }
    }
  }

  void _openHostActions(Host host) {
    final l = AppLocalizations.of(context);
    final link = ref.read(linkClientControllerProvider);
    final scheme = Theme.of(context).colorScheme;
    unawaited(
      showModalBottomSheet<void>(
        context: context,
        useSafeArea: true,
        showDragHandle: true,
        builder: (sheetContext) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.terminal_rounded),
                title: Text(l.connect),
                onTap: () {
                  Navigator.pop(sheetContext);
                  widget.onOpenHost(host);
                },
              ),
              ListTile(
                leading: const Icon(Icons.folder_outlined),
                title: Text(l.files),
                onTap: () {
                  Navigator.pop(sheetContext);
                  unawaited(
                    Navigator.of(context).push<void>(
                      MaterialPageRoute<void>(
                        builder: (routeContext) => MobileFilesPage(
                          host: host,
                          onAskAiry: (prompt) {
                            Navigator.of(routeContext).pop();
                            widget.onAskAiry(prompt);
                          },
                        ),
                      ),
                    ),
                  );
                },
              ),
              ListTile(
                leading: const Icon(Icons.monitor_heart_outlined),
                title: Text(l.monitor),
                onTap: () {
                  Navigator.pop(sheetContext);
                  unawaited(
                    showModalBottomSheet<void>(
                      context: context,
                      isScrollControlled: true,
                      useSafeArea: true,
                      showDragHandle: true,
                      builder: (_) =>
                          FractionallySizedBox(heightFactor: 0.72, child: MonitorPanel(host: host, active: true)),
                    ),
                  );
                },
              ),
              if (link.connected && !host.transient)
                ListTile(
                  leading: const Icon(Icons.desktop_windows_outlined),
                  title: Text(l.mobileHandoffToDesktop),
                  onTap: () async {
                    Navigator.pop(sheetContext);
                    final ok = await link.handoffHostToDesktop(host.id.value);
                    if (ok && mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.mobileHandoffSent)));
                    }
                  },
                ),
              ListTile(
                leading: Icon(host.pinned ? Icons.push_pin_outlined : Icons.push_pin_rounded),
                title: Text(host.pinned ? l.unpin : l.pin),
                onTap: () {
                  Navigator.pop(sheetContext);
                  unawaited(ref.read(hostsProvider.notifier).setPinned(host, !host.pinned));
                },
              ),
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: Text(l.edit),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _openHostEditor(host);
                },
              ),
              ListTile(
                leading: Icon(Icons.delete_outline, color: scheme.error),
                title: Text(l.delete, style: TextStyle(color: scheme.error)),
                onTap: () {
                  Navigator.pop(sheetContext);
                  unawaited(_deleteHost(host));
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final palette = BrandPalette.of(context);
    final scheme = Theme.of(context).colorScheme;
    final allHosts = ref.watch(hostsProvider).where((h) => !h.transient).toList();
    final linkClient = ref.watch(linkClientControllerProvider);

    final groups = <String>{
      for (final h in allHosts)
        if (h.group.isNotEmpty) h.group,
    }.toList()..sort();
    if (_group.isNotEmpty && !groups.contains(_group)) _group = '';

    final q = _search.text.trim().toLowerCase();
    final filtered =
        allHosts.where((h) {
          if (_group.isNotEmpty && h.group != _group) return false;
          if (q.isEmpty) return true;
          return h.title.toLowerCase().contains(q) ||
              h.target.toLowerCase().contains(q) ||
              h.group.toLowerCase().contains(q) ||
              h.tags.any((t) => t.toLowerCase().contains(q));
        }).toList()..sort((a, b) {
          if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
          return a.title.toLowerCase().compareTo(b.title.toLowerCase());
        });

    final quickHosts = q.isNotEmpty
        ? const <Host>[]
        : (allHosts.where((h) => h.pinned || h.lastUsed != null).toList()..sort((a, b) {
                if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
                final al = a.lastUsed, bl = b.lastUsed;
                if (al != null && bl != null) return bl.compareTo(al);
                return al != null ? -1 : 1;
              }))
              .take(6)
              .toList();

    return Column(
      key: const ValueKey('mobile-hosts-tab'),
      children: [
        _MobileTabHeader(
          leading: const BrandMark(size: 26),
          title: l.hosts,
          trailing: IconButton(
            key: const ValueKey('mobile-add-host-button'),
            tooltip: l.newHost,
            icon: Icon(Icons.add_rounded, size: 24, color: palette.primary),
            onPressed: () => _openHostEditor(),
          ),
        ),
        Expanded(
          child: ListenableBuilder(
            listenable: linkClient,
            builder: (context, _) {
              final desktopSessions = linkClient.connected ? linkClient.desktopSessions : const <LinkSessionSummary>[];
              if (allHosts.isEmpty && desktopSessions.isEmpty) {
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Space.lg),
                  child: BrandEmptyState(
                    active: widget.active,
                    child: Wrap(
                      spacing: Space.sm,
                      runSpacing: Space.sm,
                      alignment: WrapAlignment.center,
                      children: [
                        FilledButton.icon(
                          style: FilledButton.styleFrom(minimumSize: const Size(0, 46)),
                          onPressed: () => _openHostEditor(),
                          icon: const Icon(Icons.add_rounded, size: 18),
                          label: Text(l.newHost),
                        ),
                        OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(minimumSize: const Size(0, 46)),
                          onPressed: widget.onGoLink,
                          icon: const Icon(Icons.phonelink_outlined, size: 18),
                          label: Text(l.linkTitle),
                        ),
                      ],
                    ),
                  ),
                );
              }

              return ListView(
                padding: const EdgeInsets.fromLTRB(Space.lg, Space.md, Space.lg, Space.xl),
                children: [
                  if (allHosts.isNotEmpty) ...[
                    TextField(
                      key: const ValueKey('mobile-hosts-search'),
                      controller: _search,
                      onChanged: (_) => setState(() {}),
                      decoration: InputDecoration(
                        prefixIcon: const Icon(Icons.search_rounded, size: 20),
                        suffixIcon: q.isEmpty
                            ? null
                            : IconButton(
                                icon: const Icon(Icons.close_rounded, size: 18),
                                onPressed: () {
                                  _search.clear();
                                  setState(() {});
                                },
                              ),
                        hintText: l.searchHint,
                        filled: true,
                        fillColor: palette.surface,
                        contentPadding: const EdgeInsets.symmetric(horizontal: Space.md, vertical: 10),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                    const SizedBox(height: Space.md),
                  ],
                  if (desktopSessions.isNotEmpty) ...[
                    Row(
                      children: [
                        Icon(Icons.desktop_windows_outlined, size: 16, color: palette.primary),
                        const SizedBox(width: Space.xs),
                        Text(l.linkDesktopTerminals, style: Theme.of(context).textTheme.labelLarge),
                      ],
                    ),
                    const SizedBox(height: Space.sm),
                    SizedBox(
                      height: 54,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: desktopSessions.length,
                        separatorBuilder: (_, _) => const SizedBox(width: Space.sm),
                        itemBuilder: (context, index) {
                          final s = desktopSessions[index];
                          return Material(
                            color: palette.surface,
                            borderRadius: BorderRadius.circular(14),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(14),
                              onTap: () {
                                linkClient.openMirroredSessionInWorkspace(s);
                                widget.onOpenedTerminal();
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: Space.md),
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(14),
                                  border: Border.all(color: palette.primary.withValues(alpha: .35)),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.terminal_rounded, size: 16, color: palette.primary),
                                    const SizedBox(width: Space.xs),
                                    ConstrainedBox(
                                      constraints: const BoxConstraints(maxWidth: 160),
                                      child: Text(
                                        s.title,
                                        style: Theme.of(context).textTheme.labelLarge,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: Space.md),
                  ],
                  if (quickHosts.isNotEmpty && allHosts.length > 3) ...[
                    Text(l.mobileQuickConnect, style: Theme.of(context).textTheme.labelLarge),
                    const SizedBox(height: Space.sm),
                    SizedBox(
                      height: 44,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: quickHosts.length,
                        separatorBuilder: (_, _) => const SizedBox(width: Space.sm),
                        itemBuilder: (context, index) {
                          final host = quickHosts[index];
                          return ActionChip(
                            avatar: Icon(
                              host.pinned ? Icons.push_pin_rounded : Icons.bolt_rounded,
                              size: 15,
                              color: palette.primary,
                            ),
                            label: Text(host.title),
                            onPressed: () => widget.onOpenHost(host),
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: Space.md),
                  ],
                  if (groups.isNotEmpty) ...[
                    SizedBox(
                      height: 38,
                      child: ListView(
                        scrollDirection: Axis.horizontal,
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(right: Space.xs),
                            child: ChoiceChip(
                              label: Text(l.mobileAllGroups),
                              selected: _group.isEmpty,
                              onSelected: (_) => setState(() => _group = ''),
                            ),
                          ),
                          for (final g in groups)
                            Padding(
                              padding: const EdgeInsets.only(right: Space.xs),
                              child: ChoiceChip(
                                label: Text(g),
                                selected: _group == g,
                                onSelected: (_) => setState(() => _group = g),
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: Space.md),
                  ],
                  if (filtered.isEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: Space.xl),
                      child: Center(
                        child: Text(
                          l.noMatches,
                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ),
                    )
                  else
                    for (final host in filtered)
                      Padding(
                        padding: const EdgeInsets.only(bottom: Space.sm),
                        child: Material(
                          color: palette.surface.withValues(alpha: .9),
                          borderRadius: BorderRadius.circular(16),
                          child: InkWell(
                            key: ValueKey('mobile-host-${host.id.value}'),
                            borderRadius: BorderRadius.circular(16),
                            onTap: () => widget.onOpenHost(host),
                            onLongPress: () => _openHostActions(host),
                            child: Container(
                              padding: const EdgeInsets.fromLTRB(Space.md, Space.sm, Space.xs, Space.sm),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(color: scheme.outlineVariant.withValues(alpha: .35)),
                              ),
                              child: Row(
                                children: [
                                  Container(
                                    width: 40,
                                    height: 40,
                                    decoration: BoxDecoration(
                                      color: palette.primary.withValues(alpha: .12),
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    alignment: Alignment.center,
                                    child: Icon(Icons.dns_outlined, size: 20, color: palette.primary),
                                  ),
                                  const SizedBox(width: Space.md),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            Flexible(
                                              child: Text(
                                                host.title,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: Theme.of(context).textTheme.titleSmall,
                                              ),
                                            ),
                                            if (host.pinned) ...[
                                              const SizedBox(width: 4),
                                              Icon(Icons.push_pin_rounded, size: 13, color: palette.primary),
                                            ],
                                          ],
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          host.target,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: mono(context, Theme.of(context).textTheme.bodySmall),
                                        ),
                                      ],
                                    ),
                                  ),
                                  IconButton(
                                    tooltip: l.more,
                                    icon: Icon(Icons.more_vert_rounded, size: 20, color: scheme.onSurfaceVariant),
                                    onPressed: () => _openHostActions(host),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

/// Tab 1: Mobile-first Airy AI Ops hub with quick ops intent chips + desktop AI config sync shortcut.
class _MobileAiryTab extends ConsumerWidget {
  const _MobileAiryTab({required this.onGoLink});

  final VoidCallback onGoLink;

  void _seedPrompt(WidgetRef ref, String prompt) {
    ref.read(agentComposerProvider.notifier).setGoal(prompt);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final palette = BrandPalette.of(context);
    final aiConfig = ref.watch(aiConfigurationProvider);
    final linkClient = ref.watch(linkClientControllerProvider);

    final quickOps = [
      (label: l.mobileAiQuickSystem, icon: Icons.speed_rounded),
      (label: l.mobileAiQuickDisk, icon: Icons.storage_rounded),
      (label: l.mobileAiQuickLogs, icon: Icons.article_outlined),
      (label: l.mobileAiQuickPorts, icon: Icons.lan_outlined),
    ];

    return Column(
      key: const ValueKey('mobile-airy-tab'),
      children: [
        _MobileTabHeader(
          leading: Icon(Icons.auto_awesome_rounded, size: 22, color: palette.primary),
          title: l.mobileTabAiry,
          trailing: ListenableBuilder(
            listenable: linkClient,
            builder: (context, _) {
              if (aiConfig.profile != null || !linkClient.connected) return const SizedBox.shrink();
              return TextButton.icon(
                onPressed: () => unawaited(linkClient.pullConfigSync()),
                icon: const Icon(Icons.sync_rounded, size: 16),
                label: Text(l.mobileSyncAiFromDesktop),
              );
            },
          ),
        ),
        SizedBox(
          height: 46,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: Space.lg, vertical: Space.xs),
            itemCount: quickOps.length,
            separatorBuilder: (_, _) => const SizedBox(width: Space.xs),
            itemBuilder: (context, index) {
              final op = quickOps[index];
              return ActionChip(
                avatar: Icon(op.icon, size: 15, color: palette.primary),
                label: Text(op.label),
                onPressed: () => _seedPrompt(ref, op.label),
              );
            },
          ),
        ),
        const Expanded(
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: Space.xs),
            child: AgentPanel(),
          ),
        ),
      ],
    );
  }
}

/// Tab 3: Native mobile grouped "Me" settings & tools page (replaces desktop SettingsDialog on phone).
class _MobileMeTab extends ConsumerWidget {
  const _MobileMeTab();

  void _pushTool(
    BuildContext context,
    String title,
    Widget child, {
    EdgeInsets padding = const EdgeInsets.symmetric(horizontal: Space.md),
  }) {
    unawaited(
      Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => Scaffold(
            appBar: AppBar(title: Text(title)),
            body: SafeArea(
              child: Padding(padding: padding, child: child),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final palette = BrandPalette.of(context);
    final scheme = Theme.of(context).colorScheme;
    final brightness = Theme.of(context).brightness;
    final settings = ref.watch(settingsProvider);
    final writer = ref.read(settingsProvider.notifier);

    final fontSize = settings.fontSize;
    final haptics = settings.get(SettingKeys.mobileHaptics);
    final keepAwake = settings.get(SettingKeys.mobileKeepScreenOn);
    final keepAlive = settings.get(SettingKeys.mobileKeepAlive);
    final biometricLock = settings.get(SettingKeys.mobileBiometricLock);

    return Column(
      key: const ValueKey('mobile-me-tab'),
      children: [
        _MobileTabHeader(title: l.mobileTabMe),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(Space.lg, Space.md, Space.lg, Space.xl),
            children: [
              // Brand + Accent + ThemeMode card
              _SettingsGroupCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        const BrandMark(size: 36),
                        const SizedBox(width: Space.md),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Sshairy', style: Theme.of(context).textTheme.titleMedium),
                              Text('v$appVersion', style: mono(context, Theme.of(context).textTheme.bodySmall)),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: Space.md),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        for (final accent in Accent.values)
                          GestureDetector(
                            key: ValueKey('mobile-accent-${accent.name}'),
                            onTap: () => unawaited(writer.set(SettingKeys.accent, accent)),
                            child: Container(
                              width: 34,
                              height: 34,
                              decoration: BoxDecoration(
                                color: accent.of(brightness),
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: settings.accent == accent ? scheme.onSurface : Colors.transparent,
                                  width: 2.5,
                                ),
                              ),
                              child: settings.accent == accent
                                  ? const Icon(Icons.check_rounded, size: 16, color: Colors.white)
                                  : null,
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: Space.md),
                    SegmentedButton<ThemeMode>(
                      showSelectedIcon: false,
                      segments: [
                        ButtonSegment(value: ThemeMode.system, label: Text(l.themeSystem)),
                        ButtonSegment(value: ThemeMode.light, label: Text(l.themeLight)),
                        ButtonSegment(value: ThemeMode.dark, label: Text(l.themeDark)),
                      ],
                      selected: {settings.themeMode},
                      onSelectionChanged: (v) => unawaited(writer.set(SettingKeys.themeMode, v.first)),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: Space.md),
              // Custom background images (app + terminal)
              _SettingsGroupCard(
                key: const ValueKey('mobile-background-settings'),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(l.appBackgroundImage, style: Theme.of(context).textTheme.labelLarge),
                    const SizedBox(height: Space.sm),
                    const BackgroundImageControls(slot: BackgroundSlot.app),
                    const Divider(height: Space.lg),
                    Text(l.terminalBackgroundImage, style: Theme.of(context).textTheme.labelLarge),
                    const SizedBox(height: Space.sm),
                    const BackgroundImageControls(slot: BackgroundSlot.terminal),
                  ],
                ),
              ),
              const SizedBox(height: Space.md),
              // Workspace tools
              _SettingsGroupCard(
                padding: EdgeInsets.zero,
                child: Column(
                  children: [
                    ListTile(
                      leading: Icon(Icons.auto_awesome_outlined, color: palette.primary),
                      title: Text(l.aiConfigTitle),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => _pushTool(
                        context,
                        l.aiConfigTitle,
                        const SingleChildScrollView(padding: EdgeInsets.all(Space.lg), child: AiSettings()),
                        padding: EdgeInsets.zero,
                      ),
                    ),
                    const Divider(height: 1),
                    ListTile(
                      leading: const Icon(Icons.code_rounded),
                      title: Text(l.snippets),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => _pushTool(context, l.snippets, const SnippetsPanel()),
                    ),
                    const Divider(height: 1),
                    ListTile(
                      leading: const Icon(Icons.key_outlined),
                      title: Text(l.keys),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () =>
                          _pushTool(context, l.keys, const KeysPanel(), padding: const EdgeInsets.all(Space.md)),
                    ),
                    const Divider(height: 1),
                    ListTile(
                      leading: const Icon(Icons.verified_user_outlined),
                      title: Text(l.trustedKeys),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => _pushTool(
                        context,
                        l.trustedKeys,
                        SingleChildScrollView(
                          padding: const EdgeInsets.all(Space.lg),
                          child: trustSettingsSection.build(context),
                        ),
                        padding: EdgeInsets.zero,
                      ),
                    ),
                    const Divider(height: 1),
                    ListTile(
                      leading: const Icon(Icons.swap_horiz_rounded),
                      title: Text(l.portForwarding),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => _pushTool(context, l.portForwarding, const ForwardingPanel()),
                    ),
                    const Divider(height: 1),
                    ListTile(
                      leading: const Icon(Icons.alt_route_rounded),
                      title: Text(l.proxies),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => _pushTool(context, l.proxies, const ProxyPanel()),
                    ),
                    const Divider(height: 1),
                    ListTile(
                      leading: const Icon(Icons.receipt_long_outlined),
                      title: Text(l.logs),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => _pushTool(context, l.logs, const LogsPanel()),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: Space.md),
              // Terminal & touch
              Padding(
                padding: const EdgeInsets.only(left: Space.xs, bottom: Space.xs),
                child: Text(l.mobileTerminalSection, style: Theme.of(context).textTheme.labelLarge),
              ),
              _SettingsGroupCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Text(l.fontSize, style: Theme.of(context).textTheme.bodyMedium),
                        const Spacer(),
                        Text('${fontSize.round()} pt', style: mono(context, Theme.of(context).textTheme.labelMedium)),
                      ],
                    ),
                    Slider(
                      min: 8,
                      max: 32,
                      divisions: 24,
                      value: fontSize.clamp(8.0, 32.0),
                      onChanged: (v) => unawaited(writer.set(SettingKeys.fontSize, v.roundToDouble())),
                    ),
                    const SizedBox(height: Space.xs),
                    SegmentedButton<CursorShape>(
                      showSelectedIcon: false,
                      segments: [
                        ButtonSegment(value: CursorShape.block, label: Text(l.cursorBlock)),
                        ButtonSegment(value: CursorShape.underline, label: Text(l.cursorUnderline)),
                        ButtonSegment(value: CursorShape.bar, label: Text(l.cursorBar)),
                      ],
                      selected: {settings.get(SettingKeys.cursorShape)},
                      onSelectionChanged: (v) => unawaited(writer.set(SettingKeys.cursorShape, v.first)),
                    ),
                    SwitchListTile.adaptive(
                      contentPadding: EdgeInsets.zero,
                      title: Text(l.mobileHaptics),
                      value: haptics,
                      onChanged: (v) => unawaited(writer.set(SettingKeys.mobileHaptics, v)),
                    ),
                    SwitchListTile.adaptive(
                      contentPadding: EdgeInsets.zero,
                      title: Text(l.mobileKeepScreenOn),
                      value: keepAwake,
                      onChanged: (v) => unawaited(writer.set(SettingKeys.mobileKeepScreenOn, v)),
                    ),
                    SwitchListTile.adaptive(
                      contentPadding: EdgeInsets.zero,
                      title: Text(l.completionTranslation),
                      value: settings.get(SettingKeys.completionTranslation),
                      onChanged: (v) => unawaited(writer.set(SettingKeys.completionTranslation, v)),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: Space.md),
              // Security & background
              Padding(
                padding: const EdgeInsets.only(left: Space.xs, bottom: Space.xs),
                child: Text(l.mobileSecuritySection, style: Theme.of(context).textTheme.labelLarge),
              ),
              _SettingsGroupCard(
                child: Column(
                  children: [
                    SwitchListTile.adaptive(
                      contentPadding: EdgeInsets.zero,
                      title: Text(l.mobileKeepAlive),
                      value: keepAlive,
                      onChanged: (v) async {
                        if (v) await MobilePlatform.requestNotificationPermission();
                        await writer.set(SettingKeys.mobileKeepAlive, v);
                      },
                    ),
                    SwitchListTile.adaptive(
                      contentPadding: EdgeInsets.zero,
                      title: Text(l.mobileBiometricLock),
                      value: biometricLock,
                      onChanged: (v) async {
                        if (v && isMobilePlatform) {
                          final can = await MobilePlatform.canAuthenticateBiometric();
                          if (!can) return;
                          final ok = await MobilePlatform.authenticateBiometric(title: l.mobileUnlockPrompt);
                          if (!ok) return;
                        }
                        await writer.set(SettingKeys.mobileBiometricLock, v);
                      },
                    ),
                  ],
                ),
              ),
              const SizedBox(height: Space.md),
              // Language
              _SettingsGroupCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(l.language, style: Theme.of(context).textTheme.bodyMedium),
                    const SizedBox(height: Space.sm),
                    SegmentedButton<String?>(
                      showSelectedIcon: false,
                      segments: [
                        ButtonSegment(value: null, label: Text(l.themeSystem)),
                        ButtonSegment(value: 'zh', label: Text(l.langZh)),
                        ButtonSegment(value: 'en', label: Text(l.langEn)),
                      ],
                      selected: {settings.locale},
                      onSelectionChanged: (v) => unawaited(writer.set(SettingKeys.locale, v.first)),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _SettingsGroupCard extends StatelessWidget {
  const _SettingsGroupCard({super.key, required this.child, this.padding = const EdgeInsets.all(Space.md)});

  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final palette = BrandPalette.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: palette.surface.withValues(alpha: .88),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: .35)),
      ),
      child: Padding(padding: padding, child: child),
    );
  }
}

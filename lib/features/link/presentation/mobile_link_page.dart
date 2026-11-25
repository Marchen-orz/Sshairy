import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../design/badges.dart';
import '../../../design/brand.dart';
import '../../../design/controls.dart';
import '../../../design/dialog.dart';
import '../../../design/theme.dart';
import '../../../l10n/app_localizations.dart';
import '../../../platform/device_form_factor.dart';
import '../../../platform/mobile_platform.dart';
import '../adapters/qr_adapter.dart';
import '../application/link_service.dart';
import '../domain/protocol.dart';

/// Mobile "Link" hub for pairing with Desktop, live terminal mirroring, desktop-proxied SSH,
/// config/credential sync, and remote Agent/MCP approvals (docs/MOBILE.md §3-4).
class MobileLinkPage extends ConsumerStatefulWidget {
  const MobileLinkPage({super.key, this.active = true, this.onOpenedTerminal, this.onOpenFiles});

  /// Whether this tab is currently visible; defers auto LAN discovery until opened.
  final bool active;

  /// Invoked after opening a mirrored or desktop-proxied terminal so the shell can switch to the terminal tab.
  final VoidCallback? onOpenedTerminal;

  /// Opens the file page on this phone and the computer.
  final VoidCallback? onOpenFiles;

  @override
  ConsumerState<MobileLinkPage> createState() => _MobileLinkPageState();
}

class _MobileLinkPageState extends ConsumerState<MobileLinkPage> {
  final _hostController = TextEditingController();
  final _portController = TextEditingController(text: '$linkDefaultPort');
  final _codeController = TextEditingController();
  final _hostSearchController = TextEditingController();
  var _syncing = false;
  String? _notice;
  String? _connectingSessionId;
  String? _connectingHostId;
  String? _connectingDiscoveredId;
  String? _connectingLocalShellId;
  var _autoDiscovered = false;

  @override
  void initState() {
    super.initState();
    if (widget.active) _scheduleAutoDiscover();
  }

  @override
  void didUpdateWidget(covariant MobileLinkPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) _scheduleAutoDiscover();
  }

  void _scheduleAutoDiscover() {
    if (_autoDiscovered) return;
    _autoDiscovered = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !widget.active) return;
      final client = ref.read(linkClientControllerProvider);
      if (!client.connected &&
          client.status != LinkConnectionStatus.connecting &&
          client.discoveredDesktops.isEmpty &&
          !client.discovering) {
        unawaited(client.discoverLan());
      }
    });
  }

  @override
  void dispose() {
    _hostController.dispose();
    _portController.dispose();
    _codeController.dispose();
    _hostSearchController.dispose();
    super.dispose();
  }

  void _showNotice(String text) {
    if (!mounted) return;
    setState(() => _notice = text);
    Future<void>.delayed(const Duration(seconds: 4), () {
      if (mounted && _notice == text) setState(() => _notice = null);
    });
  }

  Future<void> _openDesktopTerminal(LinkClientController client, LinkSessionSummary session) async {
    final l = AppLocalizations.of(context);
    if (session.status == 'connected') {
      client.openMirroredSessionInWorkspace(session);
      widget.onOpenedTerminal?.call();
      return;
    }
    setState(() => _connectingSessionId = session.sessionId);
    try {
      final ok = await client.connectDesktopSession(session.sessionId);
      if (!mounted) return;
      if (!ok) {
        _showNotice(l.linkDesktopOpenFailed);
        return;
      }
      client.openMirroredSessionInWorkspace(session);
      widget.onOpenedTerminal?.call();
    } finally {
      if (mounted) setState(() => _connectingSessionId = null);
    }
  }

  Future<void> _mirrorHostFromDesktop(LinkClientController client, LinkHostSummary host) async {
    final l = AppLocalizations.of(context);
    setState(() => _connectingHostId = host.hostId);
    try {
      final summary = await client.openHostOnDesktopForMirror(host.hostId);
      if (!mounted) return;
      if (summary == null) {
        _showNotice(l.linkDesktopOpenFailed);
        return;
      }
      client.openMirroredSessionInWorkspace(summary);
      widget.onOpenedTerminal?.call();
    } finally {
      if (mounted) setState(() => _connectingHostId = null);
    }
  }

  Future<void> _mirrorLocalFromDesktop(LinkClientController client, LinkLocalShellSummary shell) async {
    final l = AppLocalizations.of(context);
    setState(() => _connectingLocalShellId = shell.shellId);
    try {
      final summary = await client.openLocalOnDesktopForMirror(shell.shellId);
      if (!mounted) return;
      if (summary == null) {
        _showNotice(l.linkDesktopOpenFailed);
        return;
      }
      client.openMirroredSessionInWorkspace(summary);
      widget.onOpenedTerminal?.call();
    } finally {
      if (mounted) setState(() => _connectingLocalShellId = null);
    }
  }

  void _showLocalShellActions(LinkClientController client, LinkLocalShellSummary shell) {
    final l = AppLocalizations.of(context);
    unawaited(
      showModalBottomSheet<void>(
        context: context,
        useSafeArea: true,
        showDragHandle: true,
        builder: (sheet) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                key: ValueKey('link-mirror-local-${shell.shellId}'),
                leading: const Icon(Icons.desktop_windows_outlined),
                title: Text(l.linkOpenOnDesktopMirrored),
                onTap: () {
                  Navigator.of(sheet).pop();
                  unawaited(_mirrorLocalFromDesktop(client, shell));
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showHostActions(LinkClientController client, LinkHostSummary host) {
    final l = AppLocalizations.of(context);
    unawaited(
      showModalBottomSheet<void>(
        context: context,
        useSafeArea: true,
        showDragHandle: true,
        builder: (sheet) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                key: ValueKey('link-mirror-host-${host.hostId}'),
                leading: const Icon(Icons.desktop_windows_outlined),
                title: Text(l.linkOpenOnDesktopMirrored),
                onTap: () {
                  Navigator.of(sheet).pop();
                  unawaited(_mirrorHostFromDesktop(client, host));
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _errorText(AppLocalizations l, LinkErrorKind kind) => switch (kind) {
    LinkErrorKind.invalidPairingCode => l.linkErrorCode,
    LinkErrorKind.pairingExpired => l.linkErrorExpired,
    LinkErrorKind.peerRevoked => l.linkErrorRevoked,
    LinkErrorKind.authFailed || LinkErrorKind.permissionDenied => l.linkErrorAuth,
    _ => l.linkErrorNetwork,
  };

  Future<void> _pasteUri() async {
    final clip = await Clipboard.getData(Clipboard.kTextPlain);
    final raw = clip?.text?.trim() ?? '';
    if (raw.isEmpty || !mounted) return;
    final parsed = LinkPairingInfo.parseUri(raw);
    if (parsed != null) {
      _hostController.text = parsed.host;
      _portController.text = '${parsed.port}';
      _codeController.text = parsed.code;
      await ref.read(linkClientControllerProvider).pairFromUri(raw);
      return;
    }
    // Also allow pasting plain "host:port"
    final sep = raw.lastIndexOf(':');
    if (sep > 0) {
      final p = int.tryParse(raw.substring(sep + 1));
      if (p != null && p > 0 && p <= 65535) {
        _hostController.text = raw.substring(0, sep);
        _portController.text = '$p';
      }
    }
  }

  Future<void> _pairManual() async {
    final host = _hostController.text.trim();
    final port = int.tryParse(_portController.text.trim()) ?? linkDefaultPort;
    final code = _codeController.text.replaceAll(RegExp(r'\s+'), '');
    if (host.isEmpty || code.length < 6) return;
    await ref.read(linkClientControllerProvider).pair(host: host, port: port, pairingCode: code);
  }

  Future<void> _openDiscoveredDesktop(LinkClientController client, DiscoveredDesktop desktop) async {
    final saved = client.savedDesktops.where((p) => p.deviceId == desktop.deviceId).firstOrNull;
    if (saved != null) {
      setState(() => _connectingDiscoveredId = desktop.deviceId);
      try {
        await client.connectToPeer(saved, hostOverride: desktop.address, portOverride: desktop.port);
      } finally {
        if (mounted) setState(() => _connectingDiscoveredId = null);
      }
      return;
    }

    _hostController.text = desktop.address;
    _portController.text = '${desktop.port}';
    final code = await showAppDialog<String>(
      context: context,
      builder: (_) => _DiscoveredPairDialog(desktop: desktop),
    );
    if (code == null || code.length < 6 || !mounted) return;
    _codeController.text = code;
    setState(() => _connectingDiscoveredId = desktop.deviceId);
    try {
      await client.pair(host: desktop.address, port: desktop.port, pairingCode: code);
    } finally {
      if (mounted) setState(() => _connectingDiscoveredId = null);
    }
  }

  Future<void> _scanQr() async {
    final l = AppLocalizations.of(context);
    final raw = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(
        builder: (_) => LinkQrScannerPage(title: l.mobileScanQr, hint: l.mobileScanQrHint),
      ),
    );
    if (raw == null || raw.isEmpty || !mounted) return;
    final parsed = LinkPairingInfo.parseUri(raw);
    if (parsed != null) {
      _hostController.text = parsed.host;
      _portController.text = '${parsed.port}';
      _codeController.text = parsed.code;
    }
    await ref.read(linkClientControllerProvider).pairFromUri(raw);
  }

  Future<void> _pushClipboard() async {
    final clip = await Clipboard.getData(Clipboard.kTextPlain);
    final text = clip?.text ?? '';
    if (text.isEmpty || !mounted) return;
    final ok = await ref.read(linkClientControllerProvider).pushClipboardToDesktop(text);
    if (!mounted) return;
    if (ok) _showNotice(AppLocalizations.of(context).mobileClipboardSent);
  }

  /// Sharing needs Android's all-files access; refused, the chip stays off. A reconnect meanwhile drops the answer.
  Future<void> _sharePhoneFiles(LinkClientController client, bool on) async {
    final binding = client.filesBinding;
    if (binding == null) return;
    if (on && !await MobilePlatform.requestAllFilesAccess()) return;
    await client.sharePhoneFiles(on, binding);
  }

  Future<void> _syncNow() async {
    if (_syncing) return;
    setState(() => _syncing = true);
    try {
      final summary = await ref.read(linkClientControllerProvider).pullConfigSync(includePasswords: true);
      if (!mounted) return;
      final l = AppLocalizations.of(context);
      final base = l.linkSyncDone(summary.hostsSynced, summary.snippetsSynced, summary.knownHostsAdded);
      _showNotice(summary.aiSynced ? '$base ${l.mobileSyncAiIncluded}' : base);
    } on LinkException catch (e) {
      if (!mounted) return;
      _showNotice(_errorText(AppLocalizations.of(context), e.kind));
    } on Object {
      if (!mounted) return;
      _showNotice(AppLocalizations.of(context).linkErrorNetwork);
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  Future<void> _acceptCredentials() async {
    final count = await ref.read(linkClientControllerProvider).acceptPendingCredentials();
    if (!mounted) return;
    _showNotice(AppLocalizations.of(context).linkCredentialImported(count));
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final client = ref.watch(linkClientControllerProvider);

    return ListenableBuilder(
      listenable: client,
      builder: (context, _) {
        if (client.connected) {
          return _buildConnected(context, l, scheme, client);
        }
        return _buildDisconnected(context, l, scheme, client);
      },
    );
  }

  Widget _buildDisconnected(BuildContext context, AppLocalizations l, ColorScheme scheme, LinkClientController client) {
    final theme = Theme.of(context);
    final connecting = client.status == LinkConnectionStatus.connecting;
    final nothingFound = client.savedDesktops.isEmpty && client.discoveredDesktops.isEmpty;
    final heroFill = toneFill(context, scheme.primary, BrandPalette.of(context).surface, strength: .7);
    final pairingActionStyle = OutlinedButton.styleFrom(
      backgroundColor: scheme.surface,
      minimumSize: const Size(0, MobileSize.touchTarget),
      side: BorderSide(color: scheme.outlineVariant),
      padding: const EdgeInsets.symmetric(horizontal: Space.sm, vertical: Space.xs),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.card)),
    );
    final addressStyle = mono(context, theme.textTheme.bodySmall);
    final discoveryWidgets = <Widget>[
      _SurfaceCard(
        color: heroFill,
        border: scheme.primary.withValues(alpha: .22),
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (nothingFound) ...[
              const Center(child: BrandIllustration(pose: BrandPose.security, size: 112)),
              const SizedBox(height: Space.md),
            ],
            if (isMobilePlatform) ...[
              FilledButton.icon(
                key: const ValueKey('link-scan-qr-button'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(MobileSize.touchTarget),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.card)),
                ),
                onPressed: connecting ? null : _scanQr,
                icon: const Icon(Icons.qr_code_scanner_rounded, size: 20),
                label: Text(l.mobileScanQr),
              ),
              const SizedBox(height: Space.sm),
            ],
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      key: const ValueKey('link-scan-button'),
                      style: pairingActionStyle,
                      onPressed: client.discovering ? null : () => unawaited(client.discoverLan()),
                      icon: client.discovering
                          ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.radar_rounded, size: 18),
                      label: Text(client.discovering ? l.linkScanning : l.linkScanLan, textAlign: TextAlign.center),
                    ),
                  ),
                  const SizedBox(width: Space.sm),
                  Expanded(
                    child: OutlinedButton.icon(
                      key: const ValueKey('link-paste-uri-button'),
                      style: pairingActionStyle,
                      onPressed: connecting ? null : _pasteUri,
                      icon: const Icon(Icons.content_paste_rounded, size: 18),
                      label: Text(l.linkPasteUri, textAlign: TextAlign.center),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      if (client.lastError != null)
        Container(
          margin: const EdgeInsets.only(bottom: Space.sm),
          padding: const EdgeInsets.symmetric(horizontal: Space.md, vertical: Space.sm + 2),
          decoration: BoxDecoration(
            color: toneFill(context, scheme.error, scheme.surface),
            borderRadius: BorderRadius.circular(Radii.card),
          ),
          child: Row(
            children: [
              Icon(Icons.error_outline_rounded, size: 18, color: scheme.error),
              const SizedBox(width: Space.sm),
              Expanded(
                child: Text(
                  _errorText(l, client.lastError!),
                  style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
                ),
              ),
            ],
          ),
        ),
      if (client.discoveredDesktops.isNotEmpty) ...[
        const SizedBox(height: Space.md),
        _SectionTitle(l.linkDiscoveredDesktops, count: client.discoveredDesktops.length),
        _Group(
          children: [
            for (final d in client.discoveredDesktops)
              ListTile(
                key: ValueKey('link-discovered-${d.deviceId}'),
                leading: AppIconBadge(icon: Icons.desktop_windows_rounded, tone: scheme.primary),
                title: Text(d.name, overflow: TextOverflow.ellipsis),
                subtitle: Text('${d.address}:${d.port}', style: addressStyle),
                trailing: _connectingDiscoveredId == d.deviceId
                    ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : Icon(Icons.chevron_right_rounded, color: scheme.onSurfaceVariant),
                onTap: connecting ? null : () => unawaited(_openDiscoveredDesktop(client, d)),
              ),
          ],
        ),
      ],
      if (client.savedDesktops.isNotEmpty) ...[
        const SizedBox(height: Space.md),
        _SectionTitle(l.linkSavedDesktops, count: client.savedDesktops.length),
        _Group(
          children: [
            for (final peer in client.savedDesktops)
              ListTile(
                leading: const AppIconBadge(icon: Icons.computer_rounded),
                title: Text(peer.name, overflow: TextOverflow.ellipsis),
                subtitle: peer.lastAddress == null
                    ? null
                    : Text('${peer.lastAddress}:${peer.lastPort ?? linkDefaultPort}', style: addressStyle),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextButton(
                      onPressed: connecting ? null : () => unawaited(client.connectToPeer(peer)),
                      child: Text(l.linkReconnect),
                    ),
                    IconButton(
                      tooltip: l.linkRevoke,
                      icon: Icon(Icons.delete_outline_rounded, size: 18, color: scheme.onSurfaceVariant),
                      onPressed: () => unawaited(client.forgetDesktop(peer.deviceId)),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ],
    ];

    final manualConnectWidgets = <Widget>[
      _SectionTitle(l.linkManualConnect),
      _SurfaceCard(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  flex: 3,
                  child: TextField(
                    key: const ValueKey('link-manual-host'),
                    controller: _hostController,
                    decoration: InputDecoration(
                      labelText: l.linkHostOrIp,
                      isDense: true,
                      prefixIcon: const Icon(Icons.lan_outlined, size: 18),
                    ),
                  ),
                ),
                const SizedBox(width: Space.sm),
                Expanded(
                  flex: 1,
                  child: TextField(
                    key: const ValueKey('link-manual-port'),
                    controller: _portController,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(labelText: l.linkPort, isDense: true),
                  ),
                ),
              ],
            ),
            const SizedBox(height: Space.md),
            TextField(
              key: const ValueKey('link-manual-code'),
              controller: _codeController,
              keyboardType: TextInputType.number,
              style: addressStyle.copyWith(fontSize: theme.textTheme.titleMedium?.fontSize, letterSpacing: 3),
              decoration: InputDecoration(
                labelText: l.linkPairingCode,
                isDense: true,
                prefixIcon: const Icon(Icons.pin_outlined, size: 18),
              ),
              onSubmitted: (_) => _pairManual(),
            ),
            const SizedBox(height: Space.lg),
            FilledButton(
              key: const ValueKey('link-pair-submit'),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(MobileSize.touchTarget),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.card)),
              ),
              onPressed: connecting ? null : _pairManual,
              child: connecting
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : Text(l.linkPairNow),
            ),
          ],
        ),
      ),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        final twoColumns = constraints.maxWidth >= MobileSize.twoColumnBreakpoint;
        final inset = MobileSize.contentInset(
          constraints.maxWidth,
          maxWidth: twoColumns ? MobileSize.wideContentMaxWidth : MobileSize.contentMaxWidth,
        );
        return RefreshIndicator(
          onRefresh: client.discoverLan,
          child: ListView(
            key: const ValueKey('mobile-link-disconnected'),
            physics: const AlwaysScrollableScrollPhysics(),
            padding: EdgeInsets.fromLTRB(inset, Space.md, inset, Space.xl),
            children: [
              if (client.reconnecting)
                _SurfaceCard(
                  key: const ValueKey('link-reconnecting-banner'),
                  padding: const EdgeInsets.fromLTRB(Space.md, Space.xs, Space.xs, Space.xs),
                  child: Row(
                    children: [
                      const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                      const SizedBox(width: Space.md),
                      Expanded(
                        child: Text(
                          l.linkReconnecting(client.reconnectingDesktopName ?? ''),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      TextButton(onPressed: client.cancelReconnect, child: Text(l.cancel)),
                    ],
                  ),
                ),
              if (twoColumns)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: discoveryWidgets),
                    ),
                    const SizedBox(width: Space.lg),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: manualConnectWidgets),
                    ),
                  ],
                )
              else ...[
                ...discoveryWidgets,
                const SizedBox(height: Space.md),
                ...manualConnectWidgets,
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _buildConnected(BuildContext context, AppLocalizations l, ColorScheme scheme, LinkClientController client) {
    final theme = Theme.of(context);
    final palette = BrandPalette.of(context);
    final offer = client.pendingCredentialOffer;
    final addressStyle = mono(context, theme.textTheme.bodySmall);
    final muted = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    final heroFill = toneFill(context, scheme.primary, palette.surface, strength: .7);
    final query = _hostSearchController.text.trim().toLowerCase();
    final filteredHosts = query.isEmpty
        ? client.desktopHosts
        : client.desktopHosts
              .where(
                (h) =>
                    h.label.toLowerCase().contains(query) ||
                    h.targetLabel.toLowerCase().contains(query) ||
                    h.group.toLowerCase().contains(query),
              )
              .toList();

    final approvalsAndSessions = <Widget>[
      if (client.pendingApprovals.isNotEmpty) ...[
        _SectionTitle(l.linkPendingApprovals, count: client.pendingApprovals.length, tone: scheme.error),
        for (final item in client.pendingApprovals)
          _SurfaceCard(
            key: ValueKey('link-approval-${item.approvalId}'),
            border: scheme.error.withValues(alpha: .3),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    AppIconBadge(icon: Icons.shield_outlined, tone: scheme.error),
                    const SizedBox(width: Space.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(item.title, style: theme.textTheme.titleSmall),
                          if (item.target.isNotEmpty) Text(item.target, style: addressStyle),
                        ],
                      ),
                    ),
                  ],
                ),
                if (item.command.isNotEmpty) ...[
                  const SizedBox(height: Space.sm),
                  Container(
                    padding: const EdgeInsets.all(Space.sm),
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerLowest,
                      borderRadius: BorderRadius.circular(Radii.control),
                      border: Border.all(color: scheme.outlineVariant.withValues(alpha: .5)),
                    ),
                    child: Text(item.command, style: addressStyle),
                  ),
                ],
                if (item.detail.isNotEmpty) ...[const SizedBox(height: Space.xs), Text(item.detail, style: muted)],
                const SizedBox(height: Space.md),
                if (item.actionable)
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      OutlinedButton(
                        key: ValueKey('link-deny-${item.approvalId}'),
                        onPressed: () => unawaited(client.decideApproval(item.approvalId, false)),
                        child: Text(l.linkDeny),
                      ),
                      const SizedBox(width: Space.sm),
                      FilledButton(
                        key: ValueKey('link-allow-${item.approvalId}'),
                        onPressed: () => unawaited(client.decideApproval(item.approvalId, true)),
                        child: Text(l.linkAllow),
                      ),
                    ],
                  )
                else
                  Text(
                    l.linkDesktopOnlyAction,
                    style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
                  ),
              ],
            ),
          ),
        const SizedBox(height: Space.md),
      ],
      if (client.desktopLocalShells.isNotEmpty) ...[
        _SectionTitle(l.linkDesktopLocalShells, count: client.desktopLocalShells.length),
        _Group(
          children: [
            for (final shell in client.desktopLocalShells)
              ListTile(
                key: ValueKey('link-local-shell-${shell.shellId}'),
                leading: _connectingLocalShellId == shell.shellId
                    ? const _BadgeSpinner()
                    : const AppIconBadge(icon: Icons.terminal_rounded),
                title: Text(shell.name, overflow: TextOverflow.ellipsis),
                trailing: Icon(Icons.chevron_right_rounded, color: scheme.onSurfaceVariant),
                onTap: () {
                  client.openProxiedLocalInWorkspace(shell);
                  widget.onOpenedTerminal?.call();
                },
                onLongPress: () => _showLocalShellActions(client, shell),
              ),
          ],
        ),
        const SizedBox(height: Space.md),
      ],
      _SectionTitle(l.linkDesktopTerminals, count: client.desktopSessions.length),
      if (client.desktopSessions.isEmpty)
        _EmptyNote(icon: Icons.terminal_rounded, text: l.linkNoDesktopTerminals)
      else
        _Group(
          children: [
            for (final s in client.desktopSessions)
              ListTile(
                key: ValueKey('link-mirror-${s.sessionId}'),
                leading: _connectingSessionId == s.sessionId
                    ? const _BadgeSpinner()
                    : AppIconBadge(
                        icon: s.isLocal ? Icons.terminal_rounded : Icons.dns_rounded,
                        tone: s.status == 'connected' ? scheme.primary : null,
                      ),
                title: Text(s.title, overflow: TextOverflow.ellipsis),
                subtitle: Text(s.targetLabel, style: addressStyle, overflow: TextOverflow.ellipsis),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (s.isLocal) ...[AppTag(label: l.linkLocalTag), const SizedBox(width: Space.xs)],
                    AppTag(
                      label: s.status == 'connected' ? l.linkMirrorTag : l.linkSessionPending,
                      tone: s.status == 'connected' ? scheme.primary : null,
                    ),
                  ],
                ),
                onTap: () => unawaited(_openDesktopTerminal(client, s)),
              ),
          ],
        ),
    ];

    final desktopHostsSection = <Widget>[
      _SectionTitle(l.linkDesktopHosts, count: client.desktopHosts.length),
      if (client.desktopHosts.length > 5) ...[
        TextField(
          controller: _hostSearchController,
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.search_rounded, size: 18),
            hintText: l.searchHint,
            isDense: true,
          ),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: Space.sm),
      ],
      if (filteredHosts.isEmpty)
        _EmptyNote(icon: Icons.dns_outlined, text: l.linkNoDesktopHosts)
      else
        _Group(
          children: [
            for (final h in filteredHosts)
              ListTile(
                key: ValueKey('link-proxy-${h.hostId}'),
                leading: _connectingHostId == h.hostId
                    ? const _BadgeSpinner()
                    : const AppIconBadge(icon: Icons.dns_outlined),
                title: Text(h.label.isEmpty ? h.targetLabel : h.label, overflow: TextOverflow.ellipsis),
                subtitle: Text(
                  h.group.isEmpty ? h.targetLabel : '${h.group} · ${h.targetLabel}',
                  style: addressStyle,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: Icon(Icons.chevron_right_rounded, color: scheme.onSurfaceVariant),
                onTap: () {
                  client.openProxiedHostInWorkspace(h);
                  widget.onOpenedTerminal?.call();
                },
                onLongPress: () => _showHostActions(client, h),
              ),
          ],
        ),
    ];

    final shareRow = Material(
      color: scheme.surface,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.card),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: .5)),
      ),
      child: MergeSemantics(
        child: InkWell(
          key: const ValueKey('link-share-files-switch'),
          onTap: () => unawaited(_sharePhoneFiles(client, !client.sharesPhoneFiles)),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: MobileSize.touchTarget),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: Space.md),
              child: Row(
                children: [
                  Icon(Icons.phone_android_rounded, size: 20, color: scheme.onSurfaceVariant),
                  const SizedBox(width: Space.md),
                  Expanded(child: Text(l.linkSharePhoneFiles)),
                  AppSwitch(value: client.sharesPhoneFiles, onChanged: (on) => unawaited(_sharePhoneFiles(client, on))),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    /// Wide layouts lay the shortcuts and the share switch in one row; narrow ones stack the switch below.
    Widget hero(bool wide) {
      final tiles = [
        _ActionTile(
          key: const ValueKey('link-sync-button'),
          icon: Icons.sync_rounded,
          label: l.linkSyncConfig,
          busy: _syncing,
          wide: wide,
          onTap: _syncNow,
        ),
        _ActionTile(
          key: const ValueKey('link-clipboard-button'),
          icon: Icons.content_paste_go_rounded,
          label: l.mobilePushClipboard,
          wide: wide,
          onTap: _pushClipboard,
        ),
        if (client.desktopSharesFiles && widget.onOpenFiles != null)
          _ActionTile(
            key: const ValueKey('link-files-button'),
            icon: Icons.folder_rounded,
            label: l.files,
            wide: wide,
            onTap: widget.onOpenFiles!,
          ),
        if (wide) shareRow,
      ];
      return _SurfaceCard(
        color: heroFill,
        border: scheme.primary.withValues(alpha: .22),
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                AppIconBadge(icon: Icons.desktop_windows_rounded, size: 48, tone: scheme.primary),
                const SizedBox(width: Space.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        client.connectedDesktopName ?? '',
                        style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 3),
                      AppStatusLabel(label: l.linkOnline, color: palette.success),
                    ],
                  ),
                ),
                TextButton(
                  key: const ValueKey('link-disconnect-button'),
                  onPressed: () => unawaited(client.disconnect()),
                  child: Text(l.linkDisconnect),
                ),
              ],
            ),
            const SizedBox(height: Space.lg),
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final (i, tile) in tiles.indexed) ...[
                    if (i > 0) const SizedBox(width: Space.sm),
                    Expanded(child: tile),
                  ],
                ],
              ),
            ),
            if (!wide) ...[const SizedBox(height: Space.sm), shareRow],
          ],
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final twoColumns = constraints.maxWidth >= MobileSize.twoColumnBreakpoint;
        final inset = MobileSize.contentInset(
          constraints.maxWidth,
          maxWidth: twoColumns ? MobileSize.wideContentMaxWidth : MobileSize.contentMaxWidth,
        );
        return RefreshIndicator(
          onRefresh: client.refreshRemoteState,
          child: ListView(
            key: const ValueKey('mobile-link-connected'),
            physics: const AlwaysScrollableScrollPhysics(),
            padding: EdgeInsets.fromLTRB(inset, Space.md, inset, Space.xl),
            children: [
              hero(twoColumns),
              if (_notice != null) _StatusLine(icon: Icons.check_circle_outline_rounded, text: _notice!),
              if (client.passwordSyncStatus != LinkPasswordSyncStatus.idle)
                _StatusLine(
                  key: const ValueKey('link-password-sync-status'),
                  busy: client.passwordSyncStatus == LinkPasswordSyncStatus.awaitingDesktop,
                  icon: client.passwordSyncStatus == LinkPasswordSyncStatus.imported
                      ? Icons.key_rounded
                      : Icons.info_outline_rounded,
                  quiet: client.passwordSyncStatus == LinkPasswordSyncStatus.declined,
                  text: switch (client.passwordSyncStatus) {
                    LinkPasswordSyncStatus.awaitingDesktop => l.linkPasswordSyncWaiting,
                    LinkPasswordSyncStatus.imported => l.linkPasswordSyncImported(client.lastImportedPasswordCount),
                    LinkPasswordSyncStatus.declined => l.linkPasswordSyncDeclined,
                    LinkPasswordSyncStatus.idle => '',
                  },
                ),
              if (offer != null)
                _SurfaceCard(
                  key: const ValueKey('link-credential-offer'),
                  border: palette.warning.withValues(alpha: .4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          AppIconBadge(icon: Icons.key_rounded, tone: palette.warning),
                          const SizedBox(width: Space.md),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(l.linkCredentialOfferTitle, style: theme.textTheme.titleSmall),
                                Text(
                                  offer.aiApiKey != null
                                      ? '${l.linkCredentialOfferDetail(offer.hostPasswords.length, offer.privateKeys.length)} ${l.mobileSyncAiIncluded}'
                                      : l.linkCredentialOfferDetail(
                                          offer.hostPasswords.length,
                                          offer.privateKeys.length,
                                        ),
                                  style: muted,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: Space.md),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          TextButton(onPressed: client.dismissPendingCredentials, child: Text(l.cancel)),
                          const SizedBox(width: Space.xs),
                          FilledButton(
                            key: const ValueKey('link-credential-import-button'),
                            onPressed: _acceptCredentials,
                            child: Text(l.linkCredentialImport),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: Space.md),
              if (twoColumns)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: approvalsAndSessions),
                    ),
                    const SizedBox(width: Space.lg),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: desktopHostsSection),
                    ),
                  ],
                )
              else ...[
                ...approvalsAndSessions,
                const SizedBox(height: Space.md),
                ...desktopHostsSection,
              ],
            ],
          ),
        );
      },
    );
  }
}

/// The theme surface on the page background with a hairline edge, as on the Me page; [color] and [border] tint it.
class _SurfaceCard extends StatelessWidget {
  const _SurfaceCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(Space.md),
    this.color,
    this.border,
  });

  final Widget child;
  final EdgeInsets padding;
  final Color? color, border;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.sm),
      child: Material(
        color: color ?? BrandPalette.of(context).surface.withValues(alpha: .88),
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: border ?? scheme.outlineVariant.withValues(alpha: .35)),
        ),
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}

/// List rows led by icon badges in one card, split by hairlines that start under the text.
class _Group extends StatelessWidget {
  const _Group({required this.children});

  final List<Widget> children;

  static const _badge = 36.0;

  @override
  Widget build(BuildContext context) => _SurfaceCard(
    padding: const EdgeInsets.symmetric(vertical: Space.xs),
    child: ListTileTheme.merge(
      minTileHeight: MobileSize.touchTarget + Space.sm,
      minLeadingWidth: _badge,
      horizontalTitleGap: Space.md,
      contentPadding: const EdgeInsets.symmetric(horizontal: Space.md),
      shape: const RoundedRectangleBorder(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (i, row) in children.indexed) ...[
            if (i > 0) const Divider(indent: Space.md + _badge + Space.md, endIndent: Space.md),
            row,
          ],
        ],
      ),
    ),
  );
}

/// A section name with how many items it holds.
class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text, {this.count, this.tone});

  final String text;
  final int? count;
  final Color? tone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final count = this.count;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.xs, Space.xs, Space.xs, Space.sm),
      child: Row(
        children: [
          Flexible(
            child: Text(
              text,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          if (count != null && count > 0) ...[const SizedBox(width: Space.sm), AppTag(label: '$count', tone: tone)],
        ],
      ),
    );
  }
}

/// One shortcut in the connected card: a badge over a short label, or beside it when [wide].
class _ActionTile extends StatelessWidget {
  const _ActionTile({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.busy = false,
    this.wide = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool busy, wide;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final badge = busy ? const _BadgeSpinner() : AppIconBadge(icon: icon, tone: scheme.primary);
    final style = theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w500, color: scheme.onSurface);
    final content = wide
        ? Row(
            children: [
              badge,
              const SizedBox(width: Space.md),
              Expanded(
                child: Text(label, maxLines: 2, overflow: TextOverflow.ellipsis, style: style),
              ),
            ],
          )
        : Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              badge,
              const SizedBox(height: Space.sm),
              Text(label, textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis, style: style),
            ],
          );
    return Material(
      color: scheme.surface,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.card),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: .5)),
      ),
      child: InkWell(
        onTap: busy ? null : onTap,
        child: Padding(
          padding: wide
              ? const EdgeInsets.symmetric(horizontal: Space.md, vertical: Space.sm + 2)
              : const EdgeInsets.symmetric(horizontal: Space.sm, vertical: Space.md),
          child: content,
        ),
      ),
    );
  }
}

/// A quiet card in place of an empty list.
class _EmptyNote extends StatelessWidget {
  const _EmptyNote({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return _SurfaceCard(
      child: Row(
        children: [
          AppIconBadge(icon: icon, size: 32),
          const SizedBox(width: Space.md),
          Expanded(
            child: Text(text, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ),
        ],
      ),
    );
  }
}

/// A one-line result under the connected card; [quiet] mutes it.
class _StatusLine extends StatelessWidget {
  const _StatusLine({super.key, required this.icon, required this.text, this.busy = false, this.quiet = false});

  final IconData icon;
  final String text;
  final bool busy, quiet;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = quiet ? theme.colorScheme.onSurfaceVariant : theme.colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.xs, Space.xs, Space.xs, Space.sm),
      child: Row(
        children: [
          if (busy)
            const SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2))
          else
            Icon(icon, size: 14, color: color),
          const SizedBox(width: 6),
          Expanded(
            child: Text(text, style: theme.textTheme.bodySmall?.copyWith(color: color)),
          ),
        ],
      ),
    );
  }
}

/// A spinner the size of an icon badge, while that row is opening.
class _BadgeSpinner extends StatelessWidget {
  const _BadgeSpinner();

  @override
  Widget build(BuildContext context) => const SizedBox.square(
    dimension: 36,
    child: Center(child: SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))),
  );
}

class _DiscoveredPairDialog extends StatefulWidget {
  const _DiscoveredPairDialog({required this.desktop});

  final DiscoveredDesktop desktop;

  @override
  State<_DiscoveredPairDialog> createState() => _DiscoveredPairDialogState();
}

class _DiscoveredPairDialogState extends State<_DiscoveredPairDialog> {
  final _code = TextEditingController();

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  String get _normalized => _code.text.replaceAll(RegExp(r'\s+'), '');

  void _submit() {
    final code = _normalized;
    if (code.length < 6) return;
    Navigator.of(context).pop(code);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final canSubmit = _normalized.length >= 6;
    return AnimatedPadding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      duration: Motion.overlay(context, Motion.quick),
      child: AppDialog(
        icon: Icon(Icons.desktop_windows_outlined, color: scheme.primary),
        title: Text(widget.desktop.name, overflow: TextOverflow.ellipsis),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '${widget.desktop.address}:${widget.desktop.port}',
              style: mono(context, Theme.of(context).textTheme.bodySmall),
            ),
            const SizedBox(height: Space.md),
            TextField(
              key: const ValueKey('link-discovered-code-input'),
              controller: _code,
              autofocus: true,
              keyboardType: TextInputType.number,
              textInputAction: TextInputAction.done,
              decoration: InputDecoration(labelText: l.linkPairingCode, isDense: true),
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _submit(),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(l.cancel)),
          FilledButton(
            key: const ValueKey('link-discovered-pair-confirm'),
            onPressed: canSubmit ? _submit : null,
            child: Text(l.linkPairNow),
          ),
        ],
      ),
    );
  }
}

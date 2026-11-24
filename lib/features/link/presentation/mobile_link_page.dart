import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../design/brand.dart';
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
  const MobileLinkPage({super.key, this.onOpenedTerminal, this.onOpenFiles});

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
    final connecting = client.status == LinkConnectionStatus.connecting;
    const pairingActionStyle = ButtonStyle(
      padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: Space.sm, vertical: Space.xs)),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final inset = MobileSize.contentInset(constraints.maxWidth);
        return ListView(
          key: const ValueKey('mobile-link-disconnected'),
          padding: EdgeInsets.fromLTRB(inset, Space.md, inset, Space.xl),
          children: [
            if (client.savedDesktops.isEmpty && client.discoveredDesktops.isEmpty) ...[
              const Center(child: BrandIllustration(pose: BrandPose.security, size: 112)),
              const SizedBox(height: Space.md),
            ],
            if (isMobilePlatform) ...[
              FilledButton.icon(
                key: const ValueKey('link-scan-qr-button'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(MobileSize.touchTarget),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.panel)),
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
                    child: FilledButton.tonalIcon(
                      key: const ValueKey('link-scan-button'),
                      style: pairingActionStyle,
                      onPressed: client.discovering ? null : () => unawaited(client.discoverLan()),
                      icon: client.discovering
                          ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.radar_outlined, size: 18),
                      label: Text(client.discovering ? l.linkScanning : l.linkScanLan, textAlign: TextAlign.center),
                    ),
                  ),
                  const SizedBox(width: Space.sm),
                  Expanded(
                    child: OutlinedButton.icon(
                      key: const ValueKey('link-paste-uri-button'),
                      style: pairingActionStyle,
                      onPressed: connecting ? null : _pasteUri,
                      icon: const Icon(Icons.content_paste_outlined, size: 18),
                      label: Text(l.linkPasteUri, textAlign: TextAlign.center),
                    ),
                  ),
                ],
              ),
            ),
            if (client.lastError != null) ...[
              const SizedBox(height: Space.md),
              Container(
                padding: const EdgeInsets.all(Space.sm),
                decoration: BoxDecoration(
                  color: scheme.errorContainer,
                  borderRadius: BorderRadius.circular(Radii.card),
                ),
                child: Row(
                  children: [
                    Icon(Icons.error_outline, size: 18, color: scheme.onErrorContainer),
                    const SizedBox(width: Space.sm),
                    Expanded(
                      child: Text(
                        _errorText(l, client.lastError!),
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onErrorContainer),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            if (client.discoveredDesktops.isNotEmpty) ...[
              const SizedBox(height: Space.lg),
              Text(l.linkDiscoveredDesktops, style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: Space.sm),
              for (final d in client.discoveredDesktops)
                _SurfaceCard(
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.desktop_windows_outlined, color: scheme.primary),
                    title: Text(d.name, overflow: TextOverflow.ellipsis),
                    subtitle: Text(
                      '${d.address}:${d.port}',
                      style: mono(context, Theme.of(context).textTheme.bodySmall),
                    ),
                    trailing: Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
                    onTap: () {
                      final saved = client.savedDesktops.where((p) => p.deviceId == d.deviceId).firstOrNull;
                      if (saved != null) {
                        unawaited(client.connectToPeer(saved, hostOverride: d.address, portOverride: d.port));
                      } else {
                        _hostController.text = d.address;
                        _portController.text = '${d.port}';
                      }
                    },
                  ),
                ),
            ],
            if (client.savedDesktops.isNotEmpty) ...[
              const SizedBox(height: Space.lg),
              Text(l.linkSavedDesktops, style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: Space.sm),
              for (final peer in client.savedDesktops)
                _SurfaceCard(
                  child: Row(
                    children: [
                      Icon(Icons.computer_outlined, color: scheme.primary, size: 20),
                      const SizedBox(width: Space.sm),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              peer.name,
                              style: Theme.of(context).textTheme.titleSmall,
                              overflow: TextOverflow.ellipsis,
                            ),
                            if (peer.lastAddress != null)
                              Text(
                                '${peer.lastAddress}:${peer.lastPort ?? linkDefaultPort}',
                                style: mono(context, Theme.of(context).textTheme.bodySmall),
                              ),
                          ],
                        ),
                      ),
                      FilledButton.tonal(
                        onPressed: connecting ? null : () => unawaited(client.connectToPeer(peer)),
                        child: Text(l.linkReconnect),
                      ),
                      IconButton(
                        tooltip: l.linkRevoke,
                        icon: Icon(Icons.delete_outline, size: 18, color: scheme.error),
                        onPressed: () => unawaited(client.forgetDesktop(peer.deviceId)),
                      ),
                    ],
                  ),
                ),
            ],
            const SizedBox(height: Space.lg),
            Text(l.linkManualConnect, style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: Space.sm),
            _SurfaceCard(
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
                          decoration: InputDecoration(labelText: l.linkHostOrIp, isDense: true),
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
                  const SizedBox(height: Space.sm),
                  TextField(
                    key: const ValueKey('link-manual-code'),
                    controller: _codeController,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(labelText: l.linkPairingCode, isDense: true),
                    onSubmitted: (_) => _pairManual(),
                  ),
                  const SizedBox(height: Space.md),
                  FilledButton(
                    key: const ValueKey('link-pair-submit'),
                    onPressed: connecting ? null : _pairManual,
                    child: connecting
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : Text(l.linkPairNow),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildConnected(BuildContext context, AppLocalizations l, ColorScheme scheme, LinkClientController client) {
    final offer = client.pendingCredentialOffer;
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

    return LayoutBuilder(
      builder: (context, constraints) {
        final inset = MobileSize.contentInset(constraints.maxWidth);
        return ListView(
          key: const ValueKey('mobile-link-connected'),
          padding: EdgeInsets.fromLTRB(inset, Space.md, inset, Space.xl),
          children: [
            _SurfaceCard(
              borderColor: scheme.primary.withValues(alpha: .35),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.link, color: scheme.primary, size: 20),
                      const SizedBox(width: Space.sm),
                      Expanded(
                        child: Text(
                          l.linkConnectedTo(client.connectedDesktopName ?? ''),
                          style: Theme.of(context).textTheme.titleSmall,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      TextButton(
                        key: const ValueKey('link-disconnect-button'),
                        onPressed: () => unawaited(client.disconnect()),
                        child: Text(l.linkDisconnect),
                      ),
                    ],
                  ),
                  const SizedBox(height: Space.sm),
                  Wrap(
                    spacing: Space.sm,
                    runSpacing: Space.xs,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      FilledButton.tonalIcon(
                        key: const ValueKey('link-sync-button'),
                        onPressed: _syncing ? null : _syncNow,
                        icon: _syncing
                            ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.sync_outlined, size: 16),
                        label: Text(l.linkSyncConfig),
                      ),
                      OutlinedButton.icon(
                        key: const ValueKey('link-clipboard-button'),
                        onPressed: _pushClipboard,
                        icon: const Icon(Icons.content_paste_go_rounded, size: 16),
                        label: Text(l.mobilePushClipboard),
                      ),
                      if (client.desktopSharesFiles && widget.onOpenFiles != null)
                        OutlinedButton.icon(
                          key: const ValueKey('link-files-button'),
                          onPressed: widget.onOpenFiles,
                          icon: const Icon(Icons.folder_outlined, size: 16),
                          label: Text(l.files),
                        ),
                      FilterChip(
                        key: const ValueKey('link-share-files-chip'),
                        label: Text(l.linkSharePhoneFiles),
                        selected: client.sharesPhoneFiles,
                        onSelected: (on) => unawaited(_sharePhoneFiles(client, on)),
                      ),
                      if (_notice != null)
                        Text(_notice!, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.primary)),
                    ],
                  ),
                  if (client.passwordSyncStatus != LinkPasswordSyncStatus.idle) ...[
                    const SizedBox(height: Space.xs),
                    Row(
                      key: const ValueKey('link-password-sync-status'),
                      children: [
                        if (client.passwordSyncStatus == LinkPasswordSyncStatus.awaitingDesktop)
                          const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2))
                        else
                          Icon(
                            client.passwordSyncStatus == LinkPasswordSyncStatus.imported
                                ? Icons.key_outlined
                                : Icons.info_outline,
                            size: 14,
                            color: client.passwordSyncStatus == LinkPasswordSyncStatus.imported
                                ? scheme.primary
                                : scheme.onSurfaceVariant,
                          ),
                        const SizedBox(width: Space.xs),
                        Expanded(
                          child: Text(
                            switch (client.passwordSyncStatus) {
                              LinkPasswordSyncStatus.awaitingDesktop => l.linkPasswordSyncWaiting,
                              LinkPasswordSyncStatus.imported => l.linkPasswordSyncImported(
                                client.lastImportedPasswordCount,
                              ),
                              LinkPasswordSyncStatus.declined => l.linkPasswordSyncDeclined,
                              LinkPasswordSyncStatus.idle => '',
                            },
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: client.passwordSyncStatus == LinkPasswordSyncStatus.declined
                                  ? scheme.onSurfaceVariant
                                  : scheme.primary,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            if (offer != null) ...[
              const SizedBox(height: Space.md),
              _SurfaceCard(
                key: const ValueKey('link-credential-offer'),
                borderColor: scheme.tertiary.withValues(alpha: .5),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.key_outlined, size: 18, color: scheme.tertiary),
                        const SizedBox(width: Space.sm),
                        Expanded(
                          child: Text(l.linkCredentialOfferTitle, style: Theme.of(context).textTheme.titleSmall),
                        ),
                      ],
                    ),
                    const SizedBox(height: Space.xs),
                    Text(
                      offer.aiApiKey != null
                          ? '${l.linkCredentialOfferDetail(offer.hostPasswords.length, offer.privateKeys.length)} ${l.mobileSyncAiIncluded}'
                          : l.linkCredentialOfferDetail(offer.hostPasswords.length, offer.privateKeys.length),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: Space.sm),
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
            ],
            if (client.pendingApprovals.isNotEmpty) ...[
              const SizedBox(height: Space.lg),
              Row(
                children: [
                  Icon(Icons.shield_outlined, size: 18, color: scheme.error),
                  const SizedBox(width: Space.xs),
                  Text(
                    '${l.linkPendingApprovals} (${client.pendingApprovals.length})',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ],
              ),
              const SizedBox(height: Space.sm),
              for (final item in client.pendingApprovals)
                _SurfaceCard(
                  key: ValueKey('link-approval-${item.approvalId}'),
                  borderColor: scheme.error.withValues(alpha: .35),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(item.title, style: Theme.of(context).textTheme.titleSmall),
                      if (item.target.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(item.target, style: mono(context, Theme.of(context).textTheme.bodySmall)),
                      ],
                      if (item.command.isNotEmpty) ...[
                        const SizedBox(height: Space.xs),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(Space.sm),
                          decoration: BoxDecoration(
                            color: scheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(Radii.control),
                          ),
                          child: Text(item.command, style: mono(context, Theme.of(context).textTheme.bodySmall)),
                        ),
                      ],
                      if (item.detail.isNotEmpty) ...[
                        const SizedBox(height: Space.xs),
                        Text(
                          item.detail,
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ],
                      const SizedBox(height: Space.sm),
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
                          style: Theme.of(context).textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                    ],
                  ),
                ),
            ],
            const SizedBox(height: Space.lg),
            Text(l.linkDesktopTerminals, style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: Space.sm),
            if (client.desktopSessions.isEmpty)
              Text(
                l.linkNoDesktopTerminals,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              )
            else
              for (final s in client.desktopSessions)
                _SurfaceCard(
                  key: ValueKey('link-mirror-${s.sessionId}'),
                  onTap: () => unawaited(_openDesktopTerminal(client, s)),
                  child: Row(
                    children: [
                      Icon(s.isLocal ? Icons.terminal : Icons.dns_outlined, size: 18, color: scheme.primary),
                      const SizedBox(width: Space.sm),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              s.title,
                              style: Theme.of(context).textTheme.titleSmall,
                              overflow: TextOverflow.ellipsis,
                            ),
                            Text(
                              s.targetLabel,
                              style: mono(context, Theme.of(context).textTheme.bodySmall),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                      if (_connectingSessionId == s.sessionId)
                        const SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2))
                      else
                        _Tag(
                          label: s.status == 'connected' ? l.linkMirrorTag : l.linkSessionPending,
                          color: s.status == 'connected' ? scheme.primary : scheme.onSurfaceVariant,
                        ),
                    ],
                  ),
                ),
            const SizedBox(height: Space.lg),
            Text(l.linkDesktopHosts, style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: Space.sm),
            if (client.desktopHosts.length > 5) ...[
              TextField(
                controller: _hostSearchController,
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search, size: 18),
                  hintText: l.searchHint,
                  isDense: true,
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: Space.sm),
            ],
            if (filteredHosts.isEmpty)
              Text(
                l.linkNoDesktopHosts,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              )
            else
              for (final h in filteredHosts)
                _SurfaceCard(
                  key: ValueKey('link-proxy-${h.hostId}'),
                  onTap: () {
                    client.openProxiedHostInWorkspace(h);
                    widget.onOpenedTerminal?.call();
                  },
                  onLongPress: () => _showHostActions(client, h),
                  child: Row(
                    children: [
                      Icon(Icons.hub_outlined, size: 18, color: scheme.secondary),
                      const SizedBox(width: Space.sm),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              h.label.isEmpty ? h.targetLabel : h.label,
                              style: Theme.of(context).textTheme.titleSmall,
                              overflow: TextOverflow.ellipsis,
                            ),
                            Text(
                              h.group.isEmpty ? h.targetLabel : '${h.group} · ${h.targetLabel}',
                              style: mono(context, Theme.of(context).textTheme.bodySmall),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                      if (_connectingHostId == h.hostId)
                        const SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2))
                      else
                        _Tag(label: l.linkProxyTag, color: scheme.secondary),
                    ],
                  ),
                ),
          ],
        );
      },
    );
  }
}

class _SurfaceCard extends StatelessWidget {
  const _SurfaceCard({super.key, required this.child, this.onTap, this.onLongPress, this.borderColor});

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final Color? borderColor;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final body = Padding(padding: const EdgeInsets.all(Space.md), child: child);
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.sm),
      child: Material(
        color: scheme.surfaceContainerLow,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: borderColor ?? scheme.outlineVariant.withValues(alpha: .45)),
        ),
        child: onTap == null && onLongPress == null
            ? body
            : InkWell(onTap: onTap, onLongPress: onLongPress, child: body),
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: Space.sm, vertical: 2),
    decoration: BoxDecoration(color: color.withValues(alpha: .14), borderRadius: BorderRadius.circular(Radii.pill)),
    child: Text(label, style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color)),
  );
}

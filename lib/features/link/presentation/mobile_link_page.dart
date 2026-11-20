import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../design/theme.dart';
import '../../../l10n/app_localizations.dart';
import '../application/link_service.dart';
import '../domain/protocol.dart';

/// Mobile "Link" hub for pairing with Desktop, live terminal mirroring, desktop-proxied SSH,
/// config/credential sync, and remote Agent/MCP approvals (docs/MOBILE.md §3-4).
class MobileLinkPage extends ConsumerStatefulWidget {
  const MobileLinkPage({super.key, this.onOpenedTerminal});

  /// Invoked after opening a mirrored or desktop-proxied terminal so the shell can switch to the terminal tab.
  final VoidCallback? onOpenedTerminal;

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

  Future<void> _syncNow() async {
    if (_syncing) return;
    setState(() => _syncing = true);
    try {
      final summary = await ref.read(linkClientControllerProvider).pullConfigSync();
      if (!mounted) return;
      final l = AppLocalizations.of(context);
      _showNotice(l.linkSyncDone(summary.hostsSynced, summary.snippetsSynced, summary.knownHostsAdded));
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

  Widget _buildDisconnected(
    BuildContext context,
    AppLocalizations l,
    ColorScheme scheme,
    LinkClientController client,
  ) {
    final connecting = client.status == LinkConnectionStatus.connecting;
    return ListView(
      key: const ValueKey('mobile-link-disconnected'),
      padding: const EdgeInsets.all(Space.md),
      children: [
        Wrap(
          spacing: Space.sm,
          runSpacing: Space.sm,
          children: [
            FilledButton.tonalIcon(
              key: const ValueKey('link-scan-button'),
              onPressed: client.discovering ? null : () => unawaited(client.discoverLan()),
              icon: client.discovering
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.radar_outlined, size: 18),
              label: Text(client.discovering ? l.linkScanning : l.linkScanLan),
            ),
            OutlinedButton.icon(
              key: const ValueKey('link-paste-uri-button'),
              onPressed: connecting ? null : _pasteUri,
              icon: const Icon(Icons.content_paste_outlined, size: 18),
              label: Text(l.linkPasteUri),
            ),
          ],
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
                subtitle: Text('${d.address}:${d.port}', style: mono(context, Theme.of(context).textTheme.bodySmall)),
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
                        Text(peer.name, style: Theme.of(context).textTheme.titleSmall, overflow: TextOverflow.ellipsis),
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
  }

  Widget _buildConnected(
    BuildContext context,
    AppLocalizations l,
    ColorScheme scheme,
    LinkClientController client,
  ) {
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

    return ListView(
      key: const ValueKey('mobile-link-connected'),
      padding: const EdgeInsets.all(Space.md),
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
                  if (_notice != null)
                    Text(_notice!, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.primary)),
                ],
              ),
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
                    Expanded(child: Text(l.linkCredentialOfferTitle, style: Theme.of(context).textTheme.titleSmall)),
                  ],
                ),
                const SizedBox(height: Space.xs),
                Text(
                  l.linkCredentialOfferDetail(offer.hostPasswords.length, offer.privateKeys.length),
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
              onTap: () {
                client.openMirroredSessionInWorkspace(s);
                widget.onOpenedTerminal?.call();
              },
              child: Row(
                children: [
                  Icon(s.isLocal ? Icons.terminal : Icons.dns_outlined, size: 18, color: scheme.primary),
                  const SizedBox(width: Space.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(s.title, style: Theme.of(context).textTheme.titleSmall, overflow: TextOverflow.ellipsis),
                        Text(
                          s.targetLabel,
                          style: mono(context, Theme.of(context).textTheme.bodySmall),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  _Tag(label: l.linkMirrorTag, color: scheme.primary),
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
                  _Tag(label: l.linkProxyTag, color: scheme.secondary),
                ],
              ),
            ),
      ],
    );
  }
}

class _SurfaceCard extends StatelessWidget {
  const _SurfaceCard({super.key, required this.child, this.onTap, this.borderColor});

  final Widget child;
  final VoidCallback? onTap;
  final Color? borderColor;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final box = Container(
      margin: const EdgeInsets.only(bottom: Space.sm),
      padding: const EdgeInsets.all(Space.md),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(Radii.card),
        border: Border.all(color: borderColor ?? scheme.outlineVariant.withValues(alpha: .45)),
      ),
      child: child,
    );
    if (onTap == null) return box;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(Radii.card),
      child: box,
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
    decoration: BoxDecoration(
      color: color.withValues(alpha: .14),
      borderRadius: BorderRadius.circular(Radii.pill),
    ),
    child: Text(label, style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color)),
  );
}

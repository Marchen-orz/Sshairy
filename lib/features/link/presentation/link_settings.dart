import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../design/controls.dart';
import '../../../design/dialog.dart';
import '../../../design/theme.dart';
import '../../../l10n/app_localizations.dart';
import '../../settings/api.dart';
import '../application/link_service.dart';
import '../domain/protocol.dart';

/// Optional item catalog supplied by app composition for the explicit desktop credential push dialog.
typedef LinkCredentialCatalog = ({
  List<({String id, String label})> hosts,
  List<({String id, String label})> keys,
});

final linkCredentialCatalogProvider = Provider<LinkCredentialCatalog Function()>(
  (_) =>
      () => (hosts: const [], keys: const []),
);

/// Desktop settings section for Sshairy Link (docs/MOBILE.md §4-5).
class LinkSettings extends ConsumerStatefulWidget {
  const LinkSettings({super.key});

  @override
  ConsumerState<LinkSettings> createState() => _LinkSettingsState();
}

class _LinkSettingsState extends ConsumerState<LinkSettings> {
  final _portController = TextEditingController();
  final _nameController = TextEditingController();
  String? _notice;

  @override
  void initState() {
    super.initState();
    final settings = ref.read(settingsProvider);
    _portController.text = '${settings.get(SettingKeys.linkPort)}';
    _nameController.text = settings.get(SettingKeys.linkDeviceName) ?? '';
  }

  @override
  void dispose() {
    _portController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  void _showNotice(String text) {
    if (!mounted) return;
    setState(() => _notice = text);
    Future<void>.delayed(const Duration(seconds: 3), () {
      if (mounted && _notice == text) setState(() => _notice = null);
    });
  }

  Future<void> _savePort() async {
    final parsed = int.tryParse(_portController.text.trim());
    if (parsed == null || parsed < 1024 || parsed > 65535) return;
    await ref.read(settingsProvider.notifier).set(SettingKeys.linkPort, parsed);
  }

  Future<void> _saveName() async {
    final text = _nameController.text.trim();
    await ref.read(settingsProvider.notifier).set(SettingKeys.linkDeviceName, text.isEmpty ? null : text);
  }

  Future<void> _pushCredentials(LinkPeer peer) async {
    final catalog = ref.read(linkCredentialCatalogProvider)();
    final selectedHosts = <String>{};
    final selectedKeys = <String>{};
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (context) {
        final l = AppLocalizations.of(context);
        return StatefulBuilder(
          builder: (context, setModal) => AppDialog(
            title: Text(l.linkPushCredentialsTitle(peer.name)),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (catalog.hosts.isNotEmpty) ...[
                    Text(l.hosts, style: Theme.of(context).textTheme.labelMedium),
                    const SizedBox(height: Space.xs),
                    for (final h in catalog.hosts)
                      AppToggleRow(
                        title: h.label,
                        checkbox: true,
                        value: selectedHosts.contains(h.id),
                        onChanged: (v) => setModal(() => v ? selectedHosts.add(h.id) : selectedHosts.remove(h.id)),
                      ),
                  ],
                  if (catalog.keys.isNotEmpty) ...[
                    const SizedBox(height: Space.sm),
                    Text(l.keys, style: Theme.of(context).textTheme.labelMedium),
                    const SizedBox(height: Space.xs),
                    for (final k in catalog.keys)
                      AppToggleRow(
                        title: k.label,
                        checkbox: true,
                        value: selectedKeys.contains(k.id),
                        onChanged: (v) => setModal(() => v ? selectedKeys.add(k.id) : selectedKeys.remove(k.id)),
                      ),
                  ],
                  if (catalog.hosts.isEmpty && catalog.keys.isEmpty)
                    Text(l.linkPushCredentialsEmpty, style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context, false), child: Text(l.cancel)),
              FilledButton(
                onPressed: selectedHosts.isEmpty && selectedKeys.isEmpty ? null : () => Navigator.pop(context, true),
                child: Text(l.linkPushCredentials),
              ),
            ],
          ),
        );
      },
    );
    if (confirmed != true || !mounted) return;
    final sent = await ref
        .read(linkHostControllerProvider)
        .pushOptInCredentials(peer.deviceId, hostIds: selectedHosts, keyIds: selectedKeys);
    if (!mounted) return;
    final l = AppLocalizations.of(context);
    _showNotice(sent ? l.linkPushCredentialsSent(peer.name) : l.linkPushCredentialsEmpty);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final settings = ref.watch(settingsProvider);
    final writer = ref.read(settingsProvider.notifier);
    final host = ref.watch(linkHostControllerProvider);

    final enabled = settings.get(SettingKeys.linkEnabled);
    final discovery = settings.get(SettingKeys.linkDiscovery);

    return ListenableBuilder(
      listenable: host,
      builder: (context, _) {
        final pairing = host.activePairing;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(l.linkEnabled, style: Theme.of(context).textTheme.bodyMedium),
                      const SizedBox(height: 2),
                      Text(
                        host.failed
                            ? l.linkStartFailed
                            : host.running
                            ? l.linkRunning(host.port)
                            : l.linkStopped,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: host.failed
                              ? scheme.error
                              : host.running
                              ? scheme.primary
                              : scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                Switch(
                  key: const ValueKey('link-enabled-switch'),
                  value: enabled,
                  onChanged: (v) => writer.set(SettingKeys.linkEnabled, v),
                ),
              ],
            ),
            const SizedBox(height: Space.md),
            Wrap(
              spacing: Space.md,
              runSpacing: Space.sm,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SizedBox(
                  width: 140,
                  child: TextField(
                    key: const ValueKey('link-port-field'),
                    controller: _portController,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(labelText: l.linkPort, isDense: true),
                    onSubmitted: (_) => _savePort(),
                  ),
                ),
                OutlinedButton(onPressed: _savePort, child: Text(l.mcpPortSave)),
                SizedBox(
                  width: 200,
                  child: TextField(
                    key: const ValueKey('link-name-field'),
                    controller: _nameController,
                    decoration: InputDecoration(labelText: l.linkDeviceName, isDense: true),
                    onSubmitted: (_) => _saveName(),
                    onEditingComplete: _saveName,
                  ),
                ),
              ],
            ),
            const SizedBox(height: Space.sm),
            AppToggleRow(
              title: l.linkDiscovery,
              value: discovery,
              onChanged: (v) => writer.set(SettingKeys.linkDiscovery, v),
            ),
            if (host.running && host.addresses.isNotEmpty) ...[
              const SizedBox(height: Space.sm),
              Wrap(
                spacing: Space.xs,
                runSpacing: Space.xs,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text('${l.linkAddresses}:', style: Theme.of(context).textTheme.bodySmall),
                  for (final addr in host.addresses)
                    ActionChip(
                      visualDensity: VisualDensity.compact,
                      label: Text('$addr:${host.port}', style: mono(context, Theme.of(context).textTheme.labelSmall)),
                      onPressed: () {
                        unawaited(Clipboard.setData(ClipboardData(text: '$addr:${host.port}')));
                        _showNotice(l.linkCopied);
                      },
                    ),
                ],
              ),
            ],
            const SizedBox(height: Space.md),
            Row(
              children: [
                FilledButton.icon(
                  key: const ValueKey('link-pair-button'),
                  onPressed: host.running
                      ? () {
                          if (pairing != null) {
                            host.cancelPairing();
                          } else {
                            unawaited(host.startPairing());
                          }
                        }
                      : null,
                  icon: Icon(pairing != null ? Icons.close : Icons.phonelink_setup_outlined, size: 18),
                  label: Text(pairing != null ? l.linkCancelPairing : l.linkPairDevice),
                ),
                if (_notice != null) ...[
                  const SizedBox(width: Space.md),
                  Expanded(
                    child: Text(
                      _notice!,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.primary),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ],
            ),
            if (pairing != null) ...[
              const SizedBox(height: Space.md),
              Container(
                key: const ValueKey('link-pairing-card'),
                padding: const EdgeInsets.all(Space.md),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(Radii.card),
                  border: Border.all(color: scheme.primary.withValues(alpha: .35)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(l.linkPairingCode, style: Theme.of(context).textTheme.labelMedium),
                        const Spacer(),
                        TextButton.icon(
                          key: const ValueKey('link-copy-uri'),
                          onPressed: () {
                            unawaited(Clipboard.setData(ClipboardData(text: pairing.toUri())));
                            _showNotice(l.linkCopied);
                          },
                          icon: const Icon(Icons.copy_outlined, size: 16),
                          label: Text(l.linkCopyUri),
                        ),
                      ],
                    ),
                    const SizedBox(height: Space.xs),
                    SelectableText(
                      '${pairing.code.substring(0, 3)} ${pairing.code.substring(3)}',
                      key: const ValueKey('link-pairing-code'),
                      style: mono(context, Theme.of(context).textTheme.headlineMedium).copyWith(
                        letterSpacing: 4,
                        fontWeight: FontWeight.w700,
                        color: scheme.primary,
                      ),
                    ),
                    const SizedBox(height: Space.xs),
                    SelectableText(
                      '${pairing.host}:${pairing.port}',
                      style: mono(context, Theme.of(context).textTheme.bodySmall),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: Space.lg),
            Text(l.linkPairedDevices, style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: Space.sm),
            if (host.peers.isEmpty)
              Text(
                l.linkNoPeers,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              )
            else
              for (final peer in host.peers) _PeerCard(
                peer: peer,
                online: host.connectedDeviceIds.contains(peer.deviceId),
                onUpdatePermissions: (perms) => unawaited(host.updatePermissions(peer.deviceId, perms)),
                onPushCredentials: () => unawaited(_pushCredentials(peer)),
                onDisconnect: () => host.disconnectPeer(peer.deviceId),
                onRevoke: () => unawaited(host.revokePeer(peer.deviceId)),
              ),
          ],
        );
      },
    );
  }
}

class _PeerCard extends StatelessWidget {
  const _PeerCard({
    required this.peer,
    required this.online,
    required this.onUpdatePermissions,
    required this.onPushCredentials,
    required this.onDisconnect,
    required this.onRevoke,
  });

  final LinkPeer peer;
  final bool online;
  final ValueChanged<LinkPeerPermissions> onUpdatePermissions;
  final VoidCallback onPushCredentials;
  final VoidCallback onDisconnect;
  final VoidCallback onRevoke;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final p = peer.permissions;
    return Container(
      margin: const EdgeInsets.only(bottom: Space.sm),
      padding: const EdgeInsets.all(Space.md),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(Radii.card),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: .45)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.smartphone_outlined,
                size: 18,
                color: online ? scheme.primary : scheme.onSurfaceVariant,
              ),
              const SizedBox(width: Space.sm),
              Expanded(
                child: Text(
                  peer.name,
                  style: Theme.of(context).textTheme.titleSmall,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: Space.sm, vertical: 2),
                decoration: BoxDecoration(
                  color: (online ? scheme.primary : scheme.outline).withValues(alpha: .14),
                  borderRadius: BorderRadius.circular(Radii.pill),
                ),
                child: Text(
                  online ? l.linkOnline : l.linkOffline,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: online ? scheme.primary : scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: Space.sm),
          Wrap(
            spacing: Space.xs,
            runSpacing: Space.xs,
            children: [
              FilterChip(
                label: Text(l.linkPermMirror),
                selected: p.allowMirror,
                onSelected: (v) => onUpdatePermissions(p.copyWith(allowMirror: v)),
              ),
              FilterChip(
                label: Text(l.linkPermProxy),
                selected: p.allowProxy,
                onSelected: (v) => onUpdatePermissions(p.copyWith(allowProxy: v)),
              ),
              FilterChip(
                label: Text(l.linkPermSync),
                selected: p.allowSync,
                onSelected: (v) => onUpdatePermissions(p.copyWith(allowSync: v)),
              ),
              FilterChip(
                label: Text(l.linkPermApproval),
                selected: p.allowApproval,
                onSelected: (v) => onUpdatePermissions(p.copyWith(allowApproval: v)),
              ),
            ],
          ),
          const SizedBox(height: Space.sm),
          Wrap(
            spacing: Space.sm,
            runSpacing: Space.xs,
            children: [
              if (online)
                OutlinedButton.icon(
                  onPressed: onPushCredentials,
                  icon: const Icon(Icons.key_outlined, size: 16),
                  label: Text(l.linkPushCredentials),
                ),
              if (online)
                TextButton(onPressed: onDisconnect, child: Text(l.linkDisconnect)),
              TextButton(
                onPressed: onRevoke,
                style: TextButton.styleFrom(foregroundColor: scheme.error),
                child: Text(l.linkRevoke),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

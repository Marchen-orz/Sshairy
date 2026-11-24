import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../design/controls.dart';
import '../../../design/dialog.dart';
import '../../../design/form_field.dart';
import '../../../design/theme.dart';
import '../../../foundation/result.dart';
import '../../../l10n/app_localizations.dart';
import '../../settings/api.dart';
import '../adapters/qr_adapter.dart';
import '../application/link_service.dart';
import '../domain/protocol.dart';

/// Optional item catalog supplied by app composition for the explicit desktop credential push dialog.
typedef LinkCredentialCatalog = ({
  List<({String id, String label})> hosts,
  List<({String id, String label})> keys,
  String? aiProfileLabel,
});

final linkCredentialCatalogProvider = Provider<LinkCredentialCatalog Function()>(
  (_) =>
      () => (hosts: const [], keys: const [], aiProfileLabel: null),
);

/// Desktop sidebar flyout for Sshairy Link (docs/MOBILE.md §4-5).
class LinkSettings extends ConsumerStatefulWidget {
  const LinkSettings({super.key});

  @override
  ConsumerState<LinkSettings> createState() => _LinkSettingsState();
}

class _LinkSettingsState extends ConsumerState<LinkSettings> {
  final _portController = TextEditingController();
  final _nameController = TextEditingController();
  final _portFocus = FocusNode();
  final _nameFocus = FocusNode();
  Timer? _portTimer;
  Timer? _nameTimer;
  Timer? _noticeTimer;
  late String _syncedPort;
  late String _syncedName;
  String? _notice;
  bool _noticeError = false;

  @override
  void initState() {
    super.initState();
    final settings = ref.read(settingsProvider);
    _syncedPort = '${settings.get(SettingKeys.linkPort)}';
    _syncedName = settings.get(SettingKeys.linkDeviceName) ?? '';
    _portController.text = _syncedPort;
    _nameController.text = _syncedName;
    _portFocus.addListener(_onPortFocusChange);
    _nameFocus.addListener(_onNameFocusChange);
  }

  @override
  void dispose() {
    _portTimer?.cancel();
    _nameTimer?.cancel();
    _noticeTimer?.cancel();
    _portFocus
      ..removeListener(_onPortFocusChange)
      ..dispose();
    _nameFocus
      ..removeListener(_onNameFocusChange)
      ..dispose();
    _portController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  void _syncExternal(Settings settings) {
    final port = '${settings.get(SettingKeys.linkPort)}';
    final name = settings.get(SettingKeys.linkDeviceName) ?? '';
    if (port != _syncedPort) {
      if (!_portFocus.hasFocus || _portController.text.trim() == _syncedPort) {
        _portController.text = port;
      }
      _syncedPort = port;
    }
    if (name != _syncedName) {
      if (!_nameFocus.hasFocus || _nameController.text.trim() == _syncedName) {
        _nameController.text = name;
      }
      _syncedName = name;
    }
  }

  int? get _parsedPort {
    final parsed = int.tryParse(_portController.text.trim());
    return parsed != null && SettingKeys.linkPort.accepts(parsed) ? parsed : null;
  }

  String get _trimmedName => _nameController.text.trim();

  bool get _nameValid => SettingKeys.linkDeviceName.accepts(_trimmedName.isEmpty ? null : _trimmedName);

  void _showNotice(String text, {bool error = false}) {
    if (!mounted) return;
    _noticeTimer?.cancel();
    setState(() {
      _notice = text;
      _noticeError = error;
    });
    _noticeTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && _notice == text) {
        setState(() {
          _notice = null;
          _noticeError = false;
        });
      }
    });
  }

  Map<String, Object?> _pendingTextUpdates() {
    final settings = ref.read(settingsProvider);
    final updates = <String, Object?>{};
    final port = _parsedPort;
    if (port != null && port != settings.get(SettingKeys.linkPort)) {
      updates[SettingKeys.linkPort.key] = port;
    }
    final name = _trimmedName;
    if (_nameValid && name != (settings.get(SettingKeys.linkDeviceName) ?? '')) {
      updates[SettingKeys.linkDeviceName.key] = name.isEmpty ? null : name;
    }
    return updates;
  }

  Future<void> _applyPatch(Map<String, Object?> updates) async {
    if (updates.isEmpty) return;
    final notifier = ref.read(settingsProvider.notifier);
    try {
      final result = await notifier.patch(updates);
      if (!mounted) return;
      if (result is Ok<void>) {
        if (updates.containsKey(SettingKeys.linkPort.key)) {
          _syncedPort = '${updates[SettingKeys.linkPort.key]}';
        }
        if (updates.containsKey(SettingKeys.linkDeviceName.key)) {
          _syncedName = (updates[SettingKeys.linkDeviceName.key] as String?) ?? '';
        }
      } else {
        _showNotice(AppLocalizations.of(context).errSave, error: true);
      }
    } on Object {
      if (mounted) _showNotice(AppLocalizations.of(context).errSave, error: true);
    }
  }

  Future<void> _saveBool(SettingDef<bool> setting, bool value) {
    _portTimer?.cancel();
    _nameTimer?.cancel();
    final updates = _pendingTextUpdates()..[setting.key] = value;
    return _applyPatch(updates);
  }

  void _schedulePortSave() {
    _portTimer?.cancel();
    final parsed = _parsedPort;
    if (parsed == null || parsed == ref.read(settingsProvider).get(SettingKeys.linkPort)) return;
    _portTimer = Timer(const Duration(milliseconds: 500), () {
      if (mounted) unawaited(_commitPort());
    });
  }

  void _scheduleNameSave() {
    _nameTimer?.cancel();
    final name = _trimmedName;
    if (!_nameValid || name == (ref.read(settingsProvider).get(SettingKeys.linkDeviceName) ?? '')) return;
    _nameTimer = Timer(const Duration(milliseconds: 500), () {
      if (mounted) unawaited(_commitName());
    });
  }

  Future<void> _commitPort() {
    _portTimer?.cancel();
    final parsed = _parsedPort;
    if (parsed == null || parsed == ref.read(settingsProvider).get(SettingKeys.linkPort)) return Future.value();
    return _applyPatch({SettingKeys.linkPort.key: parsed});
  }

  Future<void> _commitName() {
    _nameTimer?.cancel();
    final name = _trimmedName;
    if (!_nameValid || name == (ref.read(settingsProvider).get(SettingKeys.linkDeviceName) ?? '')) {
      return Future.value();
    }
    return _applyPatch({SettingKeys.linkDeviceName.key: name.isEmpty ? null : name});
  }

  void _onPortFocusChange() {
    if (_portFocus.hasFocus || !mounted) return;
    _portTimer?.cancel();
    final parsed = _parsedPort;
    if (parsed == null) {
      final saved = '${ref.read(settingsProvider).get(SettingKeys.linkPort)}';
      setState(() {
        _syncedPort = saved;
        _portController.text = saved;
      });
      return;
    }
    if (parsed != ref.read(settingsProvider).get(SettingKeys.linkPort)) {
      unawaited(_commitPort());
    }
  }

  void _onNameFocusChange() {
    if (_nameFocus.hasFocus || !mounted) return;
    _nameTimer?.cancel();
    if (!_nameValid) {
      final saved = ref.read(settingsProvider).get(SettingKeys.linkDeviceName) ?? '';
      setState(() {
        _syncedName = saved;
        _nameController.text = saved;
      });
      return;
    }
    final name = _trimmedName;
    if (_nameController.text != name) _nameController.text = name;
    if (name != (ref.read(settingsProvider).get(SettingKeys.linkDeviceName) ?? '')) {
      unawaited(_commitName());
    }
  }

  Future<void> _flushPending() {
    _portTimer?.cancel();
    _nameTimer?.cancel();
    return _applyPatch(_pendingTextUpdates());
  }

  Future<void> _close() async {
    await _flushPending();
    if (mounted) await Navigator.maybePop(context);
  }

  Future<void> _offerUpdate(LinkPeer peer) async {
    final sent = await ref.read(linkHostControllerProvider).offerUpdate(peer.deviceId);
    if (!mounted) return;
    final l = AppLocalizations.of(context);
    _showNotice(sent ? l.linkUpdateOffered : l.linkUpdateOfferFailed);
  }

  Future<void> _pushCredentials(LinkPeer peer) async {
    final catalog = ref.read(linkCredentialCatalogProvider)();
    final selectedHosts = <String>{};
    final selectedKeys = <String>{};
    var includeAiKey = false;
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
                  if (catalog.aiProfileLabel != null) ...[
                    Text('AI', style: Theme.of(context).textTheme.labelMedium),
                    const SizedBox(height: Space.xs),
                    AppToggleRow(
                      title: catalog.aiProfileLabel!,
                      checkbox: true,
                      value: includeAiKey,
                      onChanged: (v) => setModal(() => includeAiKey = v),
                    ),
                    const SizedBox(height: Space.sm),
                  ],
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
                  if (catalog.hosts.isEmpty && catalog.keys.isEmpty && catalog.aiProfileLabel == null)
                    Text(l.linkPushCredentialsEmpty, style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context, false), child: Text(l.cancel)),
              FilledButton(
                onPressed: selectedHosts.isEmpty && selectedKeys.isEmpty && !includeAiKey
                    ? null
                    : () => Navigator.pop(context, true),
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
        .pushOptInCredentials(peer.deviceId, hostIds: selectedHosts, keyIds: selectedKeys, includeAiKey: includeAiKey);
    if (!mounted) return;
    final l = AppLocalizations.of(context);
    _showNotice(sent ? l.linkPushCredentialsSent(peer.name) : l.linkPushCredentialsEmpty);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final settings = ref.watch(settingsProvider);
    _syncExternal(settings);
    final host = ref.watch(linkHostControllerProvider);
    final enabled = settings.get(SettingKeys.linkEnabled);
    final discovery = settings.get(SettingKeys.linkDiscovery);
    final savedName = settings.get(SettingKeys.linkDeviceName) ?? '';
    final portError = _parsedPort == null ? '1024–65535' : null;

    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) unawaited(_flushPending());
      },
      child: ListenableBuilder(
        listenable: host,
        builder: (context, _) {
          final pairing = host.activePairing;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(child: Text(l.linkTitle, style: theme.textTheme.titleMedium)),
                  IconButton(tooltip: l.close, onPressed: () => unawaited(_close()), icon: const Icon(Icons.close)),
                ],
              ),
              const SizedBox(height: Space.sm),
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(Space.md),
                        decoration: BoxDecoration(
                          color: scheme.surfaceContainerLow,
                          borderRadius: BorderRadius.circular(Radii.card),
                          border: Border.all(color: scheme.outlineVariant.withValues(alpha: .45)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            InkWell(
                              borderRadius: BorderRadius.circular(Radii.control),
                              onTap: () => unawaited(_saveBool(SettingKeys.linkEnabled, !enabled)),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(vertical: Space.xs),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(l.linkEnabled, style: theme.textTheme.bodyMedium),
                                          const SizedBox(height: 2),
                                          Text(
                                            host.failed
                                                ? l.linkStartFailed
                                                : host.running
                                                ? l.linkRunning(host.port)
                                                : l.linkStopped,
                                            style: theme.textTheme.bodySmall?.copyWith(
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
                                    const SizedBox(width: Space.md),
                                    AppSwitch(
                                      key: const ValueKey('link-enabled-switch'),
                                      value: enabled,
                                      onChanged: (v) => unawaited(_saveBool(SettingKeys.linkEnabled, v)),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(height: Space.md),
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: AppFormField(
                                    label: l.linkDeviceName,
                                    child: TextField(
                                      key: const ValueKey('link-name-field'),
                                      controller: _nameController,
                                      focusNode: _nameFocus,
                                      inputFormatters: [LengthLimitingTextInputFormatter(64)],
                                      decoration: AppFormField.decoration(context)
                                          .copyWith(hintText: savedName.isEmpty ? host.deviceName : null),
                                      onChanged: (_) => _scheduleNameSave(),
                                      onSubmitted: (_) => unawaited(_commitName()),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: Space.md),
                                SizedBox(
                                  width: 112,
                                  child: AppFormField(
                                    label: l.linkPort,
                                    child: TextField(
                                      key: const ValueKey('link-port-field'),
                                      controller: _portController,
                                      focusNode: _portFocus,
                                      keyboardType: TextInputType.number,
                                      inputFormatters: [
                                        FilteringTextInputFormatter.digitsOnly,
                                        LengthLimitingTextInputFormatter(5),
                                      ],
                                      decoration: AppFormField.decoration(context).copyWith(errorText: portError),
                                      onChanged: (_) {
                                        setState(() {});
                                        _schedulePortSave();
                                      },
                                      onSubmitted: (_) => unawaited(_commitPort()),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: Space.md),
                            InkWell(
                              borderRadius: BorderRadius.circular(Radii.control),
                              onTap: () => unawaited(_saveBool(SettingKeys.linkDiscovery, !discovery)),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(vertical: Space.xs),
                                child: Row(
                                  children: [
                                    Expanded(child: Text(l.linkDiscovery, style: theme.textTheme.bodyMedium)),
                                    const SizedBox(width: Space.md),
                                    AppSwitch(
                                      key: const ValueKey('link-discovery-switch'),
                                      value: discovery,
                                      onChanged: (v) => unawaited(_saveBool(SettingKeys.linkDiscovery, v)),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            if (host.running && host.addresses.isNotEmpty) ...[
                              const Divider(height: Space.lg),
                              Text(
                                l.linkAddresses,
                                style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                              ),
                              const SizedBox(height: Space.xs),
                              Wrap(
                                spacing: Space.xs,
                                runSpacing: Space.xs,
                                children: [
                                  for (final addr in host.addresses)
                                    ActionChip(
                                      visualDensity: VisualDensity.compact,
                                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                      label: Text(
                                        '$addr:${host.port}',
                                        style: mono(context, theme.textTheme.labelSmall),
                                      ),
                                      onPressed: () {
                                        unawaited(Clipboard.setData(ClipboardData(text: '$addr:${host.port}')));
                                        _showNotice(l.linkCopied);
                                      },
                                    ),
                                ],
                              ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(height: Space.md),
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
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              LinkQrCodeView(key: const ValueKey('link-pairing-qr'), data: pairing.toUri(), size: 132),
                              const SizedBox(width: Space.md),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            l.linkPairingCode,
                                            style: theme.textTheme.labelMedium,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
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
                                      style: mono(
                                        context,
                                        theme.textTheme.headlineMedium,
                                      ).copyWith(letterSpacing: 4, fontWeight: FontWeight.w700, color: scheme.primary),
                                    ),
                                    const SizedBox(height: Space.xs),
                                    if (host.addresses.length > 1)
                                      Wrap(
                                        spacing: Space.xs,
                                        runSpacing: Space.xs,
                                        children: [
                                          for (final addr in host.addresses)
                                            ChoiceChip(
                                              key: ValueKey('link-pairing-host-$addr'),
                                              visualDensity: VisualDensity.compact,
                                              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                              label: Text(
                                                '$addr:${pairing.port}',
                                                style: mono(context, theme.textTheme.labelSmall),
                                              ),
                                              selected: addr == pairing.host,
                                              onSelected: (_) => host.selectPairingHost(addr),
                                            ),
                                        ],
                                      )
                                    else
                                      SelectableText(
                                        '${pairing.host}:${pairing.port}',
                                        style: mono(context, theme.textTheme.bodySmall),
                                      ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                      const SizedBox(height: Space.lg),
                      Text(l.linkPairedDevices, style: theme.textTheme.titleSmall),
                      const SizedBox(height: Space.sm),
                      if (host.peers.isEmpty)
                        Text(l.linkNoPeers, style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant))
                      else
                        for (final peer in host.peers)
                          _PeerCard(
                            peer: peer,
                            online: host.connectedDeviceIds.contains(peer.deviceId),
                            onUpdatePermissions: (perms) => unawaited(host.updatePermissions(peer.deviceId, perms)),
                            onPushCredentials: () => unawaited(_pushCredentials(peer)),
                            onOfferUpdate: host.canOfferUpdate(peer.deviceId)
                                ? () => unawaited(_offerUpdate(peer))
                                : null,
                            onDisconnect: () => host.disconnectPeer(peer.deviceId),
                            onRevoke: () => unawaited(host.revokePeer(peer.deviceId)),
                          ),
                    ],
                  ),
                ),
              ),
              if (_notice != null) ...[
                const Divider(height: Space.lg),
                Text(
                  _notice!,
                  style: theme.textTheme.bodySmall?.copyWith(color: _noticeError ? scheme.error : scheme.primary),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _PeerCard extends StatelessWidget {
  const _PeerCard({
    required this.peer,
    required this.online,
    required this.onUpdatePermissions,
    required this.onPushCredentials,
    this.onOfferUpdate,
    required this.onDisconnect,
    required this.onRevoke,
  });

  final LinkPeer peer;
  final bool online;
  final ValueChanged<LinkPeerPermissions> onUpdatePermissions;
  final VoidCallback onPushCredentials;
  final VoidCallback? onOfferUpdate;
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
              Icon(Icons.smartphone_outlined, size: 18, color: online ? scheme.primary : scheme.onSurfaceVariant),
              const SizedBox(width: Space.sm),
              Expanded(
                child: Text(peer.name, style: Theme.of(context).textTheme.titleSmall, overflow: TextOverflow.ellipsis),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: Space.sm, vertical: 2),
                decoration: BoxDecoration(
                  color: (online ? scheme.primary : scheme.outline).withValues(alpha: .14),
                  borderRadius: BorderRadius.circular(Radii.pill),
                ),
                child: Text(
                  online ? l.linkOnline : l.linkOffline,
                  style: Theme.of(context).textTheme.labelSmall
                      ?.copyWith(color: online ? scheme.primary : scheme.onSurfaceVariant),
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
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                label: Text(l.linkPermMirror),
                selected: p.allowMirror,
                onSelected: (v) => onUpdatePermissions(p.copyWith(allowMirror: v)),
              ),
              FilterChip(
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                label: Text(l.linkPermProxy),
                selected: p.allowProxy,
                onSelected: (v) => onUpdatePermissions(p.copyWith(allowProxy: v)),
              ),
              FilterChip(
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                label: Text(l.files),
                selected: p.allowFiles,
                onSelected: (v) => onUpdatePermissions(p.copyWith(allowFiles: v)),
              ),
              FilterChip(
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                label: Text(l.linkPermSync),
                selected: p.allowSync,
                onSelected: (v) => onUpdatePermissions(p.copyWith(allowSync: v)),
              ),
              FilterChip(
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
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
              if (onOfferUpdate != null) TextButton(onPressed: onOfferUpdate, child: Text(l.linkOfferUpdate)),
              if (online) TextButton(onPressed: onDisconnect, child: Text(l.linkDisconnect)),
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

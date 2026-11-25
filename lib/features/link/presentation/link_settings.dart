import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../design/badges.dart';
import '../../../design/controls.dart';
import '../../../design/dialog.dart';
import '../../../design/form_field.dart';
import '../../../design/menu.dart';
import '../../../design/select.dart';
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
    final palette = BrandPalette.of(context);
    final settings = ref.watch(settingsProvider);
    _syncExternal(settings);
    final host = ref.watch(linkHostControllerProvider);
    final enabled = settings.get(SettingKeys.linkEnabled);
    final discovery = settings.get(SettingKeys.linkDiscovery);
    final savedName = settings.get(SettingKeys.linkDeviceName) ?? '';
    final portError = _parsedPort == null ? '1024–65535' : null;
    final muted = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);

    void copy(String text) {
      unawaited(Clipboard.setData(ClipboardData(text: text)));
      _showNotice(l.linkCopied);
    }

    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) unawaited(_flushPending());
      },
      child: ListenableBuilder(
        listenable: host,
        builder: (context, _) {
          final pairing = host.activePairing;
          final state = host.failed
              ? scheme.error
              : host.running
              ? palette.success
              : null;
          final heroFill = enabled ? toneFill(context, scheme.primary, scheme.surface) : scheme.surface;
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
                      _Card(
                        color: heroFill,
                        border: enabled ? scheme.primary.withValues(alpha: .28) : null,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            MergeSemantics(
                              child: InkWell(
                                borderRadius: BorderRadius.circular(Radii.control),
                                onTap: () => unawaited(_saveBool(SettingKeys.linkEnabled, !enabled)),
                                child: Row(
                                  children: [
                                    AppIconBadge(
                                      icon: Icons.phonelink_rounded,
                                      size: 44,
                                      tone: enabled ? scheme.primary : null,
                                      dot: state,
                                      ring: heroFill,
                                    ),
                                    const SizedBox(width: Space.md),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(l.linkEnabled, style: theme.textTheme.titleSmall),
                                          const SizedBox(height: 3),
                                          AppStatusLabel(
                                            label: host.failed
                                                ? l.linkStartFailed
                                                : host.running
                                                ? l.linkRunning(host.port)
                                                : l.linkStopped,
                                            color: state,
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
                            if (host.running && host.addresses.isNotEmpty) ...[
                              const SizedBox(height: Space.md),
                              Padding(
                                padding: const EdgeInsets.only(left: 44 + Space.md),
                                child: Wrap(
                                  spacing: 6,
                                  runSpacing: 6,
                                  children: [
                                    for (final addr in host.addresses)
                                      _AddressChip(
                                        address: '$addr:${host.port}',
                                        onCopy: () => copy('$addr:${host.port}'),
                                      ),
                                  ],
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(height: Space.md),
                      _Card(
                        padding: const EdgeInsets.fromLTRB(Space.lg, Space.lg, Space.lg, Space.sm),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
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
                            Divider(height: 1, color: scheme.outlineVariant.withValues(alpha: .6)),
                            _SwitchRow(
                              switchKey: const ValueKey('link-discovery-switch'),
                              icon: Icons.wifi_tethering_rounded,
                              title: l.linkDiscovery,
                              value: discovery,
                              onChanged: (v) => unawaited(_saveBool(SettingKeys.linkDiscovery, v)),
                            ),
                          ],
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(Space.xs, Space.xl, 0, Space.sm),
                        child: Row(
                          children: [
                            Expanded(
                              child: Row(
                                children: [
                                  Flexible(
                                    child: Text(
                                      l.linkPairedDevices,
                                      style: theme.textTheme.titleSmall,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  if (host.peers.isNotEmpty) ...[
                                    const SizedBox(width: Space.sm),
                                    AppTag(label: '${host.peers.length}'),
                                  ],
                                ],
                              ),
                            ),
                            const SizedBox(width: Space.sm),
                            if (pairing != null)
                              TextButton.icon(
                                key: const ValueKey('link-pair-button'),
                                onPressed: host.cancelPairing,
                                icon: const Icon(Icons.close, size: 16),
                                label: Text(l.linkCancelPairing),
                              )
                            else
                              FilledButton.icon(
                                key: const ValueKey('link-pair-button'),
                                onPressed: host.running ? () => unawaited(host.startPairing()) : null,
                                icon: const Icon(Icons.qr_code_2_rounded, size: 16),
                                label: Text(l.linkPairDevice),
                              ),
                          ],
                        ),
                      ),
                      AnimatedSize(
                        duration: Motion.of(context, Motion.panel),
                        curve: Motion.move,
                        alignment: Alignment.topCenter,
                        child: pairing == null
                            ? const SizedBox(width: double.infinity)
                            : Padding(
                                padding: const EdgeInsets.only(bottom: Space.md),
                                child: _PairingCard(
                                  key: const ValueKey('link-pairing-card'),
                                  pairing: pairing,
                                  addresses: host.addresses,
                                  onSelectHost: host.selectPairingHost,
                                  onCopy: () => copy(pairing.toUri()),
                                ),
                              ),
                      ),
                      if (host.peers.isEmpty && pairing == null)
                        _Card(
                          padding: const EdgeInsets.symmetric(horizontal: Space.lg, vertical: Space.xl),
                          child: Column(
                            children: [
                              const AppIconBadge(icon: Icons.devices_other_rounded, size: 44),
                              const SizedBox(height: Space.md),
                              Text(l.linkNoPeers, style: muted, textAlign: TextAlign.center),
                            ],
                          ),
                        )
                      else
                        for (final (i, peer) in host.peers.indexed) ...[
                          if (i > 0) const SizedBox(height: Space.sm),
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
                    ],
                  ),
                ),
              ),
              if (_notice != null)
                Padding(
                  padding: const EdgeInsets.only(top: Space.md),
                  child: Row(
                    children: [
                      Icon(
                        _noticeError ? Icons.error_outline_rounded : Icons.check_circle_outline_rounded,
                        size: 14,
                        color: _noticeError ? scheme.error : scheme.primary,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          _notice!,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: _noticeError ? scheme.error : scheme.primary,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// A block on the flyout; [color] and [border] tint it for a live or highlighted state.
class _Card extends StatelessWidget {
  const _Card({required this.child, this.color, this.border, this.padding = const EdgeInsets.all(Space.lg)});

  final Widget child;
  final Color? color, border;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AnimatedContainer(
      duration: Motion.of(context, Motion.normal),
      curve: Motion.move,
      padding: padding,
      decoration: BoxDecoration(
        color: color ?? scheme.surface,
        borderRadius: BorderRadius.circular(Radii.card),
        border: Border.all(color: border ?? scheme.outlineVariant.withValues(alpha: .6)),
      ),
      child: child,
    );
  }
}

/// An icon, a title and a switch; the whole row toggles.
class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.switchKey,
    required this.icon,
    required this.title,
    required this.value,
    required this.onChanged,
  });

  final Key switchKey;
  final IconData icon;
  final String title;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => MergeSemantics(
    child: InkWell(
      borderRadius: BorderRadius.circular(Radii.control),
      onTap: () => onChanged(!value),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: Space.sm + 2),
        child: Row(
          children: [
            Icon(icon, size: 18, color: Theme.of(context).colorScheme.onSurfaceVariant),
            const SizedBox(width: Space.md),
            Expanded(child: Text(title)),
            const SizedBox(width: Space.md),
            AppSwitch(key: switchKey, value: value, onChanged: onChanged),
          ],
        ),
      ),
    ),
  );
}

/// One local address in a pill; tapping copies it.
class _AddressChip extends StatelessWidget {
  const _AddressChip({required this.address, required this.onCopy});

  final String address;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Tooltip(
      message: AppLocalizations.of(context).copy,
      child: Material(
        type: MaterialType.transparency,
        child: Ink(
          decoration: BoxDecoration(
            color: scheme.surface.withValues(alpha: .75),
            borderRadius: BorderRadius.circular(Radii.pill),
            border: Border.all(color: scheme.outlineVariant.withValues(alpha: .7)),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(Radii.pill),
            onTap: onCopy,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: Space.xs),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(address, style: mono(context, theme.textTheme.bodySmall)),
                  const SizedBox(width: 6),
                  Icon(Icons.copy_rounded, size: 12, color: scheme.onSurfaceVariant),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The live pairing offer: QR, the spaced code, the time it has left and the address it advertises.
class _PairingCard extends StatelessWidget {
  const _PairingCard({
    super.key,
    required this.pairing,
    required this.addresses,
    required this.onSelectHost,
    required this.onCopy,
  });

  final LinkPairingInfo pairing;
  final List<String> addresses;
  final ValueChanged<String> onSelectHost;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    return _Card(
      color: toneFill(context, scheme.primary, scheme.surface, strength: .8),
      border: scheme.primary.withValues(alpha: .3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LinkQrCodeView(key: const ValueKey('link-pairing-qr'), data: pairing.toUri(), size: 116),
          const SizedBox(width: Space.lg),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l.linkPairingCode, style: muted),
                SelectableText(
                  '${pairing.code.substring(0, 3)} ${pairing.code.substring(3)}',
                  key: const ValueKey('link-pairing-code'),
                  maxLines: 1,
                  style: mono(
                    context,
                    theme.textTheme.headlineMedium,
                  ).copyWith(letterSpacing: 4, fontWeight: FontWeight.w700, color: scheme.primary),
                ),
                const SizedBox(height: Space.xs),
                _PairingCountdown(expiresAt: pairing.expiresAt),
                const SizedBox(height: Space.md),
                if (addresses.length > 1)
                  AppSelect<String>(
                    key: const ValueKey('link-pairing-host'),
                    value: pairing.host,
                    options: [
                      for (final addr in addresses)
                        AppOption(addr, '$addr:${pairing.port}', style: mono(context, theme.textTheme.bodySmall)),
                    ],
                    onChanged: onSelectHost,
                  )
                else
                  SelectableText('${pairing.host}:${pairing.port}', style: mono(context, muted)),
                const SizedBox(height: Space.xs),
                TextButton.icon(
                  key: const ValueKey('link-copy-uri'),
                  style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: Space.sm)),
                  onPressed: onCopy,
                  icon: const Icon(Icons.link_rounded, size: 16),
                  label: Text(l.linkCopyUri),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A draining bar and m:ss until the pairing code expires.
class _PairingCountdown extends StatefulWidget {
  const _PairingCountdown({required this.expiresAt});

  final DateTime expiresAt;

  @override
  State<_PairingCountdown> createState() => _PairingCountdownState();
}

class _PairingCountdownState extends State<_PairingCountdown> {
  late final Timer _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _tick.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final total = LinkHostController.pairingLifetime.inSeconds;
    final left = widget.expiresAt.difference(DateTime.now()).inSeconds.clamp(0, total);
    return Row(
      children: [
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(Radii.pill),
            child: Container(
              height: 4,
              color: scheme.primary.withValues(alpha: .16),
              child: AnimatedFractionallySizedBox(
                duration: Motion.of(context, const Duration(seconds: 1)),
                alignment: Alignment.centerLeft,
                widthFactor: left / total,
                child: ColoredBox(color: scheme.primary),
              ),
            ),
          ),
        ),
        const SizedBox(width: Space.sm),
        Text(
          '${left ~/ 60}:${(left % 60).toString().padLeft(2, '0')}',
          style: mono(context, theme.textTheme.bodySmall).copyWith(color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

enum _PeerAction { pushCredentials, offerUpdate, disconnect, revoke }

/// A paired phone: who it is, whether it is here, its menu, and one chip per permission.
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

  void _run(_PeerAction action) {
    switch (action) {
      case _PeerAction.pushCredentials:
        onPushCredentials();
      case _PeerAction.offerUpdate:
        onOfferUpdate?.call();
      case _PeerAction.disconnect:
        onDisconnect();
      case _PeerAction.revoke:
        onRevoke();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final success = BrandPalette.of(context).success;
    final p = peer.permissions;
    final permissions = <(IconData, String, bool, LinkPeerPermissions Function(bool))>[
      (Icons.screen_share_outlined, l.linkPermMirror, p.allowMirror, (v) => p.copyWith(allowMirror: v)),
      (Icons.hub_outlined, l.linkPermProxy, p.allowProxy, (v) => p.copyWith(allowProxy: v)),
      (Icons.folder_outlined, l.files, p.allowFiles, (v) => p.copyWith(allowFiles: v)),
      (Icons.sync_rounded, l.linkPermSync, p.allowSync, (v) => p.copyWith(allowSync: v)),
      (Icons.verified_user_outlined, l.linkPermApproval, p.allowApproval, (v) => p.copyWith(allowApproval: v)),
    ];
    return _Card(
      padding: const EdgeInsets.fromLTRB(Space.md, Space.md, Space.sm, Space.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              AppIconBadge(
                icon: Icons.smartphone_rounded,
                tone: online ? scheme.primary : null,
                dot: online ? success : null,
              ),
              const SizedBox(width: Space.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(peer.name, style: theme.textTheme.titleSmall, overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 2),
                    AppStatusLabel(label: online ? l.linkOnline : l.linkOffline, color: online ? success : null),
                  ],
                ),
              ),
              AppMenuButton<_PeerAction>(
                tooltip: l.more,
                items: () => [
                  if (online)
                    AppMenuItem(
                      value: _PeerAction.pushCredentials,
                      label: l.linkPushCredentials,
                      icon: Icons.key_outlined,
                    ),
                  if (onOfferUpdate != null)
                    AppMenuItem(
                      value: _PeerAction.offerUpdate,
                      label: l.linkOfferUpdate,
                      icon: Icons.system_update_outlined,
                    ),
                  if (online) AppMenuItem(value: _PeerAction.disconnect, label: l.linkDisconnect, icon: Icons.link_off),
                  if (online || onOfferUpdate != null) const AppMenuDivider(),
                  AppMenuItem(
                    value: _PeerAction.revoke,
                    label: l.linkRevoke,
                    icon: Icons.delete_outline,
                    destructive: true,
                  ),
                ],
                onSelected: _run,
              ),
            ],
          ),
          const SizedBox(height: Space.md),
          Padding(
            padding: const EdgeInsets.only(right: Space.xs),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final (icon, label, value, update) in permissions)
                  AppToggleChip(
                    icon: icon,
                    label: label,
                    value: value,
                    onChanged: (v) => onUpdatePermissions(update(v)),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

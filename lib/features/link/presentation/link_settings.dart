import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
                      _SwitchRow(
                        switchKey: const ValueKey('link-enabled-switch'),
                        title: l.linkEnabled,
                        value: enabled,
                        onChanged: (v) => unawaited(_saveBool(SettingKeys.linkEnabled, v)),
                        status: _Status(
                          label: host.failed
                              ? l.linkStartFailed
                              : host.running
                              ? l.linkRunning(host.port)
                              : l.linkStopped,
                          color: host.failed
                              ? scheme.error
                              : host.running
                              ? scheme.primary
                              : null,
                          error: host.failed,
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
                      const SizedBox(height: Space.sm),
                      _SwitchRow(
                        switchKey: const ValueKey('link-discovery-switch'),
                        title: l.linkDiscovery,
                        value: discovery,
                        onChanged: (v) => unawaited(_saveBool(SettingKeys.linkDiscovery, v)),
                      ),
                      if (host.running && host.addresses.isNotEmpty) ...[
                        const SizedBox(height: Space.md),
                        Text(l.linkAddresses, style: muted),
                        const SizedBox(height: Space.xs),
                        for (final addr in host.addresses)
                          _AddressRow(address: '$addr:${host.port}', onCopy: () => copy('$addr:${host.port}')),
                      ],
                      const Divider(height: Space.xxl),
                      Row(
                        children: [
                          Expanded(child: Text(l.linkPairedDevices, style: theme.textTheme.titleSmall)),
                          TextButton.icon(
                            key: const ValueKey('link-pair-button'),
                            style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: Space.sm)),
                            onPressed: host.running
                                ? () {
                                    if (pairing != null) {
                                      host.cancelPairing();
                                    } else {
                                      unawaited(host.startPairing());
                                    }
                                  }
                                : null,
                            icon: Icon(pairing != null ? Icons.close : Icons.add, size: 16),
                            label: Text(pairing != null ? l.linkCancelPairing : l.linkPairDevice),
                          ),
                        ],
                      ),
                      if (pairing != null) ...[
                        const SizedBox(height: Space.sm),
                        Row(
                          key: const ValueKey('link-pairing-card'),
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            LinkQrCodeView(key: const ValueKey('link-pairing-qr'), data: pairing.toUri(), size: 132),
                            const SizedBox(width: Space.lg),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(l.linkPairingCode, style: muted),
                                  const SizedBox(height: Space.xs),
                                  SelectableText(
                                    '${pairing.code.substring(0, 3)} ${pairing.code.substring(3)}',
                                    key: const ValueKey('link-pairing-code'),
                                    style: mono(
                                      context,
                                      theme.textTheme.headlineMedium,
                                    ).copyWith(letterSpacing: 4, fontWeight: FontWeight.w700, color: scheme.primary),
                                  ),
                                  const SizedBox(height: Space.sm),
                                  if (host.addresses.length > 1)
                                    AppSelect<String>(
                                      key: const ValueKey('link-pairing-host'),
                                      value: pairing.host,
                                      options: [
                                        for (final addr in host.addresses)
                                          AppOption(
                                            addr,
                                            '$addr:${pairing.port}',
                                            style: mono(context, theme.textTheme.bodySmall),
                                          ),
                                      ],
                                      onChanged: host.selectPairingHost,
                                    )
                                  else
                                    SelectableText('${pairing.host}:${pairing.port}', style: mono(context, muted)),
                                  const SizedBox(height: Space.xs),
                                  TextButton.icon(
                                    key: const ValueKey('link-copy-uri'),
                                    style: TextButton.styleFrom(
                                      padding: const EdgeInsets.symmetric(horizontal: Space.sm),
                                    ),
                                    onPressed: () => copy(pairing.toUri()),
                                    icon: const Icon(Icons.copy_outlined, size: 16),
                                    label: Text(l.linkCopyUri),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: Space.md),
                      ],
                      if (host.peers.isEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: Space.sm),
                          child: Text(l.linkNoPeers, style: muted),
                        )
                      else
                        for (final (i, peer) in host.peers.indexed) ...[
                          if (i > 0) const Divider(height: Space.lg),
                          _PeerTile(
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

/// A title, an optional status line under it, and a switch; the whole row toggles.
class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.switchKey,
    required this.title,
    required this.value,
    required this.onChanged,
    this.status,
  });

  final Key switchKey;
  final String title;
  final bool value;
  final ValueChanged<bool> onChanged;
  final Widget? status;

  @override
  Widget build(BuildContext context) => MergeSemantics(
    child: InkWell(
      borderRadius: BorderRadius.circular(Radii.control),
      onTap: () => onChanged(!value),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: Space.xs),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title),
                  if (status != null) ...[const SizedBox(height: 2), status!],
                ],
              ),
            ),
            const SizedBox(width: Space.md),
            AppSwitch(key: switchKey, value: value, onChanged: onChanged),
          ],
        ),
      ),
    ),
  );
}

/// A dot and a short label: filled in [color], or hollow when there is none.
class _Status extends StatelessWidget {
  const _Status({required this.label, this.color, this.error = false});

  final String label;
  final Color? color;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Text.rich(
      TextSpan(
        children: [
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: Padding(
              padding: const EdgeInsets.only(right: Space.xs),
              child: Icon(
                color == null ? Icons.circle_outlined : Icons.circle,
                size: 8,
                color: color ?? scheme.outline,
              ),
            ),
          ),
          TextSpan(text: label),
        ],
      ),
      style: theme.textTheme.bodySmall?.copyWith(color: error ? scheme.error : scheme.onSurfaceVariant),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}

/// One local address; tapping copies it.
class _AddressRow extends StatelessWidget {
  const _AddressRow({required this.address, required this.onCopy});

  final String address;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Tooltip(
      message: AppLocalizations.of(context).copy,
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.control),
        onTap: onCopy,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: Space.xs),
          child: Row(
            children: [
              Expanded(
                child: Text(address, style: mono(context, theme.textTheme.bodyMedium), overflow: TextOverflow.ellipsis),
              ),
              Icon(Icons.copy_outlined, size: 14, color: theme.colorScheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}

enum _PeerAction { pushCredentials, offerUpdate, disconnect, revoke }

class _PeerTile extends StatelessWidget {
  const _PeerTile({
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
    final p = peer.permissions;
    final permissions = <(String, bool, LinkPeerPermissions Function(bool))>[
      (l.linkPermMirror, p.allowMirror, (v) => p.copyWith(allowMirror: v)),
      (l.linkPermProxy, p.allowProxy, (v) => p.copyWith(allowProxy: v)),
      (l.files, p.allowFiles, (v) => p.copyWith(allowFiles: v)),
      (l.linkPermSync, p.allowSync, (v) => p.copyWith(allowSync: v)),
      (l.linkPermApproval, p.allowApproval, (v) => p.copyWith(allowApproval: v)),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(Icons.smartphone_outlined, size: 18, color: scheme.onSurfaceVariant),
            const SizedBox(width: Space.sm),
            Expanded(
              child: Text(peer.name, style: theme.textTheme.titleSmall, overflow: TextOverflow.ellipsis),
            ),
            const SizedBox(width: Space.sm),
            _Status(label: online ? l.linkOnline : l.linkOffline, color: online ? scheme.primary : null),
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
        Padding(
          padding: const EdgeInsets.only(left: 18 + Space.sm),
          child: Column(
            children: [
              for (var i = 0; i < permissions.length; i += 2)
                Row(
                  children: [
                    for (final (label, value, update) in permissions.skip(i).take(2))
                      Expanded(
                        child: _PermissionToggle(
                          label: label,
                          value: value,
                          onChanged: (v) => onUpdatePermissions(update(v)),
                        ),
                      ),
                    if (i + 1 == permissions.length) const Spacer(),
                  ],
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _PermissionToggle extends StatelessWidget {
  const _PermissionToggle({required this.label, required this.value, required this.onChanged});

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => MergeSemantics(
    child: InkWell(
      borderRadius: BorderRadius.circular(Radii.control),
      onTap: () => onChanged(!value),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: Space.xs + 2),
        child: Row(
          children: [
            AppCheckbox(value: value, onChanged: onChanged),
            const SizedBox(width: Space.sm),
            Flexible(child: Text(label, overflow: TextOverflow.ellipsis)),
          ],
        ),
      ),
    ),
  );
}

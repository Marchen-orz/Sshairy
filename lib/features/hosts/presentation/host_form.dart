import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../design/side_drawer.dart';
import '../../../design/theme.dart';
import '../../../l10n/app_localizations.dart';
import '../../../foundation/ids.dart';
import '../../credentials/api.dart';
import '../application/hosts.dart';
import '../domain/host.dart';
import 'keys_panel.dart';

class HostForm extends ConsumerStatefulWidget {
  const HostForm({super.key, this.host, this.group = ''});

  final Host? host;

  /// Where a new host goes: the group the vault is showing.
  final String group;

  @override
  ConsumerState<HostForm> createState() => _HostFormState();
}

class _HostFormState extends ConsumerState<HostForm> {
  final _form = GlobalKey<FormState>();
  bool _saving = false;
  String? _error;
  late final _label = TextEditingController(text: widget.host?.label);
  late final _address = TextEditingController(text: widget.host?.address);
  late final _port = TextEditingController(text: '${widget.host?.port ?? 22}');
  late final _username = TextEditingController(text: widget.host?.username);
  late final _keyPath = TextEditingController(text: widget.host?.keyPath);
  late final _group = TextEditingController(
    text: widget.host?.group ?? widget.group,
  );
  final _groupFocus = FocusNode();
  late final _tags = TextEditingController(text: widget.host?.tags.join(', '));
  late HostId? _jump = widget.host?.jumpHostId;
  late ProxyKind? _proxyKind = widget.host?.proxy?.kind;
  late final _proxyAddress = TextEditingController(
    text: widget.host?.proxy?.address,
  );
  late final _proxyPort = TextEditingController(
    text: '${widget.host?.proxy?.port ?? 1080}',
  );
  late final _proxyUser = TextEditingController(
    text: widget.host?.proxy?.username,
  );
  late bool _legacy = widget.host?.legacy ?? false;
  late var _auth = widget.host?.auth ?? AuthKind.password;

  /// An imported key's ID, or null for a key file.
  late String? _keyId = widget.host?.keyId;

  @override
  void dispose() {
    for (final c in [
      _label,
      _address,
      _port,
      _username,
      _keyPath,
      _group,
      _tags,
      _proxyAddress,
      _proxyPort,
      _proxyUser,
    ]) {
      c.dispose();
    }
    _groupFocus.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving || !_form.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    final useKey = _auth == AuthKind.key;
    final old = widget.host;
    try {
      await ref
          .read(hostsProvider.notifier)
          .save(
            Host(
              id: old?.id ?? HostsNotifier.newId(),
              label: _label.text.trim(),
              address: _address.text.trim(),
              port: int.parse(_port.text),
              username: _username.text.trim(),
              auth: _auth,
              keyPath: useKey && _keyId == null ? _keyPath.text.trim() : null,
              keyId: useKey ? _keyId : null,
              group: normalizeGroup(_group.text),
              tags: parseTags(_tags.text),
              pinned: old?.pinned ?? false,
              lastUsed: old?.lastUsed,
              jumpHostId: _jump,
              proxy: _jump == null && _proxyKind != null
                  ? Proxy(
                      _proxyKind!,
                      _proxyAddress.text.trim(),
                      int.parse(_proxyPort.text),
                      username: _proxyUser.text.trim(),
                    )
                  : null,
              legacy: _legacy,
            ),
          );
      if (mounted) Navigator.pop(context);
    } on ArgumentError {
      if (mounted) {
        setState(() => _error = AppLocalizations.of(context).errRouteInvalid);
      }
    } on Object {
      if (mounted) {
        setState(() => _error = AppLocalizations.of(context).errHostSave);
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final keys = ref.watch(keysProvider);
    final hosts = ref.watch(hostsProvider);
    final groups = allGroups(hosts);
    // A key deleted elsewhere falls back to the file field rather than an empty dropdown.
    if (_keyId != null && keys.every((k) => k.id != _keyId)) _keyId = null;
    String? required(String? v) =>
        v == null || v.trim().isEmpty ? l.required : null;
    Widget field(
      String label,
      TextEditingController c, {
      String? Function(String?)? validator,
      bool autofocus = false,
      String? hint,
    }) => TextFormField(
      controller: c,
      autofocus: autofocus,
      validator: validator,
      decoration: InputDecoration(labelText: label, hintText: hint),
    );
    const gap = SizedBox(height: Space.lg);
    return Form(
      key: _form,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: ListView(
              children: [
                field(l.label, _label, autofocus: true),
                gap,
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: field(l.address, _address, validator: required),
                    ),
                    const SizedBox(width: Space.md),
                    SizedBox(
                      width: 96,
                      child: field(
                        l.port,
                        _port,
                        validator: (v) {
                          final port = int.tryParse(v ?? '');
                          return port == null || port < 1 || port > 65535
                              ? l.invalidPort
                              : null;
                        },
                      ),
                    ),
                  ],
                ),
                gap,
                field(l.username, _username, validator: required),
                gap,
                SegmentedButton<AuthKind>(
                  showSelectedIcon: false,
                  segments: [
                    ButtonSegment(
                      value: AuthKind.password,
                      label: Text(l.password),
                    ),
                    ButtonSegment(
                      value: AuthKind.key,
                      label: Text(l.privateKey),
                    ),
                  ],
                  selected: {_auth},
                  onSelectionChanged: (s) => setState(() => _auth = s.single),
                ),
                if (_auth == AuthKind.key) ...[
                  gap,
                  Row(
                    children: [
                      Expanded(
                        child: DropdownButtonFormField<String?>(
                          initialValue: _keyId,
                          decoration: InputDecoration(labelText: l.privateKey),
                          items: [
                            for (final k in keys)
                              DropdownMenuItem(
                                value: k.id,
                                child: Text('${k.label} · ${k.algorithm}'),
                              ),
                            DropdownMenuItem(
                              value: null,
                              child: Text(l.keyFile),
                            ),
                          ],
                          onChanged: (v) => setState(() => _keyId = v),
                        ),
                      ),
                      IconButton(
                        tooltip: l.keys,
                        onPressed: () => showSideDrawer<void>(
                          context,
                          (_) => const KeysPanel(),
                        ),
                        icon: const Icon(Icons.key_outlined, size: 20),
                      ),
                    ],
                  ),
                  if (_keyId == null) ...[
                    gap,
                    field(l.keyPath, _keyPath, validator: required),
                  ],
                ],
                gap,
                Autocomplete<String>(
                  textEditingController: _group,
                  focusNode: _groupFocus,
                  optionsBuilder: (v) => groups.where(
                    (g) => g.toLowerCase().contains(v.text.toLowerCase()),
                  ),
                  fieldViewBuilder: (context, controller, focus, onSubmit) =>
                      TextFormField(
                        controller: controller,
                        focusNode: focus,
                        decoration: InputDecoration(
                          labelText: l.group,
                          hintText: 'prod/web',
                        ),
                      ),
                ),
                gap,
                field(l.tags, _tags, hint: l.tagsHint),
                gap,
                ExpansionTile(
                  title: Text(l.route),
                  tilePadding: EdgeInsets.zero,
                  initiallyExpanded:
                      _jump != null || _proxyKind != null || _legacy,
                  children: [
                    DropdownButtonFormField<HostId>(
                      initialValue: _jump,
                      isExpanded: true,
                      decoration: InputDecoration(labelText: l.jumpHost),
                      items: [
                        DropdownMenuItem(
                          value: null,
                          child: Text(l.directConnection),
                        ),
                        if (_jump != null &&
                            (_jump == widget.host?.id ||
                                hosts.every((h) => h.id != _jump)))
                          DropdownMenuItem(
                            value: _jump,
                            child: Text(l.errRouteMissing),
                          ),
                        for (final h in hosts.where(
                          (h) => h.id != widget.host?.id,
                        ))
                          DropdownMenuItem(
                            value: h.id,
                            child: Text(
                              h.title,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: (v) => setState(() => _jump = v),
                    ),
                    if (_jump == null) ...[
                      gap,
                      DropdownButtonFormField<ProxyKind>(
                        initialValue: _proxyKind,
                        decoration: InputDecoration(labelText: l.proxy),
                        items: [
                          DropdownMenuItem(
                            value: null,
                            child: Text(l.directConnection),
                          ),
                          const DropdownMenuItem(
                            value: ProxyKind.socks5,
                            child: Text('SOCKS5'),
                          ),
                          const DropdownMenuItem(
                            value: ProxyKind.http,
                            child: Text('HTTP CONNECT'),
                          ),
                        ],
                        onChanged: (v) => setState(() => _proxyKind = v),
                      ),
                      if (_proxyKind != null) ...[
                        gap,
                        field(
                          l.proxyAddress,
                          _proxyAddress,
                          validator: required,
                        ),
                        gap,
                        field(
                          l.port,
                          _proxyPort,
                          validator: (v) {
                            final port = int.tryParse(v ?? '');
                            return port == null || port < 1 || port > 65535
                                ? l.invalidPort
                                : null;
                          },
                        ),
                        gap,
                        field(l.proxyUser, _proxyUser),
                      ],
                    ],
                    gap,
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(l.legacyAlgorithms),
                      subtitle: Text(l.legacyAlgorithmsHint),
                      value: _legacy,
                      onChanged: (v) => setState(() => _legacy = v),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (_error != null)
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          const SizedBox(height: Space.lg),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(l.cancel),
              ),
              const SizedBox(width: Space.sm),
              FilledButton(
                onPressed: _saving ? null : _save,
                child: Text(l.save),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

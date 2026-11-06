import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../design/side_drawer.dart';
import '../../../design/theme.dart';
import '../../../l10n/app_localizations.dart';
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
  late final _label = TextEditingController(text: widget.host?.label);
  late final _address = TextEditingController(text: widget.host?.address);
  late final _port = TextEditingController(text: '${widget.host?.port ?? 22}');
  late final _username = TextEditingController(text: widget.host?.username);
  late final _keyPath = TextEditingController(text: widget.host?.keyPath);
  late final _group = TextEditingController(text: widget.host?.group ?? widget.group);
  final _groupFocus = FocusNode();
  late final _tags = TextEditingController(text: widget.host?.tags.join(', '));
  late var _auth = widget.host?.auth ?? AuthKind.password;

  /// An imported key's ID, or null for a key file.
  late String? _keyId = widget.host?.keyId;

  @override
  void dispose() {
    for (final c in [_label, _address, _port, _username, _keyPath, _group, _tags]) {
      c.dispose();
    }
    _groupFocus.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    final useKey = _auth == AuthKind.key;
    final old = widget.host;
    await ref.read(hostsProvider.notifier).save(Host(
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
        ));
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final keys = ref.watch(keysProvider);
    final groups = allGroups(ref.watch(hostsProvider));
    // A key deleted elsewhere falls back to the file field rather than an empty dropdown.
    if (_keyId != null && keys.every((k) => k.id != _keyId)) _keyId = null;
    String? required(String? v) => v == null || v.trim().isEmpty ? l.required : null;
    Widget field(String label, TextEditingController c,
            {String? Function(String?)? validator, bool autofocus = false, String? hint}) =>
        TextFormField(
          controller: c,
          autofocus: autofocus,
          validator: validator,
          decoration: InputDecoration(labelText: label, hintText: hint),
        );
    const gap = SizedBox(height: Space.lg);
    return Form(
      key: _form,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Expanded(
          child: ListView(children: [
            field(l.label, _label, autofocus: true),
            gap,
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: field(l.address, _address, validator: required)),
              const SizedBox(width: Space.md),
              SizedBox(
                width: 96,
                child: field(l.port, _port, validator: (v) {
                  final port = int.tryParse(v ?? '');
                  return port == null || port < 1 || port > 65535 ? l.invalidPort : null;
                }),
              ),
            ]),
            gap,
            field(l.username, _username, validator: required),
            gap,
            SegmentedButton<AuthKind>(
              showSelectedIcon: false,
              segments: [
                ButtonSegment(value: AuthKind.password, label: Text(l.password)),
                ButtonSegment(value: AuthKind.key, label: Text(l.privateKey)),
              ],
              selected: {_auth},
              onSelectionChanged: (s) => setState(() => _auth = s.single),
            ),
            if (_auth == AuthKind.key) ...[
              gap,
              Row(children: [
                Expanded(
                  child: DropdownButtonFormField<String?>(
                    initialValue: _keyId,
                    decoration: InputDecoration(labelText: l.privateKey),
                    items: [
                      for (final k in keys) DropdownMenuItem(value: k.id, child: Text('${k.label} · ${k.algorithm}')),
                      DropdownMenuItem(value: null, child: Text(l.keyFile)),
                    ],
                    onChanged: (v) => setState(() => _keyId = v),
                  ),
                ),
                IconButton(
                  tooltip: l.keys,
                  onPressed: () => showSideDrawer<void>(context, (_) => const KeysPanel()),
                  icon: const Icon(Icons.key_outlined, size: 20),
                ),
              ]),
              if (_keyId == null) ...[
                gap,
                field(l.keyPath, _keyPath, validator: required),
              ],
            ],
            gap,
            Autocomplete<String>(
              textEditingController: _group,
              focusNode: _groupFocus,
              optionsBuilder: (v) => groups.where((g) => g.toLowerCase().contains(v.text.toLowerCase())),
              fieldViewBuilder: (context, controller, focus, onSubmit) => TextFormField(
                controller: controller,
                focusNode: focus,
                decoration: InputDecoration(labelText: l.group, hintText: 'prod/web'),
              ),
            ),
            gap,
            field(l.tags, _tags, hint: l.tagsHint),
          ]),
        ),
        const SizedBox(height: Space.lg),
        Row(mainAxisAlignment: MainAxisAlignment.end, children: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(l.cancel)),
          const SizedBox(width: Space.sm),
          FilledButton(onPressed: _save, child: Text(l.save)),
        ]),
      ]),
    );
  }
}

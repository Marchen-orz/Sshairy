import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../design/theme.dart';
import '../../../l10n/app_localizations.dart';
import '../application/hosts.dart';
import '../domain/host.dart';

class HostForm extends ConsumerStatefulWidget {
  const HostForm({super.key, this.host});

  final Host? host;

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
  late var _auth = widget.host?.auth ?? AuthKind.password;

  @override
  void dispose() {
    for (final c in [_label, _address, _port, _username, _keyPath]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    await ref.read(hostsProvider.notifier).save(Host(
          id: widget.host?.id ?? HostsNotifier.newId(),
          label: _label.text.trim(),
          address: _address.text.trim(),
          port: int.parse(_port.text),
          username: _username.text.trim(),
          auth: _auth,
          keyPath: _auth == AuthKind.key ? _keyPath.text.trim() : null,
        ));
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    String? required(String? v) => v == null || v.trim().isEmpty ? l.required : null;
    Widget field(String label, TextEditingController c, {String? Function(String?)? validator, bool autofocus = false}) =>
        TextFormField(
          controller: c,
          autofocus: autofocus,
          validator: validator,
          decoration: InputDecoration(labelText: label),
        );
    const gap = SizedBox(height: Space.lg);
    return Form(
      key: _form,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
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
          field(l.keyPath, _keyPath, validator: required),
        ],
        const Spacer(),
        Row(mainAxisAlignment: MainAxisAlignment.end, children: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(l.cancel)),
          const SizedBox(width: Space.sm),
          FilledButton(onPressed: _save, child: Text(l.save)),
        ]),
      ]),
    );
  }
}

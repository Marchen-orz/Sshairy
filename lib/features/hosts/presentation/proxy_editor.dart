import 'package:flutter/material.dart';

import '../../../design/select.dart';
import '../../../l10n/app_localizations.dart';
import '../domain/host.dart';
import 'form_parts.dart';

class ProxyEditor extends StatefulWidget {
  const ProxyEditor({super.key, this.initial, this.enabled = true, this.onInvalid});

  final Proxy? initial;
  final bool enabled;
  final VoidCallback? onInvalid;

  @override
  State<ProxyEditor> createState() => ProxyEditorState();
}

class ProxyEditorState extends State<ProxyEditor> {
  late ProxyKind? _kind = widget.initial?.kind;
  late final _address = TextEditingController(text: widget.initial?.address);
  late final _portField = TextEditingController(text: '${widget.initial?.port ?? 1080}');
  late final _user = TextEditingController(text: widget.initial?.username);

  @override
  void dispose() {
    _address.dispose();
    _portField.dispose();
    _user.dispose();
    super.dispose();
  }

  String? _checked(String? error) {
    if (error != null) widget.onInvalid?.call();
    return error;
  }

  Proxy? get value => _kind == null
      ? null
      : Proxy(_kind!, _address.text.trim(), int.parse(_portField.text), username: _user.text.trim());

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final enabled = widget.enabled;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppSelect<ProxyKind?>(
          value: _kind,
          label: l.proxy,
          options: [
            AppOption(null, l.directConnection),
            const AppOption(ProxyKind.socks5, 'SOCKS5'),
            const AppOption(ProxyKind.http, 'HTTP CONNECT'),
          ],
          onChanged: enabled ? (v) => setState(() => _kind = v) : null,
        ),
        if (_kind != null) ...[
          formGap,
          TextFormField(
            controller: _address,
            enabled: enabled,
            validator: (v) => enabled ? _checked(requiredField(l, v)) : null,
            decoration: InputDecoration(labelText: l.proxyAddress),
          ),
          formGap,
          TextFormField(
            controller: _portField,
            enabled: enabled,
            validator: (v) => enabled ? _checked(portField(l, v)) : null,
            decoration: InputDecoration(labelText: l.port),
          ),
          formGap,
          TextFormField(
            controller: _user,
            enabled: enabled,
            decoration: InputDecoration(labelText: l.proxyUser),
          ),
        ],
      ],
    );
  }
}

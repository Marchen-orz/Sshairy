import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../design/controls.dart';
import '../../../design/select.dart';
import '../../../design/side_drawer.dart';
import '../../../design/theme.dart';
import '../../../l10n/app_localizations.dart';
import '../../../platform/file_drop.dart';
import '../../../platform/local_paths.dart';
import '../../credentials/api.dart';
import '../domain/host.dart';
import '../domain/host_library.dart';
import 'form_parts.dart';
import 'keys_panel.dart';

enum _AuthMode { password, key, keyPassword }

/// Username and the way to authenticate it: shared by hosts, groups, defaults and identities. Host passwords are
/// edited separately in the host form; passphrases are asked for when needed.
class LoginEditor extends ConsumerStatefulWidget {
  const LoginEditor({super.key, this.initial, this.enabled = true});

  final Login? initial;
  final bool enabled;

  @override
  ConsumerState<LoginEditor> createState() => LoginEditorState();
}

class LoginEditorState extends ConsumerState<LoginEditor> {
  late final _username = TextEditingController(text: widget.initial?.username);
  late final _keyPath = TextEditingController(text: widget.initial?.policy.keyPath);
  late var _mode = switch (widget.initial?.policy) {
    final p? when p.usesKey && p.usesPassword => _AuthMode.keyPassword,
    final p? when p.usesKey => _AuthMode.key,
    _ => _AuthMode.password,
  };

  /// An imported key's ID, or null for a key file.
  late String? _keyId = widget.initial?.policy.keyId;
  late var _interactive = widget.initial?.policy.allowInteractive ?? true;

  @override
  void dispose() {
    _username.dispose();
    _keyPath.dispose();
    super.dispose();
  }

  /// What the fields describe; the caller validates the form first.
  Login get value {
    final useKey = _mode != _AuthMode.password;
    return (
      username: _username.text.trim(),
      policy: AuthPolicy(
        methods: switch (_mode) {
          _AuthMode.password => const [AuthKind.password],
          _AuthMode.key => const [AuthKind.key],
          _AuthMode.keyPassword => const [AuthKind.key, AuthKind.password],
        },
        keyId: useKey ? _keyId : null,
        keyPath: useKey && _keyId == null ? unquoteWindowsPath(_keyPath.text.trim()) : null,
        allowInteractive: _interactive,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final keys = ref.watch(keysProvider);
    final enabled = widget.enabled;
    // A key deleted elsewhere falls back to the file field rather than an empty dropdown.
    if (_keyId != null && keys.every((k) => k.id != _keyId)) _keyId = null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextFormField(
          controller: _username,
          enabled: enabled,
          validator: enabled ? (v) => requiredField(l, v) : null,
          decoration: InputDecoration(labelText: l.username),
        ),
        formGap,
        AppSelect<_AuthMode>(
          value: _mode,
          options: [
            AppOption(_AuthMode.password, l.password),
            AppOption(_AuthMode.key, l.privateKey),
            AppOption(_AuthMode.keyPassword, l.keyThenPassword),
          ],
          onChanged: enabled ? (v) => setState(() => _mode = v) : null,
        ),
        if (_mode != _AuthMode.password) ...[
          formGap,
          FileDropZone(
            enabled: enabled,
            preview: true,
            onDrop: (paths, _) => setState(() {
              _keyId = null;
              _keyPath.text = paths.first;
            }),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: AppSelect<String?>(
                        value: _keyId,
                        label: l.privateKey,
                        options: [
                          for (final k in keys) AppOption(k.id, '${k.label} · ${k.algorithm}'),
                          AppOption(null, l.keyFile),
                        ],
                        onChanged: enabled ? (v) => setState(() => _keyId = v) : null,
                      ),
                    ),
                    IconButton(
                      tooltip: l.keys,
                      onPressed: enabled ? () => showSideDrawer<void>(context, (_) => const KeysPanel()) : null,
                      icon: const Icon(Icons.key_outlined, size: 18),
                    ),
                  ],
                ),
                if (_keyId == null) ...[
                  formGap,
                  TextFormField(
                    controller: _keyPath,
                    enabled: enabled,
                    validator: enabled ? (v) => requiredField(l, unquoteWindowsPath(v ?? '')) : null,
                    decoration: InputDecoration(labelText: l.keyPath),
                  ),
                ],
              ],
            ),
          ),
        ],
        const SizedBox(height: Space.sm),
        AppToggleRow(
          title: l.allowInteractive,
          value: _interactive,
          onChanged: enabled ? (v) => setState(() => _interactive = v) : null,
        ),
      ],
    );
  }
}

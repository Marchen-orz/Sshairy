import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../design/form_field.dart';
import '../../../design/select.dart';
import '../../../design/theme.dart';
import '../../../foundation/ids.dart';
import '../../../l10n/app_localizations.dart';
import '../../../platform/file_drop.dart';
import '../adapters/folder_picker.dart';
import '../../../platform/local_paths.dart';
import '../../hosts/api.dart';
import '../application/local_profiles.dart';
import '../application/local_terminal.dart';
import '../domain/local_profile.dart';
import '../domain/terminal_target.dart';

/// Name, shell and starting folder of a saved local terminal (docs/UI.md §3).
class LocalProfileForm extends ConsumerStatefulWidget {
  const LocalProfileForm({super.key, this.profile});

  final LocalProfile? profile;

  @override
  ConsumerState<LocalProfileForm> createState() => _LocalProfileFormState();
}

class _LocalProfileFormState extends ConsumerState<LocalProfileForm> {
  final _form = GlobalKey<FormState>();
  late final _label = TextEditingController(text: widget.profile?.label);
  late final _directory = TextEditingController(text: widget.profile?.directory);
  late LocalShell? _shell = widget.profile?.shell ?? ref.read(localShellsProvider).firstOrNull;
  var _saving = false;
  String? _error;

  @override
  void dispose() {
    _label.dispose();
    _directory.dispose();
    super.dispose();
  }

  Future<void> _browse() async {
    final current = unquoteWindowsPath(_directory.text.trim());
    final picked = await pickFolder(initial: current.isEmpty ? null : current);
    if (picked != null && mounted) setState(() => _directory.text = picked);
  }

  Future<void> _save() async {
    final shell = _shell;
    if (_saving || shell == null || !_form.currentState!.validate()) return;
    final l = AppLocalizations.of(context);
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref
          .read(localProfilesProvider.notifier)
          .save(
            LocalProfile(
              id: widget.profile?.id ?? newId(),
              label: _label.text.trim(),
              shell: shell,
              directory: unquoteWindowsPath(_directory.text.trim()),
            ),
          );
      if (mounted) Navigator.pop(context);
    } on Object {
      if (mounted) setState(() => _error = l.errSave);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final discovered = ref.watch(localShellsProvider);
    // A saved shell that is no longer found stays selectable, so editing the name does not change it.
    final shells = [?widget.profile?.shell, ...discovered.where((s) => s != widget.profile?.shell)];
    return FloatingLabelFields(
      child: Form(
        key: _form,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: AbsorbPointer(
                absorbing: _saving,
                child: ListView(
                  padding: const EdgeInsets.only(top: Space.sm),
                  children: [
                    TextFormField(
                      controller: _label,
                      autofocus: true,
                      validator: (v) => requiredField(l, v),
                      decoration: InputDecoration(labelText: l.label),
                    ),
                    formGap,
                    AppSelect<LocalShell?>(
                      value: _shell,
                      label: l.localShell,
                      options: [for (final s in shells) AppOption(s, s.name)],
                      onChanged: (v) => setState(() => _shell = v),
                    ),
                    formGap,
                    FileDropZone(
                      preview: true,
                      onDrop: (paths, _) => setState(() => _directory.text = paths.first),
                      child: TextFormField(
                        controller: _directory,
                        decoration: InputDecoration(
                          labelText: l.startDirectory,
                          suffixIcon: IconButton(
                            tooltip: l.chooseFolder,
                            onPressed: _browse,
                            icon: const Icon(Icons.folder_open_outlined, size: 18),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            FormFooter(
              onSave: _save,
              saving: _saving || _shell == null,
              error: _shell == null ? l.noLocalShells : _error,
            ),
          ],
        ),
      ),
    );
  }
}

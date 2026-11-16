import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../design/form_field.dart';
import '../../../l10n/app_localizations.dart';
import '../application/hosts.dart';
import '../domain/host.dart';
import '../domain/host_library.dart';
import 'connection_editor.dart';
import 'form_parts.dart';

/// A group's path and the defaults its hosts and subgroups inherit.
class GroupPanel extends ConsumerStatefulWidget {
  const GroupPanel({super.key, this.group, this.parent = ''});

  /// The group to edit; null creates one.
  final HostGroup? group;

  /// Where a new group starts: the group the vault is showing.
  final String parent;

  @override
  ConsumerState<GroupPanel> createState() => _GroupPanelState();
}

class _GroupPanelState extends ConsumerState<GroupPanel> {
  final _form = GlobalKey<FormState>();
  final _connection = GlobalKey<ConnectionEditorState>();
  late final _path = TextEditingController(
    text: switch (widget.group) {
      final group? => ref.read(hostLibraryProvider).groupPath(group.id),
      _ => widget.parent.isEmpty ? '' : '${widget.parent}/',
    },
  );
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _path.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving || !_form.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    final l = AppLocalizations.of(context);
    final hosts = ref.read(hostsProvider.notifier);
    final defaults = _connection.currentState!.value;
    final group = widget.group;
    try {
      if (group == null) {
        await hosts.createGroup(_path.text, defaults: defaults);
      } else {
        await hosts.updateGroup(group.id, path: _path.text, defaults: defaults);
      }
      if (mounted) Navigator.pop(context);
    } on Object catch (e) {
      if (mounted) setState(() => _error = saveError(l, e, invalid: l.errGroupInvalid));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final library = ref.watch(hostLibraryProvider);
    final path = normalizeGroup(_path.text);
    // The group's own defaults sit on top of what its parent gives.
    final parent = path.contains('/') ? library.groupIdFor(path.substring(0, path.lastIndexOf('/'))) : null;
    return FloatingLabelFields(
      child: Form(
        key: _form,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: ListView(
                children: [
                  TextFormField(
                    controller: _path,
                    autofocus: true,
                    validator: (v) => requiredField(l, v) ?? (normalizeGroup(v!).isEmpty ? l.required : null),
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(labelText: l.group, hintText: 'prod/web'),
                  ),
                  formGap,
                  ConnectionEditor(
                    key: _connection,
                    initial: widget.group?.defaults ?? const ConnectionOverrides(),
                    inherited: library.resolveConnection(parent, null),
                    loginOptional: true,
                  ),
                ],
              ),
            ),
            FormFooter(onSave: _save, saving: _saving, error: _error),
          ],
        ),
      ),
    );
  }
}

/// What every host starts from before its group and its own settings apply.
class DefaultsPanel extends ConsumerStatefulWidget {
  const DefaultsPanel({super.key});

  @override
  ConsumerState<DefaultsPanel> createState() => _DefaultsPanelState();
}

class _DefaultsPanelState extends ConsumerState<DefaultsPanel> {
  final _form = GlobalKey<FormState>();
  final _connection = GlobalKey<ConnectionEditorState>();
  bool _saving = false;
  String? _error;

  Future<void> _save() async {
    if (_saving || !_form.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    final l = AppLocalizations.of(context);
    try {
      await ref.read(hostsProvider.notifier).saveDefaults(_connection.currentState!.value);
      if (mounted) Navigator.pop(context);
    } on Object catch (e) {
      if (mounted) setState(() => _error = saveError(l, e));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final library = ref.read(hostLibraryProvider);
    return FloatingLabelFields(
      child: Form(
        key: _form,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: ListView(
                children: [
                  ConnectionEditor(
                    key: _connection,
                    initial: library.defaults,
                    inherited: HostLibrary().resolveConnection(null, null),
                    loginOptional: true,
                  ),
                ],
              ),
            ),
            FormFooter(onSave: _save, saving: _saving, error: _error),
          ],
        ),
      ),
    );
  }
}

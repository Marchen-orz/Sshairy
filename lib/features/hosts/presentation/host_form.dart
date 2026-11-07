import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../application/hosts.dart';
import '../domain/host.dart';
import '../domain/host_library.dart';
import 'connection_editor.dart';
import 'form_parts.dart';

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
  final _connection = GlobalKey<ConnectionEditorState>();
  bool _saving = false;
  String? _error;
  late final _label = TextEditingController(text: widget.host?.label);
  late final _address = TextEditingController(text: widget.host?.address);
  late final _group = TextEditingController(text: widget.host?.group ?? widget.group);
  final _groupFocus = FocusNode();
  late final _tags = TextEditingController(text: widget.host?.tags.join(', '));

  @override
  void dispose() {
    for (final c in [_label, _address, _group, _tags]) {
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
    final l = AppLocalizations.of(context);
    final old = widget.host;
    final path = normalizeGroup(_group.text);
    try {
      await ref
          .read(hostsProvider.notifier)
          .save(
            Host(
              id: old?.id ?? HostsNotifier.newId(),
              label: _label.text.trim(),
              address: _address.text.trim(),
              // Placeholder: what the host connects with is resolved from its overrides and the layers above.
              username: old?.username ?? '',
              group: path,
              groupId: ref.read(hostLibraryProvider).groupIdFor(path),
              tags: parseTags(_tags.text),
              pinned: old?.pinned ?? false,
              lastUsed: old?.lastUsed,
              overrides: _connection.currentState!.value,
            ),
          );
      if (mounted) Navigator.pop(context);
    } on Object catch (e) {
      final route = e is ArgumentError && e.message == 'invalid route';
      if (mounted) setState(() => _error = route ? l.errRouteInvalid : l.errHostSave);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final library = ref.watch(hostLibraryProvider);
    final old = widget.host;
    final path = normalizeGroup(_group.text);
    return Form(
      key: _form,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: ListView(
              children: [
                TextFormField(
                  controller: _label,
                  autofocus: true,
                  decoration: InputDecoration(labelText: l.label),
                ),
                formGap,
                TextFormField(
                  controller: _address,
                  validator: (v) => requiredField(l, v),
                  decoration: InputDecoration(labelText: l.address),
                ),
                formGap,
                Autocomplete<String>(
                  textEditingController: _group,
                  focusNode: _groupFocus,
                  optionsBuilder: (v) =>
                      library.groupPaths.where((g) => g.toLowerCase().contains(v.text.toLowerCase())),
                  onSelected: (_) => setState(() {}),
                  fieldViewBuilder: (context, controller, focus, onSubmit) => TextFormField(
                    controller: controller,
                    focusNode: focus,
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(labelText: l.group, hintText: 'prod/web'),
                  ),
                ),
                formGap,
                TextFormField(
                  controller: _tags,
                  decoration: InputDecoration(labelText: l.tags, hintText: l.tagsHint),
                ),
                formGap,
                ConnectionEditor(
                  key: _connection,
                  initial: old?.overrides ?? (old == null ? const ConnectionOverrides() : explicitConnection(old)),
                  // A host in a group that does not exist yet inherits from the groups above that path, if any.
                  inherited: library.resolveConnection(_resolvableGroup(library, path), null),
                  self: old?.id,
                  fresh: old == null,
                ),
              ],
            ),
          ),
          FormFooter(onSave: _save, saving: _saving, error: _error),
        ],
      ),
    );
  }

  /// The deepest existing group on [path]; a group still to be created has no defaults of its own.
  String? _resolvableGroup(HostLibrary library, String path) {
    var current = path;
    while (current.isNotEmpty) {
      final id = library.groupIdFor(current);
      if (id != null) return id;
      current = current.contains('/') ? current.substring(0, current.lastIndexOf('/')) : '';
    }
    return null;
  }
}

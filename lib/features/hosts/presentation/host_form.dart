import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../design/form_field.dart';
import '../../../design/theme.dart';
import '../../../foundation/ids.dart';
import '../../../foundation/secret.dart';
import '../../../l10n/app_localizations.dart';
import '../../credentials/api.dart';
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
  var _connection = GlobalKey<ConnectionEditorState>();
  bool _saving = false;
  String? _error;
  final _label = TextEditingController();
  final _address = TextEditingController();
  final _group = TextEditingController();
  final _groupFocus = FocusNode();
  final _tags = TextEditingController();
  final _password = TextEditingController();
  late HostId _id;
  Host? _seed;
  bool get _missing => widget.host != null && _seed == null;
  late int _revision;
  var _passwordLoad = 0;
  bool _loadingPassword = false;
  bool _passwordError = false;
  bool _passwordDirty = false;
  bool _hasPassword = false;
  bool _removePassword = false;
  bool _showPassword = false;

  @override
  void initState() {
    super.initState();
    _reset();
  }

  @override
  void didUpdateWidget(HostForm oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.host?.id != widget.host?.id) {
      _connection = GlobalKey<ConnectionEditorState>();
      _reset();
    }
  }

  void _reset() {
    final hosts = ref.read(hostsProvider.notifier);
    final requested = widget.host;
    final host = _seed = requested == null ? null : hosts.byId(requested.id);
    _id = requested?.id ?? HostsNotifier.newId();
    _revision = hosts.revision;
    _label.text = host?.label ?? '';
    _address.text = host?.address ?? '';
    _group.text = host?.group ?? widget.group;
    _tags.text = host?.tags.join(', ') ?? '';
    _password.clear();
    _error = null;
    _passwordDirty = _hasPassword = _removePassword = _showPassword = _passwordError = false;
    _loadingPassword = host != null;
    _passwordLoad++;
    if (host != null) _loadPassword();
  }

  Future<void> _loadPassword() async {
    final generation = ++_passwordLoad;
    final id = _id;
    final credentials = ref.read(hostPasswordEditorProvider);
    _loadingPassword = true;
    _passwordError = false;
    try {
      final value = await credentials.readPassword(id);
      if (!mounted || generation != _passwordLoad) return;
      setState(() {
        _hasPassword = value != null;
        // Typing while the OS store is opening wins over the saved value, including an empty edited draft.
        if (!_passwordDirty && !_removePassword) _password.text = value?.reveal() ?? '';
        _loadingPassword = false;
      });
    } on Object {
      if (!mounted || generation != _passwordLoad) return;
      setState(() {
        _loadingPassword = false;
        _passwordError = true;
      });
    }
  }

  @override
  void dispose() {
    _passwordLoad++;
    _password.clear();
    for (final c in [_label, _address, _group, _tags, _password]) {
      c.dispose();
    }
    _groupFocus.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving || _missing || _loadingPassword || _passwordError || !_form.currentState!.validate()) return;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _saving = true;
      _error = null;
    });
    final l = AppLocalizations.of(context);
    final old = _seed;
    final path = normalizeGroup(_group.text);
    final hosts = ref.read(hostsProvider.notifier);
    final credentials = ref.read(hostPasswordEditorProvider);
    final id = _id;
    final generation = _passwordLoad;
    final remove = _removePassword;
    final password = _passwordDirty && _password.text.isNotEmpty ? Secret(_password.text) : null;
    var metadataSaved = false;
    try {
      final committedRevision = await hosts.saveWithRevision(
        Host(
          id: id,
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
        expectedRevision: _revision,
      );
      metadataSaved = true;
      if (generation == _passwordLoad) _revision = committedRevision;
      if (remove) {
        await credentials.clearPassword(id);
      } else if (password != null) {
        await credentials.savePassword(id, password);
      }
      if (mounted && generation == _passwordLoad) Navigator.pop(context);
    } on HostProxyCleanupFailure catch (failure) {
      if (mounted && generation == _passwordLoad) {
        setState(() {
          _revision = failure.committedRevision;
          _error = l.hostPasswordCleanupFailed;
        });
      }
    } on Object catch (e) {
      final route = e is ArgumentError && e.message == 'invalid route';
      if (mounted && generation == _passwordLoad) {
        setState(
          () => _error = metadataSaved
              ? l.hostPasswordSaveFailed
              : route
              ? l.errRouteInvalid
              : l.errHostSave,
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _passwordField(AppLocalizations l) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      TextFormField(
        controller: _password,
        readOnly: _saving,
        obscureText: !_showPassword,
        obscuringCharacter: '•',
        autocorrect: false,
        enableSuggestions: false,
        decoration: InputDecoration(
          labelText: l.password,
          helperText: _loadingPassword
              ? l.hostPasswordLoading
              : _removePassword
              ? l.hostPasswordRemovalPending
              : null,
          errorText: _passwordError ? l.hostPasswordLoadFailed : null,
          errorMaxLines: 3,
          suffixIcon: IconButton(
            tooltip: _showPassword ? l.hidePassword : l.showPassword,
            onPressed: () => setState(() => _showPassword = !_showPassword),
            icon: Icon(_showPassword ? Icons.visibility_off_outlined : Icons.visibility_outlined, size: 18),
          ),
        ),
        onChanged: (_) => setState(() {
          _passwordDirty = true;
          _removePassword = false;
        }),
      ),
      if (_passwordError)
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: () {
              setState(() => _loadingPassword = true);
              _loadPassword();
            },
            child: Text(l.hostPasswordRetry),
          ),
        ),
      if (_hasPassword && !_passwordError)
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: () => setState(() {
              _removePassword = !_removePassword;
              _passwordDirty = true;
              _password.clear();
            }),
            child: Text(_removePassword ? l.hostPasswordKeep : l.hostPasswordRemove),
          ),
        ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final library = ref.watch(hostLibraryProvider);
    final old = _seed;
    final path = normalizeGroup(_group.text);
    return FloatingLabelFields(
      child: Form(
        key: _form,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: ExcludeFocus(
                excluding: _saving || _missing,
                child: AbsorbPointer(
                  absorbing: _saving || _missing,
                  child: ListView(
                    padding: const EdgeInsets.only(top: Space.sm),
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
                        initial:
                            old?.overrides ?? (old == null ? const ConnectionOverrides() : explicitConnection(old)),
                        // A host in a group that does not exist yet inherits from the groups above that path, if any.
                        inherited: library.resolveConnection(_resolvableGroup(library, path), null),
                        self: _id,
                        fresh: old == null,
                        passwordField: _passwordField(l),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            FormFooter(
              onSave: _save,
              saving: _saving || _missing || _loadingPassword || _passwordError,
              error: _missing ? l.fwErrHost : _error,
            ),
          ],
        ),
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

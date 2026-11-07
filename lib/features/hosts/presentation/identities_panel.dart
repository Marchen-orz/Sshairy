import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../design/dialog.dart';
import '../../../design/side_drawer.dart';
import '../../../design/theme.dart';
import '../../../l10n/app_localizations.dart';
import '../application/hosts.dart';
import '../domain/host_library.dart';
import 'form_parts.dart';
import 'login_editor.dart';

/// Named logins that hosts, groups and the defaults can share: a username and how to authenticate it, never a secret.
class IdentitiesPanel extends ConsumerWidget {
  const IdentitiesPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final library = ref.watch(hostLibraryProvider);

    Future<void> remove(HostIdentity identity) async {
      final ok = await showAppDialog<bool>(
        context: context,
        builder: (context) => AppDialog(
          content: Text(l.deleteIdentity(identity.label)),
          actions: [
            TextButton(autofocus: true, onPressed: () => Navigator.pop(context, false), child: Text(l.cancel)),
            TextButton(
              style: TextButton.styleFrom(foregroundColor: theme.colorScheme.error),
              onPressed: () => Navigator.pop(context, true),
              child: Text(l.delete),
            ),
          ],
        ),
      );
      if (ok != true) return;
      try {
        await ref.read(hostsProvider.notifier).deleteIdentity(identity.id);
      } on IdentityInUse catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.keyInUse(e.references.join(', ')))));
        }
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton.icon(
              onPressed: () => showSideDrawer<void>(context, (_) => const IdentityForm()),
              icon: const Icon(Icons.add, size: 16),
              label: Text(l.newIdentity),
            ),
          ],
        ),
        const SizedBox(height: Space.md),
        if (library.identities.isEmpty) Text(l.none, style: muted),
        Expanded(
          child: ListView(
            children: [
              for (final identity in library.identities)
                Builder(
                  builder: (context) {
                    final users = library.identityReferences(identity.id);
                    return Padding(
                      padding: const EdgeInsets.only(bottom: Space.sm),
                      child: Row(
                        children: [
                          Icon(Icons.badge_outlined, size: 18, color: theme.colorScheme.primary),
                          const SizedBox(width: Space.md),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(identity.label, maxLines: 1, overflow: TextOverflow.ellipsis),
                                Text(identity.username, maxLines: 1, overflow: TextOverflow.ellipsis, style: muted),
                                if (users.isNotEmpty)
                                  Text(
                                    l.keyInUse(users.join(', ')),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: muted,
                                  ),
                              ],
                            ),
                          ),
                          IconButton(
                            tooltip: l.edit,
                            onPressed: () => showSideDrawer<void>(context, (_) => IdentityForm(identity: identity)),
                            icon: const Icon(Icons.edit_outlined, size: 16),
                          ),
                          // An identity something still uses cannot go: the host would be left without a login.
                          IconButton(
                            tooltip: l.delete,
                            onPressed: users.isEmpty ? () => remove(identity) : null,
                            icon: const Icon(Icons.delete_outline, size: 16),
                          ),
                        ],
                      ),
                    );
                  },
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class IdentityForm extends ConsumerStatefulWidget {
  const IdentityForm({super.key, this.identity});

  final HostIdentity? identity;

  @override
  ConsumerState<IdentityForm> createState() => _IdentityFormState();
}

class _IdentityFormState extends ConsumerState<IdentityForm> {
  final _form = GlobalKey<FormState>();
  final _login = GlobalKey<LoginEditorState>();
  late final _label = TextEditingController(text: widget.identity?.label);
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _label.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving || !_form.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    final login = _login.currentState!.value;
    try {
      await ref
          .read(hostsProvider.notifier)
          .saveIdentity(
            HostIdentity(
              id: widget.identity?.id ?? HostsNotifier.newIdentityId(),
              label: _label.text.trim(),
              username: login.username,
              policy: login.policy,
            ),
          );
      if (mounted) Navigator.pop(context);
    } on Object {
      if (mounted) setState(() => _error = AppLocalizations.of(context).errSave);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final identity = widget.identity;
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
                  validator: (v) => requiredField(l, v),
                  decoration: InputDecoration(labelText: l.label),
                ),
                formGap,
                LoginEditor(
                  key: _login,
                  initial: identity == null ? null : (username: identity.username, policy: identity.policy),
                ),
              ],
            ),
          ),
          FormFooter(onSave: _save, saving: _saving, error: _error),
        ],
      ),
    );
  }
}

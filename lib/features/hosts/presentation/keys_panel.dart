import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../design/text_prompt.dart';
import '../../../design/theme.dart';
import '../../../foundation/result.dart';
import '../../../foundation/secret.dart';
import '../../../l10n/app_localizations.dart';
import '../../credentials/api.dart';
import '../application/hosts.dart';

/// Imported and generated keys. Lives with hosts so it can tell which hosts use a key before it goes.
class KeysPanel extends ConsumerWidget {
  const KeysPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final keys = ref.watch(keysProvider);
    final library = ref.watch(hostLibraryProvider);
    final notifier = ref.read(keysProvider.notifier);

    Future<void> remove(SshKey key) async {
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          content: Text(l.deleteKey(key.label)),
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
        await notifier.delete(key);
      } on KeyInUse catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.keyInUse(e.hosts.join(', ')))));
        }
      }
    }

    Future<void> rename(SshKey key) async {
      final label = await showDialog<String>(
        context: context,
        builder: (_) => TextPromptDialog(title: l.rename, initial: key.label),
      );
      if (label != null && label.trim().isNotEmpty) await notifier.rename(key, label);
    }

    Future<void> generate() async {
      final label = await showDialog<String>(
        context: context,
        builder: (_) => TextPromptDialog(title: l.generateKey, hint: l.label),
      );
      if (label != null) await notifier.generate(label);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton.icon(
              onPressed: () => showDialog<void>(context: context, builder: (_) => const _ImportDialog()),
              icon: const Icon(Icons.file_download_outlined, size: 18),
              label: Text(l.importKey),
            ),
            const SizedBox(width: Space.xs),
            TextButton.icon(onPressed: generate, icon: const Icon(Icons.add, size: 18), label: Text(l.generateKey)),
          ],
        ),
        const SizedBox(height: Space.lg),
        if (keys.isEmpty) Text(l.none, style: muted),
        Expanded(
          child: ListView(
            children: [
              for (final key in keys)
                Builder(
                  builder: (context) {
                    final users = library.keyReferences(key.id);
                    return Padding(
                      padding: const EdgeInsets.only(bottom: Space.md),
                      child: Row(
                        children: [
                          Icon(Icons.key_outlined, size: 20, color: theme.colorScheme.primary),
                          const SizedBox(width: Space.md),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(key.label, maxLines: 1, overflow: TextOverflow.ellipsis),
                                Tooltip(
                                  message: key.fingerprint,
                                  child: Text(
                                    '${key.algorithm}  ${key.fingerprint}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: muted?.copyWith(fontFamily: 'Consolas'),
                                  ),
                                ),
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
                            tooltip: l.copyPublicKey,
                            onPressed: () => Clipboard.setData(ClipboardData(text: key.publicKey)),
                            icon: const Icon(Icons.copy_outlined, size: 18),
                          ),
                          PopupMenuButton<VoidCallback>(
                            tooltip: l.more,
                            icon: const Icon(Icons.more_horiz, size: 18),
                            onSelected: (run) => run(),
                            itemBuilder: (_) => [
                              PopupMenuItem(value: () => rename(key), child: Text(l.rename)),
                              // A key some host still uses cannot go: the host would be left pointing at nothing.
                              PopupMenuItem(enabled: users.isEmpty, value: () => remove(key), child: Text(l.delete)),
                            ],
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

class _ImportDialog extends ConsumerStatefulWidget {
  const _ImportDialog();

  @override
  ConsumerState<_ImportDialog> createState() => _ImportDialogState();
}

class _ImportDialogState extends ConsumerState<_ImportDialog> {
  final _label = TextEditingController();
  final _source = TextEditingController();
  final _passphrase = TextEditingController();
  var _remember = false, _busy = false, _needsPassphrase = false;
  String? _error;

  @override
  void dispose() {
    for (final c in [_label, _source, _passphrase]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _import() async {
    final l = AppLocalizations.of(context);
    setState(() => _busy = true);
    final result = await ref
        .read(keysProvider.notifier)
        .import(
          _label.text,
          _source.text,
          passphrase: _passphrase.text.isEmpty ? null : Secret(_passphrase.text),
          remember: _remember,
        );
    if (!mounted) return;
    switch (result) {
      case Ok():
        Navigator.pop(context);
      case Err(:final error):
        setState(() {
          _busy = false;
          _needsPassphrase |= error.code == 'keyNeedsPassphrase' || error.code == 'keyWrongPassphrase';
          _error = switch (error.code) {
            'keyNeedsPassphrase' => l.errKeyNeedsPassphrase,
            'keyWrongPassphrase' => l.errKeyWrongPassphrase,
            'keyDuplicate' => l.errKeyDuplicate(error.detail),
            'keyUnreadable' => l.errKeyUnreadable,
            _ => l.errKeyUnsupported,
          };
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    const gap = SizedBox(height: Space.lg);
    return AlertDialog(
      title: Text(l.importKey),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _label,
              autofocus: true,
              decoration: InputDecoration(labelText: l.label),
            ),
            gap,
            TextField(
              controller: _source,
              minLines: 4,
              maxLines: 8,
              style: const TextStyle(fontFamily: 'Consolas', fontSize: 12),
              decoration: InputDecoration(labelText: l.keySource, alignLabelWithHint: true),
            ),
            if (_needsPassphrase) ...[
              gap,
              TextField(
                controller: _passphrase,
                obscureText: true,
                autofocus: true,
                decoration: InputDecoration(labelText: l.passphrase),
                onSubmitted: (_) => _import(),
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: _remember,
                onChanged: (v) => setState(() => _remember = v ?? false),
                title: Text(l.remember),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: Space.sm),
              Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(l.cancel)),
        FilledButton(onPressed: _busy ? null : _import, child: Text(l.importKey)),
      ],
    );
  }
}

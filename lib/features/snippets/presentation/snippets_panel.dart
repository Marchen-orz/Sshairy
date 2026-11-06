import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../design/theme.dart';
import '../../../foundation/ids.dart';
import '../../../foundation/cancellation.dart';
import '../../../l10n/app_localizations.dart';
import '../../terminal/api.dart';
import '../application/snippets.dart';
import '../domain/snippet.dart';

class SnippetsPanel extends ConsumerStatefulWidget {
  const SnippetsPanel({super.key});
  @override
  ConsumerState<SnippetsPanel> createState() => _SnippetsPanelState();
}

class _SnippetsPanelState extends ConsumerState<SnippetsPanel> {
  String _query = '';
  String? _busy;
  CancellationToken? _insertion;

  @override
  void dispose() {
    _insertion?.cancel();
    super.dispose();
  }

  Future<void> _edit([Snippet? snippet]) => showDialog<void>(context: context, builder: (_) => _SnippetEditor(snippet));

  Future<void> _insert(Snippet snippet, {bool run = false}) async {
    if (_busy != null) return;
    final cancel = CancellationToken();
    _insertion = cancel;
    final route = ModalRoute.of(context);
    setState(() => _busy = snippet.id);
    try {
      final result = await ref.read(snippetsProvider.notifier).insert(snippet.id, run: run, cancel: cancel);
      if (!mounted) return;
      if (result == InsertResult.sent) {
        if (route?.isCurrent ?? false) Navigator.pop(context);
      } else if (result != InsertResult.rejected && result != InsertResult.cancelled) {
        ScaffoldMessenger.maybeOf(context)
            ?.showSnackBar(SnackBar(content: Text(AppLocalizations.of(context).snippetUnavailable)));
      }
    } finally {
      if (identical(_insertion, cancel)) _insertion = null;
      if (mounted) setState(() => _busy = null);
    }
  }

  Future<void> _delete(Snippet snippet) async {
    final l = AppLocalizations.of(context);
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        content: Text(l.deleteOne(snippet.label)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(l.cancel)),
          TextButton(onPressed: () => Navigator.pop(context, true), child: Text(l.delete)),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    try {
      await ref.read(snippetsProvider.notifier).delete(snippet.id);
    } on Object {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(l.snippetSaveFailed)));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final items = ref.watch(snippetsProvider).where((s) => s.matches(_query)).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                autofocus: true,
                onChanged: (s) => setState(() => _query = s),
                decoration: InputDecoration(hintText: l.snippets, prefixIcon: const Icon(Icons.search)),
              ),
            ),
            IconButton(tooltip: l.newSnippet, onPressed: () => _edit(), icon: const Icon(Icons.add)),
            IconButton(tooltip: l.closePane, onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close)),
          ],
        ),
        const SizedBox(height: Space.lg),
        Expanded(
          child: items.isEmpty
              ? Center(child: Text(l.noMatches))
              : ListView.builder(
                  itemCount: items.length,
                  itemBuilder: (context, index) {
                    final s = items[index];
                    return Padding(
                      padding: const EdgeInsets.only(bottom: Space.sm),
                      child: Card(
                        child: Padding(
                          padding: const EdgeInsets.all(Space.md),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Row(
                                children: [
                                  Expanded(child: Text(s.label, style: Theme.of(context).textTheme.titleSmall)),
                                  IconButton(
                                    tooltip: l.edit,
                                    onPressed: () => _edit(s),
                                    icon: const Icon(Icons.edit_outlined, size: 18),
                                  ),
                                  IconButton(
                                    tooltip: l.delete,
                                    onPressed: () => _delete(s),
                                    icon: const Icon(Icons.delete_outline, size: 18),
                                  ),
                                ],
                              ),
                              Text(
                                InsertPreview('', s.text, run: false).visibleText,
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                              ),
                              if (s.tags.isNotEmpty)
                                Text(s.tags.join(' · '), style: Theme.of(context).textTheme.bodySmall),
                              const SizedBox(height: Space.sm),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.end,
                                children: [
                                  TextButton(
                                    onPressed: _busy != null ? null : () => _insert(s, run: true),
                                    child: Text(l.runSnippet),
                                  ),
                                  const SizedBox(width: Space.sm),
                                  FilledButton.tonal(
                                    onPressed: _busy != null ? null : () => _insert(s),
                                    child: Text(l.insertSnippet),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _SnippetEditor extends ConsumerStatefulWidget {
  const _SnippetEditor(this.snippet);
  final Snippet? snippet;
  @override
  ConsumerState<_SnippetEditor> createState() => _SnippetEditorState();
}

class _SnippetEditorState extends ConsumerState<_SnippetEditor> {
  late final _label = TextEditingController(text: widget.snippet?.label);
  late final _text = TextEditingController(text: widget.snippet?.text);
  late final _tags = TextEditingController(text: widget.snippet?.tags.join(', '));
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _label.dispose();
    _text.dispose();
    _tags.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    final l = AppLocalizations.of(context);
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref
          .read(snippetsProvider.notifier)
          .save(
            Snippet(
              id: widget.snippet?.id ?? newId(),
              label: _label.text.trim(),
              text: _text.text,
              tags: _tags.text.split(RegExp(r'[,\s]+')).where((s) => s.isNotEmpty).toSet().toList(),
            ),
          );
      if (mounted) Navigator.pop(context);
    } on ArgumentError {
      if (mounted) setState(() => _error = l.snippetInvalid);
    } on Object {
      if (mounted) setState(() => _error = l.snippetSaveFailed);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return AlertDialog(
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _label,
                autofocus: true,
                decoration: InputDecoration(labelText: l.label),
              ),
              const SizedBox(height: Space.lg),
              TextField(
                controller: _text,
                minLines: 5,
                maxLines: 12,
                decoration: InputDecoration(labelText: l.snippetText),
              ),
              const SizedBox(height: Space.lg),
              TextField(
                controller: _tags,
                decoration: InputDecoration(labelText: l.tags),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: Space.sm),
                  child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: _saving ? null : () => Navigator.pop(context), child: Text(l.cancel)),
        FilledButton(onPressed: _saving ? null : _save, child: Text(l.save)),
      ],
    );
  }
}

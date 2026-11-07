import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import 'dialog.dart';

/// Asks for one line of text, such as a new name; pops with the text, or null on cancel.
/// Owns its controller, so the closing animation never sees a disposed one.
class TextPromptDialog extends StatefulWidget {
  const TextPromptDialog({super.key, required this.title, this.initial = '', this.hint, this.validate});

  final String title;
  final String initial;
  final String? hint;

  /// Returns an error to show under the field, or null when the text is fine.
  final String? Function(String text)? validate;

  @override
  State<TextPromptDialog> createState() => _TextPromptDialogState();
}

class _TextPromptDialogState extends State<TextPromptDialog> {
  late final _text = TextEditingController(text: widget.initial)
    ..selection = TextSelection(baseOffset: 0, extentOffset: widget.initial.length);
  String? _error;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _submit() {
    final error = widget.validate?.call(_text.text);
    if (error != null) return setState(() => _error = error);
    Navigator.pop(context, _text.text);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return AppDialog(
      width: 408,
      title: Text(widget.title),
      content: TextField(
        controller: _text,
        autofocus: true,
        decoration: InputDecoration(hintText: widget.hint, errorText: _error),
        onChanged: (_) {
          if (_error != null) setState(() => _error = null);
        },
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(l.cancel)),
        FilledButton(onPressed: _submit, child: Text(l.save)),
      ],
    );
  }
}

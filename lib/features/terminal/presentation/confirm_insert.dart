import 'package:flutter/material.dart';

import '../../../design/theme.dart';
import '../../../l10n/app_localizations.dart';
import '../domain/insertion.dart';

Future<bool> confirmTerminalInsert(BuildContext context, InsertPreview preview) async {
  if (!context.mounted) return false;
  return await showDialog<bool>(
        context: context,
        builder: (context) {
          final l = AppLocalizations.of(context);
          return AlertDialog(
            title: Text(preview.target),
            content: SizedBox(
              width: 520,
              height: 240,
              child: SingleChildScrollView(
                child: SelectableText(preview.visibleText, style: Theme.of(context).textTheme.bodyMedium),
              ),
            ),
            actions: [
              TextButton(autofocus: true, onPressed: () => Navigator.pop(context, false), child: Text(l.cancel)),
              Padding(
                padding: const EdgeInsets.only(left: Space.sm),
                child: FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: Text(preview.run ? l.runSnippet : l.paste),
                ),
              ),
            ],
          );
        },
      ) ??
      false;
}

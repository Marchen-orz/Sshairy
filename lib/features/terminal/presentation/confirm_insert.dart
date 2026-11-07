import 'dart:async';

import 'package:flutter/material.dart';

import '../../../design/dialog.dart';
import '../../../l10n/app_localizations.dart';
import '../domain/insertion.dart';

Future<bool> confirmTerminalInsert(BuildContext context, InsertPreview preview) async {
  if (!context.mounted || (preview.cancellation?.isCancelled ?? false)) return false;
  final navigator = Navigator.of(context, rootNavigator: true);
  // A route of our own rather than showAppDialog, so cancellation can remove it.
  final route = DialogRoute<bool>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: Theme.of(context).brightness == Brightness.dark ? .5 : .28),
    builder: (context) {
      final l = AppLocalizations.of(context);
      return AppDialog(
        width: 568,
        title: Text(preview.target),
        content: SizedBox(
          height: 240,
          child: SingleChildScrollView(
            child: SelectableText(preview.visibleText, style: Theme.of(context).textTheme.bodyMedium),
          ),
        ),
        actions: [
          TextButton(autofocus: true, onPressed: () => Navigator.pop(context, false), child: Text(l.cancel)),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(preview.run ? l.runSnippet : l.paste),
          ),
        ],
      );
    },
  );
  var completed = false;
  final result = navigator.push(route);
  unawaited(
    preview.cancellation?.whenCancelled.then((_) {
      if (!completed && route.isActive && navigator.mounted) navigator.removeRoute(route, false);
    }),
  );
  try {
    return await result ?? false;
  } finally {
    completed = true;
  }
}

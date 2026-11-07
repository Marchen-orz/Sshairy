import 'package:flutter/material.dart';

import '../../../design/theme.dart';
import '../../../l10n/app_localizations.dart';

const formGap = SizedBox(height: Space.lg);

String? requiredField(AppLocalizations l, String? v) => v == null || v.trim().isEmpty ? l.required : null;

String? portField(AppLocalizations l, String? v) {
  final port = int.tryParse(v ?? '');
  return port == null || port < 1 || port > 65535 ? l.invalidPort : null;
}

/// Cancel and Save at the foot of an edit drawer, with the reason a save failed above them.
class FormFooter extends StatelessWidget {
  const FormFooter({super.key, required this.onSave, required this.saving, this.error});

  final VoidCallback onSave;
  final bool saving;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (error != null) Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
        const SizedBox(height: Space.lg),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(onPressed: () => Navigator.pop(context), child: Text(l.cancel)),
            const SizedBox(width: Space.sm),
            FilledButton(onPressed: saving ? null : onSave, child: Text(l.save)),
          ],
        ),
      ],
    );
  }
}

/// The message for a save that did not land: a route the change would break, or the disk and secure storage.
String saveError(AppLocalizations l, Object error, {String? invalid}) => switch (error) {
  ArgumentError(message: 'invalid route') => l.errRouteInvalid,
  ArgumentError() when invalid != null => invalid,
  _ => l.errSave,
};

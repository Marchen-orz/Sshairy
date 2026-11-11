import 'package:flutter/material.dart';

import 'theme.dart';

/// Shared label placement for fields and selections in settings forms.
class AppFormField extends StatelessWidget {
  const AppFormField({super.key, required this.label, required this.child, this.helperText});

  final String label;
  final Widget child;
  final String? helperText;

  static const decoration = InputDecoration(
    isDense: true,
    constraints: BoxConstraints(minHeight: WorkspaceSize.control),
    contentPadding: EdgeInsets.symmetric(horizontal: 10),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ExcludeSemantics(child: Text(label, style: style)),
        const SizedBox(height: Space.xs),
        Semantics(label: label, child: child),
        if (helperText != null) ...[const SizedBox(height: Space.xs), Text(helperText!, style: style)],
      ],
    );
  }
}

import 'dart:math';

import 'package:flutter/material.dart';

import 'theme.dart';

/// For forms whose text fields float their label inside the box: those fields and [AppSelect]s below share one
/// height, a little taller than [AppFormField.height] so the floating label fits.
class FloatingLabelFields extends StatelessWidget {
  const FloatingLabelFields({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => _FloatingLabelScope(
    child: Builder(
      builder: (context) {
        final theme = Theme.of(context);
        final line = TextPainter(
          text: TextSpan(text: ' ', style: theme.textTheme.bodyLarge),
          textDirection: TextDirection.ltr,
          textScaler: MediaQuery.textScalerOf(context),
        )..layout();
        // An outlined label floats on the border, so the input line and its padding make up the whole height.
        final inset = max(2.0, (AppFormField.height(context) - line.preferredLineHeight) / 2);
        line.dispose();
        return Theme(
          data: theme.copyWith(
            inputDecorationTheme: theme.inputDecorationTheme.copyWith(
              contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: inset),
            ),
          ),
          child: child,
        );
      },
    ),
  );
}

class _FloatingLabelScope extends InheritedWidget {
  const _FloatingLabelScope({required super.child});

  @override
  bool updateShouldNotify(_FloatingLabelScope oldWidget) => false;
}

/// Shared label placement and visible field geometry in settings forms.
class AppFormField extends StatelessWidget {
  const AppFormField({super.key, required this.label, required this.child, this.helperText});

  final String label;
  final Widget child;
  final String? helperText;

  static double height(BuildContext context) {
    final style = Theme.of(context).textTheme.bodyMedium!;
    final line = MediaQuery.textScalerOf(context).scale(style.fontSize!) * (style.height ?? 1.5);
    // Matches AppSelect's painted box: rounded text line, vertical inset and border.
    final base = max(WorkspaceSize.control, line.ceilToDouble() + Space.sm + 2);
    return context.dependOnInheritedWidgetOfExactType<_FloatingLabelScope>() == null ? base : base + Space.xs;
  }

  static Color fill(BuildContext context, {bool enabled = true}) =>
      enabled ? Theme.of(context).colorScheme.surface : BrandPalette.of(context).disabledSurface;

  static BorderSide border(
    BuildContext context, {
    bool enabled = true,
    bool focused = false,
    bool error = false,
    bool hovered = false,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return BorderSide(
      color: !enabled
          ? scheme.outlineVariant
          : error
          ? scheme.error
          : focused
          ? scheme.primary
          : hovered
          ? scheme.outline
          : scheme.outlineVariant,
      width: enabled && focused ? 1.5 : 1,
    );
  }

  static InputDecoration decoration(BuildContext context) => InputDecoration(
    isDense: true,
    constraints: BoxConstraints(minHeight: height(context)),
    contentPadding: const EdgeInsets.symmetric(horizontal: 10),
    // InputDecorator's outer minHeight does not stretch its painted container.
    suffixIcon: SizedBox(width: 10, height: height(context)),
    suffixIconConstraints: const BoxConstraints(minWidth: 10, minHeight: 0),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    OutlineInputBorder outline({bool enabled = true, bool focused = false, bool error = false}) => OutlineInputBorder(
      borderRadius: BorderRadius.circular(Radii.control),
      borderSide: border(context, enabled: enabled, focused: focused, error: error),
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ExcludeSemantics(child: Text(label, style: style)),
        const SizedBox(height: Space.xs),
        Theme(
          data: theme.copyWith(
            textTheme: theme.textTheme.copyWith(bodyLarge: theme.textTheme.bodyMedium),
            inputDecorationTheme: theme.inputDecorationTheme.copyWith(
              fillColor: WidgetStateColor.resolveWith(
                (states) => fill(context, enabled: !states.contains(WidgetState.disabled)),
              ),
              border: outline(),
              enabledBorder: outline(),
              disabledBorder: outline(enabled: false),
              focusedBorder: outline(focused: true),
              errorBorder: outline(error: true),
              focusedErrorBorder: outline(focused: true, error: true),
            ),
          ),
          child: Semantics(label: label, child: child),
        ),
        if (helperText != null) ...[const SizedBox(height: Space.xs), Text(helperText!, style: style)],
      ],
    );
  }
}

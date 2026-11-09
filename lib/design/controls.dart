import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'theme.dart';

/// Focus, hover and keyboard activation for the hand-drawn controls below.
class _Pressable extends StatefulWidget {
  const _Pressable({required this.onTap, required this.builder, this.radius = Radii.pill});

  final VoidCallback? onTap;
  final Widget Function(BuildContext context, bool hovered, bool focused) builder;
  final double radius;

  @override
  State<_Pressable> createState() => _PressableState();
}

class _PressableState extends State<_Pressable> {
  var _hovered = false, _focused = false;

  @override
  Widget build(BuildContext context) => FocusableActionDetector(
    enabled: widget.onTap != null,
    mouseCursor: widget.onTap == null ? SystemMouseCursors.basic : SystemMouseCursors.click,
    onShowHoverHighlight: (v) => setState(() => _hovered = v),
    onShowFocusHighlight: (v) => setState(() => _focused = v),
    actions: {ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) => widget.onTap?.call())},
    shortcuts: const {
      SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
      SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
    },
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onTap,
      child: widget.builder(context, widget.onTap != null && _hovered, widget.onTap != null && _focused),
    ),
  );
}

BoxBorder? _ring(BuildContext context, bool focused, double gap) =>
    focused ? Border.all(color: Theme.of(context).colorScheme.primary, width: 2) : null;

class AppSwitch extends StatelessWidget {
  const AppSwitch({super.key, required this.value, required this.onChanged, this.semanticLabel});

  final bool value;
  final ValueChanged<bool>? onChanged;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = onChanged != null;
    final palette = BrandPalette.of(context);
    return Semantics(
      label: semanticLabel,
      toggled: value,
      enabled: enabled,
      child: Opacity(
        opacity: enabled ? 1 : .45,
        child: _Pressable(
          onTap: enabled ? () => onChanged!(!value) : null,
          builder: (context, hovered, focused) => AnimatedContainer(
            duration: Motion.quick,
            width: 34,
            height: 20,
            padding: const EdgeInsets.all(2),
            decoration: BoxDecoration(
              color: !enabled
                  ? scheme.outlineVariant
                  : value
                  ? scheme.primary
                  : hovered
                  ? scheme.outline
                  : scheme.outlineVariant,
              borderRadius: BorderRadius.circular(Radii.pill),
              border: _ring(context, focused, 2),
            ),
            child: AnimatedAlign(
              duration: Motion.normal,
              curve: Curves.easeOutCubic,
              alignment: value ? Alignment.centerRight : Alignment.centerLeft,
              child: Container(
                width: 16,
                height: 16,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: !enabled ? palette.textMuted : (value ? scheme.onPrimary : Colors.white),
                  boxShadow: [
                    BoxShadow(color: Colors.black.withValues(alpha: .18), blurRadius: 2, offset: const Offset(0, 1)),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class AppCheckbox extends StatelessWidget {
  const AppCheckbox({super.key, required this.value, required this.onChanged, this.semanticLabel});

  final bool value;
  final ValueChanged<bool>? onChanged;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = onChanged != null;
    final palette = BrandPalette.of(context);
    return Semantics(
      label: semanticLabel,
      checked: value,
      enabled: enabled,
      child: Opacity(
        opacity: enabled ? 1 : .45,
        child: _Pressable(
          radius: 5,
          onTap: enabled ? () => onChanged!(!value) : null,
          builder: (context, hovered, focused) => AnimatedContainer(
            duration: Motion.quick,
            width: 16,
            height: 16,
            decoration: BoxDecoration(
              color: !enabled ? palette.disabledSurface : (value ? scheme.primary : scheme.surface),
              borderRadius: BorderRadius.circular(4),
              border: !enabled
                  ? Border.all(color: scheme.outlineVariant)
                  : focused
                  ? Border.all(color: scheme.primary, width: 2)
                  : Border.all(color: value ? scheme.primary : (hovered ? scheme.onSurfaceVariant : scheme.outline)),
            ),
            child: value
                ? Icon(Icons.check_rounded, size: 13, color: enabled ? scheme.onPrimary : palette.textMuted)
                : null,
          ),
        ),
      ),
    );
  }
}

/// A pill track with a sliding highlight; replaces Material's segmented button.
class AppSegmented<T> extends StatelessWidget {
  const AppSegmented({super.key, required this.segments, required this.selected, required this.onChanged});

  final Map<T, String> segments;
  final T selected;
  final ValueChanged<T>? onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final enabled = onChanged != null;
    final palette = BrandPalette.of(context);
    return Container(
      height: 30,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: enabled
            ? scheme.surfaceContainerHighest.withValues(alpha: theme.brightness == Brightness.light ? 1 : .7)
            : palette.disabledSurface,
        borderRadius: BorderRadius.circular(Radii.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final MapEntry(key: value, value: label) in segments.entries)
            Semantics(
              button: true,
              enabled: enabled,
              selected: value == selected,
              child: _Pressable(
                onTap: onChanged == null ? null : () => onChanged!(value),
                builder: (context, hovered, focused) => AnimatedContainer(
                  duration: Motion.normal,
                  curve: Curves.easeOutCubic,
                  padding: const EdgeInsets.symmetric(horizontal: Space.md),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: value == selected ? (enabled ? scheme.surface : scheme.outlineVariant) : Colors.transparent,
                    borderRadius: BorderRadius.circular(Radii.pill),
                    border: _ring(context, focused, 0),
                    boxShadow: enabled && value == selected
                        ? [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: .1),
                              blurRadius: 3,
                              offset: const Offset(0, 1),
                            ),
                          ]
                        : null,
                  ),
                  child: Text(
                    label,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontWeight: value == selected ? FontWeight.w600 : FontWeight.w500,
                      color: !enabled
                          ? palette.textMuted
                          : value == selected || hovered
                          ? scheme.onSurface
                          : scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// A label with a switch on the right, or a checkbox on the left; the whole row toggles.
class AppToggleRow extends StatelessWidget {
  const AppToggleRow({
    super.key,
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
    this.checkbox = false,
  });

  final String title;
  final String? subtitle;
  final bool value, checkbox;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(title, style: onChanged == null ? TextStyle(color: BrandPalette.of(context).textMuted) : null),
        if (subtitle != null)
          Text(subtitle!, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      ],
    );
    return MergeSemantics(
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.control),
        onTap: onChanged == null ? null : () => onChanged!(!value),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: Space.xs),
          child: Row(
            children: checkbox
                ? [
                    AppCheckbox(value: value, onChanged: onChanged),
                    const SizedBox(width: Space.md),
                    Expanded(child: text),
                  ]
                : [
                    Expanded(child: text),
                    const SizedBox(width: Space.md),
                    AppSwitch(value: value, onChanged: onChanged),
                  ],
          ),
        ),
      ),
    );
  }
}

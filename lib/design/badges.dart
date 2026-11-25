import 'package:flutter/material.dart';

import 'theme.dart';

/// [tone] washed over [base], for the faint fill behind badges, tags and highlighted cards.
Color toneFill(BuildContext context, Color tone, Color base, {double strength = 1}) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  return Color.alphaBlend(tone.withValues(alpha: (dark ? .16 : .09) * strength), base);
}

/// An icon in [tone] on a rounded square of the same tone.
class AppIconBadge extends StatelessWidget {
  const AppIconBadge({super.key, required this.icon, this.tone, this.size = 36});

  final IconData icon;
  final Color? tone;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final color = tone ?? scheme.onSurfaceVariant;
    return AnimatedContainer(
      duration: Motion.of(context, Motion.normal),
      curve: Motion.move,
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color.withValues(alpha: dark ? .2 : .12),
        borderRadius: BorderRadius.circular(size >= 40 ? Radii.card : Radii.control),
      ),
      child: Icon(icon, size: size * .5, color: color),
    );
  }
}

/// A short state word in a pill of its own tone.
class AppTag extends StatelessWidget {
  const AppTag({super.key, required this.label, this.tone});

  final String label;
  final Color? tone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = tone ?? theme.colorScheme.onSurfaceVariant;
    final fill = toneFill(context, color, theme.colorScheme.surface, strength: 1.3);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Space.sm, vertical: 2),
      decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(Radii.pill)),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.labelSmall?.copyWith(
          color: readableColor(color, fill, 4.5),
          fontWeight: FontWeight.w600,
          height: 1.4,
        ),
      ),
    );
  }
}

/// A dot and a short label in [color]: filled for a live state, hollow when [color] is null.
class AppStatusLabel extends StatelessWidget {
  const AppStatusLabel({super.key, required this.label, this.color});

  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final color = this.color;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color,
            border: color == null ? Border.all(color: scheme.outline, width: 1.2) : null,
          ),
        ),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: color == null ? scheme.onSurfaceVariant : readableColor(color, scheme.surface, 4.5),
            ),
          ),
        ),
      ],
    );
  }
}

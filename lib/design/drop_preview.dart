import 'package:flutter/material.dart';

import 'theme.dart';

/// A drop destination over existing content, without intercepting its pointer events.
class DropPreview extends StatelessWidget {
  const DropPreview({super.key});

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    return IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: color.withValues(alpha: .18),
          border: Border.all(color: color, width: 2),
          borderRadius: BorderRadius.circular(Radii.control),
        ),
      ),
    );
  }
}

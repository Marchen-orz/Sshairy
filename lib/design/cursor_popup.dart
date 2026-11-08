import 'dart:math';

import 'package:flutter/material.dart';

import 'theme.dart';

/// Places a non-modal candidate list beside a caret, within its own terminal pane.
class CursorPopupLayout extends SingleChildLayoutDelegate {
  const CursorPopupLayout({required this.cursor, required this.preferredSize});

  final Rect cursor;
  final Size preferredSize;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final below = max(0.0, constraints.maxHeight - cursor.bottom - Space.xs - Space.sm);
    final above = max(0.0, cursor.top - Space.xs - Space.sm);
    return BoxConstraints(
      maxWidth: max(0, min(preferredSize.width, constraints.maxWidth - Space.sm * 2)),
      maxHeight: min(preferredSize.height, max(above, below)),
    );
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final x = cursor.right + Space.xs;
    final maxX = max(Space.sm, size.width - Space.sm - childSize.width);
    final below = size.height - cursor.bottom - Space.xs - Space.sm;
    final y = below >= childSize.height ? cursor.bottom + Space.xs : cursor.top - Space.xs - childSize.height;
    return Offset(x.clamp(Space.sm, maxX), y.clamp(Space.sm, max(Space.sm, size.height - Space.sm - childSize.height)));
  }

  @override
  bool shouldRelayout(CursorPopupLayout oldDelegate) =>
      cursor != oldDelegate.cursor || preferredSize != oldDelegate.preferredSize;
}

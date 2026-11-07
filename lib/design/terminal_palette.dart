import 'package:flutter/material.dart';

import 'brand_palette.dart';

/// Terminal colors follow the whole theme; dark ANSI colors come from the author's pack.
class TerminalPalette {
  const TerminalPalette._({
    required this.background,
    required this.foreground,
    required this.cursor,
    required this.selection,
    required this.ansi,
    required this.searchHit,
    required this.searchHitCurrent,
    required this.searchHitForeground,
  });

  final Color background, foreground, cursor, selection, searchHit, searchHitCurrent, searchHitForeground;

  /// black, red, green, yellow, blue, magenta, cyan, white, then the bright variants.
  final List<Color> ansi;

  factory TerminalPalette.of(ThemeData theme) {
    final palette = BrandPalette.fromTheme(theme);
    return TerminalPalette._(
      background: palette.terminalBackground,
      foreground: palette.terminalForeground,
      cursor: palette.terminalCursor,
      selection: readableColor(palette.selection, palette.terminalBackground, 2),
      searchHit: const Color(0xFFF3D181),
      searchHitCurrent: const Color(0xFFFFAE70),
      searchHitForeground: const Color(0xFF1F3A5F),
      ansi: palette.ansi,
    );
  }
}

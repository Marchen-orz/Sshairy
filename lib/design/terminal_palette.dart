import 'package:flutter/material.dart';

/// Terminal colors for the current theme (docs/UI.md §2). ANSI colors are the documented exception to tokens.
class TerminalPalette {
  const TerminalPalette._({
    required this.background,
    required this.foreground,
    required this.cursor,
    required this.selection,
    required this.ansi,
    required this.searchHit,
    required this.searchHitCurrent,
  });

  final Color background, foreground, cursor, selection, searchHit, searchHitCurrent;

  /// black, red, green, yellow, blue, magenta, cyan, white, then the bright variants.
  final List<Color> ansi;

  factory TerminalPalette.of(ThemeData theme) {
    final accent = theme.colorScheme.primary;
    final light = theme.brightness == Brightness.light;
    return TerminalPalette._(
      background: light ? const Color(0xFFFFFFFF) : const Color(0xFF10151C),
      foreground: light ? const Color(0xFF1E2633) : const Color(0xFFD8DEE9),
      cursor: accent,
      selection: accent.withValues(alpha: light ? 0.22 : 0.35),
      searchHit: const Color(0xFFF5C66B),
      searchHitCurrent: const Color(0xFFFF9F43),
      ansi: light ? _light : _dark,
    );
  }

  static const _light = [
    Color(0xFF1E2633), Color(0xFFC42B3A), Color(0xFF1A7F37), Color(0xFF8A6100),
    Color(0xFF1F5FD6), Color(0xFF8B3FC7), Color(0xFF087F8C), Color(0xFF8A94A3),
    Color(0xFF5B6575), Color(0xFFD93848), Color(0xFF22913F), Color(0xFF9E7100),
    Color(0xFF2F6FE8), Color(0xFF9D52D6), Color(0xFF0A919F), Color(0xFFB4BCC8),
  ];

  static const _dark = [
    Color(0xFF1B222C), Color(0xFFF0717A), Color(0xFF7BD88F), Color(0xFFF2C66D),
    Color(0xFF6CB6FF), Color(0xFFC79BFF), Color(0xFF5FD4E0), Color(0xFFC9D1DC),
    Color(0xFF5C6773), Color(0xFFFF8F96), Color(0xFF98E6A8), Color(0xFFFFD98A),
    Color(0xFF8FCBFF), Color(0xFFD9B8FF), Color(0xFF85E6EF), Color(0xFFF2F5F9),
  ];
}

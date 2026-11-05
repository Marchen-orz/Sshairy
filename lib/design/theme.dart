import 'package:flutter/material.dart';

/// Spacing and radius tokens from docs/UI.md §2.
abstract final class Space {
  static const xs = 4.0, sm = 8.0, md = 12.0, lg = 16.0, xl = 24.0, xxl = 32.0;
}

abstract final class Radii {
  static const control = 6.0, card = 10.0, panel = 12.0;
}

ThemeData buildTheme(Brightness brightness) {
  final light = brightness == Brightness.light;
  Color c(int l, int d) => Color(light ? l : d);
  final scheme = ColorScheme(
    brightness: brightness,
    surface: c(0xFFFFFFFF, 0xFF20252D),
    surfaceContainerLowest: c(0xFFF4F6F8, 0xFF15181D),
    surfaceContainerLow: c(0xFFEBEEF2, 0xFF1C2026),
    surfaceContainerHigh: c(0xFFFFFFFF, 0xFF272D37),
    onSurface: c(0xFF17212F, 0xFFE6EAF0),
    onSurfaceVariant: c(0xFF596579, 0xFFA6B0BF),
    outlineVariant: c(0xFFD6DDE5, 0xFF39424F),
    outline: c(0xFFB4BFCC, 0xFF55606F),
    primary: c(0xFF087F5B, 0xFF34D399),
    onPrimary: c(0xFFFFFFFF, 0xFF10241D),
    secondary: c(0xFF087F5B, 0xFF34D399),
    onSecondary: c(0xFFFFFFFF, 0xFF10241D),
    error: c(0xFFB42332, 0xFFFF8792),
    onError: c(0xFFFFFFFF, 0xFF2A0A0E),
    tertiary: c(0xFF865400, 0xFFF5C66B),
    onTertiary: c(0xFFFFFFFF, 0xFF2A1D00),
  );
  final controlShape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.control));
  const controlSize = Size(64, 36);
  final focusRing = WidgetStateProperty.resolveWith<BorderSide?>(
    (s) => s.contains(WidgetState.focused) ? BorderSide(color: scheme.primary, width: 2) : null,
  );
  return ThemeData(
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surfaceContainerLowest,
    visualDensity: VisualDensity.standard,
    textTheme: const TextTheme(
      bodyMedium: TextStyle(fontSize: 14),
      bodySmall: TextStyle(fontSize: 12),
      titleMedium: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
    ),
    dividerTheme: DividerThemeData(color: scheme.outlineVariant, space: 1, thickness: 1),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(minimumSize: controlSize, shape: controlShape).copyWith(side: focusRing),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(minimumSize: controlSize, shape: controlShape),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(minimumSize: controlSize, shape: controlShape).copyWith(side: focusRing),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(minimumSize: const Size(32, 32), shape: controlShape).copyWith(side: focusRing),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: SegmentedButton.styleFrom(
        minimumSize: controlSize,
        shape: controlShape,
        foregroundColor: scheme.onSurface,
        selectedBackgroundColor: scheme.primary,
        selectedForegroundColor: scheme.onPrimary,
      ),
    ),
    sliderTheme: SliderThemeData(tickMarkShape: SliderTickMarkShape.noTickMark),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: scheme.surface,
      contentPadding: const EdgeInsets.symmetric(horizontal: Space.md, vertical: 10),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Radii.control),
        borderSide: BorderSide(color: scheme.outlineVariant),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Radii.control),
        borderSide: BorderSide(color: scheme.outlineVariant),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Radii.control),
        borderSide: BorderSide(color: scheme.primary, width: 2),
      ),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: scheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.card),
        side: BorderSide(color: scheme.outlineVariant),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: scheme.surfaceContainerHigh,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.panel)),
    ),
    tooltipTheme: const TooltipThemeData(waitDuration: Duration(milliseconds: 500)),
  );
}

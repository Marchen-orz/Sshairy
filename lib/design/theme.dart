import 'dart:math';

import 'package:flutter/material.dart';

/// Spacing and radius tokens from docs/UI.md §2.
abstract final class Space {
  static const xs = 4.0, sm = 8.0, md = 12.0, lg = 16.0, xl = 24.0, xxl = 32.0;
}

abstract final class Radii {
  static const control = 6.0, card = 10.0, panel = 12.0;
}

abstract final class WorkspaceSize {
  static const navigation = 224.0, navigationCollapsed = 56.0, navigationBreakpoint = 1200.0;
  static const toolPanel = 360.0, toolPanelMin = 300.0, toolPanelMax = 560.0, terminalMin = 480.0;
  static const divider = 1.0, dividerGrab = 8.0, treeRow = 30.0, tabMin = 120.0, tabMax = 220.0;
}

/// Accent presets from docs/UI.md §2; each has one shade per brightness.
enum Accent {
  blue(Color(0xFF06ADC8), Color(0xFF5ADDEB)),
  green(Color(0xFF087F5B), Color(0xFF34D399)),
  violet(Color(0xFF6D4AE0), Color(0xFFA78BFA)),
  orange(Color(0xFFC2410C), Color(0xFFFB923C));

  const Accent(this.light, this.dark);

  final Color light, dark;

  Color of(Brightness b) => b == Brightness.light ? light : dark;
}

const _onAccentDark = Color(0xFF0B1220);

/// White or a near-black, whichever reads better on [c].
Color onColor(Color c) {
  double contrast(Color a, Color b) {
    final (x, y) = (a.computeLuminance(), b.computeLuminance());
    return (max(x, y) + 0.05) / (min(x, y) + 0.05);
  }

  return contrast(c, const Color(0xFFFFFFFF)) >= contrast(c, _onAccentDark) ? const Color(0xFFFFFFFF) : _onAccentDark;
}

ThemeData buildTheme(Brightness brightness, [Accent accent = Accent.blue]) {
  final light = brightness == Brightness.light;
  Color c(int l, int d) => Color(light ? l : d);
  final primary = accent.of(brightness);
  final scheme = ColorScheme(
    brightness: brightness,
    surface: c(0xFFFFFFFF, 0xFF18252D),
    surfaceContainerLowest: c(0xFFF4F8FA, 0xFF10191E),
    surfaceContainerLow: c(0xFFEAF2F5, 0xFF142129),
    surfaceContainerHigh: c(0xFFFFFFFF, 0xFF1E3039),
    onSurface: c(0xFF16323E, 0xFFE3F2F4),
    onSurfaceVariant: c(0xFF536D78, 0xFF9AB6C1),
    outlineVariant: c(0xFFD5E5E9, 0xFF30454F),
    outline: c(0xFFB0BDCD, 0xFF4B5869),
    primary: primary,
    onPrimary: onColor(primary),
    secondary: primary,
    onSecondary: onColor(primary),
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

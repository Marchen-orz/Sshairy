import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'brand_palette.dart';
import 'motion.dart';
export 'brand_palette.dart';
export 'motion.dart';

/// Spacing and radius tokens from docs/UI.md §2.
abstract final class Space {
  static const xs = 4.0, sm = 8.0, md = 12.0, lg = 16.0, xl = 24.0, xxl = 32.0;
}

abstract final class Radii {
  static const control = 8.0, card = 12.0, panel = 14.0, pill = 999.0;
}

abstract final class WorkspaceSize {
  static const titleBar = 44.0, titleBarContent = 36.0, tabHeight = 28.0, tabMin = 80.0, tabMax = 200.0;
  static const navigationExpanded = 200.0, navigationMin = 176.0, navigationMax = 320.0;
  static const navigationHeader = 76.0, navigationItem = 40.0;
  static const rail = 48.0, railItem = 36.0, flyout = 400.0, flyoutWide = 440.0, monitor = 240.0;
  static const monitorMin = 240.0, monitorMax = 400.0;
  static const wideBreakpoint = 1200.0, terminalMin = 480.0;
  static const toolPanel = 360.0, toolPanelMin = 300.0, toolPanelMax = 560.0;
  static const dockBottom = 260.0, dockBottomMin = 160.0, dockBottomMaxShare = 0.6;
  static const directoryTree = 240.0, settingsDialog = 960.0;
  static const settingsHeight = 640.0, settingsNavigation = 164.0, settingsNavigationCompact = 104.0;
  static const divider = 1.0, dividerGrab = 8.0, treeRow = 26.0, listRow = 34.0, control = 32.0;
  static const paneMin = 120.0, paneHeader = 24.0;
}

abstract final class MobileSize {
  static const touchTarget = 48.0;
  static const contentMaxWidth = 720.0;
  static const wideContentMaxWidth = 1120.0;
  static const gridBreakpoint = 680.0;
  static const railBreakpoint = 840.0;
  static const twoColumnBreakpoint = 840.0;
  static const threeColumnBreakpoint = 1040.0;

  /// Horizontal padding that keeps scroll surfaces full-width while centering content on tablets.
  static double contentInset(double availableWidth, {double maxWidth = contentMaxWidth}) =>
      max(Space.lg, (availableWidth - maxWidth) / 2);
}

abstract final class ScrollSize {
  static const thumb = 6.0, gutter = thumb + Space.xs;
}

abstract final class CompletionSize {
  static const minWidth = 200.0, width = 380.0, labelWidth = 160.0, detailWidth = 200.0;
  static const maxHeight = 272.0, row = 32.0;
}

abstract final class InlineAiPopupSize {
  static const width = 360.0;
}

abstract final class HistoryPopupSize {
  static const width = 440.0, height = 360.0, minWidth = 280.0, minHeight = 180.0;
  static const maxWidth = 720.0, maxHeight = 560.0, resizeGrip = 20.0;
}

/// Font defaults from docs/UI.md §2. Chinese text falls back explicitly, so the system never picks Japanese glyphs.
abstract final class AppFonts {
  static const uiSize = 13.0, uiSizeMin = 11.0, uiSizeMax = 18.0;
  static String get mono => switch (defaultTargetPlatform) {
    TargetPlatform.macOS => 'Menlo',
    TargetPlatform.linux => 'monospace',
    _ => 'Cascadia Mono',
  };
  static List<String> get cjk => switch (defaultTargetPlatform) {
    TargetPlatform.macOS => const ['PingFang SC', 'Noto Sans CJK SC', 'Source Han Sans SC'],
    TargetPlatform.linux => const ['Noto Sans CJK SC', 'WenQuanYi Micro Hei', 'Source Han Sans SC'],
    _ => const ['Microsoft YaHei UI', 'Microsoft YaHei', 'PingFang SC', 'Noto Sans CJK SC', 'Source Han Sans SC'],
  };
  static List<String> get monoFallback => [
    'Cascadia Code',
    'Consolas',
    'Menlo',
    'DejaVu Sans Mono',
    'Noto Sans Mono CJK SC',
    ...cjk,
    'monospace',
  ];

  static String? get ui => !kIsWeb && defaultTargetPlatform == TargetPlatform.windows ? 'Segoe UI' : null;
}

/// The terminal font, also used for fingerprints, paths and permissions in the interface.
class MonoFont extends ThemeExtension<MonoFont> {
  const MonoFont(this.family);

  final String family;

  static MonoFont of(BuildContext context) => Theme.of(context).extension<MonoFont>() ?? MonoFont(AppFonts.mono);

  TextStyle apply(TextStyle? base) =>
      (base ?? const TextStyle()).copyWith(fontFamily: family, fontFamilyFallback: AppFonts.monoFallback);

  @override
  MonoFont copyWith({String? family}) => MonoFont(family ?? this.family);

  @override
  MonoFont lerp(MonoFont? other, double t) => t < .5 ? this : other ?? this;
}

/// [base] in the terminal font.
TextStyle mono(BuildContext context, [TextStyle? base]) => MonoFont.of(context).apply(base);

/// A visible selection fill that keeps regular text readable through a translucent code background.
Color textSelectionColor(ColorScheme scheme, {Color overlay = Colors.transparent}) {
  final primary = scheme.primary;
  if (colorContrast(Color.alphaBlend(overlay, primary), scheme.onSurface) >= 4.5) return primary;
  var low = 0.0, high = 1.0;
  for (var i = 0; i < 16; i++) {
    final middle = (low + high) / 2;
    final candidate = Color.lerp(primary, scheme.surface, middle)!;
    if (colorContrast(Color.alphaBlend(overlay, candidate), scheme.onSurface) >= 4.5) {
      high = middle;
    } else {
      low = middle;
    }
  }
  return Color.lerp(primary, scheme.surface, high)!;
}

const _onAccentDark = Color(0xFF0B1220);

/// White or a near-black, whichever reads better on [c].
Color onColor(Color c) {
  double contrast(Color a, Color b) {
    final (x, y) = (a.computeLuminance(), b.computeLuminance());
    return (max(x, y) + 0.05) / (min(x, y) + 0.05);
  }

  final chosen = contrast(c, const Color(0xFFFFFFFF)) >= contrast(c, _onAccentDark)
      ? const Color(0xFFFFFFFF)
      : _onAccentDark;
  return contrast(c, chosen) >= 4.5 ? chosen : Colors.black;
}

/// The soft shadow under floating surfaces: dialogs, menus, flyouts.
List<BoxShadow> overlayShadow(Brightness b) => [
  BoxShadow(
    color: Colors.black.withValues(alpha: b == Brightness.light ? .14 : .45),
    blurRadius: 28,
    offset: const Offset(0, 10),
  ),
  BoxShadow(color: Colors.black.withValues(alpha: b == Brightness.light ? .06 : .3), blurRadius: 3),
];

ThemeData buildTheme(
  Brightness brightness, [
  Accent accent = Accent.blue,
  double fontSize = AppFonts.uiSize,
  String? fontFamily,
  String? monoFamily,
]) {
  final palette = accent.palette(brightness);
  final primary = palette.controlPrimary;
  final scheme = ColorScheme(
    brightness: brightness,
    surface: palette.surface,
    surfaceContainerLowest: palette.background,
    surfaceContainerLow: palette.sidebar,
    surfaceContainer: Color.lerp(palette.surface, palette.raised, .5),
    surfaceContainerHigh: palette.raised,
    surfaceContainerHighest: palette.selection,
    onSurface: palette.text,
    onSurfaceVariant: palette.textSecondary,
    outlineVariant: palette.borderSubtle,
    outline: palette.borderControl,
    primary: primary,
    onPrimary: onColor(primary),
    primaryContainer: palette.selection,
    onPrimaryContainer: palette.onSelection,
    secondary: palette.accentInk,
    onSecondary: onColor(palette.accentInk),
    secondaryContainer: palette.selection,
    onSecondaryContainer: palette.onSelection,
    error: palette.danger,
    onError: onColor(palette.danger),
    tertiary: palette.warning,
    onTertiary: onColor(palette.warning),
  );
  final f = fontSize.clamp(AppFonts.uiSizeMin, AppFonts.uiSizeMax).toDouble();
  final small = max(11.0, f - 1);
  TextStyle text(double size, [FontWeight? weight]) => TextStyle(
    fontSize: size,
    fontWeight: weight,
    letterSpacing: 0,
    fontFamily: fontFamily ?? AppFonts.ui,
    fontFamilyFallback: AppFonts.cjk,
  );
  final controlShape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.control));
  const controlSize = Size(56, WorkspaceSize.control);
  const buttonPadding = EdgeInsets.symmetric(horizontal: 14);
  final buttonText = text(f, FontWeight.w500);
  final focusRing = WidgetStateProperty.resolveWith<BorderSide?>(
    (s) => s.contains(WidgetState.focused) ? BorderSide(color: scheme.primary, width: 2) : null,
  );
  OutlineInputBorder border(Color color, [double width = 1]) => OutlineInputBorder(
    borderRadius: BorderRadius.circular(Radii.control),
    borderSide: BorderSide(color: color, width: width),
  );
  return ThemeData(
    colorScheme: scheme,
    fontFamily: fontFamily ?? AppFonts.ui,
    fontFamilyFallback: AppFonts.cjk,
    scaffoldBackgroundColor: scheme.surfaceContainerLowest,
    visualDensity: VisualDensity.standard,
    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    // Desktop feedback is the hover and pressed tint; no ripple.
    splashFactory: NoSplash.splashFactory,
    extensions: [palette, MonoFont(monoFamily ?? AppFonts.mono)],
    iconTheme: IconThemeData(size: 18, color: scheme.onSurface),
    textTheme: TextTheme(
      titleLarge: text(f + 5, FontWeight.w600),
      titleMedium: text(f + 3, FontWeight.w600),
      titleSmall: text(f + 1, FontWeight.w600),
      bodyLarge: text(f + 1),
      bodyMedium: text(f),
      bodySmall: text(small),
      labelLarge: text(f, FontWeight.w600),
      labelMedium: text(small, FontWeight.w500),
      labelSmall: text(max(10.0, f - 2), FontWeight.w500),
    ),
    dividerTheme: DividerThemeData(color: scheme.outlineVariant, space: 1, thickness: 1),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: palette.fillPrimary,
        foregroundColor: onColor(palette.fillPrimary),
        minimumSize: controlSize,
        padding: buttonPadding,
        shape: controlShape,
        textStyle: buttonText,
        elevation: 0,
      ).copyWith(side: focusRing),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: controlSize,
        padding: buttonPadding,
        shape: controlShape,
        textStyle: buttonText,
        side: BorderSide(color: scheme.outline),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        minimumSize: controlSize,
        padding: buttonPadding,
        shape: controlShape,
        textStyle: buttonText,
      ).copyWith(side: focusRing),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        minimumSize: const Size(28, 28),
        padding: const EdgeInsets.all(6),
        iconSize: 16,
        shape: controlShape,
      ).copyWith(side: focusRing),
    ),
    sliderTheme: SliderThemeData(
      tickMarkShape: SliderTickMarkShape.noTickMark,
      trackHeight: 3,
      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
      overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
      inactiveTrackColor: scheme.outlineVariant,
    ),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: WidgetStateColor.resolveWith(
        (states) => states.contains(WidgetState.disabled) ? palette.disabledSurface : scheme.surface,
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      hintStyle: TextStyle(color: scheme.onSurfaceVariant),
      labelStyle: WidgetStateTextStyle.resolveWith(
        (states) => TextStyle(color: states.contains(WidgetState.disabled) ? palette.textMuted : null),
      ),
      border: border(scheme.outline),
      enabledBorder: border(scheme.outline),
      disabledBorder: border(scheme.outlineVariant.withValues(alpha: .5)),
      focusedBorder: border(scheme.primary, 1.5),
      errorBorder: border(scheme.error),
      focusedErrorBorder: border(scheme.error, 1.5),
      prefixIconConstraints: const BoxConstraints(minWidth: 32, minHeight: 28),
      suffixIconConstraints: const BoxConstraints(minWidth: 32, minHeight: 28),
    ),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: scheme.primary,
      selectionColor: scheme.primary.withValues(alpha: .25),
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
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: scheme.surfaceContainerHigh,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(Radii.panel))),
    ),
    pageTransitionsTheme: PageTransitionsTheme(
      builders: {for (final p in TargetPlatform.values) p: const AppPageTransitionsBuilder()},
    ),
    listTileTheme: ListTileThemeData(
      dense: true,
      minTileHeight: WorkspaceSize.listRow,
      contentPadding: const EdgeInsets.symmetric(horizontal: Space.md),
      shape: controlShape,
      iconColor: scheme.onSurfaceVariant,
    ),
    expansionTileTheme: const ExpansionTileThemeData(
      shape: Border(),
      collapsedShape: Border(),
      tilePadding: EdgeInsets.zero,
      childrenPadding: EdgeInsets.zero,
    ),
    chipTheme: ChipThemeData(
      shape: const StadiumBorder(),
      side: BorderSide(color: scheme.outlineVariant),
      backgroundColor: scheme.surface,
      selectedColor: scheme.primary.withValues(alpha: .14),
      labelStyle: text(small, FontWeight.w500).copyWith(color: scheme.onSurface),
      padding: const EdgeInsets.symmetric(horizontal: Space.xs),
      labelPadding: const EdgeInsets.symmetric(horizontal: Space.sm),
      showCheckmark: false,
    ),
    checkboxTheme: CheckboxThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      visualDensity: VisualDensity.compact,
    ),
    scrollbarTheme: ScrollbarThemeData(
      crossAxisMargin: 0,
      thickness: const WidgetStatePropertyAll(ScrollSize.thumb),
      radius: const Radius.circular(3),
      thumbColor: WidgetStateProperty.resolveWith(
        (s) => scheme.onSurface.withValues(alpha: s.contains(WidgetState.hovered) ? .35 : .2),
      ),
    ),
    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 500),
      padding: const EdgeInsets.symmetric(horizontal: Space.sm, vertical: Space.xs),
      textStyle: text(small).copyWith(color: scheme.surface),
      decoration: BoxDecoration(color: scheme.onSurface.withValues(alpha: .92), borderRadius: BorderRadius.circular(6)),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      width: 420,
      elevation: 0,
      backgroundColor: scheme.onSurface,
      contentTextStyle: text(f).copyWith(color: scheme.surface),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.card)),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: scheme.primary,
      linearTrackColor: scheme.outlineVariant,
      borderRadius: BorderRadius.circular(Radii.pill),
    ),
  );
}

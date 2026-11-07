import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Spacing and radius tokens from docs/UI.md §2.
abstract final class Space {
  static const xs = 4.0, sm = 8.0, md = 12.0, lg = 16.0, xl = 24.0, xxl = 32.0;
}

abstract final class Radii {
  static const control = 8.0, card = 12.0, panel = 14.0, pill = 999.0;
}

abstract final class WorkspaceSize {
  static const titleBar = 36.0, tabHeight = 28.0, tabMin = 110.0, tabMax = 200.0;
  static const rail = 48.0, railItem = 36.0, flyout = 400.0, flyoutWide = 440.0, monitor = 240.0;
  static const wideBreakpoint = 1200.0, terminalMin = 480.0;
  static const toolPanel = 360.0, toolPanelMin = 300.0, toolPanelMax = 560.0;
  static const dockBottom = 260.0, dockBottomMin = 160.0, dockBottomMaxShare = 0.6;
  static const divider = 1.0, dividerGrab = 8.0, treeRow = 26.0, listRow = 34.0, control = 32.0;
}

abstract final class Motion {
  static const quick = Duration(milliseconds: 120), normal = Duration(milliseconds: 180);
  static const panel = Duration(milliseconds: 220);
}

/// Font defaults from docs/UI.md §2. Chinese text falls back explicitly, so the system never picks Japanese glyphs.
abstract final class AppFonts {
  static const uiSize = 13.0, uiSizeMin = 11.0, uiSizeMax = 18.0;
  static const mono = 'Cascadia Mono';
  static const cjk = ['Microsoft YaHei UI', 'Microsoft YaHei', 'PingFang SC', 'Noto Sans CJK SC', 'Source Han Sans SC'];
  static const monoFallback = ['Cascadia Code', 'Consolas', ...cjk, 'Noto Sans Mono CJK SC', 'monospace'];

  static String? get ui => !kIsWeb && defaultTargetPlatform == TargetPlatform.windows ? 'Segoe UI' : null;
}

/// The terminal font, also used for fingerprints, paths and permissions in the interface.
class MonoFont extends ThemeExtension<MonoFont> {
  const MonoFont(this.family);

  final String family;

  static MonoFont of(BuildContext context) => Theme.of(context).extension<MonoFont>() ?? const MonoFont(AppFonts.mono);

  TextStyle apply(TextStyle? base) =>
      (base ?? const TextStyle()).copyWith(fontFamily: family, fontFamilyFallback: AppFonts.monoFallback);

  @override
  MonoFont copyWith({String? family}) => MonoFont(family ?? this.family);

  @override
  MonoFont lerp(MonoFont? other, double t) => t < .5 ? this : other ?? this;
}

/// [base] in the terminal font.
TextStyle mono(BuildContext context, [TextStyle? base]) => MonoFont.of(context).apply(base);

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
  final light = brightness == Brightness.light;
  Color c(int l, int d) => Color(light ? l : d);
  final primary = accent.of(brightness);
  final scheme = ColorScheme(
    brightness: brightness,
    surface: c(0xFFFFFFFF, 0xFF18252D),
    surfaceContainerLowest: c(0xFFF4F8FA, 0xFF10191E),
    surfaceContainerLow: c(0xFFEAF2F5, 0xFF142129),
    surfaceContainer: c(0xFFF0F5F7, 0xFF1A2A32),
    surfaceContainerHigh: c(0xFFFFFFFF, 0xFF1E3039),
    surfaceContainerHighest: c(0xFFE3EDF0, 0xFF263A44),
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
  final f = fontSize.clamp(AppFonts.uiSizeMin, AppFonts.uiSizeMax).toDouble();
  final small = max(11.0, f - 1);
  TextStyle text(double size, [FontWeight? weight]) => TextStyle(fontSize: size, fontWeight: weight, letterSpacing: 0);
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
    extensions: [MonoFont(monoFamily ?? AppFonts.mono)],
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
        side: BorderSide(color: scheme.outlineVariant),
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
      fillColor: scheme.surface,
      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      hintStyle: TextStyle(color: scheme.onSurfaceVariant),
      border: border(scheme.outlineVariant),
      enabledBorder: border(scheme.outlineVariant),
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
      thickness: const WidgetStatePropertyAll(6),
      radius: const Radius.circular(3),
      thumbColor: WidgetStateProperty.resolveWith(
        (s) => scheme.onSurface.withValues(alpha: s.contains(WidgetState.hovered) ? .35 : .2),
      ),
    ),
    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 500),
      padding: const EdgeInsets.symmetric(horizontal: Space.sm, vertical: Space.xs),
      textStyle: text(small).copyWith(color: scheme.surface),
      decoration: BoxDecoration(
        color: scheme.onSurface.withValues(alpha: .92),
        borderRadius: BorderRadius.circular(6),
      ),
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

import 'dart:math';

import 'package:flutter/material.dart';

part 'brand_palette_data.dart';

/// Persisted names keep the first four themes compatible with existing settings.json files.
enum Accent {
  blue,
  green,
  violet,
  orange,
  deepSea,
  pink;

  BrandPalette palette(Brightness brightness) {
    final pair = _brandPalettes[this]!;
    return brightness == Brightness.light ? pair.$1 : pair.$2;
  }

  Color of(Brightness brightness) => palette(brightness).primary;
}

/// The author's brand colors and semantic surfaces. Source: docs/BRAND.md.
class BrandPalette extends ThemeExtension<BrandPalette> {
  const BrandPalette(this.theme, this.brightness, this.colors, this.ansi);

  final Accent theme;
  final Brightness brightness;
  final Map<String, Color> colors;
  final List<Color> ansi;

  static BrandPalette of(BuildContext context) => fromTheme(Theme.of(context));

  static BrandPalette fromTheme(ThemeData theme) =>
      theme.extension<BrandPalette>() ?? Accent.blue.palette(theme.brightness);

  Color get background => colors['background']!;
  Color get sidebar => colors['sidebar']!;
  Color get surface => colors['surface']!;
  Color get raised => colors['surface-raised']!;
  Color get borderSubtle => colors['border-subtle']!;
  Color get borderControl => colors['border-control']!;
  Color get text => colors['text']!;
  Color get textSecondary => colors['text-secondary']!;
  Color get textMuted => colors['text-muted']!;
  Color get primary => colors['primary']!;
  Color get accent => colors['accent']!;
  Color get selection => colors['selection']!;
  Color get onSelection => colors['on-selection']!;
  Color get focus => colors['focus-ring']!;
  Color get success => colors['success']!;
  Color get warning => colors['warning']!;
  Color get danger => colors['danger']!;
  Color get info => colors['info']!;
  Color get terminalBackground => colors['terminal-bg']!;
  Color get terminalForeground => colors['terminal-fg']!;
  Color get terminalCursor => colors['terminal-cursor']!;

  // Pale accents stay faithful in artwork; interactive text must also read on its surface.
  Color get controlPrimary {
    var color = primary;
    for (final background in [surface, raised, sidebar, this.background]) {
      color = readableColor(color, background, 4.5);
    }
    return color;
  }

  Color get accentInk => readableColor(accent, surface, 3);

  @override
  BrandPalette copyWith({Map<String, Color>? colors, List<Color>? ansi}) =>
      BrandPalette(theme, brightness, colors ?? this.colors, ansi ?? this.ansi);

  @override
  BrandPalette lerp(BrandPalette? other, double t) {
    if (other == null) return this;
    final identity = t < .5 ? this : other;
    return BrandPalette(
      identity.theme,
      identity.brightness,
      {for (final key in colors.keys) key: Color.lerp(colors[key], other.colors[key], t)!},
      [for (var i = 0; i < ansi.length; i++) Color.lerp(ansi[i], other.ansi[i], t)!],
    );
  }
}

double colorContrast(Color a, Color b) {
  final x = a.computeLuminance(), y = b.computeLuminance();
  return (max(x, y) + .05) / (min(x, y) + .05);
}

/// Preserve the hue and change only as far toward black/white as readability requires.
Color readableColor(Color color, Color background, double minimum) {
  if (colorContrast(color, background) >= minimum) return color;
  final target = colorContrast(Colors.black, background) > colorContrast(Colors.white, background)
      ? Colors.black
      : Colors.white;
  var low = 0.0, high = 1.0;
  for (var i = 0; i < 16; i++) {
    final middle = (low + high) / 2;
    if (colorContrast(Color.lerp(color, target, middle)!, background) >= minimum) {
      high = middle;
    } else {
      low = middle;
    }
  }
  return Color.lerp(color, target, high)!;
}

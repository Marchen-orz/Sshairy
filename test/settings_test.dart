import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/design/theme.dart';
import 'package:sshairy/features/settings/settings.dart';
import 'package:sshairy/foundation/secret.dart';

void main() {
  test('Settings falls back on bad values', () {
    final s = Settings.fromJson({'themeMode': 'neon', 'fontSize': 999, 'locale': 'fr', 'renderer': 'vulkan', 'accent': 'pink'});
    expect(s.themeMode, ThemeMode.system);
    expect(s.fontSize, Settings.maxFontSize);
    expect(s.locale, isNull);
    expect(s.renderer, Renderer.skia);
    expect(s.accent, Accent.blue);
  });

  test('Settings survives a JSON round trip', () {
    const s = Settings(themeMode: ThemeMode.dark, fontSize: 16, locale: 'zh', renderer: Renderer.impeller, accent: Accent.violet);
    final copy = Settings.fromJson(s.toJson());
    expect(copy.renderer, Renderer.impeller);
    expect(copy.accent, Accent.violet);
    expect(copy.themeMode, ThemeMode.dark);
    expect(copy.fontSize, 16);
    expect(copy.locale, 'zh');
  });

  test('Every accent keeps readable text on itself in both modes', () {
    for (final a in Accent.values) {
      for (final b in Brightness.values) {
        final c = a.of(b), on = onColor(c);
        final (x, y) = (c.computeLuminance(), on.computeLuminance());
        final ratio = (x > y ? x + 0.05 : y + 0.05) / (x > y ? y + 0.05 : x + 0.05);
        expect(ratio, greaterThanOrEqualTo(4.5), reason: '$a $b');
      }
    }
  });

  test('Secret does not print its value', () {
    expect('${const Secret('hunter2')}', isNot(contains('hunter2')));
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/features/settings/settings.dart';
import 'package:sshairy/foundation/secret.dart';

void main() {
  test('Settings falls back on bad values', () {
    final s = Settings.fromJson({'themeMode': 'neon', 'fontSize': 999, 'locale': 'fr', 'renderer': 'vulkan'});
    expect(s.themeMode, ThemeMode.system);
    expect(s.fontSize, Settings.maxFontSize);
    expect(s.locale, isNull);
    expect(s.renderer, Renderer.skia);
  });

  test('Settings survives a JSON round trip', () {
    const s = Settings(themeMode: ThemeMode.dark, fontSize: 16, locale: 'zh', renderer: Renderer.impeller);
    final copy = Settings.fromJson(s.toJson());
    expect(copy.renderer, Renderer.impeller);
    expect(copy.themeMode, ThemeMode.dark);
    expect(copy.fontSize, 16);
    expect(copy.locale, 'zh');
  });

  test('Secret does not print its value', () {
    expect('${const Secret('hunter2')}', isNot(contains('hunter2')));
  });
}

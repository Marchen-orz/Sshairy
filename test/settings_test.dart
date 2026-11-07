import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/design/theme.dart';
import 'package:sshairy/features/settings/settings.dart';
import 'package:sshairy/foundation/data_dir.dart';
import 'package:sshairy/foundation/result.dart';
import 'package:sshairy/foundation/secret.dart';

void main() {
  test('Settings falls back on bad values', () {
    final s = Settings.fromJson({
      'themeMode': 'neon',
      'fontSize': 999,
      'locale': 'fr',
      'renderer': 'vulkan',
      'accent': 'unknownTheme',
    });
    expect(s.themeMode, ThemeMode.system);
    expect(s.fontSize, SettingKeys.fontSize.defaultValue);
    expect(s.locale, isNull);
    expect(s.renderer, Renderer.skia);
    expect(s.accent, Accent.blue);
  });

  test('Settings survives a JSON round trip', () {
    const s = Settings({
      'themeMode': ThemeMode.dark,
      'fontSize': 16.0,
      'locale': 'zh',
      'renderer': Renderer.impeller,
      'accent': Accent.violet,
      'scrollback': 5000,
    });
    final copy = Settings.fromJson(s.toJson());
    expect(copy.renderer, Renderer.impeller);
    expect(copy.accent, Accent.violet);
    expect(copy.themeMode, ThemeMode.dark);
    expect(copy.fontSize, 16);
    expect(copy.locale, 'zh');
    expect(copy.get(SettingKeys.scrollback), 5000);
  });

  test('every definition accepts its own default and round-trips it', () {
    for (final d in SettingKeys.all) {
      expect(d.accepts(d.encode(d.defaultValue)), isTrue, reason: d.key);
    }
    expect(SettingKeys.all.map((d) => d.key).toSet(), hasLength(SettingKeys.all.length));
  });

  test('patch is all or nothing and keeps unexposed settings from the agent', () async {
    final dir = Directory.systemTemp.createTempSync('sshairy-settings');
    addTearDown(() => dir.deleteSync(recursive: true));
    final c = ProviderContainer(overrides: [dataDirProvider.overrideWithValue(dir.path)]);
    addTearDown(c.dispose);
    final n = c.read(settingsProvider.notifier);
    expect(await n.patch({'fontSize': 18, 'scrollback': 1.5}), isA<Err<void>>());
    expect(c.read(settingsProvider).fontSize, 14);
    expect(await n.patch({'confirmPaste': false}, exposedOnly: true), isA<Err<void>>());
    expect(await n.patch({'fontSize': 18, 'scrollback': 10000}), isA<Ok<void>>());
    expect(c.read(settingsProvider).get(SettingKeys.scrollback), 10000);
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

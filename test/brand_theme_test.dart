import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/design/brand.dart';
import 'package:sshairy/design/terminal_palette.dart';
import 'package:sshairy/design/theme.dart';
import 'package:sshairy/design/theme_names.dart';
import 'package:sshairy/features/settings/api.dart';
import 'package:sshairy/foundation/data_dir.dart';
import 'package:sshairy/foundation/result.dart';
import 'package:sshairy/l10n/app_localizations.dart';

class _Assets extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async => key == 'AssetManifest.bin'
      ? const StandardMessageCodec().encodeMessage(<String, Object?>{})!
      : ByteData.sublistView(File(key).readAsBytesSync());
}

void main() {
  test('all six themes retain their supplied brand colors and dark surfaces', () {
    const expected = {
      Accent.blue: (0xFF2E6EF7, 0xFF5AB6FF, 0xFF0B1420),
      Accent.green: (0xFF168A6A, 0xFF54D6AE, 0xFF0C1916),
      Accent.violet: (0xFF7353C7, 0xFFB79AFF, 0xFF14111E),
      Accent.orange: (0xFFD86B30, 0xFFFFAE70, 0xFF1D1510),
      Accent.deepSea: (0xFF19559E, 0xFF71AAE0, 0xFF0A131F),
      Accent.pink: (0xFFC4548E, 0xFFF4A1CB, 0xFF1D121A),
    };
    expect(Accent.values, hasLength(6));
    for (final MapEntry(key: theme, value: colors) in expected.entries) {
      expect(theme.palette(Brightness.light).primary, Color(colors.$1));
      expect(theme.palette(Brightness.dark).primary, Color(colors.$2));
      expect(theme.palette(Brightness.dark).background, Color(colors.$3));
    }
  });

  test('text, controls, status and ANSI stay readable in all twelve combinations', () {
    for (final accent in Accent.values) {
      for (final brightness in Brightness.values) {
        final theme = buildTheme(brightness, accent);
        final p = theme.extension<BrandPalette>()!;
        final terminal = TerminalPalette.of(theme);
        for (final background in [p.background, p.sidebar, p.surface, p.raised]) {
          for (final foreground in [p.text, p.textSecondary, p.controlPrimary]) {
            expect(
              colorContrast(foreground, background),
              greaterThanOrEqualTo(4.5),
              reason: '$accent $brightness text',
            );
          }
        }
        expect(colorContrast(theme.colorScheme.primary, theme.colorScheme.onPrimary), greaterThanOrEqualTo(4.5));
        expect(colorContrast(p.borderControl, p.surface), greaterThanOrEqualTo(3));
        expect(colorContrast(p.focus, p.background), greaterThanOrEqualTo(3));
        expect(colorContrast(p.onSelection, p.selection), greaterThanOrEqualTo(4.5));
        expect(colorContrast(terminal.foreground, terminal.background), greaterThanOrEqualTo(4.5));
        expect(colorContrast(terminal.selection, terminal.background), greaterThanOrEqualTo(2));
        expect(colorContrast(terminal.foreground, terminal.selection), greaterThanOrEqualTo(4.5));
        expect(terminal.ansi, hasLength(16));
        for (final color in terminal.ansi) {
          expect(
            colorContrast(color, terminal.background),
            greaterThanOrEqualTo(3),
            reason: '$accent $brightness ANSI',
          );
        }
        expect(colorContrast(terminal.searchHitForeground, terminal.searchHit), greaterThanOrEqualTo(4.5));
        expect(colorContrast(terminal.searchHitForeground, terminal.searchHitCurrent), greaterThanOrEqualTo(4.5));
      }
    }
  });

  test('existing saved accents remain valid and all six can be changed through the typed settings use case', () async {
    final dir = Directory.systemTemp.createTempSync('sshairy-brand-');
    addTearDown(() => dir.deleteSync(recursive: true));
    for (final value in ['blue', 'green', 'violet', 'orange']) {
      File('${dir.path}/settings.json').writeAsStringSync('{"schemaVersion":1,"accent":"$value"}');
      final container = ProviderContainer(overrides: [dataDirProvider.overrideWithValue(dir.path)]);
      expect(container.read(settingsProvider).accent.name, value);
      container.dispose();
    }
    final container = ProviderContainer(overrides: [dataDirProvider.overrideWithValue(dir.path)]);
    addTearDown(container.dispose);
    final notifier = container.read(settingsProvider.notifier);
    for (final theme in Accent.values) {
      expect(await notifier.patch({'accent': theme.name}), isA<Ok<void>>());
      expect(container.read(settingsProvider).accent, theme);
      expect(Settings.fromJson(container.read(settingsProvider).toJson()).accent, theme);
    }
  });

  test('every theme has its own imported mark, illustration, dark/light logo and decoration', () {
    for (final accent in Accent.values) {
      for (final path in [
        BrandAssets.mark(accent),
        BrandAssets.mascot(accent),
        for (final brightness in Brightness.values) ...[
          BrandAssets.logo(accent, brightness),
          BrandAssets.breeze(accent, brightness),
        ],
      ]) {
        expect(File(path).existsSync(), isTrue, reason: path);
      }
    }
  });

  testWidgets('theme previews apply immediately with keyboard and restore from disk', (tester) async {
    final dir = Directory.systemTemp.createTempSync('sshairy-brand-picker-');
    addTearDown(() => dir.deleteSync(recursive: true));
    await tester.binding.setSurfaceSize(const Size(440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    final container = ProviderContainer(overrides: [dataDirProvider.overrideWithValue(dir.path)]);
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: DefaultAssetBundle(
          bundle: _Assets(),
          child: Consumer(
            builder: (context, ref, _) {
              final settings = ref.watch(settingsProvider);
              return MaterialApp(
                theme: buildTheme(Brightness.light, settings.accent, settings.uiFontSize),
                darkTheme: buildTheme(Brightness.dark, settings.accent, settings.uiFontSize),
                themeMode: settings.themeMode,
                locale: Locale(settings.locale ?? 'en'),
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                home: const Scaffold(
                  body: Padding(padding: EdgeInsets.all(20), child: SettingsPanel()),
                ),
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final l = AppLocalizations.of(tester.element(find.byType(SettingsPanel)));
    for (final a in Accent.values) {
      expect(find.text(a.label(l)), findsOneWidget);
    }
    // Focus traversal can activate a theme without a pointer.
    final pink = find.ancestor(of: find.text(Accent.pink.label(l)), matching: find.byType(FocusableActionDetector));
    Focus.of(tester.element(find.descendant(of: pink, matching: find.byType(GestureDetector)).first)).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    for (var i = 0; i < 30 && container.read(settingsProvider).accent != Accent.pink; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 40));
    }
    expect(container.read(settingsProvider).accent, Accent.pink);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final restored = ProviderContainer(overrides: [dataDirProvider.overrideWithValue(dir.path)]);
    expect(restored.read(settingsProvider).accent, Accent.pink);
    restored.dispose();
    // The same grid must also fit the largest supported interface font and Chinese labels.
    await tester.runAsync(() => container.read(settingsProvider.notifier).patch({'uiFontSize': 18, 'locale': 'zh'}));
    await tester.pumpAndSettle();
    expect(find.text('樱花粉'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/design/interface_scale.dart';
import 'package:sshairy/design/theme.dart';
import 'package:sshairy/design/scrolling.dart';
import 'package:sshairy/features/settings/settings.dart';
import 'package:sshairy/features/settings/presentation/settings_panel.dart';
import 'package:sshairy/foundation/data_dir.dart';
import 'package:sshairy/l10n/app_localizations.dart';

void main() {
  testWidgets('interface scale applies from settings at minimum window size and persists independently of fonts', (
    tester,
  ) async {
    final dir = Directory.systemTemp.createTempSync('sshairy-scale-settings-');
    final container = ProviderContainer(
      overrides: [dataDirProvider.overrideWithValue(dir.path), systemFontsProvider.overrideWith((_) async => [])],
    );
    addTearDown(() {
      container.dispose();
      dir.deleteSync(recursive: true);
    });
    await tester.binding.setSurfaceSize(const Size(960, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          scrollBehavior: const AppScrollBehavior(),
          theme: buildTheme(Brightness.light).copyWith(platform: TargetPlatform.windows),
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (_, child) => Consumer(
            builder: (_, ref, _) => InterfaceScale(scale: ref.watch(settingsProvider).uiScale, child: child!),
          ),
          home: const Scaffold(
            body: Align(
              alignment: Alignment.topRight,
              child: SizedBox(width: 440, child: SettingsPanel()),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('100%'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('100%'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('150%'));
    for (var i = 0; i < 100 && container.read(settingsProvider).uiScale != 1.5; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(container.read(settingsProvider).uiScale, 1.5);
    expect(container.read(settingsProvider).uiFontSize, AppFonts.uiSize);
    expect(container.read(settingsProvider).fontSize, 14);
    await tester.ensureVisible(find.text('150%'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    final reopened = ProviderContainer(overrides: [dataDirProvider.overrideWithValue(dir.path)]);
    expect(reopened.read(settingsProvider).uiScale, 1.5);
    reopened.dispose();
  });
}

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/app/capabilities/settings.dart';
import 'package:sshairy/design/dialog.dart';
import 'package:sshairy/design/popup.dart';
import 'package:sshairy/design/scrolling.dart';
import 'package:sshairy/design/theme.dart';
import 'package:sshairy/features/capabilities/api.dart';
import 'package:sshairy/features/credentials/api.dart';
import 'package:sshairy/features/settings/api.dart';
import 'package:sshairy/features/terminal/presentation/translation_settings.dart';
import 'package:sshairy/foundation/data_dir.dart';
import 'package:sshairy/foundation/secret.dart';
import 'package:sshairy/l10n/app_localizations.dart';

class _Credentials implements TranslationCredentials {
  @override
  Future<bool> has(String identity) async => false;
  @override
  Future<Secret?> read(String identity) async => null;
  @override
  Future<void> save(String identity, Secret value) async => throw StateError('unexpected credential write');
  @override
  Future<void> clear(String identity) async => throw StateError('unexpected credential deletion');
}

void main() {
  Future<({ProviderContainer container, BuildContext context, FocusNode focus, PaletteEntry entry})> start(
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final dir = Directory.systemTemp.createTempSync('sshairy-settings-dialog-');
    final focus = FocusNode();
    final container = ProviderContainer(
      overrides: [
        dataDirProvider.overrideWithValue(dir.path),
        systemFontsProvider.overrideWith((_) async => []),
        settingsSectionsProvider.overrideWithValue([
          SettingsSection((l) => l.translationService, (_) => TranslationSettings(credentials: _Credentials())),
        ]),
      ],
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() => container.read(settingsProvider.notifier).saved);
      container.dispose();
      focus.dispose();
      dir.deleteSync(recursive: true);
    });
    await tester.runAsync(() async {
      container.read(settingsProvider);
      await container.read(settingsProvider.notifier).saved;
    });
    late BuildContext pageContext;
    late PaletteEntry entry;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          scrollBehavior: const AppScrollBehavior(),
          theme: buildTheme(Brightness.light).copyWith(platform: TargetPlatform.windows),
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) {
                pageContext = context;
                entry = settingsPaletteEntries(
                  PaletteContext(context, ref, AppLocalizations.of(context), (id, [args = const {}]) async {}),
                ).first;
                return TextButton(
                  focusNode: focus,
                  onPressed: () => showSettingsDialog(context),
                  child: const Text('Open'),
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    focus.requestFocus();
    await tester.pump();
    return (container: container, context: pageContext, focus: focus, entry: entry);
  }

  testWidgets('settings are centred, shared by palette and navigation, and restore focus on close', (tester) async {
    final env = await start(tester);
    final first = env.entry.run();
    final second = showSettingsDialog(env.context);
    final third = showSettingsDialog(env.context);
    expect(identical(second, third), isTrue);
    var paletteClosed = false, dialogClosed = false;
    first.then((_) => paletteClosed = true);
    second.then((_) => dialogClosed = true);
    await tester.pumpAndSettle();
    expect(find.byType(AppDialog), findsOneWidget);
    expect(find.byType(SettingsPanel), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
    final surface = tester.getRect(find.byType(PopupSurface));
    expect(surface.width, WorkspaceSize.settingsDialog);
    expect(surface.center, const Offset(600, 400));
    expect(env.focus.hasFocus, isFalse);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(AppDialog), findsNothing);
    expect(dialogClosed, isTrue, reason: 'the shared opening future completes when the dialog closes');
    expect(paletteClosed, isTrue, reason: 'the palette action completes when the shared dialog closes');
    expect(env.focus.hasFocus, isTrue);

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.byType(AppDialog), findsOneWidget);
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(find.byType(AppDialog), findsNothing);
    expect(env.focus.hasFocus, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('settings scroll internally and keep an unsaved translation draft when scrolling away', (tester) async {
    final env = await start(tester);
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    final list = find.descendant(of: find.byType(SettingsPanel), matching: find.byType(SingleChildScrollView));
    final email = find.widgetWithText(TextFormField, 'Email (optional)');
    final header = tester.getRect(find.byTooltip('Close'));
    await tester.ensureVisible(email);
    await tester.pumpAndSettle();
    await tester.enterText(email, 'unsaved@example.com');
    final draft = tester.state(find.byType(TranslationSettings));
    final scrollable = tester.state<ScrollableState>(
      find.descendant(of: list, matching: find.byType(Scrollable)).first,
    );
    scrollable.position.jumpTo(0);
    await tester.pumpAndSettle();
    expect(find.text('Appearance'), findsOneWidget);
    expect(tester.getRect(find.byTooltip('Close')), header);
    expect(tester.state(find.byType(TranslationSettings)), same(draft));
    await tester.ensureVisible(email);
    await tester.pumpAndSettle();
    expect(tester.widget<TextFormField>(email).controller!.text, 'unsaved@example.com');
    expect(env.container.read(settingsProvider).get(SettingKeys.completionTranslationConfig).myMemoryEmail, isEmpty);
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextFormField>(email).controller!.text, isEmpty);
    expect(tester.takeException(), isNull);
  });
}

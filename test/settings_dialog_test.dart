import 'dart:async';
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
import 'package:sshairy/features/ai/api.dart';
import 'package:sshairy/features/ai/application/model_catalog.dart';
import 'package:sshairy/features/ai/domain/model_catalog.dart';
import 'package:sshairy/features/ai/presentation/model_picker.dart';
import 'package:sshairy/foundation/cancellation.dart';
import 'package:sshairy/foundation/shortcuts.dart';
import 'package:sshairy/features/capabilities/api.dart';
import 'package:sshairy/features/credentials/api.dart';
import 'package:sshairy/features/settings/api.dart';
import 'package:sshairy/features/terminal/presentation/translation_settings.dart';
import 'package:sshairy/foundation/data_dir.dart';
import 'package:sshairy/foundation/secret.dart';
import 'package:sshairy/l10n/app_localizations.dart';

class _AiCredentials implements AiCredentials {
  final _changes = Stream<void>.empty();
  Completer<void>? holdSave;
  var writes = 0;
  @override
  Stream<void> get changes => _changes;
  @override
  Future<bool> has(String identity) async => false;
  @override
  Future<Secret?> read(String identity) async => throw StateError('unexpected secret read');
  @override
  Future<void> save(String identity, Secret value) async {
    writes++;
    await holdSave?.future;
  }

  @override
  Future<void> clear(String identity) async => throw StateError('unexpected credential deletion');
}

class _Catalog implements ModelCatalog {
  @override
  Future<List<String>> list({
    required ModelProtocol protocol,
    required String endpoint,
    required CancellationToken cancel,
    String? credentialIdentity,
    Secret? draftKey,
  }) async => const ['example-model'];
  @override
  void cancelAll() {}
  @override
  void close() {}
}

Future<void> _chooseModel(WidgetTester tester, String model) async {
  final picker = find.byKey(const ValueKey('ai-config-model'));
  await tester.ensureVisible(picker);
  await tester.pumpAndSettle();
  await tester.tap(find.descendant(of: picker, matching: find.byType(OutlinedButton)));
  await tester.pumpAndSettle();
  await tester.enterText(find.byKey(const ValueKey('ai-model-search')), model);
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(ValueKey('ai-model-option-$model')));
  await tester.pumpAndSettle();
}

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

Future<void> _drain(WidgetTester tester, ProviderContainer container) async {
  var saved = false;
  container.read(settingsProvider.notifier).saved.then((_) => saved = true);
  for (var attempt = 0; attempt < 200 && !saved; attempt++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump();
  }
  expect(saved, isTrue, reason: 'settings write must finish');
}

void main() {
  Future<({ProviderContainer container, BuildContext context, FocusNode focus, PaletteEntry entry})> start(
    WidgetTester tester, {
    bool withAi = false,
    _AiCredentials? aiCredentials,
  }) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final dir = Directory.systemTemp.createTempSync('sshairy-settings-dialog-');
    final focus = FocusNode();
    final container = ProviderContainer(
      overrides: [
        dataDirProvider.overrideWithValue(dir.path),
        systemFontsProvider.overrideWith((_) async => []),
        aiCredentialsProvider.overrideWithValue(aiCredentials ?? _AiCredentials()),
        aiModelCatalogProvider.overrideWithValue(_Catalog()),
        settingsSectionsProvider.overrideWithValue([
          if (withAi)
            SettingsSection(
              (l) => l.aiConfigTitle,
              (_) => const AiSettings(),
              id: SettingsSectionId.ai,
              icon: Icons.auto_awesome_outlined,
            ),
          SettingsSection(
            (l) => l.translationService,
            (_) => TranslationSettings(credentials: _Credentials()),
            id: SettingsSectionId.translation,
            icon: Icons.translate_outlined,
          ),
        ]),
      ],
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      var drained = false;
      Future.wait([
        container.read(settingsProvider.notifier).saved,
        if (withAi) container.read(aiConfigurationProvider.notifier).saved,
      ]).then((_) => drained = true);
      for (var attempt = 0; attempt < 200 && !drained; attempt++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump();
      }
      expect(drained, isTrue, reason: 'pending configuration writes must finish before disposal');
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
    final list = find.byKey(const ValueKey('settings-content'));
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
    expect(find.text('Appearance'), findsNWidgets(2));
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

  Finder tab(int index) => find.byKey(ValueKey('settings-tab-$index'));
  ScrollPosition contentPosition(WidgetTester tester) => tester
      .state<ScrollableState>(
        find.descendant(of: find.byKey(const ValueKey('settings-content')), matching: find.byType(Scrollable)).first,
      )
      .position;
  bool selected(WidgetTester tester, int index) =>
      tester
          .widget<Semantics>(find.ancestor(of: tab(index), matching: find.byType(Semantics)).first)
          .properties
          .selected ==
      true;

  testWidgets('category clicks scroll the continuous list and manual scrolling selects the category', (tester) async {
    await start(tester);
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(selected(tester, 0), isTrue);
    await tester.tap(tab(3));
    await tester.pumpAndSettle();
    expect(selected(tester, 3), isTrue);
    final position = contentPosition(tester);
    expect(position.pixels, greaterThan(0));
    position.jumpTo(0);
    await tester.pumpAndSettle();
    expect(selected(tester, 0), isTrue);
    position.jumpTo(position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(selected(tester, 7), isTrue);
    expect(find.text('About').hitTestable(), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('shortcut recorder stores a binding and reports a conflict', (tester) async {
    final env = await start(tester);
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(tab(3));
    await tester.pumpAndSettle();
    final field = find.byKey(const ValueKey('shortcut-commandPalette'));
    await tester.ensureVisible(field);
    await tester.pumpAndSettle();
    await tester.tap(field);
    await tester.pump();
    expect(find.text('Press keys…'), findsOneWidget);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyQ);
    await tester.pump();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyQ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.pumpAndSettle();
    expect(find.text('Press keys…'), findsNothing);
    expect(find.textContaining('Already used'), findsNothing);
    expect(find.byType(AppDialog), findsOneWidget);
    expect(field, findsOneWidget);
    final inner = tester.widget<Focus>(find.descendant(of: field, matching: find.byType(Focus)).first);
    expect(inner.focusNode!.hasFocus, isTrue, reason: 'recorder has focus');
    await _drain(tester, env.container);
    expect(env.container.read(settingsProvider).shortcuts[AppShortcutAction.commandPalette.name], 'Alt+Q');
    await tester.tap(field);
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.pumpAndSettle();
    await _drain(tester, env.container);
    expect(find.text('Already used by Generate command inline'), findsOneWidget);
    expect(env.container.read(settingsProvider).shortcuts[AppShortcutAction.commandPalette.name], 'Alt+Q');
    expect(tester.takeException(), isNull);
  });

  for (final withAi in [false, true]) {
    testWidgets('opening a targeted section uses its identity with AI present: $withAi', (tester) async {
      final env = await start(tester, withAi: withAi);
      showSettingsDialog(env.context, section: SettingsSectionId.translation);
      await tester.pumpAndSettle();
      expect(selected(tester, withAi ? 7 : 6), isTrue);
      expect(find.widgetWithText(TextFormField, 'Email (optional)').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('targeted opening reuses the dialog and preserves drafts while changing sections', (tester) async {
    final env = await start(tester, withAi: true);
    final first = showSettingsDialog(env.context, section: SettingsSectionId.appearance);
    final pending = showSettingsDialog(env.context, section: SettingsSectionId.ai);
    expect(identical(first, pending), isTrue);
    await tester.pumpAndSettle();
    expect(selected(tester, 6), isTrue);
    await tester.enterText(find.byKey(const ValueKey('ai-config-endpoint')), 'https://example.com/v1');
    await tester.pumpAndSettle();
    await _chooseModel(tester, 'pending-model');
    final form = tester.state(find.byType(AiSettings));
    final reopened = showSettingsDialog(env.context, section: SettingsSectionId.translation);
    expect(identical(first, reopened), isTrue);
    await tester.pumpAndSettle();
    expect(find.byType(AppDialog), findsOneWidget);
    expect(selected(tester, 7), isTrue);
    expect(tester.state(find.byType(AiSettings)), same(form));
    expect(tester.widget<AiModelPicker>(find.byKey(const ValueKey('ai-config-model'))).value, 'pending-model');
    showSettingsDialog(env.context);
    await tester.pumpAndSettle();
    expect(selected(tester, 7), isTrue, reason: 'the general entry does not reset an already open dialog');
    showSettingsDialog(env.context, section: SettingsSectionId.security);
    await tester.pumpAndSettle();
    expect(selected(tester, 7), isTrue, reason: 'an unavailable optional section leaves the current position intact');
    expect(tester.takeException(), isNull);
  });

  testWidgets('one fixed footer saves AI and translation drafts while retaining immediate appearance changes', (
    tester,
  ) async {
    final env = await start(tester, withAi: true);
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    final save = find.byKey(const ValueKey('settings-save'));
    expect(save, findsNothing);
    await tester.tap(tab(6));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('ai-config-endpoint')), 'https://example.com/v1');
    await tester.pumpAndSettle();
    await _chooseModel(tester, 'example-model');
    expect(save, findsOneWidget);
    expect(find.byKey(const ValueKey('ai-config-save')), findsNothing);
    final footer = tester.getRect(save);
    await tester.tap(tab(7));
    await tester.pumpAndSettle();
    final email = find.widgetWithText(TextFormField, 'Email (optional)');
    await tester.enterText(email, 'pending@example.com');
    await tester.pumpAndSettle();
    expect(find.widgetWithText(FilledButton, 'Save'), findsOneWidget);
    await tester.runAsync(() => env.container.read(settingsProvider.notifier).set(SettingKeys.fontSize, 16.0));
    await tester.pumpAndSettle();
    expect(find.text('Settings changed. Cancel your edits before trying again.'), findsNothing);
    contentPosition(tester).jumpTo(0);
    await tester.pumpAndSettle();
    expect(tester.getRect(save), footer, reason: 'Save stays outside the scrolling content');
    expect(env.container.read(aiConfigurationProvider).profile, isNull);
    expect(env.container.read(settingsProvider).get(SettingKeys.completionTranslationConfig).myMemoryEmail, isEmpty);
    await tester.tap(save);
    for (var attempt = 0; attempt < 100 && save.evaluate().isNotEmpty; attempt++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(save, findsNothing);
    expect(env.container.read(aiConfigurationProvider).profile!.model, 'example-model');
    expect(
      env.container.read(settingsProvider).get(SettingKeys.completionTranslationConfig).myMemoryEmail,
      'pending@example.com',
    );
    expect(env.container.read(settingsProvider).fontSize, 16.0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('saving credentials blocks closing by Close Escape and barrier until the save completes', (tester) async {
    final credentials = _AiCredentials()..holdSave = Completer<void>();
    addTearDown(() {
      if (!credentials.holdSave!.isCompleted) credentials.holdSave!.complete();
    });
    final env = await start(tester, withAi: true, aiCredentials: credentials);
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(tab(6));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('ai-config-endpoint')), 'https://example.com/v1');
    await tester.pumpAndSettle();
    await _chooseModel(tester, 'example-model');
    final key = find.byKey(const ValueKey('ai-config-key'));
    await tester.ensureVisible(key);
    await tester.pumpAndSettle();
    await tester.enterText(key, 'synthetic-key');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-save')));
    await tester.pump();
    expect(credentials.writes, 1);
    expect(tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.close)).onPressed, isNull);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.tapAt(const Offset(8, 8));
    await tester.pump();
    expect(find.byType(AppDialog), findsOneWidget);
    credentials.holdSave!.complete();
    for (
      var attempt = 0;
      attempt < 200 && find.byKey(const ValueKey('settings-save')).evaluate().isNotEmpty;
      attempt++
    ) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(env.container.read(aiConfigurationProvider).profile!.model, 'example-model');
    expect(find.byKey(const ValueKey('settings-save')), findsNothing);
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(find.byType(AppDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed form validation keeps its draft and focuses its category, reset removes the footer', (
    tester,
  ) async {
    final env = await start(tester);
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(tab(6));
    await tester.pumpAndSettle();
    final email = find.widgetWithText(TextFormField, 'Email (optional)');
    await tester.enterText(email, 'invalid address');
    await tester.pumpAndSettle();
    await tester.tap(tab(0));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-save')));
    await tester.pumpAndSettle();
    expect(selected(tester, 6), isTrue);
    expect(find.text('Enter a valid email address of up to 254 ASCII characters.'), findsOneWidget);
    expect(tester.widget<TextFormField>(email).controller!.text, 'invalid address');
    expect(env.container.read(settingsProvider).get(SettingKeys.completionTranslationConfig).myMemoryEmail, isEmpty);
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('settings-save')), findsNothing);
    expect(tester.widget<TextFormField>(email).controller!.text, isEmpty);
    expect(tester.takeException(), isNull);
  });
}

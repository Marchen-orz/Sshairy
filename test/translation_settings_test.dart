import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/design/controls.dart';
import 'package:sshairy/design/dialog.dart';
import 'package:sshairy/design/select.dart';
import 'package:sshairy/design/theme.dart';
import 'package:sshairy/features/credentials/api.dart';
import 'package:sshairy/features/settings/api.dart';
import 'package:sshairy/features/terminal/presentation/translation_settings.dart';
import 'package:sshairy/foundation/data_dir.dart';
import 'package:sshairy/foundation/secret.dart';
import 'package:sshairy/l10n/app_localizations.dart';

class _Credentials implements TranslationCredentials {
  final values = <String, Secret>{};
  final saved = <String>[];
  final cleared = <String>[];
  final checked = <String>[];
  var reads = 0, failChecks = false;
  Completer<void>? holdSave;

  @override
  Future<bool> has(String identity) async {
    checked.add(identity);
    if (failChecks) throw StateError('secure storage unavailable');
    return values.containsKey(identity);
  }

  @override
  Future<Secret?> read(String identity) async {
    reads++;
    return values[identity];
  }

  @override
  Future<void> save(String identity, Secret value) async {
    saved.add(identity);
    values[identity] = value;
    final held = holdSave;
    if (held != null) await held.future;
  }

  @override
  Future<void> clear(String identity) async {
    cleared.add(identity);
    values.remove(identity);
  }
}

class _ControlledSettings extends SettingsNotifier {
  Completer<void>? holdSave;
  var failWrites = false;
  var _revision = 0;

  @override
  Settings build() => const Settings();

  @override
  int get revision => _revision;

  @override
  Future<void> get saved async {}

  @override
  Future<void> set<T>(SettingDef<T> setting, T value) async {
    final held = holdSave;
    if (held != null) await held.future;
    if (failWrites) throw const FileSystemException('disk full');
    _revision++;
    state = state.copyWith({setting.key: value});
  }
}

void main() {
  const conflict = 'Settings changed. Cancel your edits before trying again.';
  const saveFailure = 'Could not save. A key change may already have been saved to secure storage.';
  Finder getSave() => find.widgetWithText(FilledButton, 'Save');
  Finder getCancel() => find.widgetWithText(TextButton, 'Cancel');
  Finder field(String label) => find.widgetWithText(TextFormField, label);
  Finder keyField() => find.byWidgetPredicate((widget) => widget is TextField && widget.obscureText);

  Future<ProviderContainer> showSettings(
    WidgetTester tester,
    _Credentials credentials,
    TranslationConfig config, {
    VoidCallback? onCredentialsChanged,
    bool wholePanel = false,
    _ControlledSettings? controlledSettings,
  }) async {
    await tester.binding.setSurfaceSize(Size(900, wholePanel ? 4000 : 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final dir = Directory.systemTemp.createTempSync('sshairy-translation-settings');
    final section = SettingsSection(
      (l) => l.translationService,
      (_) => TranslationSettings(credentials: credentials, onCredentialsChanged: onCredentialsChanged),
    );
    final container = ProviderContainer(
      overrides: [
        dataDirProvider.overrideWithValue(dir.path),
        if (controlledSettings != null) settingsProvider.overrideWith(() => controlledSettings),
        if (wholePanel) settingsSectionsProvider.overrideWithValue([section]),
        if (wholePanel) systemFontsProvider.overrideWith((_) async => []),
      ],
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() => container.read(settingsProvider.notifier).saved);
      container.dispose();
      dir.deleteSync(recursive: true);
    });
    await tester.runAsync(
      () => container.read(settingsProvider.notifier).set(SettingKeys.completionTranslationConfig, config),
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildTheme(Brightness.light, Accent.blue),
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 400,
                child: wholePanel
                    ? const SettingsPanel()
                    : SingleChildScrollView(child: Builder(builder: section.build)),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  Future<void> drain(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 2)));
      await tester.pump(const Duration(milliseconds: 2));
    }
  }

  Future<void> save(WidgetTester tester, ProviderContainer container) async {
    await tester.pump();
    expect(tester.widget<FilledButton>(getSave()).onPressed, isNotNull);
    await tester.runAsync(() async {
      await tester.tap(getSave());
      await Future<void>.delayed(Duration.zero);
      await container.read(settingsProvider.notifier).saved;
    });
    await drain(tester);
    await tester.pumpAndSettle();
  }

  Future<void> selectProvider(WidgetTester tester, TranslationProvider provider) async {
    tester.widget<AppSelect<TranslationProvider>>(find.byType(AppSelect<TranslationProvider>)).onChanged!(provider);
    await tester.pumpAndSettle();
  }

  testWidgets('service dropdown is first below the switch and all translation settings stay inline', (tester) async {
    final credentials = _Credentials();
    final container = await showSettings(tester, credentials, const TranslationConfig(), wholePanel: true);
    final section = find.byType(TranslationSettings);
    final label = find.text('Translate completion descriptions automatically');
    final provider = find.byType(AppSelect<TranslationProvider>);
    final concurrency = find.byType(AppSelect<int>).last;
    expect(find.text('Confirm multi-line paste'), findsOneWidget);
    expect(label, findsOneWidget);
    expect(find.descendant(of: section, matching: label), findsOneWidget);
    expect(find.descendant(of: section, matching: provider), findsOneWidget);
    final toggle = find.descendant(of: section, matching: find.byType(AppSwitch));
    expect(tester.getTopLeft(provider).dy, greaterThan(tester.getBottomLeft(toggle).dy));
    expect(tester.getTopLeft(provider).dy, lessThan(tester.getTopLeft(field('Email (optional)')).dy));
    expect(tester.getTopLeft(getSave()).dy, lessThan(tester.getTopLeft(concurrency).dy));
    expect(find.byType(AppDialog), findsNothing);
    expect(tester.widget<FilledButton>(getSave()).onPressed, isNull);
    final select = tester.widget<AppSelect<int>>(concurrency);
    expect(select.value, 0);
    expect(select.options.map((option) => option.value), List.generate(33, (value) => value));
    expect(select.options.first.label, 'Auto (all visible)');
    await tester.runAsync(() async {
      select.onChanged!(3);
      await Future<void>.delayed(Duration.zero);
      await container.read(settingsProvider.notifier).saved;
    });
    await drain(tester);
    expect(container.read(settingsProvider).get(SettingKeys.completionTranslationConcurrency), 3);
    expect(tester.widget<AppSelect<int>>(concurrency).value, 3);
    expect(credentials.saved, isEmpty);
    expect(credentials.cleared, isEmpty);
    expect(credentials.reads, 0);
  });

  testWidgets('inline MyMemory email validates, saves explicitly and can be cleared', (tester) async {
    final credentials = _Credentials();
    final container = await showSettings(tester, credentials, const TranslationConfig());
    final email = field('Email (optional)');
    await tester.enterText(email, 'invalid address');
    await save(tester, container);
    expect(find.text('Enter a valid email address of up to 254 ASCII characters.'), findsOneWidget);
    expect(container.read(settingsProvider).get(SettingKeys.completionTranslationConfig).myMemoryEmail, isEmpty);
    await tester.enterText(email, '  translator+desktop@example.com  ');
    expect(container.read(settingsProvider).get(SettingKeys.completionTranslationConfig).myMemoryEmail, isEmpty);
    await save(tester, container);
    expect(
      container.read(settingsProvider).get(SettingKeys.completionTranslationConfig).myMemoryEmail,
      'translator+desktop@example.com',
    );
    expect(tester.widget<FilledButton>(getSave()).onPressed, isNull);
    await tester.enterText(email, '');
    await save(tester, container);
    expect(container.read(settingsProvider).get(SettingKeys.completionTranslationConfig).myMemoryEmail, isEmpty);
    expect(credentials.checked, isEmpty);
    expect(credentials.saved, isEmpty);
    expect(credentials.reads, 0);
  });

  testWidgets('provider changes are drafts until Save and Cancel restores the latest config', (tester) async {
    final container = await showSettings(
      tester,
      _Credentials(),
      const TranslationConfig(myMemoryEmail: 'old@example.com'),
    );
    await selectProvider(tester, TranslationProvider.google);
    expect(keyField(), findsOneWidget);
    expect(field('Email (optional)'), findsNothing);
    expect(
      container.read(settingsProvider).get(SettingKeys.completionTranslationConfig).provider,
      TranslationProvider.myMemory,
    );
    await tester.tap(getCancel());
    await tester.pumpAndSettle();
    expect(
      tester.widget<AppSelect<TranslationProvider>>(find.byType(AppSelect<TranslationProvider>)).value,
      TranslationProvider.myMemory,
    );
    expect(tester.widget<TextFormField>(field('Email (optional)')).controller!.text, 'old@example.com');
    await selectProvider(tester, TranslationProvider.google);
    await save(tester, container);
    final config = container.read(settingsProvider).get(SettingKeys.completionTranslationConfig);
    expect(config.provider, TranslationProvider.google);
    expect(config.myMemoryEmail, isEmpty);
    expect(find.byType(AppDialog), findsNothing);
  });

  testWidgets('translation settings disable while saving and keep failed values unchanged', (tester) async {
    final settings = _ControlledSettings();
    final container = await showSettings(
      tester,
      _Credentials(),
      const TranslationConfig(),
      controlledSettings: settings,
    );
    settings.holdSave = Completer<void>();
    await tester.tap(find.byType(AppSwitch));
    await tester.pump();
    expect(tester.widget<AppSwitch>(find.byType(AppSwitch)).onChanged, isNull);
    expect(tester.widget<AppSelect<int>>(find.byType(AppSelect<int>)).onChanged, isNull);
    expect(
      tester.widget<AppSelect<TranslationProvider>>(find.byType(AppSelect<TranslationProvider>)).onChanged,
      isNull,
    );
    expect(tester.widget<TextButton>(getCancel()).onPressed, isNull);
    expect(container.read(settingsProvider).get(SettingKeys.completionTranslation), isTrue);
    settings.holdSave!.complete();
    await tester.pumpAndSettle();
    expect(container.read(settingsProvider).get(SettingKeys.completionTranslation), isFalse);
    expect(tester.widget<AppSwitch>(find.byType(AppSwitch)).onChanged, isNotNull);
    settings.holdSave = null;
    settings.failWrites = true;
    tester.widget<AppSelect<int>>(find.byType(AppSelect<int>)).onChanged!(2);
    await tester.pumpAndSettle();
    expect(find.text('Could not save. Check access to the data directory and secure storage.'), findsOneWidget);
    expect(container.read(settingsProvider).get(SettingKeys.completionTranslationConcurrency), 0);
    expect(tester.widget<AppSelect<int>>(find.byType(AppSelect<int>)).value, 0);
    expect(tester.widget<AppSwitch>(find.byType(AppSwitch)).onChanged, isNotNull);
    settings.failWrites = false;
    tester.widget<AppSelect<int>>(find.byType(AppSelect<int>)).onChanged!(2);
    await tester.pumpAndSettle();
    expect(container.read(settingsProvider).get(SettingKeys.completionTranslationConcurrency), 2);
    expect(find.text('Could not save. Check access to the data directory and secure storage.'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('blank key retains the saved key; removal is explicit and never reads its value', (tester) async {
    final credentials = _Credentials()..values['google'] = const Secret('existing-secret');
    var changes = 0;
    final container = await showSettings(
      tester,
      credentials,
      const TranslationConfig(provider: TranslationProvider.google),
      onCredentialsChanged: () => changes++,
    );
    expect(find.text('Key saved · leave blank to keep'), findsOneWidget);
    expect(find.text('existing-secret'), findsNothing);
    expect(tester.widget<FilledButton>(getSave()).onPressed, isNull);
    await selectProvider(tester, TranslationProvider.microsoft);
    await selectProvider(tester, TranslationProvider.google);
    expect(tester.widget<FilledButton>(getSave()).onPressed, isNull);
    expect(credentials.saved, isEmpty);
    expect(credentials.cleared, isEmpty);
    expect(credentials.reads, 0);
    expect(changes, 0);
    await tester.tap(find.text('Remove saved key'));
    await tester.pump();
    expect(credentials.cleared, isEmpty);
    await save(tester, container);
    expect(credentials.cleared, ['google']);
    expect(credentials.reads, 0);
    expect(changes, 1);
    expect(find.text('No saved key'), findsOneWidget);
  });

  testWidgets('saving a new model with a blank key retains the saved destination key', (tester) async {
    const initial = TranslationConfig(
      provider: TranslationProvider.openAi,
      endpoint: 'https://first.example/v1',
      model: 'translate',
    );
    final credentials = _Credentials()..values[initial.credentialId] = const Secret('existing-secret');
    var changes = 0;
    final container = await showSettings(tester, credentials, initial, onCredentialsChanged: () => changes++);
    await tester.enterText(field('Model'), 'updated-model');
    await save(tester, container);
    expect(container.read(settingsProvider).get(SettingKeys.completionTranslationConfig).model, 'updated-model');
    expect(credentials.values[initial.credentialId], isNotNull);
    expect(credentials.saved, isEmpty);
    expect(credentials.cleared, isEmpty);
    expect(credentials.reads, 0);
    expect(changes, 0);
    expect(find.text('Key saved · leave blank to keep'), findsOneWidget);
  });

  testWidgets('changed OpenAI destinations clear unsaved keys and never reuse the previous key', (tester) async {
    const initial = TranslationConfig(
      provider: TranslationProvider.openAi,
      endpoint: 'https://first.example/v1',
      model: 'translate',
    );
    final credentials = _Credentials()..values[initial.credentialId] = const Secret('old-key');
    final container = await showSettings(tester, credentials, initial);
    expect(find.text('Key saved · leave blank to keep'), findsOneWidget);
    await tester.enterText(keyField(), 'unsaved-old-destination-key');
    await tester.enterText(field('API base URL'), 'https://second.example/v1');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(find.text('No saved key'), findsOneWidget);
    expect(tester.widget<TextField>(keyField()).controller!.text, isEmpty);
    await tester.enterText(keyField(), 'new-key');
    await save(tester, container);
    expect(credentials.saved, ['openAi:https://second.example/v1']);
    expect(credentials.values[initial.credentialId], isNotNull);
    expect(credentials.reads, 0);
    expect(
      container.read(settingsProvider).get(SettingKeys.completionTranslationConfig).endpoint,
      'https://second.example/v1',
    );
  });

  testWidgets('DeepL tier and Microsoft region select their own credential identities', (tester) async {
    final credentials = _Credentials()
      ..values['deepL:free'] = const Secret('free-key')
      ..values['microsoft:eastus'] = const Secret('region-key');
    await showSettings(tester, credentials, const TranslationConfig(provider: TranslationProvider.deepL));
    expect(find.text('Key saved · leave blank to keep'), findsOneWidget);
    await tester.tap(find.byType(AppSwitch).last);
    await tester.pumpAndSettle();
    expect(credentials.checked.last, 'deepL:pro');
    expect(find.text('No saved key'), findsOneWidget);
    await selectProvider(tester, TranslationProvider.microsoft);
    await tester.enterText(field('Region (optional)'), 'eastus');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(credentials.checked.last, 'microsoft:eastus');
    expect(find.text('Key saved · leave blank to keep'), findsOneWidget);
    expect(credentials.reads, 0);
  });

  testWidgets('credential check failure can retry through Cancel without reading stored keys', (tester) async {
    final credentials = _Credentials()..failChecks = true;
    await showSettings(tester, credentials, const TranslationConfig(provider: TranslationProvider.google));
    expect(find.text('Could not check secure storage. Cancel to try again.'), findsOneWidget);
    expect(tester.widget<FilledButton>(getSave()).onPressed, isNull);
    expect(tester.widget<TextButton>(getCancel()).onPressed, isNotNull);
    credentials.failChecks = false;
    await tester.tap(getCancel());
    await tester.pumpAndSettle();
    expect(find.text('No saved key'), findsOneWidget);
    expect(credentials.checked, ['google', 'google']);
    expect(credentials.reads, 0);
  });

  testWidgets('clean form follows external config while dirty edits survive conflicts until Cancel', (tester) async {
    final container = await showSettings(tester, _Credentials(), const TranslationConfig());
    final notifier = container.read(settingsProvider.notifier);
    await tester.runAsync(
      () => notifier.set(
        SettingKeys.completionTranslationConfig,
        const TranslationConfig(myMemoryEmail: 'external@example.com'),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.widget<TextFormField>(field('Email (optional)')).controller!.text, 'external@example.com');
    expect(find.text(conflict), findsNothing);
    await tester.enterText(field('Email (optional)'), 'draft@example.com');
    await tester.runAsync(
      () => notifier.set(
        SettingKeys.completionTranslationConfig,
        const TranslationConfig(myMemoryEmail: 'latest@example.com'),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.widget<TextFormField>(field('Email (optional)')).controller!.text, 'draft@example.com');
    expect(find.text(conflict), findsOneWidget);
    expect(tester.widget<FilledButton>(getSave()).onPressed, isNull);
    await tester.tap(getCancel());
    await tester.pumpAndSettle();
    expect(tester.widget<TextFormField>(field('Email (optional)')).controller!.text, 'latest@example.com');
    expect(find.text(conflict), findsNothing);
  });

  testWidgets('own switch and concurrency saves preserve a dirty form without causing a conflict', (tester) async {
    final container = await showSettings(tester, _Credentials(), const TranslationConfig());
    final notifier = container.read(settingsProvider.notifier);
    await tester.enterText(field('Email (optional)'), 'draft@example.com');
    await tester.runAsync(() async {
      tester.widget<AppSwitch>(find.byType(AppSwitch)).onChanged!(false);
      await Future<void>.delayed(Duration.zero);
      await notifier.saved;
    });
    await drain(tester);
    expect(find.text(conflict), findsNothing);
    await tester.runAsync(() async {
      tester.widget<AppSelect<int>>(find.byType(AppSelect<int>)).onChanged!(2);
      await Future<void>.delayed(Duration.zero);
      await notifier.saved;
    });
    await drain(tester);
    expect(find.text(conflict), findsNothing);
    expect(tester.widget<TextFormField>(field('Email (optional)')).controller!.text, 'draft@example.com');
    await save(tester, container);
    expect(
      container.read(settingsProvider).get(SettingKeys.completionTranslationConfig).myMemoryEmail,
      'draft@example.com',
    );
    expect(container.read(settingsProvider).get(SettingKeys.completionTranslation), isFalse);
    expect(container.read(settingsProvider).get(SettingKeys.completionTranslationConcurrency), 2);
  });

  testWidgets('an external setting change is not hidden by a later own switch write', (tester) async {
    final container = await showSettings(tester, _Credentials(), const TranslationConfig());
    await tester.enterText(field('Email (optional)'), 'draft@example.com');
    await tester.runAsync(() => container.read(settingsProvider.notifier).set(SettingKeys.fontSize, 16.0));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      tester.widget<AppSwitch>(find.byType(AppSwitch)).onChanged!(false);
      await Future<void>.delayed(Duration.zero);
      await container.read(settingsProvider.notifier).saved;
    });
    await drain(tester);
    expect(find.text(conflict), findsOneWidget);
    expect(tester.widget<FilledButton>(getSave()).onPressed, isNull);
    expect(container.read(settingsProvider).get(SettingKeys.completionTranslationConfig).myMemoryEmail, isEmpty);
    expect(tester.widget<TextFormField>(field('Email (optional)')).controller!.text, 'draft@example.com');
  });

  testWidgets('credential changes still notify when a later settings revision conflicts', (tester) async {
    final credentials = _Credentials()..holdSave = Completer<void>();
    var changes = 0;
    final container = await showSettings(
      tester,
      credentials,
      const TranslationConfig(provider: TranslationProvider.google),
      onCredentialsChanged: () => changes++,
    );
    await tester.enterText(keyField(), 'new-key');
    await tester.pump();
    expect(tester.widget<FilledButton>(getSave()).onPressed, isNotNull);
    await tester.runAsync(() async {
      await tester.tap(getSave());
      for (var i = 0; i < 20 && credentials.saved.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(credentials.saved, ['google']);
      await container.read(settingsProvider.notifier).set(SettingKeys.fontSize, 16.0);
      credentials.holdSave!.complete();
      await Future<void>.delayed(Duration.zero);
      await container.read(settingsProvider.notifier).saved;
    });
    final error = find.text(saveFailure);
    for (var i = 0; i < 100 && error.evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 1)));
      await tester.pump(const Duration(milliseconds: 1));
    }
    expect(credentials.saved, ['google']);
    expect(changes, 1);
    expect(credentials.reads, 0);
    expect(error, findsOneWidget);
    expect(find.byType(AppDialog), findsNothing);
  });
}

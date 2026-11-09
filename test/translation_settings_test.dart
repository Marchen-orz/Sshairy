import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
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
  var reads = 0;
  Completer<void>? holdSave;

  @override
  Future<bool> has(String identity) async => values.containsKey(identity);
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

void main() {
  Future<ProviderContainer> showSettings(
    WidgetTester tester,
    _Credentials credentials,
    TranslationConfig config, {
    VoidCallback? onCredentialsChanged,
  }) async {
    final dir = Directory.systemTemp.createTempSync('sshairy-translation-settings');
    final container = ProviderContainer(overrides: [dataDirProvider.overrideWithValue(dir.path)]);
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
            body: TranslationSettings(credentials: credentials, onCredentialsChanged: onCredentialsChanged),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(TextButton).first);
    await tester.pumpAndSettle();
    return container;
  }

  Future<void> save(WidgetTester tester, ProviderContainer container) async {
    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await Future<void>.delayed(Duration.zero);
      await container.read(settingsProvider.notifier).saved;
    });
    await tester.pumpAndSettle();
  }

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
    await save(tester, container);
    expect(find.byType(AppDialog), findsNothing);
    expect(credentials.saved, isEmpty);
    expect(credentials.cleared, isEmpty);
    expect(credentials.reads, 0);
    expect(changes, 0);
    expect(
      container.read(settingsProvider).get(SettingKeys.completionTranslationConfig).provider,
      TranslationProvider.google,
    );

    await tester.tap(find.byType(TextButton).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove saved key'));
    await tester.pump();
    expect(credentials.cleared, isEmpty);
    await save(tester, container);
    expect(credentials.cleared, ['google']);
    expect(credentials.reads, 0);
    expect(changes, 1);
  });

  testWidgets('provider selection and changed OpenAI destinations do not reuse the previous key', (tester) async {
    const initial = TranslationConfig(
      provider: TranslationProvider.openAi,
      endpoint: 'https://first.example/v1',
      model: 'translate',
    );
    final credentials = _Credentials()..values[initial.credentialId] = const Secret('old-key');
    final container = await showSettings(tester, credentials, initial);
    expect(find.text('Key saved · leave blank to keep'), findsOneWidget);
    final endpoint = find.widgetWithText(TextFormField, 'API base URL');
    await tester.enterText(endpoint, 'https://second.example/v1');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(find.text('No saved key'), findsOneWidget);
    final key = find.byType(TextField).last;
    await tester.enterText(key, 'new-key');
    await save(tester, container);
    expect(credentials.saved, ['openAi:https://second.example/v1']);
    expect(credentials.values[initial.credentialId], isNotNull);
    expect(credentials.reads, 0);
    expect(
      container.read(settingsProvider).get(SettingKeys.completionTranslationConfig).endpoint,
      'https://second.example/v1',
    );

    await tester.tap(find.byType(TextButton).first);
    await tester.pumpAndSettle();
    tester.widget<AppSelect<TranslationProvider>>(find.byType(AppSelect<TranslationProvider>)).onChanged!(
      TranslationProvider.myMemory,
    );
    await tester.pumpAndSettle();
    expect(find.text('No key required · 5,000 free characters/day'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
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
    await tester.enterText(find.byType(TextField), 'new-key');
    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      for (var i = 0; i < 20 && credentials.saved.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      await container.read(settingsProvider.notifier).set(SettingKeys.fontSize, 16.0);
      credentials.holdSave!.complete();
      await Future<void>.delayed(Duration.zero);
      await container.read(settingsProvider.notifier).saved;
    });
    final error = find.text('Could not save. A key change may already have been saved to secure storage.');
    for (var i = 0; i < 100 && error.evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 1)));
      await tester.pump(const Duration(milliseconds: 1));
    }
    expect(credentials.saved, ['google']);
    expect(changes, 1);
    expect(credentials.reads, 0);
    expect(error, findsOneWidget);
    expect(find.byType(AppDialog), findsOneWidget);
  });
}

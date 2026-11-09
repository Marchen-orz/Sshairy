import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/features/credentials/api.dart';
import 'package:sshairy/features/settings/api.dart';
import 'package:sshairy/features/terminal/application/completion_translations.dart';
import 'package:sshairy/foundation/data_dir.dart';
import 'package:sshairy/foundation/secret.dart';

class _Credentials implements TranslationCredentials {
  var reads = 0;
  @override
  Future<Secret?> read(String identity) async {
    reads++;
    return null;
  }

  @override
  Future<bool> has(String identity) async => false;
  @override
  Future<void> save(String identity, Secret value) async {}
  @override
  Future<void> clear(String identity) async {}
}

void main() {
  test('active translator follows only service settings, concurrency and credential invalidation', () async {
    final directory = Directory.systemTemp.createTempSync('sshairy-translation-provider-');
    final credentials = _Credentials();
    final container = ProviderContainer(
      overrides: [
        dataDirProvider.overrideWithValue(directory.path),
        translationCredentialsProvider.overrideWithValue(credentials),
      ],
    );
    final settings = container.read(settingsProvider.notifier);
    final subscription = container.listen(completionTranslationsProvider, (_, _) {});
    try {
      final initial = container.read(completionTranslationsProvider);
      await initial.ready;
      await settings.set(SettingKeys.fontSize, 15.0);
      await settings.set(SettingKeys.completionTranslation, false);
      expect(identical(container.read(completionTranslationsProvider), initial), isTrue);

      await settings.set(SettingKeys.completionTranslationConcurrency, 3);
      final limited = container.read(completionTranslationsProvider);
      await limited.ready;
      expect(identical(limited, initial), isFalse);

      await settings.set(
        SettingKeys.completionTranslationConfig,
        const TranslationConfig(
          provider: TranslationProvider.openAi,
          endpoint: 'https://example.com/v1',
          model: 'model',
        ),
      );
      final configured = container.read(completionTranslationsProvider);
      await configured.ready;
      expect(identical(configured, limited), isFalse);

      container.invalidate(completionTranslationsProvider);
      final refreshed = container.read(completionTranslationsProvider);
      await refreshed.ready;
      expect(identical(refreshed, configured), isFalse);
      expect(credentials.reads, 0, reason: 'loading a service or cache must not read keys or start HTTP');
      expect(
        directory.listSync(recursive: true).whereType<File>().any((file) => file.path.endsWith('apiKey')),
        isFalse,
      );
      await Future.wait([initial.saved, limited.saved, configured.saved, refreshed.saved]);
    } finally {
      subscription.close();
      await settings.saved;
      container.dispose();
      directory.deleteSync(recursive: true);
    }
  });

  test('MyMemory email changes recreate the engine without changing translation history', () async {
    final directory = Directory.systemTemp.createTempSync('sshairy-email-cache-');
    final cache = File('${directory.path}/cache/completion-translations/myMemory/completion-translations.json');
    await cache.parent.create(recursive: true);
    await cache.writeAsString(
      jsonEncode({
        'version': 1,
        'identity': jsonEncode(['myMemory', 1]),
        'entries': [
          ['Public description', 'zh-CN', '公开说明'],
        ],
      }),
    );
    final credentials = _Credentials();
    final container = ProviderContainer(
      overrides: [
        dataDirProvider.overrideWithValue(directory.path),
        translationCredentialsProvider.overrideWithValue(credentials),
      ],
    );
    final settings = container.read(settingsProvider.notifier);
    final subscription = container.listen(completionTranslationsProvider, (_, _) {});
    try {
      final initial = container.read(completionTranslationsProvider);
      await initial.ready;
      await settings.set(
        SettingKeys.completionTranslationConfig,
        const TranslationConfig(myMemoryEmail: 'desktop@example.com'),
      );
      final updated = container.read(completionTranslationsProvider);
      await updated.ready;
      expect(identical(initial, updated), isFalse);
      expect(updated.lookup('Public description', 'zh'), '公开说明');
      expect(credentials.reads, 0);
      await Future.wait([initial.saved, updated.saved]);
      expect(await cache.readAsString(), isNot(contains('desktop@example.com')));
    } finally {
      subscription.close();
      await settings.saved;
      container.dispose();
      directory.deleteSync(recursive: true);
    }
  });

  test('concurrency changes replace the translator while reusing the same service cache', () async {
    final directory = Directory.systemTemp.createTempSync('sshairy-translation-cache-');
    final credentials = _Credentials();
    final cache = File('${directory.path}/cache/completion-translations/openAi/completion-translations.json');
    await cache.parent.create(recursive: true);
    await cache.writeAsString(
      jsonEncode({
        'version': 1,
        'identity': jsonEncode(['openAi', 'https://example.com/v1', 'model', 1]),
        'entries': [
          ['Public command description', 'zh-CN', '公开命令说明'],
        ],
      }),
    );
    final container = ProviderContainer(
      overrides: [
        dataDirProvider.overrideWithValue(directory.path),
        translationCredentialsProvider.overrideWithValue(credentials),
      ],
    );
    final settings = container.read(settingsProvider.notifier);
    await settings.set(
      SettingKeys.completionTranslationConfig,
      const TranslationConfig(provider: TranslationProvider.openAi, endpoint: 'https://example.com/v1', model: 'model'),
    );
    final subscription = container.listen(completionTranslationsProvider, (_, _) {});
    try {
      final initial = container.read(completionTranslationsProvider);
      await initial.ready;
      expect(initial.lookup('Public command description', 'zh'), '公开命令说明');
      await settings.set(SettingKeys.completionTranslationConcurrency, 1);
      final limited = container.read(completionTranslationsProvider);
      await limited.ready;
      expect(identical(limited, initial), isFalse);
      expect(limited.lookup('Public command description', 'zh'), '公开命令说明');
      await settings.set(SettingKeys.completionTranslationConcurrency, 0);
      final automatic = container.read(completionTranslationsProvider);
      await automatic.ready;
      expect(identical(automatic, limited), isFalse);
      expect(automatic.lookup('Public command description', 'zh'), '公开命令说明');
      expect(credentials.reads, 0, reason: 'changing concurrency must reuse the cache without a request');
      await Future.wait([initial.saved, limited.saved, automatic.saved]);
      expect(
        directory
            .listSync(recursive: true)
            .whereType<File>()
            .where((file) => file.path.endsWith('completion-translations.json')),
        hasLength(1),
      );
    } finally {
      subscription.close();
      await settings.saved;
      container.dispose();
      directory.deleteSync(recursive: true);
    }
  });
}

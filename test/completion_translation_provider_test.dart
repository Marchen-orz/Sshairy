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
  test('active translator follows only service settings and credential invalidation', () async {
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
      expect(identical(configured, initial), isFalse);

      container.invalidate(completionTranslationsProvider);
      final refreshed = container.read(completionTranslationsProvider);
      await refreshed.ready;
      expect(identical(refreshed, configured), isFalse);
      expect(credentials.reads, 0, reason: 'loading a service or cache must not read keys or start HTTP');
      expect(
        directory.listSync(recursive: true).whereType<File>().any((file) => file.path.endsWith('apiKey')),
        isFalse,
      );
      await Future.wait([initial.saved, configured.saved, refreshed.saved]);
    } finally {
      subscription.close();
      await settings.saved;
      container.dispose();
      directory.deleteSync(recursive: true);
    }
  });
}

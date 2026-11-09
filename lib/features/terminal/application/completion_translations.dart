import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../foundation/data_dir.dart';
import '../../credentials/api.dart';
import '../../settings/api.dart';
import '../adapters/completion_translations.dart';
import '../adapters/configured_translation_engine.dart';

/// One shared translator for the active service; open panes follow configuration changes.
final completionTranslationsProvider = Provider<CompletionTranslations>((ref) {
  final config = ref.watch(
    settingsProvider.select((settings) => settings.get(SettingKeys.completionTranslationConfig)),
  );
  final concurrency = ref.watch(
    settingsProvider.select((settings) => settings.get(SettingKeys.completionTranslationConcurrency)),
  );
  final identity = jsonEncode(switch (config.provider) {
    TranslationProvider.myMemory => ['myMemory', 1],
    TranslationProvider.deepL => ['deepL', config.deepLFree, 1],
    TranslationProvider.google => ['google', 1],
    TranslationProvider.microsoft => ['microsoft', config.region, 1],
    TranslationProvider.openAi => ['openAi', config.canonicalEndpoint, config.model, 1],
  });
  final translations = CompletionTranslations(
    cacheDirectory: '${ref.watch(dataDirProvider)}/cache/completion-translations/${config.provider.name}',
    cacheIdentity: identity,
    maxConcurrent: concurrency == 0 ? 32 : concurrency,
    engine: config.provider == TranslationProvider.myMemory
        ? MyMemoryCompletionTranslationEngine()
        : ConfiguredCompletionTranslationEngine(config: config, credentials: ref.watch(translationCredentialsProvider)),
  );
  ref.onDispose(translations.dispose);
  return translations;
});

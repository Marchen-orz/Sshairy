import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../../../foundation/cancellation.dart';
import '../../credentials/api.dart';
import '../../settings/api.dart';
import '../domain/completion_translation.dart';
import 'completion_translations.dart';

const _maximumResponseBytes = 32 * 1024;
const _translationInstruction =
    'Translate the supplied public English command-line description into concise '
    'Simplified Chinese. Return only one single-line translation, without '
    'explanation, formatting, or quotation marks.';

/// Only public bundled descriptions may reach this adapter, never terminal context.
class ConfiguredCompletionTranslationEngine implements CompletionTranslationEngine {
  ConfiguredCompletionTranslationEngine({
    required TranslationConfig config,
    required this.credentials,
    @visibleForTesting HttpClient Function()? createClient,
    Duration timeout = const Duration(seconds: 10),
  }) : _config = config,
       _createClient = createClient ?? HttpClient.new,
       _timeout = timeout,
       _myMemory = config.provider == TranslationProvider.myMemory
           ? MyMemoryCompletionTranslationEngine(createClient: createClient, timeout: timeout)
           : null {
    if (timeout <= Duration.zero) {
      throw ArgumentError('Invalid translation timeout');
    }
  }

  final TranslationConfig _config;
  final TranslationCredentials credentials;
  final HttpClient Function() _createClient;
  final Duration _timeout;
  final MyMemoryCompletionTranslationEngine? _myMemory;
  final _active = <void Function()>{};
  bool _disposed = false;

  @override
  Future<String?> translate(String original, String target, CancellationToken cancel) {
    if (_disposed || cancel.isCancelled || target != 'zh-CN' || !_plain(original, characters: 500, bytes: 500)) {
      return Future.value(null);
    }
    if (!_config.isValid) {
      return Future.error(const CompletionTranslationFailure());
    }
    final myMemory = _myMemory;
    if (myMemory != null) return myMemory.translate(original, target, cancel);

    final result = Completer<String?>();
    final cancellation = _RequestCancellation();
    HttpClient? client;
    HttpClientRequest? request;
    StreamSubscription<List<int>>? subscription;
    Timer? timer;
    var stopped = false;
    late final void Function() abort;

    void finish(String? text, [CompletionTranslationFailure? failure]) {
      if (stopped) return;
      stopped = true;
      timer?.cancel();
      cancellation.action = null;
      _active.remove(abort);
      if (text == null) {
        try {
          request?.abort(const CompletionTranslationFailure());
        } catch (_) {}
      }
      final stream = subscription;
      if (stream != null) unawaited(stream.cancel().catchError((Object _) {}));
      try {
        client?.close(force: true);
      } catch (_) {}
      if (failure != null) {
        result.completeError(failure);
      } else {
        result.complete(text);
      }
    }

    abort = () => finish(null);
    _active.add(abort);
    cancellation.action = abort;
    _watchCancellation(cancel, cancellation);
    timer = Timer(_timeout, () => finish(null, const CompletionTranslationFailure()));
    unawaited(() async {
      try {
        final secret = await credentials.read(_config.credentialId);
        if (stopped || cancel.isCancelled) {
          finish(null);
          return;
        }
        final key = secret?.reveal();
        if ((key == null && !_keylessLoopback(_config)) ||
            (key != null && !_plain(key, characters: 8192, bytes: 8192))) {
          throw const CompletionTranslationFailure();
        }
        final connection = _createClient();
        client = connection;
        final opened = await connection.postUrl(_endpoint(_config));
        if (stopped || cancel.isCancelled) {
          opened.abort(const CompletionTranslationFailure());
          finish(null);
          return;
        }
        request = opened;
        opened.followRedirects = false;
        opened.maxRedirects = 0;
        opened.headers.contentType = ContentType.json;
        _authenticate(opened.headers, _config, key);
        opened.add(utf8.encode(jsonEncode(_payload(_config, original))));
        final response = await opened.close();
        if (stopped || cancel.isCancelled) {
          _discard(response);
          finish(null);
          return;
        }
        if (response.statusCode == 429 ||
            (_config.provider == TranslationProvider.deepL && response.statusCode == 456)) {
          _discard(response);
          finish(null, const CompletionTranslationFailure(quotaExceeded: true));
          return;
        }
        if (response.statusCode != 200 || response.contentLength > _maximumResponseBytes) {
          _discard(response);
          finish(null, const CompletionTranslationFailure());
          return;
        }
        final bytes = BytesBuilder(copy: false);
        subscription = response.listen(
          (chunk) {
            if (stopped) return;
            if (bytes.length + chunk.length > _maximumResponseBytes) {
              finish(null, const CompletionTranslationFailure());
              return;
            }
            bytes.add(chunk);
          },
          onError: (Object _, StackTrace stack) => finish(null, const CompletionTranslationFailure()),
          onDone: () {
            if (stopped) return;
            try {
              final data = jsonDecode(utf8.decode(bytes.takeBytes()));
              final text = _translatedText(_config.provider, data);
              if (!_plain(text, characters: 2048, bytes: 8 * 1024)) {
                throw const CompletionTranslationFailure();
              }
              finish(text);
            } catch (_) {
              finish(null, const CompletionTranslationFailure());
            }
          },
          cancelOnError: true,
        );
        if (stopped) {
          unawaited(subscription!.cancel().catchError((Object _) {}));
        }
      } catch (_) {
        finish(null, const CompletionTranslationFailure());
      }
    }());
    return result.future;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _myMemory?.dispose();
    for (final abort in _active.toList()) {
      abort();
    }
  }
}

class _RequestCancellation {
  void Function()? action;

  void cancel() {
    final callback = action;
    action = null;
    callback?.call();
  }
}

void _watchCancellation(CancellationToken token, _RequestCancellation cancellation) {
  unawaited(token.whenCancelled.then((_) => cancellation.cancel()));
}

bool _keylessLoopback(TranslationConfig config) {
  if (config.provider != TranslationProvider.openAi) return false;
  final host = Uri.parse(config.canonicalEndpoint).host.toLowerCase().replaceAll('[', '').replaceAll(']', '');
  return const {'localhost', '127.0.0.1', '::1'}.contains(host);
}

Uri _endpoint(TranslationConfig config) => switch (config.provider) {
  TranslationProvider.deepL => Uri.https(config.deepLFree ? 'api-free.deepl.com' : 'api.deepl.com', '/v2/translate'),
  TranslationProvider.google => Uri.https('translation.googleapis.com', '/language/translate/v2'),
  TranslationProvider.microsoft => Uri.https('api.cognitive.microsofttranslator.com', '/translate', {
    'api-version': '3.0',
    'from': 'en',
    'to': 'zh-Hans',
  }),
  TranslationProvider.openAi => Uri.parse('${config.canonicalEndpoint}/chat/completions'),
  TranslationProvider.myMemory => throw const CompletionTranslationFailure(),
};

void _authenticate(HttpHeaders headers, TranslationConfig config, String? key) {
  switch (config.provider) {
    case TranslationProvider.deepL:
      headers.set(HttpHeaders.authorizationHeader, 'DeepL-Auth-Key $key');
    case TranslationProvider.google:
      headers.set('X-Goog-Api-Key', key!);
    case TranslationProvider.microsoft:
      headers.set('Ocp-Apim-Subscription-Key', key!);
      if (config.region.isNotEmpty) {
        headers.set('Ocp-Apim-Subscription-Region', config.region);
      }
    case TranslationProvider.openAi:
      if (key != null) {
        headers.set(HttpHeaders.authorizationHeader, 'Bearer $key');
      }
    case TranslationProvider.myMemory:
      throw const CompletionTranslationFailure();
  }
}

Object _payload(TranslationConfig config, String original) => switch (config.provider) {
  TranslationProvider.deepL => {
    'text': [original],
    'source_lang': 'EN',
    'target_lang': 'ZH-HANS',
  },
  TranslationProvider.google => {'q': original, 'source': 'en', 'target': 'zh-CN', 'format': 'text'},
  TranslationProvider.microsoft => [
    {'Text': original},
  ],
  TranslationProvider.openAi => {
    'model': config.model,
    'messages': [
      {'role': 'system', 'content': _translationInstruction},
      {'role': 'user', 'content': original},
    ],
    'stream': false,
    'max_completion_tokens': 512,
  },
  TranslationProvider.myMemory => throw const CompletionTranslationFailure(),
};

String _translatedText(TranslationProvider provider, Object? data) {
  Object? text;
  switch (provider) {
    case TranslationProvider.deepL:
      if (data is! Map || data['error'] != null) {
        throw const CompletionTranslationFailure();
      }
      text = _oneTranslation(data['translations'])['text'];
    case TranslationProvider.google:
      if (data is! Map || data['error'] != null || data['data'] is! Map) {
        throw const CompletionTranslationFailure();
      }
      text = _oneTranslation((data['data'] as Map)['translations'])['translatedText'];
      if (text is String) text = _decodeEntities(text);
    case TranslationProvider.microsoft:
      final response = _oneTranslation(data);
      if (response['error'] != null) {
        throw const CompletionTranslationFailure();
      }
      final translated = _oneTranslation(response['translations']);
      if (translated['to'] != 'zh-Hans') {
        throw const CompletionTranslationFailure();
      }
      text = translated['text'];
    case TranslationProvider.openAi:
      if (data is! Map || data['error'] != null) {
        throw const CompletionTranslationFailure();
      }
      final choice = _oneTranslation(data['choices']);
      final message = choice['message'];
      if (choice['finish_reason'] != 'stop' ||
          message is! Map ||
          message['role'] != 'assistant' ||
          message['tool_calls'] != null ||
          message['function_call'] != null ||
          message['refusal'] != null) {
        throw const CompletionTranslationFailure();
      }
      text = message['content'];
    case TranslationProvider.myMemory:
      throw const CompletionTranslationFailure();
  }
  if (text is! String) throw const CompletionTranslationFailure();
  return text;
}

Map _oneTranslation(Object? value) {
  if (value is! List || value.length != 1 || value.single is! Map) {
    throw const CompletionTranslationFailure();
  }
  return value.single as Map;
}

final _entity = RegExp(r'&(#(?:[xX][0-9a-fA-F]{1,6}|[0-9]{1,7})|amp|lt|gt|quot|apos);');

String _decodeEntities(String value) => value.replaceAllMapped(_entity, (match) {
  final name = match[1]!;
  if (!name.startsWith('#')) {
    return const {'amp': '&', 'lt': '<', 'gt': '>', 'quot': '"', 'apos': "'"}[name]!;
  }
  final hexadecimal = name.length > 1 && name[1].toLowerCase() == 'x';
  final rune = int.parse(name.substring(hexadecimal ? 2 : 1), radix: hexadecimal ? 16 : 10);
  if (rune == 0 || rune > 0x10ffff || (rune >= 0xd800 && rune <= 0xdfff)) {
    throw const CompletionTranslationFailure();
  }
  return String.fromCharCode(rune);
});

bool _plain(String value, {required int characters, required int bytes}) {
  if (value.isEmpty || value.length > characters || value.trim().isEmpty) {
    return false;
  }
  for (final rune in value.runes) {
    if (rune < 0x20 ||
        (rune >= 0x7f && rune <= 0x9f) ||
        rune == 0xad ||
        rune == 0x61c ||
        rune == 0x180e ||
        (rune >= 0x200b && rune <= 0x200f) ||
        (rune >= 0x2028 && rune <= 0x202e) ||
        (rune >= 0x2060 && rune <= 0x206f) ||
        rune == 0xfeff ||
        (rune >= 0xfff9 && rune <= 0xfffb) ||
        (rune >= 0xd800 && rune <= 0xdfff)) {
      return false;
    }
  }
  final encoded = utf8.encode(value);
  return encoded.length <= bytes && utf8.decode(encoded) == value;
}

void _discard(HttpClientResponse response) {
  try {
    final stream = response.listen((_) {}, onError: (Object _) {});
    unawaited(stream.cancel().catchError((Object _) {}));
  } catch (_) {}
}

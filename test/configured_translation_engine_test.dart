import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/features/credentials/api.dart';
import 'package:sshairy/features/settings/api.dart';
import 'package:sshairy/features/terminal/adapters/configured_translation_engine.dart';
import 'package:sshairy/features/terminal/domain/completion_translation.dart';
import 'package:sshairy/foundation/cancellation.dart';
import 'package:sshairy/foundation/secret.dart';

void main() {
  final engines = <ConfiguredCompletionTranslationEngine>[];

  tearDown(() {
    for (final engine in engines) {
      engine.dispose();
    }
    engines.clear();
  });

  ConfiguredCompletionTranslationEngine engine({
    TranslationConfig config = const TranslationConfig(provider: TranslationProvider.deepL),
    _Credentials? credentials,
    _Client? client,
    HttpClient Function()? createClient,
    Duration timeout = const Duration(seconds: 10),
  }) {
    final value = ConfiguredCompletionTranslationEngine(
      config: config,
      credentials: credentials ?? _Credentials(),
      createClient: createClient ?? () => client!,
      timeout: timeout,
    );
    engines.add(value);
    return value;
  }

  Future<String?> translate(
    ConfiguredCompletionTranslationEngine value, {
    String original = 'List public files',
    String target = 'zh-CN',
    CancellationToken? cancel,
  }) => value.translate(original, target, cancel ?? CancellationToken());

  Matcher failure({bool quota = false}) =>
      isA<CompletionTranslationFailure>().having((value) => value.quotaExceeded, 'quotaExceeded', quota);

  test('DeepL free and pro use fixed HTTPS POST, headers and exact original', () async {
    const original = 'Use + & / ? = # % “file”';
    for (final free in [true, false]) {
      final config = TranslationConfig(provider: TranslationProvider.deepL, deepLFree: free);
      final credentials = _Credentials();
      final request = _Request(
        _Response.json({
          'translations': [
            {'text': '使用文件', 'detected_source_language': 'EN'},
          ],
        }),
      );
      final client = _Client(request);
      final value = engine(config: config, credentials: credentials, client: client);
      expect(await translate(value, original: original), '使用文件');
      expect(client.method, 'POST');
      expect(
        client.uri.toString(),
        free ? 'https://api-free.deepl.com/v2/translate' : 'https://api.deepl.com/v2/translate',
      );
      expect(credentials.reads, [free ? 'deepL:free' : 'deepL:pro']);
      expect(request.headers.values, {'authorization': 'DeepL-Auth-Key vendor-test-key'});
      expect(request.json, {
        'text': [original],
        'source_lang': 'EN',
        'target_lang': 'ZH-HANS',
      });
      expect(request.headers.contentType?.mimeType, 'application/json');
      expect(request.followRedirects, isFalse);
      expect(request.maxRedirects, 0);
      expect(client.forceClosed, isTrue);
    }
  });

  test('Google keeps the key out of the URL and decodes entities once', () async {
    final credentials = _Credentials();
    final request = _Request(
      _Response.json({
        'data': {
          'translations': [
            {'translatedText': '甲 &amp; &lt;x&gt; &quot;文&quot; &apos;字&apos; &#20013; &#x6587; &amp;lt;'},
          ],
        },
      }),
    );
    final client = _Client(request);
    final value = engine(
      config: const TranslationConfig(provider: TranslationProvider.google),
      credentials: credentials,
      client: client,
    );
    expect(await translate(value), '甲 & <x> "文" \'字\' 中 文 &lt;');
    expect(client.uri.toString(), 'https://translation.googleapis.com/language/translate/v2');
    expect(client.uri!.hasQuery, isFalse);
    expect(credentials.reads, ['google']);
    expect(request.headers.values, {'x-goog-api-key': 'vendor-test-key'});
    expect(request.json, {'q': 'List public files', 'source': 'en', 'target': 'zh-CN', 'format': 'text'});
  });

  test('Microsoft uses fixed query, body and optional region', () async {
    for (final region in ['', 'eastasia']) {
      final credentials = _Credentials();
      final request = _Request(
        _Response.json([
          {
            'translations': [
              {'text': '列出公开文件', 'to': 'zh-Hans'},
            ],
          },
        ]),
      );
      final client = _Client(request);
      final value = engine(
        config: TranslationConfig(provider: TranslationProvider.microsoft, region: region),
        credentials: credentials,
        client: client,
      );
      expect(await translate(value), '列出公开文件');
      expect(client.uri!.scheme, 'https');
      expect(client.uri!.host, 'api.cognitive.microsofttranslator.com');
      expect(client.uri!.path, '/translate');
      expect(client.uri!.queryParameters, {'api-version': '3.0', 'from': 'en', 'to': 'zh-Hans'});
      expect(credentials.reads, ['microsoft:$region']);
      expect(request.headers.values, {
        'ocp-apim-subscription-key': 'vendor-test-key',
        if (region.isNotEmpty) 'ocp-apim-subscription-region': region,
      });
      expect(request.json, [
        {'Text': 'List public files'},
      ]);
    }
  });

  test('OpenAI binds the key to canonical base and sends only fixed translation messages', () async {
    final credentials = _Credentials();
    final request = _Request(_Response.json(_openAiResponse()));
    final client = _Client(request);
    final value = engine(
      config: const TranslationConfig(
        provider: TranslationProvider.openAi,
        endpoint: 'https://MODEL.example:443/proxy/v1/',
        model: 'vendor/translation-model',
      ),
      credentials: credentials,
      client: client,
    );
    expect(await translate(value), '列出公开文件');
    expect(client.uri.toString(), 'https://model.example/proxy/v1/chat/completions');
    expect(credentials.reads, ['openAi:https://model.example/proxy/v1']);
    expect(request.headers.values, {'authorization': 'Bearer vendor-test-key'});
    final body = request.json as Map;
    expect(body.keys.toSet(), {'model', 'messages', 'stream', 'max_completion_tokens'});
    expect(body['model'], 'vendor/translation-model');
    expect(body['stream'], isFalse);
    expect(body['max_completion_tokens'], 512);
    final messages = body['messages'] as List;
    expect(messages.length, 2);
    expect(messages[0], {
      'role': 'system',
      'content':
          'Translate the supplied public English command-line description into concise '
          'Simplified Chinese. Return only one single-line translation, without '
          'explanation, formatting, or quotation marks.',
    });
    expect(messages[1], {'role': 'user', 'content': 'List public files'});
  });

  test('OpenAI allows missing keys only for exact loopback names', () async {
    for (final endpoint in [
      'http://localhost:8000/v1',
      'http://127.0.0.1:8000/v1',
      'http://[::1]:8000/v1',
      'https://localhost/v1',
    ]) {
      final credentials = _Credentials()..key = null;
      final request = _Request(_Response.json(_openAiResponse()));
      final client = _Client(request);
      final value = engine(
        config: TranslationConfig(provider: TranslationProvider.openAi, endpoint: endpoint, model: 'local-model'),
        credentials: credentials,
        client: client,
      );
      expect(await translate(value), '列出公开文件');
      expect(request.headers.values, isEmpty);
      expect(client.uri!.path, '/v1/chat/completions');
    }
    for (final endpoint in [
      'https://model.example/v1',
      'https://localhost.example/v1',
      'https://127.0.0.2/v1',
      'https://[::2]/v1',
    ]) {
      var clients = 0;
      final value = engine(
        config: TranslationConfig(provider: TranslationProvider.openAi, endpoint: endpoint, model: 'model'),
        credentials: _Credentials()..key = null,
        createClient: () {
          clients++;
          throw StateError('Must not create a client');
        },
      );
      await expectLater(translate(value), throwsA(failure()));
      expect(clients, 0);
    }
  });

  test('MyMemory delegates without reading credentials', () async {
    final credentials = _Credentials()..error = StateError('Must not read secrets');
    final request = _Request(
      _Response.json({
        'responseStatus': 200,
        'responseData': {'translatedText': '列出文件'},
      }),
    );
    final client = _Client(request);
    final value = engine(config: const TranslationConfig(), credentials: credentials, client: client);
    expect(await translate(value), '列出文件');
    expect(credentials.reads, isEmpty);
    expect(client.method, 'GET');
    expect(client.uri!.host, 'api.mymemory.translated.net');
    expect(client.uri!.queryParameters['q'], 'List public files');
  });

  test('every request reads the current credential, never a saved key snapshot', () async {
    final credentials = _Credentials();
    final requests = <_Request>[];
    final value = engine(
      credentials: credentials,
      createClient: () {
        final request = _Request(
          _Response.json({
            'translations': [
              {'text': '列出文件'},
            ],
          }),
        );
        requests.add(request);
        return _Client(request);
      },
    );
    expect(await translate(value), '列出文件');
    credentials.key = const Secret('updated-test-key');
    expect(await translate(value), '列出文件');
    expect(credentials.reads, ['deepL:free', 'deepL:free']);
    expect(requests[0].headers.value('authorization'), 'DeepL-Auth-Key vendor-test-key');
    expect(requests[1].headers.value('authorization'), 'DeepL-Auth-Key updated-test-key');
  });

  test('invalid config and missing, unreadable or malformed keys never create HTTP clients', () async {
    var clients = 0;
    HttpClient createClient() {
      clients++;
      throw StateError('Must not create a client');
    }

    for (final config in [
      const TranslationConfig(provider: TranslationProvider.deepL, endpoint: 'https://attacker.example'),
      const TranslationConfig(provider: TranslationProvider.google, model: 'unexpected'),
      const TranslationConfig(provider: TranslationProvider.microsoft, region: 'bad\r\nregion'),
      const TranslationConfig(
        provider: TranslationProvider.openAi,
        endpoint: 'http://remote.example/v1',
        model: 'model',
      ),
      const TranslationConfig(
        provider: TranslationProvider.openAi,
        endpoint: 'https://model.example/v1?key=secret',
        model: 'model',
      ),
      const TranslationConfig(provider: TranslationProvider.openAi, endpoint: 'https://model.example/v1', model: ''),
    ]) {
      final credentials = _Credentials();
      final value = engine(config: config, credentials: credentials, createClient: createClient);
      await expectLater(translate(value), throwsA(failure()));
      expect(credentials.reads, isEmpty);
    }
    for (final key in <Secret?>[
      null,
      const Secret(''),
      const Secret('   '),
      const Secret('header\r\ninjection'),
      const Secret('header\u0085injection'),
      const Secret('header\u202einjection'),
      Secret('x' * 8193),
    ]) {
      final credentials = _Credentials()..key = key;
      final value = engine(credentials: credentials, createClient: createClient);
      await expectLater(translate(value), throwsA(failure()));
      expect(credentials.reads, ['deepL:free']);
    }
    final value = engine(
      credentials: _Credentials()..error = StateError('raw-secret-store-error'),
      createClient: createClient,
    );
    await expectLater(translate(value), throwsA(failure()));
    expect(clients, 0);
  });

  test('invalid input, unsupported target and pre-cancellation never read a key', () async {
    final credentials = _Credentials();
    var clients = 0;
    final value = engine(
      credentials: credentials,
      createClient: () {
        clients++;
        throw StateError('Must not create a client');
      },
    );
    for (final original in [
      '',
      '   ',
      'two\nlines',
      'tab\ttext',
      'escape\x1btext',
      'control\x7f',
      'control\u0085',
      'bidi\u202e',
      'isolate\u2066',
      'separator ',
      String.fromCharCode(0xd800),
      'x' * 501,
      '汉' * 167,
    ]) {
      expect(await translate(value, original: original), isNull);
    }
    for (final target in ['', 'en', 'fr', 'zh', 'zh_Hans', 'ZH-CN']) {
      expect(await translate(value, target: target), isNull);
    }
    expect(await translate(value, cancel: CancellationToken()..cancel()), isNull);
    expect(credentials.reads, isEmpty);
    expect(clients, 0);
  });

  test('provider structure and error envelopes cannot become translations', () async {
    final cases = <(TranslationConfig, Object?)>[
      (const TranslationConfig(provider: TranslationProvider.deepL), []),
      (const TranslationConfig(provider: TranslationProvider.deepL), {'translations': []}),
      (
        const TranslationConfig(provider: TranslationProvider.deepL),
        {
          'translations': [
            {'text': '甲'},
            {'text': '乙'},
          ],
        },
      ),
      (
        const TranslationConfig(provider: TranslationProvider.deepL),
        {
          'translations': [
            {'text': 7},
          ],
        },
      ),
      (
        const TranslationConfig(provider: TranslationProvider.deepL),
        {
          'error': 'secret error',
          'translations': [
            {'text': '甲'},
          ],
        },
      ),
      (
        const TranslationConfig(provider: TranslationProvider.google),
        {
          'data': {
            'translations': {'translatedText': '甲'},
          },
        },
      ),
      (
        const TranslationConfig(provider: TranslationProvider.google),
        {
          'error': {'code': 400},
          'data': {
            'translations': [
              {'translatedText': '甲'},
            ],
          },
        },
      ),
      (
        const TranslationConfig(provider: TranslationProvider.microsoft),
        {
          'translations': [
            {'text': '甲', 'to': 'zh-Hans'},
          ],
        },
      ),
      (
        const TranslationConfig(provider: TranslationProvider.microsoft),
        [
          {
            'translations': [
              {'text': '甲', 'to': 'en'},
            ],
          },
        ],
      ),
      (
        const TranslationConfig(provider: TranslationProvider.microsoft),
        [
          {
            'translations': [
              {'text': '甲'},
            ],
          },
        ],
      ),
      (
        const TranslationConfig(provider: TranslationProvider.microsoft),
        [
          {
            'error': 'failure',
            'translations': [
              {'text': '甲', 'to': 'zh-Hans'},
            ],
          },
        ],
      ),
    ];
    for (final (config, data) in cases) {
      final value = engine(config: config, client: _Client(_Request(_Response.json(data))));
      await expectLater(translate(value), throwsA(failure()));
    }
  });

  test('OpenAI rejects incomplete, tool, refusal and non-assistant answers', () async {
    const config = TranslationConfig(
      provider: TranslationProvider.openAi,
      endpoint: 'https://model.example/v1',
      model: 'model',
    );
    for (final data in [
      {'choices': []},
      {
        'choices': [_openAiChoice(), _openAiChoice()],
      },
      {
        'error': {'message': 'raw secret'},
        'choices': [_openAiChoice()],
      },
      {
        'choices': [_openAiChoice(finishReason: 'length')],
      },
      {
        'choices': [_openAiChoice(finishReason: 'content_filter')],
      },
      {
        'choices': [_openAiChoice(finishReason: 'tool_calls')],
      },
      {
        'choices': [_openAiChoice(role: 'tool')],
      },
      {
        'choices': [
          _openAiChoice(
            content: [
              {'text': '甲'},
            ],
          ),
        ],
      },
      {
        'choices': [
          _openAiChoice(extra: {'tool_calls': []}),
        ],
      },
      {
        'choices': [
          _openAiChoice(extra: {'function_call': {}}),
        ],
      },
      {
        'choices': [
          _openAiChoice(extra: {'refusal': '拒绝'}),
        ],
      },
    ]) {
      final value = engine(config: config, client: _Client(_Request(_Response.json(data))));
      await expectLater(translate(value), throwsA(failure()));
    }
  });

  test('all translations remain bounded single-line plain text', () async {
    for (final text in [
      '',
      '   ',
      'two\nlines',
      'tab\ttext',
      'escape\x1btext',
      'control\u0085',
      'bidi\u202e',
      'zero​width',
      'isolate\u2066',
      'separator ',
      'x' * 2049,
    ]) {
      final value = engine(
        client: _Client(
          _Request(
            _Response.json({
              'translations': [
                {'text': text},
              ],
            }),
          ),
        ),
      );
      await expectLater(translate(value), throwsA(failure()));
    }
    final value = engine(
      client: _Client(
        _Request(
          _Response.json({
            'translations': [
              {'text': '汉' * 2048},
            ],
          }),
        ),
      ),
    );
    expect(await translate(value), '汉' * 2048);
  });

  test('Google numeric entities cannot inject controls or invalid Unicode', () async {
    for (final text in ['&#10;', '&#x1b;', '&#x202e;', '&#x2066;', '&#0;', '&#xD800;', '&#x110000;']) {
      final value = engine(
        config: const TranslationConfig(provider: TranslationProvider.google),
        client: _Client(
          _Request(
            _Response.json({
              'data': {
                'translations': [
                  {'translatedText': text},
                ],
              },
            }),
          ),
        ),
      );
      await expectLater(translate(value), throwsA(failure()));
    }
  });

  test('HTTP failures and redirects fail once without exposing remote content', () async {
    for (final status in [301, 302, 307, 308, 400, 401, 403, 404, 500]) {
      final request = _Request(_Response.json({'error': 'vendor-test-key'}, status: status));
      final client = _Client(request);
      final value = engine(client: client);
      Object? thrown;
      try {
        await translate(value);
      } catch (error) {
        thrown = error;
      }
      expect(thrown, failure());
      expect(thrown.toString(), isNot(contains('vendor-test-key')));
      expect(client.requests, 1);
      expect(request.followRedirects, isFalse);
      expect(request.maxRedirects, 0);
      expect(request.aborted, isTrue);
      expect(client.forceClosed, isTrue);
    }
  });

  test('rate limits and DeepL quota errors use the quota failure', () async {
    for (final provider in [
      TranslationProvider.deepL,
      TranslationProvider.google,
      TranslationProvider.microsoft,
      TranslationProvider.openAi,
    ]) {
      final config = provider == TranslationProvider.openAi
          ? const TranslationConfig(
              provider: TranslationProvider.openAi,
              endpoint: 'https://model.example/v1',
              model: 'model',
            )
          : TranslationConfig(provider: provider);
      for (final status in [429, if (provider == TranslationProvider.deepL) 456]) {
        final value = engine(
          config: config,
          client: _Client(_Request(_Response.json({}, status: status))),
        );
        await expectLater(translate(value), throwsA(failure(quota: true)));
      }
    }
  });

  test('malformed JSON, invalid UTF-8 and raw IO exceptions are sanitized', () async {
    for (final response in [
      _Response(Stream.value(utf8.encode('{not-json'))),
      _Response(Stream.value([0xff])),
      _Response(Stream.error(StateError('vendor-test-key raw-response'))),
    ]) {
      final value = engine(client: _Client(_Request(response)));
      await expectLater(translate(value), throwsA(failure()));
    }
    final value = engine(createClient: () => throw StateError('vendor-test-key https://secret.example?key=private'));
    await expectLater(translate(value), throwsA(failure()));
  });

  test('advertised and streamed oversize bodies close and cancel immediately', () async {
    final advertised = _Client(_Request(_Response(const Stream<List<int>>.empty(), contentLength: 32 * 1024 + 1)));
    await expectLater(translate(engine(client: advertised)), throwsA(failure()));
    expect(advertised.forceClosed, isTrue);

    var cancelled = false;
    final controller = StreamController<List<int>>(onCancel: () => cancelled = true);
    final request = _Request(_Response(controller.stream));
    final client = _Client(request);
    final pending = expectLater(translate(engine(client: client)), throwsA(failure()));
    await _eventually(() => request.response.listened);
    controller.add(List.filled(32 * 1024, 0x20));
    controller.add([0x20]);
    await pending;
    expect(cancelled, isTrue);
    expect(request.aborted, isTrue);
    expect(client.forceClosed, isTrue);
    await controller.close();
  });

  test('credential reads are inside the deadline and cannot start HTTP late', () async {
    final credentials = _Credentials()..pending = Completer<Secret?>();
    var clients = 0;
    final value = engine(
      credentials: credentials,
      timeout: const Duration(milliseconds: 20),
      createClient: () {
        clients++;
        throw StateError('Must not create a client');
      },
    );
    await expectLater(translate(value), throwsA(failure()));
    credentials.pending!.complete(const Secret('late-key'));
    await _settle();
    expect(clients, 0);
  });

  test('cancellation during secure reads completes without waiting on storage', () async {
    final credentials = _Credentials()..pending = Completer<Secret?>();
    var clients = 0;
    final value = engine(
      credentials: credentials,
      createClient: () {
        clients++;
        throw StateError('Must not create a client');
      },
    );
    final cancel = CancellationToken();
    final pending = translate(value, cancel: cancel);
    cancel.cancel();
    expect(await pending, isNull);
    credentials.pending!.complete(const Secret('late-key'));
    await _settle();
    expect(clients, 0);
  });

  test('connection timeout or cancellation closes the client and aborts late requests', () async {
    for (final timedOut in [true, false]) {
      final request = _Request(_Response.json({}));
      final client = _Client(request)..pending = Completer<HttpClientRequest>();
      final value = engine(client: client, timeout: const Duration(milliseconds: 20));
      final cancel = CancellationToken();
      final pending = translate(value, cancel: cancel);
      final checked = timedOut ? expectLater(pending, throwsA(failure())) : expectLater(pending, completion(isNull));
      await _eventually(() => client.requests == 1);
      if (!timedOut) cancel.cancel();
      await checked;
      expect(client.forceClosed, isTrue);
      client.pending!.complete(request);
      await _settle();
      expect(request.aborted, isTrue);
      expect(request.closed, isFalse);
    }
  });

  test('header timeout or cancellation aborts request and cancels late response bodies', () async {
    for (final timedOut in [true, false]) {
      var cancelled = false;
      final controller = StreamController<List<int>>(onCancel: () => cancelled = true);
      final response = _Response(controller.stream);
      final request = _Request(response)..pending = Completer<HttpClientResponse>();
      final client = _Client(request);
      final value = engine(client: client, timeout: const Duration(milliseconds: 20));
      final cancel = CancellationToken();
      final pending = translate(value, cancel: cancel);
      final checked = timedOut ? expectLater(pending, throwsA(failure())) : expectLater(pending, completion(isNull));
      await _eventually(() => request.closed);
      if (!timedOut) cancel.cancel();
      await checked;
      expect(request.aborted, isTrue);
      expect(client.forceClosed, isTrue);
      request.pending!.complete(response);
      await _settle();
      expect(cancelled, isTrue);
      await controller.close();
    }
  });

  test('body timeout, cancellation and disposal release stalled streams', () async {
    for (final stop in ['timeout', 'cancel', 'dispose']) {
      var cancelled = false;
      final controller = StreamController<List<int>>(onCancel: () => cancelled = true);
      final request = _Request(_Response(controller.stream));
      final client = _Client(request);
      final value = engine(client: client, timeout: const Duration(milliseconds: 20));
      final cancel = CancellationToken();
      final pending = translate(value, cancel: cancel);
      final checked = stop == 'timeout'
          ? expectLater(pending, throwsA(failure()))
          : expectLater(pending, completion(isNull));
      await _eventually(() => request.response.listened);
      if (stop == 'cancel') cancel.cancel();
      if (stop == 'dispose') value.dispose();
      await checked;
      expect(cancelled, isTrue);
      expect(request.aborted, isTrue);
      expect(client.forceClosed, isTrue);
      await controller.close();
    }
  });

  test('disposal stops secure reads and all subsequent calls', () async {
    final credentials = _Credentials()..pending = Completer<Secret?>();
    final value = engine(credentials: credentials);
    final pending = translate(value);
    value.dispose();
    value.dispose();
    expect(await pending, isNull);
    expect(await translate(value), isNull);
    credentials.pending!.complete(const Secret('late-key'));
    await _settle();
    expect(credentials.reads, ['deepL:free']);
  });
}

Map<String, Object?> _openAiResponse() => {
  'choices': [_openAiChoice()],
};

Map<String, Object?> _openAiChoice({
  String finishReason = 'stop',
  String role = 'assistant',
  Object? content = '列出公开文件',
  Map<String, Object?> extra = const {},
}) => {
  'finish_reason': finishReason,
  'message': {'role': role, 'content': content, ...extra},
};

class _Credentials implements TranslationCredentials {
  Secret? key = const Secret('vendor-test-key');
  Object? error;
  Completer<Secret?>? pending;
  final reads = <String>[];

  @override
  Future<Secret?> read(String identity) async {
    reads.add(identity);
    final failure = error;
    if (failure != null) throw failure;
    final reading = pending;
    if (reading != null) return reading.future;
    return key;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Client implements HttpClient {
  _Client(this.request);
  final _Request request;
  Uri? uri;
  String? method;
  int requests = 0;
  bool forceClosed = false;
  Completer<HttpClientRequest>? pending;

  @override
  Future<HttpClientRequest> postUrl(Uri url) async => _open('POST', url);

  @override
  Future<HttpClientRequest> getUrl(Uri url) async => _open('GET', url);

  Future<HttpClientRequest> _open(String verb, Uri url) async {
    method = verb;
    uri = url;
    requests++;
    final opening = pending;
    if (opening != null) return opening.future;
    return request;
  }

  @override
  void close({bool force = false}) => forceClosed = force;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Headers implements HttpHeaders {
  final values = <String, String>{};
  @override
  ContentType? contentType;

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    values[name.toLowerCase()] = value.toString();
  }

  @override
  String? value(String name) => values[name.toLowerCase()];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Request implements HttpClientRequest {
  _Request(this.response);
  final _Response response;
  final bytes = <int>[];
  bool aborted = false, closed = false;
  Completer<HttpClientResponse>? pending;

  Object? get json => jsonDecode(utf8.decode(bytes));

  @override
  final _Headers headers = _Headers();
  @override
  bool followRedirects = true;
  @override
  int maxRedirects = 5;

  @override
  void add(List<int> data) => bytes.addAll(data);

  @override
  Future<HttpClientResponse> close() async {
    closed = true;
    final closing = pending;
    if (closing != null) return closing.future;
    return response;
  }

  @override
  void abort([Object? exception, StackTrace? stackTrace]) => aborted = true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Response extends Stream<List<int>> implements HttpClientResponse {
  _Response(this.stream, {this.statusCode = 200, this.contentLength = -1});

  factory _Response.json(Object? data, {int status = 200}) =>
      _Response(Stream.value(utf8.encode(jsonEncode(data))), statusCode: status);

  final Stream<List<int>> stream;
  bool listened = false;
  @override
  final int statusCode;
  @override
  final int contentLength;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    listened = true;
    return stream.listen(onData, onError: onError, onDone: onDone, cancelOnError: cancelOnError);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _settle() async {
  for (var i = 0; i < 4; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Future<void> _eventually(bool Function() condition) async {
  for (var i = 0; i < 100; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  expect(condition(), isTrue, reason: 'translation did not reach the expected state');
}

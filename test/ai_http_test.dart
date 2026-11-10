import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/features/ai/adapters/model_provider.dart';
import 'package:sshairy/features/ai/domain/model.dart';
import 'package:sshairy/foundation/cancellation.dart';
import 'package:sshairy/foundation/secret.dart';

ModelProfile localProfile(HttpServer server, ModelProtocol protocol) => ModelProfile(
  protocol: protocol,
  endpoint: 'http://127.0.0.1:${server.port}/v1',
  model: 'selected-model',
  tools: true,
);
ModelRequest request(ModelProfile profile, {String text = 'explain'}) => ModelRequest(
  profile: profile,
  system: 'fixed system',
  messages: [ModelMessage(ModelRole.user, text: text)],
);
String openAiText() =>
    'data: ${jsonEncode({
      'id': 'response',
      'choices': [
        {
          'index': 0,
          'delta': {'role': 'assistant', 'content': '你好🙂'},
          'finish_reason': 'stop',
        },
      ],
    })}\r\n\r\ndata: [DONE]\r\n\r\n';
String anthropicText() => [
  {
    'type': 'message_start',
    'message': {'role': 'assistant', 'content': []},
  },
  {
    'type': 'content_block_start',
    'index': 0,
    'content_block': {'type': 'text', 'text': ''},
  },
  {
    'type': 'content_block_delta',
    'index': 0,
    'delta': {'type': 'text_delta', 'text': '你好🙂'},
  },
  {'type': 'content_block_stop', 'index': 0},
  {
    'type': 'message_delta',
    'delta': {'stop_reason': 'end_turn'},
  },
  {'type': 'message_stop'},
].map((value) => 'event: ${value['type']}\ndata: ${jsonEncode(value)}\n\n').join();

void main() {
  for (final protocol in ModelProtocol.values) {
    test('${protocol.name} HTTP sends the key only to its exact endpoint and streams split UTF-8', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final served = Completer<void>();
      final profile = localProfile(server, protocol);
      var keyReads = 0;
      final provider = HttpModelProvider(
        readKey: (identity) async {
          expect(identity, profile.identity);
          keyReads++;
          return const Secret('model-key-for-test');
        },
      );
      server.listen((incoming) async {
        try {
          expect(incoming.uri.path, protocol == ModelProtocol.anthropic ? '/v1/messages' : '/v1/chat/completions');
          expect(incoming.method, 'POST');
          expect(incoming.headers.value('accept'), 'text/event-stream');
          if (protocol == ModelProtocol.anthropic) {
            expect(incoming.headers.value('x-api-key'), 'model-key-for-test');
            expect(incoming.headers.value('anthropic-version'), '2023-06-01');
            expect(incoming.headers.value('authorization'), isNull);
          } else {
            expect(incoming.headers.value('authorization'), 'Bearer model-key-for-test');
            expect(incoming.headers.value('x-api-key'), isNull);
          }
          final body = await utf8.decoder.bind(incoming).join();
          expect(body, isNot(contains('model-key-for-test')));
          final json = jsonDecode(body) as Map;
          expect(json['model'], 'selected-model');
          expect(json['stream'], isTrue);
          incoming.response.headers.contentType = ContentType('text', 'event-stream', charset: 'utf-8');
          for (final byte in utf8.encode(protocol == ModelProtocol.anthropic ? anthropicText() : openAiText())) {
            incoming.response.add([byte]);
            await incoming.response.flush();
          }
          await incoming.response.close();
          served.complete();
        } catch (error, stack) {
          served.completeError(error, stack);
        }
      });
      try {
        expect(keyReads, 0);
        final events = await provider.stream(request(profile), CancellationToken()).toList();
        expect(keyReads, 1);
        expect(events.whereType<ModelMessageComplete>().single.message.text, '你好🙂');
        await served.future.timeout(const Duration(seconds: 3));
      } finally {
        provider.close();
        await server.close(force: true).timeout(const Duration(seconds: 3));
      }
    });
  }

  test('redirect is refused and raw HTTP error data never escapes', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var calls = 0;
    server.listen((incoming) async {
      calls++;
      await incoming.drain<void>();
      incoming.response.statusCode = HttpStatus.temporaryRedirect;
      incoming.response.headers.set(HttpHeaders.locationHeader, 'http://127.0.0.1:${server.port}/stolen');
      incoming.response.headers.set(HttpHeaders.retryAfterHeader, '12');
      incoming.response.write('secret-response-body');
      await incoming.response.close();
    });
    final provider = HttpModelProvider(readKey: (_) async => const Secret('secret-model-key'));
    try {
      await expectLater(
        provider.stream(request(localProfile(server, ModelProtocol.openai)), CancellationToken()).toList(),
        throwsA(
          isA<ModelFailure>()
              .having((e) => e.statusCode, 'status', 307)
              .having((e) => e.retryAfter, 'retryAfter', const Duration(seconds: 12))
              .having((e) => e.toString(), 'sanitized', 'ModelFailure(modelHttpError)'),
        ),
      );
      expect(calls, 1);
    } finally {
      provider.close();
      await server.close(force: true).timeout(const Duration(seconds: 3));
    }
  });

  test('cancel while secure storage is pending ends promptly without opening HTTP', () async {
    final key = Completer<Secret?>();
    var clients = 0;
    final provider = HttpModelProvider(
      readKey: (_) => key.future,
      clientFactory: () {
        clients++;
        return HttpClient();
      },
    );
    final cancel = CancellationToken();
    final result = provider
        .stream(
          request(ModelProfile(protocol: ModelProtocol.openai, endpoint: 'http://127.0.0.1:1234/v1', model: 'model')),
          cancel,
        )
        .toList();
    final assertion = expectLater(result, throwsA(isA<ModelFailure>().having((e) => e.code, 'code', 'cancelled')));
    await pumpEventQueue();
    cancel.cancel();
    await assertion.timeout(const Duration(seconds: 2));
    key.complete(const Secret('late-key'));
    await pumpEventQueue();
    expect(clients, 0);
    provider.close();
  });

  test('cancel closes a waiting response and yields no completed message', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final received = Completer<void>();
    server.listen((incoming) async {
      await incoming.drain<void>();
      incoming.response.headers.contentType = ContentType('text', 'event-stream');
      incoming.response.write(': heartbeat\n\n');
      await incoming.response.flush();
      received.complete();
    });
    final provider = HttpModelProvider(readKey: (_) async => null);
    final cancel = CancellationToken();
    final completed = <ModelMessageComplete>[];
    final assertion = expectLater(
      provider.stream(request(localProfile(server, ModelProtocol.openai)), cancel).forEach((event) {
        if (event is ModelMessageComplete) completed.add(event);
      }),
      throwsA(isA<ModelFailure>().having((e) => e.code, 'code', 'cancelled')),
    );
    try {
      await received.future.timeout(const Duration(seconds: 3));
      cancel.cancel();
      await assertion.timeout(const Duration(seconds: 2));
      expect(completed, isEmpty);
    } finally {
      provider.close();
      await server.close(force: true).timeout(const Duration(seconds: 3));
    }
  });

  test('provider close cancels pending work and idle expiry is a typed failure', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final received = Completer<void>();
    server.listen((incoming) async {
      await incoming.drain<void>();
      received.complete();
    });
    final provider = HttpModelProvider(readKey: (_) async => null, idleTimeout: const Duration(milliseconds: 100));
    try {
      final result = provider.stream(request(localProfile(server, ModelProtocol.openai)), CancellationToken()).toList();
      final assertion = expectLater(
        result,
        throwsA(isA<ModelFailure>().having((e) => e.code, 'code', 'modelTimedOut')),
      );
      await received.future.timeout(const Duration(seconds: 3));
      await assertion.timeout(const Duration(seconds: 2));
      provider.close();
      await expectLater(
        provider.stream(request(localProfile(server, ModelProtocol.openai)), CancellationToken()).toList(),
        throwsA(isA<ModelFailure>().having((e) => e.code, 'code', 'cancelled')),
      );
    } finally {
      provider.close();
      await server.close(force: true).timeout(const Duration(seconds: 3));
    }
  });

  test('wrong MIME type and tools absent from the offered catalog are rejected', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var calls = 0;
    server.listen((incoming) async {
      await incoming.drain<void>();
      calls++;
      if (calls == 1) {
        incoming.response.headers.contentType = ContentType.json;
        incoming.response.write('{"error":"not SSE"}');
      } else {
        incoming.response.headers.contentType = ContentType('text', 'event-stream');
        incoming.response.write(
          'data: ${jsonEncode({
            'choices': [
              {
                'index': 0,
                'delta': {
                  'tool_calls': [
                    {
                      'index': 0,
                      'id': 'one',
                      'type': 'function',
                      'function': {'name': 'forged', 'arguments': '{}'},
                    },
                  ],
                },
                'finish_reason': 'tool_calls',
              },
            ],
          })}\n\ndata: [DONE]\n\n',
        );
      }
      await incoming.response.close();
    });
    final provider = HttpModelProvider(readKey: (_) async => null);
    try {
      for (final code in ['invalidModelContentType', 'unrequestedModelTool']) {
        await expectLater(
          provider.stream(request(localProfile(server, ModelProtocol.openai)), CancellationToken()).toList(),
          throwsA(isA<ModelFailure>().having((e) => e.code, 'code', code)),
        );
      }
    } finally {
      provider.close();
      await server.close(force: true).timeout(const Duration(seconds: 3));
    }
  });

  test('the final encoded request budget includes private continuation before reading a key', () async {
    var reads = 0;
    var clients = 0;
    final provider = HttpModelProvider(
      readKey: (_) async {
        reads++;
        return null;
      },
      clientFactory: () {
        clients++;
        return HttpClient();
      },
    );
    final p = ModelProfile(protocol: ModelProtocol.anthropic, endpoint: 'http://127.0.0.1:1234/v1', model: 'model');
    final wire = [
      {
        'type': 'message_start',
        'message': {'role': 'assistant', 'content': []},
      },
      {
        'type': 'content_block_start',
        'index': 0,
        'content_block': {'type': 'redacted_thinking', 'data': 'x' * 49000},
      },
      {'type': 'content_block_stop', 'index': 0},
      {
        'type': 'message_delta',
        'delta': {'stop_reason': 'end_turn'},
      },
      {'type': 'message_stop'},
    ].map((value) => 'event: ${value['type']}\ndata: ${jsonEncode(value)}\n\n').join();
    final events = await decodeModelStream(p, Stream.value(utf8.encode(wire))).toList();
    final message = events.whereType<ModelMessageComplete>().single.message;
    await expectLater(
      provider
          .stream(
            ModelRequest(
              profile: p,
              system: '',
              messages: [
                ModelMessage(ModelRole.user, text: 'explain'),
                message,
                ModelMessage(ModelRole.user, text: 'next'),
              ],
            ),
            CancellationToken(),
          )
          .toList(),
      throwsA(isA<ModelFailure>().having((e) => e.code, 'code', 'inputLimit')),
    );
    expect(reads, 0);
    expect(clients, 0);
    provider.close();
  });
}

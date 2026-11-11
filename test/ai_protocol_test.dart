// Protocol samples intentionally concatenate independent SSE records.
// ignore_for_file: prefer_interpolation_to_compose_strings

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/features/ai/adapters/model_provider.dart';
import 'package:sshairy/features/ai/adapters/sse.dart';
import 'package:sshairy/features/ai/domain/model.dart';

ModelProfile profile(ModelProtocol protocol, {String endpoint = 'https://model.example/v1'}) =>
    ModelProfile(protocol: protocol, endpoint: endpoint, model: 'user-selected', tools: true);

String sse(Object value, {String? event}) =>
    '${event == null ? '' : 'event: $event\r\n'}data: ${jsonEncode(value)}\r\n\r\n';
String anthropic(String type, Map<String, Object?> fields) => sse({'type': type, ...fields}, event: type);
String chunk(Map<String, Object?> delta, {String? reason}) => sse({
  'id': 'message-1',
  'choices': [
    {'index': 0, 'delta': delta, 'finish_reason': reason},
  ],
});
Stream<List<int>> split(String text, int width) async* {
  final bytes = utf8.encode(text);
  for (var offset = 0; offset < bytes.length; offset += width) {
    yield bytes.sublist(offset, (offset + width).clamp(0, bytes.length));
  }
}

String get start => anthropic('message_start', {
  'message': {
    'role': 'assistant',
    'content': [],
    'usage': {'input_tokens': 3},
  },
});
String end(String reason) =>
    anthropic('message_delta', {
      'delta': {'stop_reason': reason},
      'usage': {'output_tokens': 5},
    }) +
    anthropic('message_stop', {});
String block(int index, Map<String, Object?> value, {Map<String, Object?>? delta}) =>
    anthropic('content_block_start', {'index': index, 'content_block': value}) +
    (delta == null ? '' : anthropic('content_block_delta', {'index': index, 'delta': delta})) +
    anthropic('content_block_stop', {'index': index});

void main() {
  test('profiles canonicalize destinations and reject ambiguous or credential-bearing addresses', () {
    final p = profile(ModelProtocol.openai, endpoint: 'https://MODEL.EXAMPLE:443/v1/');
    expect(p.endpoint, 'https://model.example/v1');
    expect(p.requestUri.toString(), 'https://model.example/v1/chat/completions');
    expect(ModelProfile.fromJson(p.toJson()).identity, p.identity);
    for (final valid in ['http://127.0.0.1:1234/v1', 'http://localhost/v1', 'http://[::1]:1234/v1']) {
      expect(() => profile(ModelProtocol.openai, endpoint: valid), returnsNormally);
    }
    for (final invalid in [
      'http://model.example/v1',
      'http://localhost.example/v1',
      'http://127.1/v1',
      'http://127.0.0.2/v1',
      'https://user:secret@model.example/v1',
      'https://model.example/v1?key=secret',
      'https://model.example/v1#part',
      'https://model.example/a/../v1',
      'https://model.example/a/%2e%2e/v1',
      'https://model.example/a/%2F/v1',
      'https://model.example/%0A/v1',
      'file:///v1',
      'https://model.example:0/v1',
    ]) {
      expect(() => profile(ModelProtocol.openai, endpoint: invalid), throwsFormatException, reason: invalid);
    }
    expect(() => ModelProfile.fromJson({...p.toJson(), 'tools': 'true'}), throwsFormatException);
    expect(() => ModelProfile.fromJson({...p.toJson(), 'maxOutputTokens': p.contextWindow}), throwsFormatException);
    expect(() => ModelProfile.fromJson({...p.toJson(), 'key': 'secret'}), throwsFormatException);
  });

  test('SSE handles every UTF-8 byte boundary, CRLF, standalone CR, multiline data and comments', () async {
    const wire = ': heartbeat\r\nevent: sample\r\ndata: 你\r\ndata: 好🙂\r\n\r\ndata: next\r\r';
    for (var width = 1; width <= utf8.encode(wire).length; width++) {
      final events = await decodeSse(split(wire, width)).toList();
      expect(events.map((e) => e.data), ['你\n好🙂', 'next']);
      expect(events.first.event, 'sample');
      expect(events.last.event, isNull);
    }
  });

  test('SSE rejects incomplete UTF-8, unfinished event and oversized ignored lines', () async {
    await expectLater(decodeSse(Stream.value([0xf0, 0x9f])).toList(), throwsA(isA<ModelFailure>()));
    await expectLater(
      decodeSse(Stream.value(utf8.encode('data: unfinished\n'))).toList(),
      throwsA(isA<ModelFailure>()),
    );
    await expectLater(
      decodeSse(Stream.value(utf8.encode(': ${'a' * 100}')), maxEventBytes: 32).toList(),
      throwsA(isA<ModelFailure>().having((e) => e.code, 'code', 'modelEventTooLarge')),
    );
  });

  test('OpenAI aggregates multiple tools by index across arbitrary chunks only after DONE', () async {
    final tools =
        chunk({'role': 'assistant', 'content': '你好🙂'}) +
        chunk({
          'tool_calls': [
            {
              'index': 1,
              'id': 'second',
              'type': 'function',
              'function': {'name': 'command_', 'arguments': '{"host'},
            },
            {
              'index': 0,
              'id': 'first',
              'type': 'function',
              'function': {'name': 'host_list', 'arguments': '{}'},
            },
          ],
        }) +
        chunk({
          'tool_calls': [
            {
              'index': 1,
              'function': {'name': 'execute', 'arguments': '":"甲"}'},
            },
          ],
        }) +
        chunk({}, reason: 'tool_calls') +
        'data: [DONE]\n\n';
    for (final width in [1, 2, 3, 7, 64, utf8.encode(tools).length]) {
      final events = await decodeModelStream(profile(ModelProtocol.openai), split(tools, width)).toList();
      expect(events.whereType<ModelTextDelta>().map((e) => e.text).join(), '你好🙂');
      final message = events.whereType<ModelMessageComplete>().single.message;
      expect(message.calls.map((c) => c.id), ['first', 'second']);
      expect(message.calls.last.name, 'command_execute');
      expect(message.calls.last.arguments, {'host': '甲'});
    }
  });

  test('OpenAI refuses EOF, length, malformed arguments, duplicate IDs and mismatched tool finish', () async {
    final validCall = chunk({
      'tool_calls': [
        {
          'index': 0,
          'id': 'one',
          'type': 'function',
          'function': {'name': 'command_execute', 'arguments': '{}'},
        },
      ],
    });
    final cases = [
      chunk({'content': 'partial'}),
      chunk({'content': 'partial'}, reason: 'stop'),
      chunk({'content': 'partial'}, reason: 'length') + 'data: [DONE]\n\n',
      validCall + chunk({}, reason: 'stop') + 'data: [DONE]\n\n',
      chunk({
            'tool_calls': [
              {
                'index': 0,
                'id': 'one',
                'function': {'name': 'command_execute', 'arguments': '{'},
              },
            ],
          }, reason: 'tool_calls') +
          'data: [DONE]\n\n',
      chunk({
            'tool_calls': [
              {
                'index': 0,
                'id': 'one',
                'function': {'name': 'command_execute', 'arguments': '{}'},
              },
              {
                'index': 1,
                'id': 'one',
                'function': {'name': 'command_execute', 'arguments': '{}'},
              },
            ],
          }, reason: 'tool_calls') +
          'data: [DONE]\n\n',
      sse({
        'error': {'message': 'do not leak'},
      }),
    ];
    for (final wire in cases) {
      final completed = <ModelMessageComplete>[];
      await expectLater(
        decodeModelStream(profile(ModelProtocol.openai), split(wire, 1)).forEach((event) {
          if (event is ModelMessageComplete) completed.add(event);
        }),
        throwsA(isA<ModelFailure>()),
      );
      expect(completed, isEmpty);
    }
  });

  test('Anthropic preserves private signed blocks and groups tool results without exposing thinking', () async {
    final wire =
        start +
        anthropic('content_block_start', {
          'index': 0,
          'content_block': {'type': 'thinking', 'thinking': '', 'signature': ''},
        }) +
        anthropic('content_block_delta', {
          'index': 0,
          'delta': {'type': 'thinking_delta', 'thinking': 'private'},
        }) +
        anthropic('content_block_delta', {
          'index': 0,
          'delta': {'type': 'signature_delta', 'signature': 'signed-blob'},
        }) +
        anthropic('content_block_stop', {'index': 0}) +
        block(1, {'type': 'redacted_thinking', 'data': 'opaque-blob'}) +
        block(2, {'type': 'text', 'text': ''}, delta: {'type': 'text_delta', 'text': '检查🙂'}) +
        block(
          3,
          {'type': 'tool_use', 'id': 'one', 'name': 'host_list', 'input': {}},
          delta: {'type': 'input_json_delta', 'partial_json': '{}'},
        ) +
        block(
          4,
          {'type': 'tool_use', 'id': 'two', 'name': 'command_execute', 'input': {}},
          delta: {'type': 'input_json_delta', 'partial_json': '{"host":"甲"}'},
        ) +
        end('tool_use');
    for (final width in [1, 2, 5, 64, wire.length]) {
      final p = profile(ModelProtocol.anthropic);
      final events = await decodeModelStream(p, split(wire, width)).toList();
      expect(events.whereType<ModelTextDelta>().map((e) => e.text).join(), '检查🙂');
      final message = events.whereType<ModelMessageComplete>().single.message;
      expect(message.text, '检查🙂');
      expect(message.calls, hasLength(2));
      final body = encodeModelRequest(
        ModelRequest(
          profile: p,
          system: 'system',
          messages: [
            ModelMessage(ModelRole.user, text: 'check'),
            message,
            ModelMessage(ModelRole.tool, toolCallId: 'one', text: '{}'),
            ModelMessage(ModelRole.tool, toolCallId: 'two', text: 'denied', isError: true),
          ],
        ),
      );
      final messages = body['messages'] as List;
      expect(messages, hasLength(3));
      expect(messages[1]['content'][0], {'type': 'thinking', 'thinking': 'private', 'signature': 'signed-blob'});
      expect(messages[1]['content'][1], {'type': 'redacted_thinking', 'data': 'opaque-blob'});
      expect(messages[2]['content'], hasLength(2));
      expect(messages[2]['content'][1]['is_error'], isTrue);
      final edited = ModelMessage(ModelRole.assistant, text: 'changed', calls: message.calls, opaque: message.opaque);
      expect(
        () => encodeModelRequest(
          ModelRequest(
            profile: p,
            system: '',
            messages: [
              edited,
              ModelMessage(ModelRole.tool, toolCallId: 'one'),
              ModelMessage(ModelRole.tool, toolCallId: 'two'),
            ],
          ),
        ),
        throwsA(isA<ModelFailure>().having((e) => e.code, 'code', 'invalidModelContinuation')),
      );
      for (final other in [
        profile(ModelProtocol.openai),
        profile(ModelProtocol.anthropic, endpoint: 'https://other.example/v1'),
      ]) {
        expect(
          () => encodeModelRequest(
            ModelRequest(
              profile: other,
              system: '',
              messages: [
                message,
                ModelMessage(ModelRole.tool, toolCallId: 'one'),
                ModelMessage(ModelRole.tool, toolCallId: 'two'),
              ],
            ),
          ),
          throwsA(isA<ModelFailure>().having((e) => e.code, 'code', 'invalidModelContinuation')),
        );
      }
    }
  });

  test('Anthropic incomplete blocks, truncated arguments and hosted tools never complete', () async {
    final cases = [
      start +
          anthropic('content_block_start', {
            'index': 0,
            'content_block': {'type': 'tool_use', 'id': 'one', 'name': 'host_list', 'input': {}},
          }) +
          end('tool_use'),
      start +
          block(
            0,
            {'type': 'tool_use', 'id': 'one', 'name': 'host_list', 'input': {}},
            delta: {'type': 'input_json_delta', 'partial_json': '{'},
          ) +
          end('tool_use'),
      start + block(0, {'type': 'text', 'text': 'partial'}) + end('max_tokens'),
      start + block(0, {'type': 'server_tool_use', 'id': 'one', 'name': 'web_search', 'input': {}}) + end('tool_use'),
      start +
          sse({
            'type': 'error',
            'error': {'message': 'private'},
          }, event: 'error'),
    ];
    for (final wire in cases) {
      await expectLater(
        decodeModelStream(profile(ModelProtocol.anthropic), split(wire, 3)).toList(),
        throwsA(isA<ModelFailure>()),
      );
    }
  });

  test('messages require complete call/result pairs and local bounds', () {
    final p = profile(ModelProtocol.openai);
    final call = ModelMessage(ModelRole.assistant, calls: [ModelCall('one', 'host_list', {})]);
    for (final messages in [
      [call],
      [ModelMessage(ModelRole.tool, toolCallId: 'forged')],
      [call, ModelMessage(ModelRole.user, text: 'skip')],
      [call, ModelMessage(ModelRole.tool, toolCallId: 'one'), ModelMessage(ModelRole.tool, toolCallId: 'one')],
    ]) {
      expect(
        () => encodeModelRequest(ModelRequest(profile: p, system: '', messages: messages)),
        throwsA(isA<ModelFailure>()),
      );
    }
  });

  test('tool arguments and assistant text have independent hard limits', () async {
    final tooLargeArguments =
        chunk({
          'tool_calls': [
            {
              'index': 0,
              'id': 'one',
              'function': {'name': 'host_list', 'arguments': '{"a":"${'x' * (64 * 1024)}"}'},
            },
          ],
        }) +
        chunk({}, reason: 'tool_calls') +
        'data: [DONE]\n\n';
    await expectLater(
      decodeModelStream(profile(ModelProtocol.openai), split(tooLargeArguments, 2048)).toList(),
      throwsA(isA<ModelFailure>().having((e) => e.code, 'code', 'modelArgumentsTooLarge')),
    );
    final tooLargeText =
        List.generate(17, (_) => chunk({'content': 'x' * 65536})).join() +
        chunk({}, reason: 'stop') +
        'data: [DONE]\n\n';
    await expectLater(
      decodeModelStream(profile(ModelProtocol.openai), split(tooLargeText, 8192)).toList(),
      throwsA(isA<ModelFailure>().having((e) => e.code, 'code', 'modelMessageTooLarge')),
    );
  });
}

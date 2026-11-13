import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/features/ai/adapters/model_provider.dart';
import 'package:sshairy/features/ai/application/context.dart';
import 'package:sshairy/features/ai/domain/model.dart';

ModelProfile _profile(ModelProtocol protocol) =>
    ModelProfile(protocol: protocol, endpoint: 'https://model.invalid/v1', model: 'test');

int _estimate(ModelProfile profile, List<ModelMessage> messages) =>
    estimateModelRequestBytes(ModelRequest(profile: profile, system: 'fixed rules', messages: messages));

int _projectionBytes(List<ModelMessage> messages) {
  var bytes = messages
      .where((message) => message.role == ModelRole.tool)
      .fold(0, (size, message) => size + utf8.encode(jsonEncode(message.text)).length);
  final first = jsonDecode(messages.first.text);
  if (first is Map && first['contextSummary'] != null) {
    bytes += utf8.encode(jsonEncode(jsonEncode({'contextSummary': first['contextSummary']}))).length;
  }
  return bytes;
}

List<ModelMessage> _group(String id, String result) => [
  ModelMessage(
    ModelRole.assistant,
    calls: [
      ModelCall(id, 'output_read', {'handle': 'not-summary-data'}),
    ],
  ),
  ModelMessage(ModelRole.tool, toolCallId: id, text: result),
];

String _event(String type, Map<String, Object?> data) =>
    'event: $type\ndata: ${jsonEncode({'type': type, ...data})}\n\n';

Future<ModelMessage> _signedMessage(ModelProfile profile, {String? callId}) async {
  final wire = [
    _event('message_start', {
      'message': {'role': 'assistant', 'content': []},
    }),
    _event('content_block_start', {
      'index': 0,
      'content_block': {'type': 'thinking', 'thinking': 'private-thought', 'signature': 'private-signature'},
    }),
    _event('content_block_stop', {'index': 0}),
    _event('content_block_start', {
      'index': 1,
      'content_block': {'type': 'text', 'text': 'Short answer'},
    }),
    _event('content_block_stop', {'index': 1}),
    if (callId != null) ...[
      _event('content_block_start', {
        'index': 2,
        'content_block': {'type': 'tool_use', 'id': callId, 'name': 'host_list', 'input': {}},
      }),
      _event('content_block_stop', {'index': 2}),
    ],
    _event('message_delta', {
      'delta': {'stop_reason': callId == null ? 'end_turn' : 'tool_use'},
    }),
    _event('message_stop', {}),
  ].join();
  final events = await decodeModelStream(profile, Stream.value(utf8.encode(wire))).toList();
  return events.whereType<ModelMessageComplete>().single.message;
}

void main() {
  test(
    'short Anthropic replies use the complete encoded estimate before and after adding opaque continuation',
    () async {
      final profile = _profile(ModelProtocol.anthropic);
      final context = AgentContext(input: 'inspect', goalInput: 'inspect');
      final complete = await _signedMessage(profile);
      final expected = (_estimate(profile, [...context.messages, complete]) + 1) ~/ 2;
      expect(expected, lessThan(2048));
      expect(
        context.estimatedTokens(
          profile,
          'fixed rules',
          [],
          pending: complete,
          estimateBytes: (messages) => _estimate(profile, messages),
        ),
        expected,
      );
      expect(context.messages, hasLength(1));
      context.add(complete);
      expect(
        context.estimatedTokens(profile, 'fixed rules', [], estimateBytes: (messages) => _estimate(profile, messages)),
        expected,
      );
      expect(
        context.prepare(profile, 'fixed rules', [], estimateBytes: (messages) => _estimate(profile, messages)),
        isFalse,
      );
      expect(context.messages.last, same(complete));
    },
  );

  test('pending tool calls use the same full encoder with temporary result placeholders only for estimation', () async {
    final profile = _profile(ModelProtocol.anthropic);
    final context = AgentContext(input: 'inspect', goalInput: 'inspect');
    final complete = await _signedMessage(profile, callId: 'pending-call');
    List<ModelMessage>? estimated;
    final tokens = context.estimatedTokens(
      profile,
      'fixed rules',
      [],
      pending: complete,
      estimateBytes: (messages) {
        estimated = messages;
        return _estimate(profile, messages);
      },
    );
    expect(tokens, (_estimate(profile, estimated!) + 1) ~/ 2);
    expect(tokens, lessThan(2048));
    expect(estimated, hasLength(3));
    expect(estimated![1], same(complete));
    expect(estimated!.last.role, ModelRole.tool);
    expect(estimated!.last.toolCallId, 'pending-call');
    expect(estimated!.last.text, isEmpty);
    expect(context.messages, hasLength(1));
  });

  test('encoded tool content accumulates across complete groups even in a large model window', () {
    for (final protocol in ModelProtocol.values) {
      final profile = _profile(protocol);
      final context = AgentContext(input: '{}', goalInput: 'keep this goal');
      final result = jsonEncode({'text': '\\' * 6000});
      final older = _group('older', result), latest = _group('latest', result);
      for (final message in [...older, ...latest]) {
        context.add(message);
      }
      expect(utf8.encode(result).length * 2, lessThan(32 << 10));
      expect(utf8.encode(jsonEncode(result)).length, lessThan(32 << 10));
      expect(_projectionBytes(context.messages), greaterThan(32 << 10));
      expect(_estimate(profile, context.messages), lessThan(100000));
      expect(
        context.prepare(profile, 'fixed rules', [], estimateBytes: (messages) => _estimate(profile, messages)),
        isTrue,
      );
      expect(context.messages.skip(1), latest);
      expect(_projectionBytes(context.messages), lessThanOrEqualTo(32 << 10));
      final root = jsonDecode(context.messages.first.text) as Map;
      expect(root['currentRequest'], 'keep this goal');
      expect(root['contextSummary']['entries'].single['results'].single['callId'], 'older');
      expect(jsonEncode(root), isNot(contains('not-summary-data')));
      expect(
        context.prepare(profile, 'fixed rules', [], estimateBytes: (messages) => _estimate(profile, messages)),
        isFalse,
      );
    }
  });

  test(
    'a latest tool group over the cumulative limit becomes data as a whole and preserves the goal and attachments',
    () {
      for (final protocol in ModelProtocol.values) {
        final profile = _profile(protocol);
        final attachment = AgentAttachment.text(id: 'attached', name: 'notes.txt', text: 'a' * 40000);
        final context = AgentContext(input: '{}', goalInput: 'exact current goal', attachments: [attachment]);
        context.add(
          ModelMessage(
            ModelRole.assistant,
            calls: [ModelCall('one', 'output_read', {}), ModelCall('two', 'output_read', {})],
          ),
        );
        for (final id in ['one', 'two']) {
          context.add(ModelMessage(ModelRole.tool, toolCallId: id, text: jsonEncode({'text': '\\' * 6000})));
        }
        expect(
          context.prepare(profile, 'fixed rules', [], estimateBytes: (messages) => _estimate(profile, messages)),
          isTrue,
        );
        expect(context.messages, hasLength(1));
        expect(context.messages.single.calls, isEmpty);
        expect(context.messages.single.attachments.single, same(attachment));
        expect(_projectionBytes(context.messages), lessThanOrEqualTo(32 << 10));
        final root = jsonDecode(context.messages.single.text) as Map;
        expect(root['currentRequest'], 'exact current goal');
        final summary = root['contextSummary'] as Map;
        expect(summary['truncated'], isTrue);
        expect(summary['entries'].single['results'].map((dynamic result) => result['callId']), ['one', 'two']);
        expect(
          _estimate(profile, context.messages),
          greaterThan(32 << 10),
          reason: 'attachments have a separate budget',
        );
      }
    },
  );

  test('summary material shares the tool budget and oldest omissions are marked', () {
    final profile = _profile(ModelProtocol.openai);
    final context = AgentContext(input: '{}', goalInput: 'goal');
    final latest = jsonEncode({'text': 'x' * 32730});
    for (final message in [..._group('older', '{"text":"old data"}'), ..._group('latest', latest)]) {
      context.add(message);
    }
    expect(utf8.encode(jsonEncode(latest)).length, lessThan(32 << 10));
    expect(
      context.prepare(profile, 'fixed rules', [], estimateBytes: (messages) => _estimate(profile, messages)),
      isTrue,
    );
    expect(context.messages, hasLength(1), reason: 'the newest raw result leaves no space for the summary marker');
    expect(_projectionBytes(context.messages), lessThanOrEqualTo(32 << 10));
    final summary = (jsonDecode(context.messages.single.text) as Map)['contextSummary'] as Map;
    expect(summary['omittedGroupsOrEntries'], greaterThan(0));
    expect(summary['entries'].single['results'].single['callId'], 'latest');
  });

  test('a fixed input above the soft compaction target keeps its last summary when hard limits allow it', () {
    final profile = ModelProfile(
      protocol: ModelProtocol.openai,
      endpoint: 'https://model.invalid/v1',
      model: 'small-window',
      contextWindow: 8000,
      maxOutputTokens: 1000,
    );
    final context = AgentContext(input: '{}', goalInput: 'g' * 6500);
    for (final message in _group('last-result', jsonEncode({'text': 'x' * 10000}))) {
      context.add(message);
    }
    expect(
      context.prepare(profile, 'fixed rules', [], estimateBytes: (messages) => _estimate(profile, messages)),
      isTrue,
    );
    expect(context.messages, hasLength(1));
    final root = jsonDecode(context.messages.single.text) as Map;
    expect(root['currentRequest'], 'g' * 6500);
    expect(root['contextSummary']['entries'].single['results'].single['callId'], 'last-result');
    expect(root['contextSummary']['omittedGroupsOrEntries'], 0);
  });

  test('cumulative projection compaction ends opaque continuation instead of replaying signed groups', () async {
    final profile = _profile(ModelProtocol.anthropic);
    final context = AgentContext(input: '{}', goalInput: 'preserved goal');
    for (final id in ['one', 'two']) {
      context.add(await _signedMessage(profile, callId: id));
      context.add(ModelMessage(ModelRole.tool, toolCallId: id, text: jsonEncode({'text': '\\' * 6000})));
    }
    expect(
      context.prepare(profile, 'fixed rules', [], estimateBytes: (messages) => _estimate(profile, messages)),
      isTrue,
    );
    expect(context.messages, hasLength(1));
    expect(context.messages.single.opaque, isNull);
    final root = jsonDecode(context.messages.single.text) as Map;
    expect(root['currentRequest'], 'preserved goal');
    expect(root['contextSummary']['protocolRestarted'], isTrue);
    final encoded = jsonEncode(
      encodeModelRequest(ModelRequest(profile: profile, system: 'fixed rules', messages: context.messages)),
    );
    expect(encoded, isNot(contains('private-thought')));
    expect(encoded, isNot(contains('private-signature')));
    expect(_projectionBytes(context.messages), lessThanOrEqualTo(32 << 10));
  });
}

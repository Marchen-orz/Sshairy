import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/features/ai/adapters/model_provider.dart';
import 'package:sshairy/features/ai/application/context.dart';
import 'package:sshairy/features/ai/domain/agent.dart';
import 'package:sshairy/features/ai/domain/model.dart';
import 'package:sshairy/foundation/cancellation.dart';

ModelProfile _profile(ModelProtocol protocol, {int contextWindow = 1000000, int maxOutputTokens = 4096}) =>
    ModelProfile(
      protocol: protocol,
      endpoint: 'https://model.invalid/v1',
      model: 'test',
      contextWindow: contextWindow,
      maxOutputTokens: maxOutputTokens,
    );

AgentAttachment _image(String id, {int bytes = 1 << 20, int width = 1920, int height = 1080}) {
  final data = Uint8List(bytes);
  data.setRange(0, 16, [137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82]);
  final header = ByteData.sublistView(data);
  header.setUint32(16, width);
  header.setUint32(20, height);
  return AgentAttachment.image(id: id, name: '$id.png', base64: base64Encode(data));
}

final _contextLimit = throwsA(isA<AgentFailure>().having((failure) => failure.code, 'code', 'contextLimit'));
final _wireLimit = throwsA(isA<ModelFailure>().having((failure) => failure.code, 'code', 'modelContextTooLarge'));

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
  for (final protocol in ModelProtocol.values) {
    test('${protocol.name} budgets multiple large screenshots by dimensions and keeps the complete wire payload', () {
      final profile = _profile(protocol, contextWindow: 128000);
      final images = [_image('first'), _image('second')];
      final context = AgentContext(input: 'inspect screenshots', goalInput: 'inspect screenshots', attachments: images);
      final request = ModelRequest(profile: profile, system: 'fixed rules', messages: context.messages);
      final wire = jsonEncode(encodeModelRequest(request));
      final wireBytes = utf8.encode(wire).length;
      expect(wireBytes, greaterThan(2 << 20));
      expect(wireBytes, lessThan(ModelInputBudget.maxWireBytes));
      expect(wire, contains(images.first.content));
      expect(wire, contains(images.last.content));
      final imageBytes = images.fold(0, (size, image) => size + ModelInputBudget.imageBytes(image));
      final payloadBytes = images.fold(0, (size, image) => size + image.content.length);
      expect(estimateModelRequestBytes(request), wireBytes - payloadBytes + imageBytes);
      expect(estimateModelRequestBytes(request), lessThan(ModelInputBudget.availableBytes(profile)));
      for (final int Function(List<ModelMessage>)? estimate in [
        null,
        (List<ModelMessage> messages) => _estimate(profile, messages),
      ]) {
        expect(context.prepare(profile, 'fixed rules', [], estimateBytes: estimate), isFalse);
        expect(context.estimatedTokens(profile, 'fixed rules', [], estimateBytes: estimate), lessThan(20000));
      }
      expect(context.messages.single.attachments, images);
    });

    test('${protocol.name} image budget follows dimensions rather than compressed payload size', () {
      final small = _image('same', bytes: 400000, width: 32, height: 32);
      final padded = _image('same', bytes: 800000, width: 32, height: 32);
      final large = _image('same', bytes: 800000, width: 2048, height: 2048);
      final profile = _profile(protocol);
      int estimate(AgentAttachment image) => _estimate(profile, [
        ModelMessage(ModelRole.user, attachments: [image]),
      ]);
      expect(estimate(small), estimate(padded));
      expect(estimate(large) - estimate(padded), 4 * (64 * 64 - 1) * 2);
    });

    test(
      '${protocol.name} a small window rejects accumulated images before reading a key or opening a client',
      () async {
        final profile = _profile(protocol, contextWindow: 16000, maxOutputTokens: 1000);
        final images = [_image('first'), _image('second')];
        final one = AgentContext(input: 'inspect', goalInput: 'inspect', attachments: images.take(1));
        expect(one.prepare(profile, 'fixed rules', []), isFalse);
        final context = AgentContext(input: 'inspect', goalInput: 'inspect', attachments: images);
        for (final int Function(List<ModelMessage>)? estimate in [
          null,
          (List<ModelMessage> messages) => _estimate(profile, messages),
        ]) {
          expect(() => context.prepare(profile, 'fixed rules', [], estimateBytes: estimate), _contextLimit);
        }
        var reads = 0, clients = 0;
        final provider = HttpModelProvider(
          readKey: (_) async {
            reads++;
            throw StateError('unexpected key access');
          },
          clientFactory: () {
            clients++;
            throw StateError('unexpected network access');
          },
        );
        addTearDown(provider.close);
        await expectLater(
          provider
              .stream(
                ModelRequest(profile: profile, system: 'fixed rules', messages: context.messages),
                CancellationToken(),
              )
              .toList(),
          throwsA(isA<ModelFailure>().having((failure) => failure.code, 'code', 'inputLimit')),
        );
        expect(reads, 0);
        expect(clients, 0);
      },
    );

    test('${protocol.name} text attachments can use a large window but retain escaped-text context costs', () {
      final attachment = AgentAttachment.text(id: 'text', name: 'notes.txt', text: 'a' * (3 << 20));
      final profile = _profile(protocol, contextWindow: 2000000);
      final context = AgentContext(input: 'inspect', goalInput: 'inspect', attachments: [attachment]);
      expect(_estimate(profile, context.messages), greaterThan(2 << 20));
      expect(
        context.prepare(profile, 'fixed rules', [], estimateBytes: (messages) => _estimate(profile, messages)),
        isFalse,
      );
      final escaped = AgentAttachment.text(id: 'escaped', name: 'escaped.txt', text: '\\' * (600 << 10));
      final escapedContext = AgentContext(input: 'inspect', goalInput: 'inspect', attachments: [escaped]);
      final defaultProfile = _profile(protocol);
      expect(escaped.bytes, lessThan(ModelInputBudget.availableBytes(defaultProfile)));
      expect(
        _estimate(defaultProfile, escapedContext.messages),
        greaterThan(ModelInputBudget.availableBytes(defaultProfile)),
      );
      expect(() => escapedContext.prepare(defaultProfile, 'fixed rules', []), _contextLimit);
      expect(
        () => escapedContext.prepare(
          defaultProfile,
          'fixed rules',
          [],
          estimateBytes: (messages) => _estimate(defaultProfile, messages),
        ),
        _contextLimit,
      );
      final huge = AgentContext(
        input: 'inspect',
        goalInput: 'inspect',
        attachments: [AgentAttachment.text(id: 'huge', name: 'huge.txt', text: 'a' * (5 << 20))],
      );
      expect(
        () => huge.prepare(profile, 'fixed rules', [], estimateBytes: (messages) => _estimate(profile, messages)),
        _contextLimit,
      );
    });

    test('${protocol.name} a large configured window retains the independent ordinary-message cap', () {
      final profile = _profile(protocol, contextWindow: 2000000);
      final input = 'a' * ((2 << 20) + 1);
      final context = AgentContext(input: input, goalInput: input);
      expect(
        () => encodeModelRequest(ModelRequest(profile: profile, system: '', messages: context.messages)),
        _wireLimit,
      );
      expect(_estimate(profile, context.messages), greaterThan(ModelInputBudget.availableBytes(profile)));
      expect(() => context.prepare(profile, '', []), _contextLimit);
      expect(
        () => context.prepare(profile, 'fixed rules', [], estimateBytes: (messages) => _estimate(profile, messages)),
        _contextLimit,
      );
    });

    test('${protocol.name} wire size stays bounded when image context alone would fit', () async {
      final image = _image('image', bytes: 13 << 20, width: 32, height: 32);
      final profile = _profile(protocol, contextWindow: 2000000);
      final messages = [
        ModelMessage(ModelRole.user, attachments: [image]),
        ModelMessage(ModelRole.assistant, text: 'next'),
        ModelMessage(ModelRole.user, attachments: [image]),
      ];
      final request = ModelRequest(profile: profile, system: 'fixed rules', messages: messages);
      expect(2 * ModelInputBudget.imageBytes(image), lessThan(ModelInputBudget.availableBytes(profile)));
      expect(() => encodeModelRequest(request), _wireLimit);
      expect(estimateModelRequestBytes(request), greaterThan(ModelInputBudget.availableBytes(profile)));
      final context = AgentContext(input: '', goalInput: '', attachments: [image]);
      context.add(messages[1]);
      context.add(messages[2]);
      // Estimation also rejects the wire envelope before any compaction can parse later groups.
      expect(
        context.estimatedTokens(profile, 'fixed rules', []),
        greaterThan(profile.contextWindow - profile.maxOutputTokens - 2048),
      );
      var reads = 0, clients = 0;
      final provider = HttpModelProvider(
        readKey: (_) async {
          reads++;
          throw StateError('unexpected key access');
        },
        clientFactory: () {
          clients++;
          throw StateError('unexpected network access');
        },
      );
      addTearDown(provider.close);
      await expectLater(provider.stream(request, CancellationToken()).toList(), _wireLimit);
      expect(reads, 0);
      expect(clients, 0);
    });

    test('${protocol.name} final JSON escaping is included in the wire bound', () {
      final attachment = AgentAttachment.text(id: 'escaped', name: 'notes.txt', text: '\\' * (9 << 20));
      final request = ModelRequest(
        profile: _profile(protocol, contextWindow: 2000000),
        system: '',
        messages: [
          ModelMessage(ModelRole.user, attachments: [attachment]),
        ],
      );
      expect(attachment.bytes, lessThan(AgentAttachmentLimits.totalBytes));
      expect(() => encodeModelRequest(request), _wireLimit);
      expect(estimateModelRequestBytes(request), greaterThan(ModelInputBudget.availableBytes(request.profile)));
    });
  }

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

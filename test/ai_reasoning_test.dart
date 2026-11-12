import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/features/ai/adapters/model_provider.dart';
import 'package:sshairy/features/ai/application/configuration.dart';
import 'package:sshairy/features/ai/application/model_selection.dart';
import 'package:sshairy/features/ai/application/providers.dart';
import 'package:sshairy/features/ai/domain/agent.dart';
import 'package:sshairy/features/ai/domain/conversation.dart';
import 'package:sshairy/features/ai/domain/model.dart';
import 'package:sshairy/features/capabilities/api.dart';
import 'package:sshairy/features/credentials/api.dart';
import 'package:sshairy/foundation/cancellation.dart';
import 'package:sshairy/foundation/data_dir.dart';
import 'package:sshairy/foundation/ids.dart';
import 'package:sshairy/foundation/secret.dart';

ModelProfile _profile({
  ModelProtocol protocol = ModelProtocol.openai,
  ReasoningEffort effort = ReasoningEffort.modelDefault,
  String model = 'claude-sonnet-5-5',
}) => ModelProfile(protocol: protocol, endpoint: 'https://model.invalid/v1', model: model, reasoningEffort: effort);

ModelRequest _request(ModelProfile profile) => ModelRequest(
  profile: profile,
  system: '',
  messages: [ModelMessage(ModelRole.user, text: 'inspect')],
);

String _event(String type, Map<String, Object?> data) =>
    'event: $type\ndata: ${jsonEncode({'type': type, ...data})}\n\n';
String _thinkingWire(String summary) =>
    _event('message_start', {
      'message': {'role': 'assistant', 'content': []},
    }) +
    _event('content_block_start', {
      'index': 0,
      'content_block': {'type': 'thinking', 'thinking': '', 'signature': ''},
    }) +
    _event('content_block_delta', {
      'index': 0,
      'delta': {'type': 'thinking_delta', 'thinking': summary},
    }) +
    _event('content_block_delta', {
      'index': 0,
      'delta': {'type': 'signature_delta', 'signature': 'private-signature'},
    }) +
    _event('content_block_stop', {'index': 0}) +
    _event('content_block_start', {
      'index': 1,
      'content_block': {'type': 'redacted_thinking', 'data': 'private-redacted'},
    }) +
    _event('content_block_stop', {'index': 1}) +
    _event('content_block_start', {
      'index': 2,
      'content_block': {'type': 'text', 'text': 'Answer'},
    }) +
    _event('content_block_stop', {'index': 2}) +
    _event('message_delta', {
      'delta': {'stop_reason': 'end_turn'},
    }) +
    _event('message_stop', {});

class _Backend implements AgentBackend {
  @override
  List<AgentHost> get hosts => const [];
  @override
  Future<AgentTarget> prepare(HostId host, CancellationToken cancel) => throw StateError('no connection');
}

class _Journal implements OperationJournal {
  @override
  Future<List<OperationRecord>> load() async => const [];
  @override
  Future<void> record(OperationRecord record) async {}
  @override
  Future<void> get saved async {}
}

class _Model implements ModelProvider {
  final entered = Completer<void>();
  final finish = Completer<void>();
  final requests = <ModelRequest>[];
  @override
  Stream<ModelEvent> stream(ModelRequest request, CancellationToken cancel) async* {
    requests.add(request);
    yield ModelReasoningDelta('检' * 1200);
    if (!entered.isCompleted) entered.complete();
    await Future.any([finish.future, cancel.whenCancelled]);
    if (cancel.isCancelled) return;
    yield const ModelTextDelta('Answer');
    yield ModelMessageComplete(ModelMessage(ModelRole.assistant, text: 'Answer'));
  }

  @override
  void close() {}
}

class _Credentials implements AiCredentials {
  @override
  Stream<void> get changes => const Stream.empty();
  @override
  Future<bool> has(String identity) async => false;
  @override
  Future<Secret?> read(String identity) async => null;
  @override
  Future<void> clear(String identity) async {}
  @override
  Future<void> save(String identity, Secret value) async {}
}

class _Configuration extends AiConfigurationController {
  _Configuration(this.profile);
  final ModelProfile profile;
  @override
  AiConfiguration build() => AiConfiguration(enabled: true, profile: profile);
}

void main() {
  test('default omits reasoning parameters and explicit effort uses each protocol contract', () {
    for (final protocol in ModelProtocol.values) {
      final defaultProfile = _profile(protocol: protocol);
      final body = encodeModelRequest(_request(defaultProfile));
      expect(body.keys, isNot(contains('reasoning_effort')));
      expect(body.keys, isNot(contains('thinking')));
      expect(body.keys, isNot(contains('output_config')));
      expect(defaultProfile.toJson(), isNot(contains('reasoningEffort')));
      for (final effort in [ReasoningEffort.low, ReasoningEffort.medium, ReasoningEffort.high]) {
        final selected = defaultProfile.withModel(defaultProfile.model, reasoningEffort: effort);
        expect(ModelProfile.fromJson(selected.toJson()).reasoningEffort, effort);
        final configured = encodeModelRequest(_request(selected));
        if (protocol == ModelProtocol.openai) {
          expect(configured['reasoning_effort'], effort.name);
          expect(configured['max_completion_tokens'], selected.maxOutputTokens);
          expect(configured.keys, isNot(contains('max_tokens')));
        } else {
          expect(configured['thinking'], {'type': 'adaptive', 'display': 'summarized'});
          expect(configured['output_config'], {'effort': effort.name});
        }
      }
    }
    expect(() => ModelProfile.fromJson({..._profile().toJson(), 'reasoningEffort': 'invented'}), throwsFormatException);
    final unsupported = _profile(
      protocol: ModelProtocol.anthropic,
      model: 'unknown-compat-alias',
      effort: ReasoningEffort.high,
    );
    expect(
      () => encodeModelRequest(_request(unsupported)),
      throwsA(isA<ModelFailure>().having((e) => e.code, 'code', 'unsupportedReasoning')),
    );
  });

  test('only explicitly requested Anthropic summaries are emitted and opaque material stays private', () async {
    for (final effort in [ReasoningEffort.modelDefault, ReasoningEffort.high]) {
      final profile = _profile(protocol: ModelProtocol.anthropic, effort: effort);
      final events = await decodeModelStream(
        profile,
        Stream.value(utf8.encode(_thinkingWire('Check the result.'))),
      ).toList();
      final summaries = events.whereType<ModelReasoningDelta>().map((event) => event.summary).join();
      expect(summaries, effort == ReasoningEffort.high ? 'Check the result.' : '');
      expect(summaries, isNot(contains('private')));
      final complete = events.whereType<ModelMessageComplete>().single.message;
      expect(complete.text, 'Answer');
      final continued = encodeModelRequest(
        ModelRequest(
          profile: profile,
          system: '',
          messages: [
            ModelMessage(ModelRole.user, text: 'inspect'),
            complete,
          ],
        ),
      );
      expect(jsonEncode(continued), contains('private-signature'));
      expect(jsonEncode(continued), contains('private-redacted'));
    }
  });

  test('OpenAI compatible reasoning content emits activity without exposing the content', () async {
    final wire =
        'data: ${jsonEncode({
          'id': 'reason',
          'choices': [
            {
              'index': 0,
              'delta': {'role': 'assistant', 'reasoning_content': 'private-internal-thought'},
            },
          ],
        })}\n\n'
        'data: ${jsonEncode({
          'id': 'reason',
          'choices': [
            {
              'index': 0,
              'delta': {'content': 'Answer'},
              'finish_reason': 'stop',
            },
          ],
        })}\n\n'
        'data: [DONE]\n\n';
    final events = await decodeModelStream(_profile(), Stream.value(utf8.encode(wire))).toList();
    expect(events.whereType<ModelReasoningDelta>().single.summary, isEmpty);
    expect(events.whereType<ModelTextDelta>().single.text, 'Answer');
    expect(events.whereType<ModelMessageComplete>().single.message.text, 'Answer');
  });

  test('reasoning overrides freeze per turn and runtime summaries remain bounded in memory', () async {
    final dir = Directory.systemTemp.createTempSync('sshairy-reasoning-');
    final profile = _profile(effort: ReasoningEffort.low);
    final model = _Model();
    final container = ProviderContainer(
      overrides: [
        dataDirProvider.overrideWithValue(dir.path),
        aiConfigurationProvider.overrideWith(() => _Configuration(profile)),
        aiModelProvider.overrideWithValue(model),
        aiCredentialsProvider.overrideWithValue(_Credentials()),
        agentBackendProvider.overrideWithValue(_Backend()),
        aiJournalProvider.overrideWithValue(_Journal()),
        capabilityDispatcherProvider.overrideWithValue(CapabilityDispatcher([])),
      ],
    );
    addTearDown(() async {
      await container.read(agentRuntimeProvider).shutdown();
      container.dispose();
      try {
        dir.deleteSync(recursive: true);
      } on FileSystemException {
        /* Windows lock cleanup can finish later. */
      }
    });
    expect(container.read(effectiveAgentProfileProvider)!.reasoningEffort, ReasoningEffort.low);
    final selection = container.read(selectedAgentReasoningProvider.notifier);
    selection.select(ReasoningEffort.high);
    final runtime = container.read(agentRuntimeProvider);
    final work = runtime.start('inspect', AgentScope());
    await model.entered.future;
    await Future<void>.delayed(Duration.zero);
    expect(model.requests.single.profile.reasoningEffort, ReasoningEffort.high);
    expect(runtime.reasoningEffort, ReasoningEffort.high);
    selection.select(ReasoningEffort.medium);
    expect(container.read(selectedAgentReasoningProvider), ReasoningEffort.high);
    final entry = runtime.messages.last;
    expect(entry.reasoningReceived, isTrue);
    expect(entry.reasoningActive, isTrue);
    expect(utf8.encode(entry.reasoningSummary).length, lessThanOrEqualTo(2048));
    expect(entry.reasoningSummary, isNot(contains('�')));
    model.finish.complete();
    await work;
    expect(entry.reasoningActive, isFalse);
    expect(entry.text, 'Answer');
    runtime.restoreConversation([
      const ConversationEntry(kind: ConversationEntryKind.assistant, text: 'Restored answer'),
    ]);
    expect(runtime.messages.single.reasoningReceived, isFalse);
    expect(runtime.messages.single.reasoningSummary, isEmpty);
    selection.reset();
    expect(container.read(selectedAgentReasoningProvider), isNull);
    expect(container.read(effectiveAgentProfileProvider)!.reasoningEffort, ReasoningEffort.low);
    final config = AiConfiguration(profile: profile, reviewModel: 'reviewer');
    expect(config.profileForInline!.reasoningEffort, ReasoningEffort.modelDefault);
    expect(config.profileForCompletion!.reasoningEffort, ReasoningEffort.modelDefault);
    expect(config.profileForReview!.reasoningEffort, ReasoningEffort.modelDefault);
  });
}

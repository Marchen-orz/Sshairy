import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/features/ai/adapters/conversation_store.dart';
import 'package:sshairy/features/ai/application/composer.dart';
import 'package:sshairy/features/ai/application/conversations.dart';
import 'package:sshairy/features/ai/application/providers.dart';
import 'package:sshairy/features/ai/application/runtime.dart';
import 'package:sshairy/features/ai/domain/agent.dart';
import 'package:sshairy/features/ai/domain/conversation.dart';
import 'package:sshairy/features/ai/domain/model.dart';
import 'package:sshairy/features/capabilities/api.dart';
import 'package:sshairy/foundation/cancellation.dart';
import 'package:sshairy/foundation/ids.dart';

const _hostA = HostId('host-a');
const _hostB = HostId('host-b');
const _routeA = '0123456789abcdef0123456789abcdef';
const _routeB = 'abcdef0123456789abcdef0123456789';
const _changedRoute = '11111111111111111111111111111111';

typedef _Script = Stream<ModelEvent> Function(ModelRequest request, CancellationToken cancel);

ModelProfile _profile({
  String model = 'test-model',
  bool tools = true,
  ModelProtocol protocol = ModelProtocol.openai,
  String endpoint = 'https://model.invalid/v1',
}) => ModelProfile(protocol: protocol, endpoint: endpoint, model: model, tools: tools);

AgentConversationRecord _record(
  String id, {
  HostId? host = _hostA,
  String? destination,
  List<ConversationEntry>? entries,
}) {
  final now = DateTime.now().toUtc();
  return AgentConversationRecord(
    id: id,
    title: 'Conversation $id',
    createdAt: now.subtract(const Duration(minutes: 1)),
    updatedAt: now,
    destination: destination ?? _profile().identity,
    host: host,
    routeSignature: host == null
        ? null
        : host == _hostA
        ? _routeA
        : _routeB,
    entries:
        entries ??
        [
          ConversationEntry(kind: ConversationEntryKind.user, text: 'earlier user $id'),
          ConversationEntry(kind: ConversationEntryKind.assistant, text: 'earlier answer $id'),
        ],
  );
}

class _MemoryStore implements ConversationStore {
  _MemoryStore([List<AgentConversationRecord> initial = const []]) : records = List.of(initial);

  List<AgentConversationRecord> records;
  final writes = <List<AgentConversationRecord>>[];
  bool failLoad = false, failSave = false;
  int loads = 0, attempts = 0;
  Completer<void>? loadGate, saveGate, saveStarted;

  @override
  Future<List<AgentConversationRecord>> load() async {
    loads++;
    if (loadGate case final gate?) await gate.future;
    if (failLoad) throw StateError('synthetic load failure');
    return List.unmodifiable(records);
  }

  @override
  Future<void> save(List<AgentConversationRecord> next) async {
    attempts++;
    if (saveStarted case final started?) {
      if (!started.isCompleted) started.complete();
    }
    if (saveGate case final gate?) await gate.future;
    if (failSave) throw StateError('synthetic save failure');
    records = List.unmodifiable(next);
    writes.add(records);
  }

  @override
  Future<void> get saved async {}
}

class _Model implements ModelProvider {
  _Model(this.script);
  final _Script? script;
  final requests = <ModelRequest>[];

  @override
  Stream<ModelEvent> stream(ModelRequest request, CancellationToken cancel) async* {
    requests.add(request);
    if (script case final run?) {
      yield* run(request, cancel);
    } else {
      yield const ModelTextDelta('A safe answer');
      yield ModelMessageComplete(ModelMessage(ModelRole.assistant, text: 'A safe answer'));
    }
  }

  @override
  void close() {}
}

class _Backend implements AgentBackend {
  final prepared = <HostId>[];

  @override
  List<AgentHost> hosts = const [AgentHost(_hostA, 'Host A'), AgentHost(_hostB, 'Host B')];

  @override
  Future<AgentTarget> prepare(HostId host, CancellationToken cancel) async {
    prepared.add(host);
    throw StateError('these lifecycle tests must not connect');
  }
}

class _Journal implements OperationJournal {
  @override
  Future<List<OperationRecord>> load() async => const [];
  @override
  Future<void> record(OperationRecord record) async {}
  @override
  Future<void> get saved async {}
}

class _Runtime extends AgentRuntime {
  _Runtime({
    required super.model,
    required super.backend,
    required super.journal,
    required super.dispatcher,
    required super.configuration,
    super.hostRoutes,
  });

  List<AgentTimelineEntry>? projectedTimeline;

  @override
  List<AgentTimelineEntry> get timeline => projectedTimeline ?? super.timeline;
}

class _Harness {
  _Harness({
    List<AgentConversationRecord> initial = const [],
    _MemoryStore? store,
    _Script? script,
    bool discoveryTools = false,
  }) : store = store ?? _MemoryStore(initial),
       model = _Model(script) {
    runtime = _Runtime(
      model: model,
      backend: backend,
      journal: _Journal(),
      dispatcher: CapabilityDispatcher([
        if (discoveryTools) ...[
          FunctionCapability(
            'agent.hosts',
            Effect.query,
            (_, _) async => runtime.listHosts(),
            agentExposed: true,
            inputSchema: const {'type': 'object', 'properties': {}, 'required': [], 'additionalProperties': false},
          ),
          FunctionCapability(
            'agent.diagnose',
            Effect.connect,
            (args, context) => runtime.diagnose(args.raw, context),
            agentExposed: true,
            inputSchema: const {
              'type': 'object',
              'properties': {
                'hostId': {'type': 'string'},
                'template': {'type': 'string'},
              },
              'required': ['hostId', 'template'],
              'additionalProperties': false,
            },
          ),
        ],
      ]),
      hostRoutes: () => routes,
      configuration: () => (enabled: enabled, profile: profile, revision: revision),
    );
    container = ProviderContainer(overrides: [agentRuntimeProvider.overrideWithValue(runtime)]);
    composer = container.read(agentComposerProvider.notifier);
    conversations = AgentConversations(
      runtime: runtime,
      store: this.store,
      composer: composer,
      draft: () => container.read(agentComposerProvider),
      destination: () => profile.identity,
      toolsEnabled: () => profile.tools,
      routes: () => routes,
      permissionMode: () => permissionMode,
    );
  }

  final _MemoryStore store;
  final _Model model;
  final backend = _Backend();
  final routes = <HostId, String>{_hostA: _routeA, _hostB: _routeB};
  ModelProfile profile = _profile();
  AgentPermissionMode permissionMode = AgentPermissionMode.confirm;
  bool enabled = true;
  int revision = 0;
  late final _Runtime runtime;
  late final ProviderContainer container;
  late final AgentComposer composer;
  late final AgentConversations conversations;

  AgentComposerState get draft => container.read(agentComposerProvider);

  Future<void> close() async {
    await conversations.saved;
    conversations.dispose();
    container.dispose();
    await runtime.shutdown().timeout(const Duration(seconds: 2));
    runtime.dispose();
    model.close();
  }
}

Future<_Harness> _create({
  List<AgentConversationRecord> initial = const [],
  _MemoryStore? store,
  _Script? script,
  bool discoveryTools = false,
}) async {
  final harness = _Harness(initial: initial, store: store, script: script, discoveryTools: discoveryTools);
  addTearDown(harness.close);
  await harness.conversations.ready;
  return harness;
}

Map<String, dynamic> _input(ModelRequest request) => jsonDecode(request.messages.single.text) as Map<String, dynamic>;

void main() {
  test('attachment-only messages persist, regenerate and withdraw without rereading files', () async {
    final h = await _create();
    final attachment = AgentAttachment.text(id: 'text', name: 'example.txt', text: 'hello attachment');
    h.composer.setAttachments([attachment]);
    await h.conversations.send('', _hostA);
    expect(h.model.requests.single.messages.first.attachments.single, same(attachment));
    expect(h.draft.attachments, isEmpty);
    expect(h.conversations.current!.entries.first.attachments.single, same(attachment));
    expect(h.conversations.current!.title, 'example.txt');
    expect(await h.conversations.regenerate(_hostA), isTrue);
    expect(h.model.requests.last.messages.first.attachments.single, same(attachment));
    expect(h.model.requests.last.tools, isEmpty);
    expect(h.backend.prepared, isEmpty);
    expect(h.conversations.withdrawLastTurn(), isTrue);
    expect(h.draft.goal, isEmpty);
    expect(h.draft.attachments.single, same(attachment));
    expect(h.conversations.current!.entries.first.retracted, isTrue);
  });

  test('attachment drafts survive conversation switching and block accidental withdrawal overwrite', () async {
    final h = await _create(initial: [_record('old')]);
    h.conversations.select('old');
    final attachment = AgentAttachment.text(id: 'draft', name: 'notes.txt', text: 'draft attachment');
    h.composer.setAttachments([attachment]);
    expect(h.conversations.canWithdraw, isFalse);
    h.conversations.newConversation();
    expect(h.draft.attachments, isEmpty);
    h.conversations.select('old');
    expect(h.draft.attachments.single, same(attachment));
    h.profile = _profile(endpoint: 'https://other.invalid/v1');
    await h.conversations.send('', _hostA, continueHistory: true);
    expect(h.model.requests, isEmpty);
    expect(h.draft.attachments.single, same(attachment));
  });

  test('conversation sends freeze the current user mode and history never restores it', () async {
    final entered = Completer<void>();
    final h = await _create(
      initial: [_record('old')],
      script: (_, cancel) async* {
        entered.complete();
        await cancel.whenCancelled;
      },
    );
    h.permissionMode = AgentPermissionMode.auto;
    h.conversations.select('old');
    expect(h.runtime.permissionMode, AgentPermissionMode.confirm);
    final work = h.conversations.send('use the selected mode', _hostA, continueHistory: true);
    await entered.future;
    expect(h.runtime.permissionMode, AgentPermissionMode.auto);
    h.permissionMode = AgentPermissionMode.observe;
    expect(h.runtime.permissionMode, AgentPermissionMode.auto);
    h.runtime.stop();
    await work;
    h.conversations.newConversation();
    h.conversations.select('old');
    expect(h.runtime.permissionMode, AgentPermissionMode.confirm);
    expect(h.permissionMode, AgentPermissionMode.observe);
  });

  test('draft-only A/B conversations preserve independent goals and hosts without persistence', () async {
    final h = await _create();
    final a = h.conversations.selectedId;
    h.composer.setGoal('unsent A');
    h.composer.selectHost(_hostA);
    expect(h.conversations.newConversation(), isTrue);
    final b = h.conversations.selectedId;
    expect(h.draft.goal, isEmpty);
    h.composer.setGoal('unsent B');
    h.composer.selectHost(_hostB);
    expect(h.conversations.select(a), isTrue);
    expect(h.draft.goal, 'unsent A');
    expect(h.draft.host, _hostA);
    expect(h.conversations.select(b), isTrue);
    expect(h.draft.goal, 'unsent B');
    expect(h.draft.host, _hostB);
    await h.conversations.saved;
    expect(h.conversations.records.map((record) => record.id).toSet(), {a, b});
    expect(h.conversations.records.every((record) => record.entries.isEmpty), isTrue);
    expect(h.store.records, isEmpty);
    expect(h.model.requests, isEmpty);
    expect(h.backend.prepared, isEmpty);
  });

  test('sent A/B conversations retain their drafts and host selections across switching', () async {
    final h = await _create();
    await h.conversations.send('first A', _hostA);
    final a = h.conversations.selectedId;
    h.composer.setGoal('next A');
    h.composer.selectHost(_hostA);
    expect(h.conversations.newConversation(), isTrue);
    h.composer.selectHost(_hostB);
    await h.conversations.send('first B', _hostB);
    final b = h.conversations.selectedId;
    h.composer.setGoal('next B');
    expect(h.conversations.select(a), isTrue);
    expect(h.draft.goal, 'next A');
    expect(h.draft.host, _hostA);
    expect(h.runtime.messages.first.text, 'first A');
    expect(h.conversations.select(b), isTrue);
    expect(h.draft.goal, 'next B');
    expect(h.draft.host, _hostB);
    expect(h.runtime.messages.first.text, 'first B');
    expect(h.model.requests, hasLength(2));
  });

  test('loading guards new, select, delete and send until readable history is ready', () async {
    final store = _MemoryStore([_record('old')])..loadGate = Completer<void>();
    final h = _Harness(store: store);
    addTearDown(h.close);
    expect(h.conversations.loading, isTrue);
    final selected = h.conversations.selectedId;
    h.composer.setGoal('keep draft');
    expect(h.conversations.newConversation(), isFalse);
    expect(h.conversations.select('old'), isFalse);
    await h.conversations.delete('old');
    await h.conversations.send('do not send yet', _hostA);
    expect(h.conversations.selectedId, selected);
    expect(h.draft.goal, 'keep draft');
    expect(h.model.requests, isEmpty);
    expect(store.records.single.id, 'old');
    store.loadGate!.complete();
    await h.conversations.ready;
    expect(h.conversations.loading, isFalse);
    expect(h.conversations.records.single.id, 'old');
  });

  test('busy runtime guards all conversation mutations and never implicitly cancels work', () async {
    final entered = Completer<void>();
    final h = await _create(
      initial: [
        _record('a'),
        _record('b', host: _hostB),
      ],
      script: (_, cancel) async* {
        entered.complete();
        await cancel.whenCancelled;
      },
    );
    expect(h.conversations.select('a'), isTrue);
    final work = h.conversations.send('wait for stop', _hostA, continueHistory: true);
    await entered.future.timeout(const Duration(seconds: 2));
    expect(h.runtime.busy, isTrue);
    final before = h.conversations.records.map((record) => record.id).toSet();
    expect(h.conversations.newConversation(), isFalse);
    expect(h.conversations.select('b'), isFalse);
    await h.conversations.delete('a');
    await h.conversations.delete('b');
    await h.conversations.send('must not replace running turn', _hostB);
    expect(h.runtime.busy, isTrue);
    expect(h.conversations.selectedId, 'a');
    expect(h.conversations.records.map((record) => record.id).toSet(), before);
    expect(h.model.requests, hasLength(1));
    h.runtime.stop();
    await work.timeout(const Duration(seconds: 2));
    expect(h.runtime.busy, isFalse);
    expect(h.conversations.newConversation(), isTrue);
  });

  test('restoring and selecting history never sends, connects or restores approvals and output handles', () async {
    final h = await _create(
      initial: [
        _record(
          'restored',
          entries: const [
            ConversationEntry(kind: ConversationEntryKind.user, text: 'old question'),
            ConversationEntry(
              kind: ConversationEntryKind.execution,
              text: 'previously shared projection',
              capability: 'command.execute',
              state: 'running',
              truncated: true,
            ),
            ConversationEntry(kind: ConversationEntryKind.assistant, text: 'old answer'),
          ],
        ),
      ],
    );
    expect(h.model.requests, isEmpty);
    expect(h.runtime.timeline, isEmpty);
    expect(h.conversations.select('restored'), isTrue);
    expect(h.runtime.messages.map((entry) => entry.text), ['old question', 'old answer']);
    final execution = h.runtime.executions.single;
    expect(execution.archived, isTrue);
    expect(execution.state, 'outcomeUnknown');
    expect(execution.sharedText, 'previously shared projection');
    expect(execution.historyTruncated, isTrue);
    expect(execution.command, isEmpty);
    expect(execution.target, isEmpty);
    expect(execution.cwd, isEmpty);
    expect(execution.output, isNull);
    expect(h.runtime.outputs.count, 0);
    expect(h.runtime.approval, isNull);
    expect(h.runtime.busy, isFalse);
    expect(h.model.requests, isEmpty);
    expect(h.backend.prepared, isEmpty);
  });

  test('unfocused discovery confirms an actual target without changing its original default', () async {
    var step = 0;
    final h = await _create(
      discoveryTools: true,
      script: (_, _) async* {
        if (step++ == 0) {
          yield ModelMessageComplete(
            ModelMessage(
              ModelRole.assistant,
              calls: [
                ModelCall('list', 'host_list', {}),
                ModelCall('target', 'diagnostics_collect', {'hostId': _hostA.value, 'template': 'systemSummary'}),
              ],
            ),
          );
        } else {
          yield ModelMessageComplete(ModelMessage(ModelRole.assistant, text: 'Declined.'));
        }
      },
    );
    final work = h.conversations.send('check Host A', null);
    for (var attempt = 0; attempt < 1000 && h.runtime.hostApproval == null; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(h.runtime.hostApproval, isNotNull);
    expect(h.backend.prepared, isEmpty);
    h.runtime.decideHost(h.runtime.hostApproval!, true);
    for (var attempt = 0; attempt < 1000 && h.runtime.approval == null; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(h.runtime.approval?.template, 'systemSummary');
    expect(h.backend.prepared, isEmpty);
    h.runtime.approve(true, expected: h.runtime.approval!);
    await work;
    expect(h.backend.prepared, [_hostA]);
    expect(h.runtime.resolvedHost, _hostA);
    expect(h.conversations.current!.host, isNull);
    expect(h.conversations.current!.routeSignature, isNull);
    expect(h.store.records.single.host, isNull);
    expect(h.conversations.canContinue(_hostA), isTrue);
    expect(h.conversations.canContinue(null), isTrue);
    expect(_input(h.model.requests.first)['targetSelection'], 'discoverFromUserRequest');
  });

  test('host-bound conversation continues without focus and retains its initial host', () async {
    final h = await _create(initial: [_record('host-bound')]);
    h.conversations.select('host-bound');
    expect(h.conversations.canContinue(null), isTrue);
    await h.conversations.send('which host should I use?', null, continueHistory: true);
    expect(h.conversations.selectedId, 'host-bound');
    final input = _input(h.model.requests.single);
    expect(input['targetSelection'], 'discoverFromUserRequest');
    expect(input['defaultHost'], _hostA.value);
    expect(input.containsKey('conversationHistory'), isTrue);
    expect(h.conversations.current!.host, _hostA);
    expect(h.backend.prepared, isEmpty);
  });

  test('send without explicit continue creates a new conversation and omits old history', () async {
    final h = await _create(initial: [_record('old')]);
    h.conversations.select('old');
    expect(h.conversations.canContinue(_hostA), isTrue);
    await h.conversations.send('new question', _hostA);
    expect(h.conversations.selectedId, isNot('old'));
    expect(h.conversations.records.any((record) => record.id == 'old'), isTrue);
    final input = _input(h.model.requests.single);
    expect(input['goal'], 'new question');
    expect(input.containsKey('conversationHistory'), isFalse);
    expect(h.conversations.current!.entries.map((entry) => entry.text), ['new question', 'A safe answer']);
  });

  test('explicit matching continuation sends bounded plain history in a fresh protocol context', () async {
    final h = await _create(initial: [_record('old')]);
    h.conversations.select('old');
    await h.conversations.send('continue question', _hostA, continueHistory: true);
    expect(h.conversations.selectedId, 'old');
    final request = h.model.requests.single;
    expect(request.messages, hasLength(1));
    final message = request.messages.single;
    expect(message.role, ModelRole.user);
    expect(message.calls, isEmpty);
    expect(message.toolCallId, isNull);
    expect(message.opaque, isNull);
    final input = _input(request);
    expect(input['goal'], 'continue question');
    final history = input['conversationHistory'] as Map;
    expect((history['entries'] as List).map((entry) => entry['text']), ['earlier user old', 'earlier answer old']);
    expect(h.conversations.current!.entries.map((entry) => entry.text), [
      'earlier user old',
      'earlier answer old',
      'continue question',
      'A safe answer',
    ]);
  });

  test('switching models continues legacy history in the same conversation using fresh requests', () async {
    final h = await _create(initial: [_record('old')]);
    h.conversations.select('old');
    h.composer.setGoal('follow up after switching models');
    h.permissionMode = AgentPermissionMode.observe;
    for (final model in ['next-model', 'test-model']) {
      h.profile = _profile(model: model, endpoint: 'https://model.invalid/v1/');
      h.revision++;
      expect(h.conversations.canContinue(_hostA), isTrue);
      expect(h.conversations.selectedId, 'old');
      expect(h.model.requests.length, model == 'next-model' ? 0 : 1);
      expect(h.draft.goal, 'follow up after switching models');
      await h.conversations.send(h.draft.goal, _hostA, continueHistory: true);
      final request = h.model.requests.last;
      expect(request.profile.model, model);
      expect(request.messages, hasLength(1));
      expect(request.messages.single.opaque, isNull);
      expect(request.messages.single.calls, isEmpty);
      final input = _input(request);
      final history = input['conversationHistory'] as Map;
      expect((history['entries'] as List).first['text'], 'earlier user old');
      expect(h.runtime.permissionMode, AgentPermissionMode.observe);
      expect(h.conversations.selectedId, 'old');
      expect(h.backend.prepared, isEmpty);
      h.composer.setGoal('follow up after switching models');
    }
    expect(h.store.records.single.id, 'old');
    expect(h.conversations.current!.entries, hasLength(6));
  });

  test('regenerating after a model switch uses the new model without tools in the same conversation', () async {
    final h = await _create(initial: [_record('old')]);
    h.conversations.select('old');
    h.profile = _profile(model: 'new-answer-model');
    h.revision++;
    expect(await h.conversations.regenerate(_hostA), isTrue);
    expect(h.conversations.selectedId, 'old');
    final request = h.model.requests.single;
    expect(request.profile.model, 'new-answer-model');
    expect(request.tools, isEmpty);
    expect(request.messages.single.opaque, isNull);
    expect(h.conversations.current!.entries.map((entry) => entry.text), ['earlier user old', 'A safe answer']);
    expect(h.backend.prepared, isEmpty);
  });

  for (final change in ['endpoint', 'protocol']) {
    test('explicit continuation refuses $change mismatch without a request or history resend', () async {
      final h = await _create(initial: [_record('old')]);
      h.conversations.select('old');
      h.profile = change == 'endpoint'
          ? _profile(endpoint: 'https://other.invalid/v1')
          : _profile(protocol: ModelProtocol.anthropic);
      h.revision++;
      expect(h.conversations.canContinue(_hostA), isFalse);
      await h.conversations.send('fresh after mismatch', _hostA, continueHistory: true);
      expect(h.model.requests, isEmpty);
      expect(h.conversations.selectedId, 'old');
      h.conversations.newConversation(keepDraft: true);
      await h.conversations.send('fresh after mismatch', _hostA, continueHistory: true);
      expect(h.conversations.selectedId, isNot('old'));
      expect(h.conversations.current!.destination, h.profile.identity);
      expect(h.conversations.current!.host, _hostA);
      expect(h.conversations.current!.routeSignature, h.routes[_hostA]);
      expect(_input(h.model.requests.single).containsKey('conversationHistory'), isFalse);
      final old = h.conversations.records.singleWhere((record) => record.id == 'old');
      expect(old.destination, _profile().identity);
      expect(old.routeSignature, _routeA);
      expect(old.entries.map((entry) => entry.text), ['earlier user old', 'earlier answer old']);
    });
  }

  test('malformed or unknown legacy destinations never qualify for readable history continuation', () async {
    for (final destination in [
      'unstructured-destination',
      jsonEncode(['openai', 'https://model.invalid/v1']),
      jsonEncode(['unknown', 'https://model.invalid/v1', 'model']),
      jsonEncode(['openai', 'https://model.invalid/v1', 42]),
      jsonEncode(['openai', 'https://model.invalid/v1?route=other', 'model']),
      jsonEncode(['openai', 'https://model.invalid/v1/other', 'model']),
    ]) {
      final h = await _create(initial: [_record('old', destination: destination)]);
      h.conversations.select('old');
      expect(h.conversations.canContinue(_hostA), isFalse);
      await h.conversations.send('do not send mismatched history', _hostA, continueHistory: true);
      expect(h.model.requests, isEmpty);
    }
  });

  for (final change in ['host', 'route', 'missing route']) {
    test('$change continues readable history in the same conversation', () async {
      final h = await _create(initial: [_record('old')]);
      h.conversations.select('old');
      final host = change == 'host' ? _hostB : _hostA;
      if (change == 'route') h.routes[_hostA] = _changedRoute;
      if (change == 'missing route') h.routes.remove(_hostA);
      expect(h.conversations.canContinue(host), isTrue);
      await h.conversations.send('continue on the selected host', host, continueHistory: true);
      expect(h.conversations.selectedId, 'old');
      final input = _input(h.model.requests.single);
      expect(input['focusedHost'], host.value);
      expect(input['defaultHost'], _hostA.value);
      expect(input.containsKey('conversationHistory'), isTrue);
      expect(h.conversations.current!.host, _hostA);
      expect(h.conversations.current!.routeSignature, _routeA);
      expect(h.backend.prepared, isEmpty);
    });
  }

  test('oversized discovery keeps the draft without copying a prior conversation into the new record', () async {
    final h = await _create();
    await h.conversations.send('previous host-bound question', _hostA);
    final previous = h.conversations.selectedId;
    h.composer.setGoal('check another server');
    h.backend.hosts = [for (var index = 0; index < 1001; index++) AgentHost(HostId('host-$index'), 'Host $index')];
    await h.conversations.send('check another server', null);
    await h.conversations.flush();
    expect(h.runtime.error, 'scopeLimit');
    expect(h.conversations.selectedId, isNot(previous));
    expect(h.draft.goal, 'check another server');
    expect(h.conversations.current!.entries, isEmpty);
    expect(h.store.records.map((record) => record.id), [previous]);
    expect(h.model.requests, hasLength(1));
  });

  test('disabling tools keeps readable history while exposing no remote tools', () async {
    final h = await _create(initial: [_record('old')]);
    h.conversations.select('old');
    h.profile = _profile(tools: false);
    await h.conversations.send('plain question', _hostA, continueHistory: true);
    expect(h.conversations.selectedId, 'old');
    expect(h.conversations.current!.host, _hostA);
    expect(h.conversations.current!.routeSignature, _routeA);
    final input = _input(h.model.requests.single);
    expect(input['goal'], 'plain question');
    expect(input.containsKey('conversationHistory'), isTrue);
    expect(input.containsKey('authorizedHosts'), isFalse);
    expect(h.model.requests.single.tools, isEmpty);
    expect(h.backend.prepared, isEmpty);
  });

  test('first send rebinds a draft-only conversation to its actual destination, host and route', () async {
    final h = await _create();
    final draftId = h.conversations.selectedId;
    h.composer.setGoal('unsent original goal');
    h.composer.selectHost(_hostA);
    h.conversations.newConversation();
    h.conversations.select(draftId);
    expect(h.conversations.current!.entries, isEmpty);
    h.profile = _profile(model: 'draft-selected-model');
    h.composer.selectHost(_hostB);
    await h.conversations.send('actual first question', _hostB);
    final current = h.conversations.current!;
    expect(current.destination, h.profile.identity);
    expect(current.host, _hostB);
    expect(current.routeSignature, _routeB);
    expect(current.entries.first.text, 'actual first question');
    expect(h.conversations.canContinue(_hostB), isTrue);
    expect(_input(h.model.requests.single).containsKey('conversationHistory'), isFalse);
  });

  test(
    'snapshots retain only shared bounded execution text and status, never raw buffers or command metadata',
    () async {
      final h = await _create();
      await h.conversations.send('safe question', _hostA);
      final output = h.runtime.outputs.create('synthetic-owner', _hostA, h.profile.identity, 0);
      h.runtime.outputs.append(output, false, Uint8List.fromList(utf8.encode('synthetic-private-stdout')));
      h.runtime.outputs.append(output, true, Uint8List.fromList(utf8.encode('synthetic-private-stderr')));
      output.dropped = 1;
      final withheld =
          AgentExecution(
              'withheld',
              'command.execute',
              'synthetic-account@synthetic-address',
              'synthetic-private-command',
              '/synthetic-private-cwd',
            )
            ..state = 'completed'
            ..exitCode = 0
            ..output = output;
      final shared =
          AgentExecution(
              'shared',
              'command.execute',
              'synthetic-account@synthetic-address',
              'synthetic-private-command',
              '/synthetic-private-cwd',
            )
            ..state = 'running'
            ..output = output
            ..sharedText = 'API_KEY=synthetic-shared-secret\nshared readable line';
      h.runtime.projectedTimeline = [...h.runtime.timeline, withheld, shared];
      await h.conversations.flush();
      final record = h.store.records.single;
      final executions = record.entries.where((entry) => entry.kind == ConversationEntryKind.execution).toList();
      expect(executions, hasLength(2));
      expect(executions.first.text, isEmpty);
      expect(executions.first.state, 'completed');
      expect(executions.first.exitCode, 0);
      expect(executions.last.text, 'API_KEY=[redacted]\nshared readable line');
      expect(executions.last.state, 'outcomeUnknown');
      expect(executions.every((entry) => entry.truncated), isTrue);
      final readable = [record.title, for (final entry in record.entries) entry.text].join('\n');
      for (final private in [
        'synthetic-private-stdout',
        'synthetic-private-stderr',
        'synthetic-account',
        'synthetic-address',
        'synthetic-private-command',
        'synthetic-private-cwd',
        'synthetic-shared-secret',
      ]) {
        expect(readable, isNot(contains(private)));
      }
      expect(h.runtime.outputs.count, 1);
    },
  );

  test('tool snapshots preserve safe metadata and stopped states without tool arguments or result data', () async {
    final h = await _create();
    await h.conversations.send('safe question', _hostA);
    h.runtime.projectedTimeline = [
      ...h.runtime.timeline,
      AgentExecution('list-operation', 'agent.hosts', '', '', '')..state = 'completed',
      AgentExecution('read-operation', 'agent.output', '', '', '')..state = 'running',
      AgentExecution('cancel-operation', 'agent.execute', '', '', '')..state = 'cancelled',
    ];
    await h.conversations.flush();
    final entries = h.store.records.single.entries
        .where((entry) => entry.kind == ConversationEntryKind.execution)
        .toList();
    expect(entries.map((entry) => entry.capability), ['agent.hosts', 'agent.output', 'agent.execute']);
    expect(entries.map((entry) => entry.state), ['completed', 'interrupted', 'cancelled']);
    expect(entries.every((entry) => entry.text.isEmpty && entry.exitCode == null), isTrue);
    expect(entries.map((entry) => entry.executionId), ['list-operation', 'read-operation', 'cancel-operation']);
    expect(h.backend.prepared, isEmpty);
    expect(h.model.requests, hasLength(1));
  });

  test('save failure retains completed in-memory history and retries without replaying the model', () async {
    final store = _MemoryStore()..failSave = true;
    final h = await _create(store: store);
    await h.conversations.send('retain this question', _hostA);
    await h.conversations.saved;
    final id = h.conversations.selectedId;
    expect(h.conversations.saveFailed, isTrue);
    expect(h.conversations.current!.entries.map((entry) => entry.text), ['retain this question', 'A safe answer']);
    expect(store.records, isEmpty);
    h.composer.setGoal('unsent retry draft');
    store.failSave = false;
    await h.conversations.retrySave();
    expect(h.conversations.saveFailed, isFalse);
    expect(store.records.single.id, id);
    expect(store.records.single.entries.map((entry) => entry.text), ['retain this question', 'A safe answer']);
    expect(h.draft.goal, 'unsent retry draft');
    expect(h.model.requests, hasLength(1));
  });

  test('older pending save success cannot clear a newer snapshot validation failure', () async {
    final h = await _create();
    await h.conversations.send('accepted question', _hostA);
    final accepted = h.conversations.current!.entries;
    final saveGate = Completer<void>();
    h.store.saveGate = saveGate;
    h.store.saveStarted = Completer<void>();
    addTearDown(() {
      if (!saveGate.isCompleted) saveGate.complete();
    });
    final olderSave = h.conversations.retrySave();
    await h.store.saveStarted!.future.timeout(const Duration(seconds: 2));
    h.runtime.projectedTimeline = [AgentChatEntry('user', 'x' * maxConversationTextBytes)];
    final validationFailed = Completer<void>();
    void observeValidation() {
      if (h.conversations.saveFailed && !validationFailed.isCompleted) validationFailed.complete();
    }

    h.conversations.addListener(observeValidation);
    final newerFlush = h.conversations.flush().then<Object?>((_) => null, onError: (Object error) => error);
    await validationFailed.future.timeout(const Duration(seconds: 2));
    h.conversations.removeListener(observeValidation);
    await h.conversations.retrySave();
    expect(h.conversations.saveFailed, isTrue);
    expect(h.conversations.current!.entries.single.text.length, maxConversationTextBytes);
    h.store.saveGate!.complete();
    await olderSave;
    expect(await newerFlush, isA<StateError>());
    expect(h.conversations.saveFailed, isTrue);
    expect(h.store.records.single.entries.map((entry) => entry.text), accepted.map((entry) => entry.text));
    h.runtime.projectedTimeline = null;
    await h.conversations.flush();
    expect(h.conversations.saveFailed, isFalse);
    expect(h.model.requests, hasLength(1));
  });

  test('viewing, switching and flushing unchanged history preserves update times and retention', () async {
    final olderTime = DateTime.now().toUtc().subtract(const Duration(days: 29));
    final newerTime = olderTime.add(const Duration(days: 1));
    AgentConversationRecord at(String id, DateTime time) {
      final source = _record(id);
      return AgentConversationRecord(
        id: source.id,
        title: source.title,
        createdAt: time,
        updatedAt: time,
        destination: source.destination,
        host: source.host,
        routeSignature: source.routeSignature,
        entries: source.entries,
      );
    }

    final h = await _create(initial: [at('older', olderTime), at('newer', newerTime)]);
    h.conversations.select('older');
    await h.conversations.flush();
    expect(h.conversations.current!.updatedAt, olderTime);
    h.conversations.select('newer');
    await h.conversations.flush();
    expect(h.conversations.current!.updatedAt, newerTime);
    h.conversations.newConversation();
    await h.conversations.saved;
    expect(h.conversations.records.map((record) => record.id), ['newer', 'older']);
    expect(h.store.records.singleWhere((record) => record.id == 'older').updatedAt, olderTime);
    expect(h.store.records.singleWhere((record) => record.id == 'newer').updatedAt, newerTime);
    final afterRetention = boundedConversationRecords(h.store.records, now: olderTime.add(const Duration(days: 31)));
    expect(afterRetention.map((record) => record.id), ['newer']);
    expect(h.model.requests, isEmpty);
  });

  test('load retry merges unsaved memory instead of replacing it with disk history', () async {
    final store = _MemoryStore([_record('disk')])..failLoad = true;
    final h = await _create(store: store);
    expect(h.conversations.loadFailed, isTrue);
    await h.conversations.send('new in-memory question', _hostB);
    final selected = h.conversations.selectedId;
    expect(h.conversations.current!.entries.first.text, 'new in-memory question');
    expect(store.attempts, 0);
    await expectLater(h.conversations.flush(), throwsStateError);
    store.failLoad = false;
    await h.conversations.reload();
    expect(h.conversations.loadFailed, isFalse);
    expect(h.conversations.selectedId, selected);
    expect(h.conversations.records.map((record) => record.id).toSet(), {'disk', selected});
    expect(h.conversations.current!.entries.first.text, 'new in-memory question');
    await h.conversations.retrySave();
    expect(store.records.map((record) => record.id).toSet(), {'disk', selected});
    expect(h.model.requests, hasLength(1));
  });

  test('flush and restart never persist unsent drafts or draft-only conversations', () async {
    final h = await _create();
    await h.conversations.send('sent question', _hostA);
    final sentId = h.conversations.selectedId;
    h.composer.setGoal('unsent follow-up must remain local');
    h.composer.selectHost(_hostB);
    h.conversations.newConversation();
    h.composer.setGoal('draft-only question must remain local');
    h.conversations.newConversation();
    await h.conversations.flush();
    expect(h.store.records, hasLength(1));
    expect(h.store.records.single.id, sentId);
    expect(h.store.records.single.entries.map((entry) => entry.text), ['sent question', 'A safe answer']);
    final reopened = await _create(initial: h.store.records);
    expect(reopened.draft.goal, isEmpty);
    expect(reopened.conversations.records, hasLength(1));
    expect(reopened.model.requests, isEmpty);
  });

  test('continuing at entry capacity prunes whole old turns and retains the latest turn', () async {
    final h = await _create(
      initial: [
        _record(
          'full',
          entries: [
            for (var i = 0; i < maxConversationEntries ~/ 2; i++) ...[
              ConversationEntry(kind: ConversationEntryKind.user, text: 'old user $i'),
              ConversationEntry(kind: ConversationEntryKind.assistant, text: 'old answer $i'),
            ],
          ],
        ),
      ],
    );
    h.conversations.select('full');
    await h.conversations.send('latest user text', _hostA, continueHistory: true);
    final retained = h.conversations.current!;
    expect(retained.id, 'full');
    expect(retained.historyTruncated, isTrue);
    expect(retained.entries, hasLength(maxConversationEntries));
    expect(retained.entries.first.kind, ConversationEntryKind.user);
    expect(retained.entries.first.text, 'old user 1');
    expect(retained.entries[retained.entries.length - 2].text, 'latest user text');
    expect(retained.entries.last.text, 'A safe answer');
    expect(h.store.records.single.historyTruncated, isTrue);
    expect(h.store.records.single.entries, hasLength(maxConversationEntries));
    final history = _input(h.model.requests.single)['conversationHistory'] as Map;
    expect((history['entries'] as List).length, lessThanOrEqualTo(32));
    expect(history['truncated'], isTrue);
  });

  test('regenerate replaces only the answer without tools, approvals or private output', () async {
    final h = await _create(
      initial: [
        _record(
          'regen',
          entries: const [
            ConversationEntry(kind: ConversationEntryKind.user, text: 'explain the load'),
            ConversationEntry(
              kind: ConversationEntryKind.execution,
              capability: 'agent.diagnose',
              state: 'completed',
              exitCode: 0,
              text: 'Only shared output',
              executionId: '0123456789abcdef0123456789abcdef',
            ),
            ConversationEntry(kind: ConversationEntryKind.assistant, text: 'old answer'),
          ],
        ),
      ],
    );
    h.conversations.select('regen');
    expect(h.conversations.canRegenerate, isTrue);
    expect(await h.conversations.regenerate(_hostA), isTrue);
    final request = h.model.requests.single;
    expect(request.tools, isEmpty);
    final input = _input(request);
    expect(input['responseMode'], 'answerOnly');
    expect((input['conversationHistory'] as Map)['entries'], isNotEmpty);
    expect(h.backend.prepared, isEmpty);
    final entries = h.conversations.current!.entries;
    expect(entries.map((entry) => entry.text), ['explain the load', 'Only shared output', 'A safe answer']);
    expect(entries[1].executionId, '0123456789abcdef0123456789abcdef');
    await h.conversations.flush();
    expect(h.store.records.single.entries[1].executionId, '0123456789abcdef0123456789abcdef');
  });

  test('withdraw restores the last question and keeps executed records out of the next context', () async {
    final h = await _create(
      initial: [
        _record(
          'turn',
          entries: const [
            ConversationEntry(kind: ConversationEntryKind.user, text: 'check disk'),
            ConversationEntry(
              kind: ConversationEntryKind.execution,
              capability: 'agent.execute',
              state: 'completed',
              text: 'shared disk output',
              executionId: '0123456789abcdef0123456789abcdef',
            ),
            ConversationEntry(kind: ConversationEntryKind.assistant, text: 'disk answer'),
          ],
        ),
      ],
    );
    h.conversations.select('turn');
    expect(h.conversations.canWithdraw, isTrue);
    expect(h.conversations.withdrawLastTurn(), isTrue);
    expect(h.draft.goal, 'check disk');
    expect(h.conversations.canWithdraw, isFalse);
    final retracted = h.conversations.current!.entries;
    expect(retracted.every((entry) => entry.retracted), isTrue);
    expect(h.runtime.timeline.whereType<AgentExecution>().single.retracted, isTrue);
    expect(h.runtime.timeline.whereType<AgentExecution>().single.sharedText, 'shared disk output');
    h.composer.setGoal('follow up after undo');
    await h.conversations.send('follow up after undo', _hostA, continueHistory: true);
    final input = _input(h.model.requests.single);
    expect((input['conversationHistory'] as Map)['entries'], isEmpty);
    expect(h.backend.prepared, isEmpty);
    final answer = h.conversations.current!.entries.last;
    expect(answer.text, 'A safe answer');
    expect(h.conversations.current!.entries.any((entry) => entry.text == 'disk answer'), isTrue);
  });

  test('deleting an inactive conversation preserves current draft and deleting current clears it', () async {
    final h = await _create(
      initial: [
        _record('a'),
        _record('b', host: _hostB),
      ],
    );
    h.conversations.select('a');
    h.composer.setGoal('keep while removing B');
    await h.conversations.delete('b');
    expect(h.conversations.selectedId, 'a');
    expect(h.draft.goal, 'keep while removing B');
    expect(h.conversations.records.single.id, 'a');
    await h.conversations.delete('a');
    expect(h.conversations.selectedId, isNot('a'));
    expect(h.conversations.records, isEmpty);
    expect(h.draft.goal, isEmpty);
    expect(h.draft.host, isNull);
    expect(h.runtime.timeline, isEmpty);
    expect(h.store.records, isEmpty);
    expect(h.model.requests, isEmpty);
  });
}

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

ModelProfile _profile({String model = 'test-model', bool tools = true}) =>
    ModelProfile(protocol: ModelProtocol.openai, endpoint: 'https://model.invalid/v1', model: model, tools: tools);

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
  List<AgentHost> get hosts => const [AgentHost(_hostA, 'Host A'), AgentHost(_hostB, 'Host B')];

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
  });

  List<AgentTimelineEntry>? projectedTimeline;

  @override
  List<AgentTimelineEntry> get timeline => projectedTimeline ?? super.timeline;
}

class _Harness {
  _Harness({List<AgentConversationRecord> initial = const [], _MemoryStore? store, _Script? script})
    : store = store ?? _MemoryStore(initial),
      model = _Model(script) {
    runtime = _Runtime(
      model: model,
      backend: backend,
      journal: _Journal(),
      dispatcher: CapabilityDispatcher([]),
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
    );
  }

  final _MemoryStore store;
  final _Model model;
  final backend = _Backend();
  final routes = <HostId, String>{_hostA: _routeA, _hostB: _routeB};
  ModelProfile profile = _profile();
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
}) async {
  final harness = _Harness(initial: initial, store: store, script: script);
  addTearDown(harness.close);
  await harness.conversations.ready;
  return harness;
}

Map<String, dynamic> _input(ModelRequest request) => jsonDecode(request.messages.single.text) as Map<String, dynamic>;

void main() {
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
    expect(h.runtime.dataRequest, isNull);
    expect(h.runtime.busy, isFalse);
    expect(h.model.requests, isEmpty);
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

  for (final change in ['destination', 'host', 'route', 'missing route']) {
    test('explicit continuation starts fresh after $change mismatch', () async {
      final h = await _create(initial: [_record('old')]);
      h.conversations.select('old');
      var selectedHost = _hostA;
      switch (change) {
        case 'destination':
          h.profile = _profile(model: 'different-model');
          h.revision++;
        case 'host':
          selectedHost = _hostB;
        case 'route':
          h.routes[_hostA] = _changedRoute;
        case 'missing route':
          h.routes.remove(_hostA);
      }
      expect(h.conversations.canContinue(selectedHost), isFalse);
      await h.conversations.send('fresh after mismatch', selectedHost, continueHistory: true);
      expect(h.conversations.selectedId, isNot('old'));
      expect(h.conversations.current!.destination, h.profile.identity);
      expect(h.conversations.current!.host, selectedHost);
      expect(h.conversations.current!.routeSignature, h.routes[selectedHost]);
      expect(_input(h.model.requests.single).containsKey('conversationHistory'), isFalse);
      final old = h.conversations.records.singleWhere((record) => record.id == 'old');
      expect(old.destination, _profile().identity);
      expect(old.routeSignature, _routeA);
      expect(old.entries.map((entry) => entry.text), ['earlier user old', 'earlier answer old']);
    });
  }

  test('tools disabled removes host binding and prevents host-derived history continuation', () async {
    final h = await _create(initial: [_record('old')]);
    h.conversations.select('old');
    h.profile = _profile(tools: false);
    await h.conversations.send('plain question', _hostA, continueHistory: true);
    expect(h.conversations.selectedId, isNot('old'));
    expect(h.conversations.current!.host, isNull);
    expect(h.conversations.current!.routeSignature, isNull);
    expect(h.model.requests.single.messages.single.text, 'plain question');
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

  test('snapshots retain only user-shared execution text and status, never raw buffers or command metadata', () async {
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

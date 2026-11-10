import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/features/ai/application/output_store.dart';
import 'package:sshairy/features/ai/application/runtime.dart';
import 'package:sshairy/features/ai/domain/agent.dart';
import 'package:sshairy/features/ai/domain/model.dart';
import 'package:sshairy/features/capabilities/api.dart';
import 'package:sshairy/foundation/cancellation.dart';
import 'package:sshairy/foundation/ids.dart';

const _host = HostId('host-a');
const _other = HostId('host-b');
const _privateOutput = 'private-output-must-not-reach-model';
const _systemOutput =
    '@@system\nLinux\n@@kernel\n6.8.0\n@@architecture\nx86_64\n'
    '@@load\n0.10 0.20 0.30 1/40 123\n@@uptime\n123.5 20.0\n'
    '@@memory\nMemTotal: 1024 kB\nMemAvailable: 512 kB\nSwapTotal: 64 kB\nSwapFree: 32 kB\n';

typedef _Script = Stream<ModelEvent> Function(ModelRequest request, CancellationToken cancel, int index);

class _Model implements ModelProvider {
  _Model(this.script);
  final _Script script;
  final requests = <ModelRequest>[];
  final cancellations = <CancellationToken>[];
  var closes = 0;

  @override
  Stream<ModelEvent> stream(ModelRequest request, CancellationToken cancel) {
    final index = requests.length;
    requests.add(request);
    cancellations.add(cancel);
    return script(request, cancel, index);
  }

  @override
  void close() => closes++;
}

class _Target implements AgentTarget {
  @override
  final hostId = _host;
  @override
  String identity = 'transport-a/config-1';
  @override
  String get display => 'tester@example.invalid:22';
  @override
  bool current = true;
  bool posix = true, block = false;
  int? result = 0;
  String stdout = _privateOutput, stderr = '';
  var probes = 0, releases = 0;
  final commands = <String>[];
  final tokens = <CancellationToken>[];
  final deadlines = <Duration>[];
  void Function()? beforeExecute;

  @override
  Future<bool> supportsPosix(CancellationToken cancel) async {
    probes++;
    return posix;
  }

  @override
  Future<int?> execute(
    String command,
    void Function(bool, Uint8List) output, {
    required Duration timeout,
    required CancellationToken cancel,
  }) async {
    beforeExecute?.call();
    commands.add(command);
    tokens.add(cancel);
    deadlines.add(timeout);
    output(false, Uint8List.fromList(utf8.encode(stdout)));
    if (stderr.isNotEmpty) output(true, Uint8List.fromList(utf8.encode(stderr)));
    if (block) {
      await cancel.whenCancelled;
      throw const AgentFailure('cancelled');
    }
    return result;
  }

  @override
  void release() => releases++;
}

class _Backend implements AgentBackend {
  final target = _Target();
  final prepared = <HostId>[];
  Future<AgentTarget>? pendingPreparation;
  @override
  List<AgentHost> hosts = const [AgentHost(_host, 'selected host'), AgentHost(_other, 'unselected host')];

  @override
  Future<AgentTarget> prepare(HostId host, CancellationToken cancel) async {
    prepared.add(host);
    if (host != _host) throw const AgentFailure('wrongTarget');
    return await (pendingPreparation ?? Future.value(target));
  }
}

class _Journal implements OperationJournal {
  final records = <OperationRecord>[];
  var loads = 0;
  bool failIntent = false;

  @override
  Future<List<OperationRecord>> load() async {
    loads++;
    return List.unmodifiable(records);
  }

  @override
  Future<void> record(OperationRecord record) async {
    if (failIntent && record.state == OperationState.intent) throw StateError('simulated disk failure');
    records.add(record);
  }

  @override
  Future<void> get saved async {}
}

Map<String, Object?> _schema(Map<String, Object?> properties, List<String> required) => {
  'type': 'object',
  'properties': properties,
  'required': required,
  'additionalProperties': false,
};

class _Harness {
  _Harness(_Script script, {bool tools = true, OutputStore? outputs}) : model = _Model(script) {
    profile = ModelProfile(
      protocol: ModelProtocol.openai,
      endpoint: 'https://model.example.invalid/v1',
      model: 'test-model',
      tools: tools,
    );
    final dispatcher = CapabilityDispatcher([
      FunctionCapability(
        'agent.hosts',
        Effect.query,
        (_, _) async => runtime.listHosts(),
        agentExposed: true,
        inputSchema: _schema({}, []),
      ),
      FunctionCapability(
        'agent.diagnose',
        Effect.connect,
        (args, context) => runtime.diagnose(args.raw, context),
        agentExposed: true,
        inputSchema: _schema(
          {
            'hostId': {'type': 'string', 'minLength': 1, 'maxLength': 128},
            'template': {
              'type': 'string',
              'enum': ['systemSummary', 'storageCapacity'],
            },
          },
          ['hostId', 'template'],
        ),
      ),
      FunctionCapability(
        'agent.execute',
        Effect.remoteWrite,
        (args, context) => runtime.execute(args.raw, context),
        agentExposed: true,
        inputSchema: _schema(
          {
            'hostId': {'type': 'string', 'minLength': 1, 'maxLength': 128},
            'cwd': {'type': 'string', 'minLength': 1, 'maxLength': 2048},
            'command': {'type': 'string', 'minLength': 1, 'maxLength': 2048},
            'timeoutSeconds': {'type': 'integer', 'minimum': 1, 'maximum': 300},
          },
          ['hostId', 'cwd', 'command'],
        ),
      ),
      FunctionCapability(
        'agent.output',
        Effect.query,
        (args, _) async => runtime.readOutput(args.raw),
        agentExposed: true,
        inputSchema: _schema(
          {
            'hostId': {'type': 'string', 'minLength': 1, 'maxLength': 128},
            'handle': {'type': 'string', 'minLength': 1, 'maxLength': 128},
          },
          ['hostId', 'handle'],
        ),
      ),
    ]);
    runtime = AgentRuntime(
      model: model,
      backend: backend,
      journal: journal,
      dispatcher: dispatcher,
      outputs: outputs,
      configuration: () => (enabled: enabled, profile: profile, revision: revision),
    );
  }

  final _Model model;
  final backend = _Backend();
  final journal = _Journal();
  late final AgentRuntime runtime;
  late ModelProfile profile;
  bool enabled = true;
  int revision = 0;

  Future<void> start([AgentMode mode = AgentMode.execute]) =>
      runtime.start('check the selected host', AgentScope(mode: mode, hosts: mode == AgentMode.explain ? [] : [_host]));

  Future<void> close() async {
    runtime.stop();
    await runtime.settled.timeout(const Duration(seconds: 2));
    runtime.dispose();
  }
}

ModelMessage _call(String name, Map<String, Object?> args, [String id = 'call-a']) =>
    ModelMessage(ModelRole.assistant, calls: [ModelCall(id, name, args)]);

Stream<ModelEvent> _oneCall(ModelMessage call, int index) async* {
  if (index == 0) {
    yield ModelMessageComplete(call);
  } else {
    yield const ModelTextDelta('done');
    yield ModelMessageComplete(ModelMessage(ModelRole.assistant, text: 'done'));
  }
}

Map<String, Object?> _command({String host = 'host-a', String command = 'printf result', String cwd = '/tmp'}) => {
  'hostId': host,
  'cwd': cwd,
  'command': command,
};

Future<void> _until(bool Function() predicate) async {
  for (var i = 0; i < 1000; i++) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  fail('Expected runtime state was not reached');
}

List<ModelMessage> _results(ModelRequest request) => request.messages.where((m) => m.role == ModelRole.tool).toList();
Map<String, Object?> _result(ModelRequest request, [int index = 0]) =>
    (jsonDecode(_results(request)[index].text) as Map).cast<String, Object?>();
String _requestText(ModelRequest request) => jsonEncode([
  request.system,
  for (final message in request.messages) [message.text, for (final call in message.calls) call.arguments],
]);

void main() {
  test('fixed diagnosis flows through dispatch and returns paired structured evidence', () async {
    final call = _call('diagnostics_collect', {'hostId': 'host-a', 'template': 'systemSummary'});
    final h = _Harness((_, _, index) => _oneCall(call, index));
    addTearDown(h.close);
    h.backend.target.stdout = _systemOutput;

    await h.start(AgentMode.diagnose);

    expect(h.runtime.phase, AgentPhase.completed);
    expect(h.model.requests, hasLength(2));
    expect(h.model.requests.first.tools.map((tool) => tool.name), contains('diagnostics_collect'));
    expect(h.model.requests.first.tools.map((tool) => tool.name), isNot(contains('command_execute')));
    expect(h.backend.prepared, [_host]);
    expect(h.backend.target.commands, hasLength(1));
    expect(h.backend.target.probes, 1);
    expect(h.backend.target.releases, 1);
    expect(h.journal.records, isEmpty);
    final result = _result(h.model.requests.last);
    expect(_results(h.model.requests.last).single.toolCallId, 'call-a');
    expect(_results(h.model.requests.last).single.isError, isFalse);
    expect(result['template'], 'systemSummary');
    expect(result['version'], 1);
    expect(result['exitCode'], 0);
    expect(result['data'], containsPair('system', 'Linux'));
    expect(result['data'], containsPair('memory', containsPair('availableKib', 512)));
    expect(result['handle'], isA<String>());
    expect(h.runtime.messages.last.text, 'done');
  });

  test('large storage evidence remains valid structured JSON and explicitly truncates entries', () async {
    final call = _call('diagnostics_collect', {'hostId': 'host-a', 'template': 'storageCapacity'});
    final h = _Harness((_, _, index) => _oneCall(call, index));
    addTearDown(h.close);
    final longPath = List.filled(100, 'a').join();
    h.backend.target.stdout =
        '@@storage\nFilesystem Type 1024-blocks Used Available Capacity Mounted on\n'
        '${[for (var i = 0; i < 90; i++) '/dev/disk$i ext4 1000 400 600 40% /mount-$i-$longPath'].join('\n')}\n';
    await h.start(AgentMode.diagnose);
    expect(h.runtime.phase, AgentPhase.completed);
    final result = _result(h.model.requests.last);
    expect(result['truncated'], isTrue);
    expect(utf8.encode(_results(h.model.requests.last).single.text).length, lessThanOrEqualTo(8192));
    final data = (result['data'] as Map).cast<String, Object?>();
    expect(data['filesystems'], isNotEmpty);
    expect((data['filesystems'] as List).length, lessThan(90));
    expect(h.runtime.executions.single.state, 'completed');
  });

  test('arbitrary execution needs approval and durable intent before a single command', () async {
    final source = _command(cwd: "/tmp/owner's directory", command: 'printf original');
    final call = _call('command_execute', source);
    final h = _Harness((_, _, index) => _oneCall(call, index));
    addTearDown(h.close);
    h.backend.target.beforeExecute = () {
      expect(h.journal.records.map((record) => record.state), [OperationState.intent]);
    };
    final turn = h.start();
    await _until(() => h.runtime.approval != null);
    expect(h.backend.target.commands, isEmpty);
    expect(h.journal.records, isEmpty);
    expect(h.runtime.approval!.command, 'printf original');
    // The caller's mutable source is no longer the model call or its bound approval.
    source['command'] = 'printf replaced';
    h.runtime.approve(true, expected: h.runtime.approval!);
    await _until(() => h.runtime.dataRequest != null);
    expect(h.backend.target.commands, hasLength(1));
    expect(h.backend.target.commands.single, contains('printf original'));
    expect(h.backend.target.commands.single, isNot(contains('printf replaced')));
    expect(h.backend.target.commands.single, startsWith('sh -c '));
    expect(h.backend.target.commands.single, contains(' || exit\nprintf original'));
    expect(h.backend.target.commands.single, isNot(contains("cd -- '/tmp/owner's directory'")));
    expect(h.backend.target.deadlines.single, const Duration(seconds: 60));
    h.runtime.shareOutput(null, expected: h.runtime.dataRequest!);
    await turn;
    expect(h.journal.loads, 1);
    expect(h.journal.records.map((record) => record.state), [OperationState.intent, OperationState.completed]);
    expect(h.journal.records.first.id, h.journal.records.last.id);
    expect(h.backend.target.releases, 1);
  });

  test('an integer-valued JSON number becomes the exact execution timeout', () async {
    final args = (jsonDecode('{"hostId":"host-a","cwd":"/tmp","command":"printf result","timeoutSeconds":1.0}') as Map)
        .cast<String, Object?>();
    expect(args['timeoutSeconds'], isA<double>());
    final call = _call('command_execute', args);
    final h = _Harness((_, _, index) => _oneCall(call, index));
    addTearDown(h.close);
    final turn = h.start();
    await _until(() => h.runtime.approval != null);
    h.runtime.approve(true, expected: h.runtime.approval!);
    await _until(() => h.runtime.dataRequest != null);
    expect(h.backend.target.commands, hasLength(1));
    expect(h.backend.target.deadlines.single, const Duration(seconds: 1));
    h.runtime.shareOutput(null, expected: h.runtime.dataRequest!);
    await turn;
    expect(h.runtime.phase, AgentPhase.completed);
    expect(h.journal.records.last.state, OperationState.completed);
    expect(_result(h.model.requests.last), containsPair('exitCode', 0));
  });

  test('callbacks from a prior turn cannot approve or share a newer request', () async {
    final call = _call('command_execute', _command());
    final h = _Harness((_, _, index) => _oneCall(call, index % 2));
    addTearDown(h.close);
    final first = h.start();
    await _until(() => h.runtime.approval != null);
    final oldApproval = h.runtime.approval!;
    h.runtime.approve(true, expected: oldApproval);
    await _until(() => h.runtime.dataRequest != null);
    final oldData = h.runtime.dataRequest!;
    h.runtime.shareOutput(null, expected: oldData);
    await first;

    final second = h.start();
    await _until(() => h.runtime.approval != null);
    final currentApproval = h.runtime.approval!;
    expect(identical(currentApproval, oldApproval), isFalse);
    h.runtime.approve(true, expected: oldApproval);
    await pumpEventQueue();
    expect(h.backend.target.commands, hasLength(1));
    expect(identical(h.runtime.approval, currentApproval), isTrue);
    h.runtime.approve(true, expected: currentApproval);
    await _until(() => h.runtime.dataRequest != null);
    final currentData = h.runtime.dataRequest!;
    h.runtime.shareOutput('stale data', expected: oldData);
    await pumpEventQueue();
    expect(identical(h.runtime.dataRequest, currentData), isTrue);
    expect(h.model.requests, hasLength(3));
    h.runtime.shareOutput('current selection', expected: currentData);
    await second;
    expect(h.backend.target.commands, hasLength(2));
    expect(_requestText(h.model.requests.last), contains('current selection'));
    expect(_requestText(h.model.requests.last), isNot(contains('stale data')));
  });

  test('denial returns a paired error without executing or writing an intent', () async {
    final call = _call('command_execute', _command());
    final h = _Harness((_, _, index) => _oneCall(call, index));
    addTearDown(h.close);
    final turn = h.start();
    await _until(() => h.runtime.approval != null);
    h.runtime.approve(false, expected: h.runtime.approval!);
    await turn;
    expect(h.runtime.phase, AgentPhase.completed);
    expect(h.backend.target.commands, isEmpty);
    expect(h.journal.records, isEmpty);
    expect(h.backend.target.releases, 1);
    expect(_results(h.model.requests.last).single.toolCallId, 'call-a');
    expect(_results(h.model.requests.last).single.isError, isTrue);
    expect(_result(h.model.requests.last), {'error': 'denied'});
  });

  test('reordering arguments cannot ask again for an action already denied in the turn', () async {
    final first = _command();
    final reordered = <String, Object?>{'command': first['command'], 'cwd': first['cwd'], 'hostId': first['hostId']};
    expect(first.keys.toList(), isNot(reordered.keys.toList()));
    final h = _Harness((_, _, index) async* {
      if (index == 0) {
        yield ModelMessageComplete(_call('command_execute', first, 'first-action'));
      } else if (index == 1) {
        yield ModelMessageComplete(_call('command_execute', reordered, 'same-action'));
      } else {
        yield ModelMessageComplete(ModelMessage(ModelRole.assistant, text: 'refusal respected'));
      }
    });
    addTearDown(h.close);
    var approvalCount = 0;
    AgentApproval? seen;
    h.runtime.addListener(() {
      final pending = h.runtime.approval;
      if (pending != null && !identical(seen, pending)) {
        seen = pending;
        approvalCount++;
        h.runtime.approve(false, expected: pending);
      }
    });
    await h.start();
    expect(h.runtime.phase, AgentPhase.completed);
    expect(approvalCount, 1);
    expect(h.model.requests, hasLength(3));
    expect(h.backend.prepared, [_host]);
    expect(h.backend.target.commands, isEmpty);
    expect(h.journal.records, isEmpty);
    expect(_results(h.model.requests.last).map((result) => result.toolCallId), ['first-action', 'same-action']);
    expect(_result(h.model.requests.last, 0), {'error': 'denied'});
    expect(_result(h.model.requests.last, 1), {'error': 'denied'});
  });

  test('withheld output never enters continuation or output.read', () async {
    final call = _call('command_execute', _command());
    final h = _Harness((request, _, index) async* {
      if (index == 0) {
        yield ModelMessageComplete(call);
      } else if (index == 1) {
        final handle = _result(request)['handle'] as String;
        yield ModelMessageComplete(_call('output_read', {'hostId': 'host-a', 'handle': handle}, 'read-a'));
      } else {
        yield ModelMessageComplete(ModelMessage(ModelRole.assistant, text: 'output was withheld'));
      }
    });
    addTearDown(h.close);
    final turn = h.start();
    await _until(() => h.runtime.approval != null);
    h.runtime.approve(true, expected: h.runtime.approval!);
    await _until(() => h.runtime.dataRequest != null);
    expect(h.runtime.dataRequest!.suggested, contains(_privateOutput));
    h.runtime.shareOutput(null, expected: h.runtime.dataRequest!);
    await turn;
    expect(h.model.requests, hasLength(3));
    expect(h.model.requests.every((request) => !_requestText(request).contains(_privateOutput)), isTrue);
    expect(_result(h.model.requests.last), containsPair('output', 'withheld'));
    expect(_result(h.model.requests.last, 1), {'error': 'unavailable'});
    expect(_results(h.model.requests.last).last.toolCallId, 'read-a');
  });

  test('only the edited projection is sent and cross-host evidence reads fail', () async {
    final call = _call('command_execute', _command());
    final h = _Harness((request, _, index) async* {
      if (index == 0) {
        yield ModelMessageComplete(call);
      } else if (index == 1) {
        final handle = _result(request)['handle'] as String;
        yield ModelMessageComplete(
          ModelMessage(
            ModelRole.assistant,
            calls: [
              ModelCall('read-valid', 'output_read', {'hostId': 'host-a', 'handle': handle}),
              ModelCall('read-host', 'output_read', {'hostId': 'host-b', 'handle': handle}),
              ModelCall('read-fake', 'output_read', {'hostId': 'host-a', 'handle': 'fabricated'}),
            ],
          ),
        );
      } else {
        yield ModelMessageComplete(ModelMessage(ModelRole.assistant, text: 'done'));
      }
    });
    addTearDown(h.close);
    final turn = h.start();
    await _until(() => h.runtime.approval != null);
    h.runtime.approve(true, expected: h.runtime.approval!);
    await _until(() => h.runtime.dataRequest != null);
    h.runtime.shareOutput('user selected summary', expected: h.runtime.dataRequest!);
    await turn;
    expect(h.model.requests, hasLength(3));
    expect(_requestText(h.model.requests.last), contains('user selected summary'));
    expect(_requestText(h.model.requests.last), isNot(contains(_privateOutput)));
    expect(_result(h.model.requests.last), containsPair('text', 'user selected summary'));
    expect(_result(h.model.requests.last, 1), containsPair('text', 'user selected summary'));
    expect(_result(h.model.requests.last, 2), {'error': 'outsideScope'});
    expect(_result(h.model.requests.last, 3), {'error': 'unavailable'});
  });

  for (final change in ['lost', 'identity']) {
    test('$change invalidates a prepared approval before execution', () async {
      final call = _call('command_execute', _command());
      final h = _Harness((_, _, index) => _oneCall(call, index));
      addTearDown(h.close);
      final turn = h.start();
      await _until(() => h.runtime.approval != null);
      if (change == 'lost') {
        h.backend.target.current = false;
      } else {
        h.backend.target.identity = 'transport-b/config-2';
      }
      h.runtime.approve(true, expected: h.runtime.approval!);
      await turn;
      expect(h.backend.target.commands, isEmpty);
      expect(h.journal.records, isEmpty);
      if (change == 'lost') {
        expect(h.model.requests, hasLength(1));
        expect(h.runtime.phase, isIn([AgentPhase.failed, AgentPhase.cancelled]));
      } else {
        expect(_result(h.model.requests.last), {'error': 'scopeChanged'});
      }
      expect(h.backend.target.releases, 1);
    });
  }

  test('a target prepared after Stop cannot attach itself to a newer turn', () async {
    final call = _call('command_execute', _command());
    final h = _Harness((_, _, index) => _oneCall(call, index));
    addTearDown(h.close);
    final pending = Completer<AgentTarget>();
    h.backend.pendingPreparation = pending.future;
    final oldTurn = h.start();
    await _until(() => h.backend.prepared.isNotEmpty);
    h.runtime.stop();
    await oldTurn;
    expect(h.runtime.phase, AgentPhase.cancelled);

    final newTurn = h.start(AgentMode.explain);
    await newTurn;
    expect(h.runtime.phase, AgentPhase.completed);
    expect(h.model.requests, hasLength(2));
    pending.complete(h.backend.target);
    await pumpEventQueue();
    expect(h.backend.target.releases, 1);
    expect(h.backend.target.commands, isEmpty);
    expect(h.runtime.approval, isNull);
    expect(h.runtime.phase, AgentPhase.completed);
    expect(h.model.requests, hasLength(2));
    expect(h.journal.records, isEmpty);
  });

  test('destination revision changes discard the approval and do not continue the model', () async {
    final call = _call('command_execute', _command());
    final h = _Harness((_, _, index) => _oneCall(call, index));
    addTearDown(h.close);
    final turn = h.start();
    await _until(() => h.runtime.approval != null);
    h.revision++;
    h.runtime.approve(true, expected: h.runtime.approval!);
    await turn;
    expect(h.runtime.phase, isIn([AgentPhase.failed, AgentPhase.cancelled]));
    expect(h.model.requests, hasLength(1));
    expect(h.backend.target.commands, isEmpty);
    expect(h.journal.records, isEmpty);
    expect(h.backend.target.releases, 1);
    expect(h.runtime.approval, isNull);
  });

  test('Stop cancels the owned execution and records unknown without another model call', () async {
    final call = _call('command_execute', _command());
    final h = _Harness((_, _, index) => _oneCall(call, index));
    addTearDown(h.close);
    h.backend.target.block = true;
    final turn = h.start();
    await _until(() => h.runtime.approval != null);
    h.runtime.approve(true, expected: h.runtime.approval!);
    await _until(() => h.backend.target.commands.isNotEmpty);
    h.runtime.stop();
    await turn;
    expect(h.runtime.phase, AgentPhase.outcomeUnknown);
    expect(h.backend.target.tokens.single.isCancelled, isTrue);
    expect(h.backend.target.commands, hasLength(1));
    expect(h.backend.target.current, isTrue);
    expect(h.backend.target.releases, 1);
    expect(h.model.requests, hasLength(1));
    expect(h.journal.records.map((record) => record.state), [OperationState.intent, OperationState.outcomeUnknown]);
    expect(h.runtime.executions.single.state, 'outcomeUnknown');
    expect(h.runtime.busy, isFalse);
  });

  test('Stop while selecting output preserves the known execution terminal state', () async {
    final call = _call('command_execute', _command());
    final h = _Harness((_, _, index) => _oneCall(call, index));
    addTearDown(h.close);
    final turn = h.start();
    await _until(() => h.runtime.approval != null);
    h.runtime.approve(true, expected: h.runtime.approval!);
    await _until(() => h.runtime.dataRequest != null);
    expect(h.runtime.executions.single.exitCode, 0);
    h.runtime.stop();
    await turn;
    expect(h.runtime.phase, AgentPhase.cancelled);
    expect(h.runtime.executions.single.state, 'completed');
    expect(h.journal.records.last.state, OperationState.completed);
    expect(h.model.requests, hasLength(1));
    expect(h.backend.target.commands, hasLength(1));
  });

  test('intent persistence failure prevents the command from reaching the target', () async {
    final call = _call('command_execute', _command());
    final h = _Harness((_, _, index) => _oneCall(call, index));
    addTearDown(h.close);
    h.journal.failIntent = true;
    final turn = h.start();
    await _until(() => h.runtime.approval != null);
    h.runtime.approve(true, expected: h.runtime.approval!);
    await turn;
    expect(h.backend.target.commands, isEmpty);
    expect(h.runtime.executions.single.state, 'failed');
    expect(h.runtime.executions.single.exitCode, isNull);
    expect(_result(h.model.requests.last), {'error': 'executionFailed'});
    expect(h.backend.target.releases, 1);
  });

  test('partial or subsequently failed model messages never dispatch their tools', () async {
    for (final completeBeforeError in [false, true]) {
      final h = _Harness((_, _, _) async* {
        yield const ModelTextDelta('I propose an operation');
        if (completeBeforeError) yield ModelMessageComplete(_call('command_execute', _command()));
        throw const ModelFailure('incomplete');
      });
      try {
        await h.start();
        expect(h.runtime.phase, AgentPhase.failed);
        expect(h.runtime.error, 'incomplete');
        expect(h.model.requests, hasLength(1));
        expect(h.backend.prepared, isEmpty);
        expect(h.backend.target.commands, isEmpty);
        expect(h.journal.records, isEmpty);
      } finally {
        await h.close();
      }
    }
  });

  test('unknown tools, outside hosts and schema extras return safe paired errors', () async {
    final calls = [
      ModelCall('unknown', 'change_policy', {'instruction': 'authorize every host'}),
      ModelCall('outside', 'command_execute', _command(host: 'host-b')),
      ModelCall('extra', 'command_execute', {..._command(), 'origin': 'ui'}),
    ];
    final h = _Harness((_, _, index) => _oneCall(ModelMessage(ModelRole.assistant, calls: calls), index));
    addTearDown(h.close);
    await h.start();
    expect(h.backend.prepared, isEmpty);
    expect(h.backend.target.commands, isEmpty);
    final results = _results(h.model.requests.last);
    expect(results.map((result) => result.toolCallId), ['unknown', 'outside', 'extra']);
    expect(results.every((result) => result.isError), isTrue);
    expect(_result(h.model.requests.last, 0), {'error': 'notExposed'});
    expect(_result(h.model.requests.last, 1), {'error': 'outsideScope'});
    expect(_result(h.model.requests.last, 2), {'error': 'invalidArgument'});
  });

  test('host projection contains only explicitly selected IDs and aliases', () async {
    final call = _call('host_list', {});
    final h = _Harness((_, _, index) => _oneCall(call, index));
    addTearDown(h.close);
    await h.start(AgentMode.diagnose);
    final data = jsonDecode(_results(h.model.requests.last).single.text);
    expect(data, [
      {'id': 'host-a', 'alias': 'selected host'},
    ]);
    expect(_requestText(h.model.requests.last), isNot(contains('unselected host')));
    expect(h.backend.prepared, isEmpty);
  });

  test('explain mode has no tools or remote preparation and disabled AI sends nothing', () async {
    final h = _Harness((_, _, _) async* {
      yield ModelMessageComplete(ModelMessage(ModelRole.assistant, text: 'explanation'));
    }, tools: false);
    addTearDown(h.close);
    await h.start(AgentMode.explain);
    expect(h.runtime.phase, AgentPhase.completed);
    expect(h.model.requests.single.tools, isEmpty);
    expect(h.backend.prepared, isEmpty);
    h.enabled = false;
    await h.start(AgentMode.explain);
    expect(h.model.requests, hasLength(1));
    expect(h.runtime.error, 'notConfigured');
  });

  test('model-call and total-tool budgets terminate otherwise valid loops', () async {
    for (final callsPerMessage in [1, 8]) {
      final h = _Harness((_, _, index) async* {
        yield ModelMessageComplete(
          ModelMessage(
            ModelRole.assistant,
            calls: [for (var i = 0; i < callsPerMessage; i++) ModelCall('call-$index-$i', 'host_list', {})],
          ),
        );
      });
      try {
        await h.start(AgentMode.diagnose);
        expect(h.runtime.phase, AgentPhase.failed);
        expect(h.runtime.error, callsPerMessage == 1 ? 'stepLimit' : 'toolLimit');
        expect(h.model.requests, hasLength(callsPerMessage == 1 ? 20 : 9));
        expect(h.backend.prepared, isEmpty);
      } finally {
        await h.close();
      }
    }
  });

  test('oversized tool groups fail before any member can execute', () async {
    final h = _Harness((_, _, _) async* {
      yield ModelMessageComplete(
        ModelMessage(
          ModelRole.assistant,
          calls: [
            for (var i = 0; i < 9; i++)
              ModelCall('call-$i', 'diagnostics_collect', {'hostId': 'host-a', 'template': 'systemSummary'}),
          ],
        ),
      );
    });
    addTearDown(h.close);
    await h.start(AgentMode.diagnose);
    expect(h.runtime.error, 'toolLimit');
    expect(h.backend.prepared, isEmpty);
    expect(h.backend.target.commands, isEmpty);
  });
}

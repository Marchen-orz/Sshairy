import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sshairy/app/composition.dart';
import 'package:sshairy/features/ai/application/context.dart';
import 'package:sshairy/features/ai/application/providers.dart' show agentConversationRoutesProvider;
import 'package:sshairy/features/connections/api.dart' show ExecError, ExecFailure, HostTrustService, hostTrustProvider;
import 'package:sshairy/features/credentials/api.dart' show ConnectionCredentials, connectionCredentialsProvider;
import 'package:sshairy/features/hosts/api.dart' show Host, HostsNotifier, hostsProvider;
import 'package:sshairy/features/monitor/api.dart' show DiagnosticTemplate, diagnosticCommand;
import 'package:sshairy/features/ai/application/output_store.dart';
import 'package:sshairy/features/ai/application/runtime.dart';
import 'package:sshairy/features/ai/domain/agent.dart';
import 'package:sshairy/features/ai/domain/conversation.dart';
import 'package:sshairy/features/ai/domain/model.dart';
import 'package:sshairy/features/ai/domain/resources.dart';
import 'package:sshairy/features/capabilities/api.dart';
import 'package:sshairy/features/terminal/api.dart';
import 'package:sshairy/foundation/cancellation.dart';
import 'package:sshairy/foundation/ids.dart';
import 'package:sshairy/foundation/result.dart';

const _host = HostId('host-a');
const _other = HostId('host-b');
const _privateOutput = 'private-output-must-not-reach-model';
const _systemOutput =
    '@@system\nLinux\n@@kernel\n6.8.0\n@@architecture\nx86_64\n'
    '@@load\n0.10 0.20 0.30 1/40 123\n@@uptime\n123.5 20.0\n'
    '@@memory\nMemTotal: 1024 kB\nMemAvailable: 512 kB\nSwapTotal: 64 kB\nSwapFree: 32 kB\n';

typedef _Script = Stream<ModelEvent> Function(ModelRequest request, CancellationToken cancel, int index);

class _Model implements ModelProvider {
  _Model(this.script, {this.review});
  final _Script script;
  final _Script? review;
  final requests = <ModelRequest>[];
  final cancellations = <CancellationToken>[];
  final reviewRequests = <ModelRequest>[];
  final reviewCancellations = <CancellationToken>[];
  var closes = 0;

  @override
  Stream<ModelEvent> stream(ModelRequest request, CancellationToken cancel) {
    if (!request.profile.tools && review != null) {
      final index = reviewRequests.length;
      reviewRequests.add(request);
      reviewCancellations.add(cancel);
      return review!(request, cancel, index);
    }
    final index = requests.length;
    requests.add(request);
    cancellations.add(cancel);
    return script(request, cancel, index);
  }

  @override
  void close() => closes++;
}

class _Target implements AgentTarget {
  _Target([this.hostId = _host]);
  @override
  final HostId hostId;
  @override
  String identity = 'transport-a/config-1';
  @override
  String get display => 'tester@example.invalid:22';
  @override
  bool current = true;
  bool posix = true, block = false;
  AgentFailure? probeFailure;
  void Function(bool stderr, Uint8List bytes)? writeOutput;
  int? result = 0;
  Future<int?>? pendingExecution;
  String stdout = _privateOutput, stderr = '';
  var probes = 0, releases = 0;
  final commands = <String>[];
  final tokens = <CancellationToken>[];
  final deadlines = <Duration>[];
  void Function()? beforeExecute;

  @override
  Future<bool> supportsPosix(CancellationToken cancel) async {
    probes++;
    if (probeFailure case final failure?) throw failure;
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
    writeOutput = output;
    commands.add(command);
    tokens.add(cancel);
    deadlines.add(timeout);
    output(false, Uint8List.fromList(utf8.encode(stdout)));
    if (stderr.isNotEmpty) output(true, Uint8List.fromList(utf8.encode(stderr)));
    if (block) {
      await cancel.whenCancelled;
      throw const AgentFailure('cancelled');
    }
    return await (pendingExecution ?? Future.value(result));
  }

  @override
  void release() => releases++;
}

class _Backend implements AgentBackend {
  final target = _Target();
  final others = <HostId, _Target>{};
  final prepared = <HostId>[];
  Future<AgentTarget>? pendingPreparation;
  AgentFailure? prepareFailure;
  @override
  List<AgentHost> hosts = const [AgentHost(_host, 'selected host'), AgentHost(_other, 'unselected host')];

  @override
  Future<AgentTarget> prepare(HostId host, CancellationToken cancel) async {
    prepared.add(host);
    if (prepareFailure case final failure?) throw failure;
    if (host != _host) return others.putIfAbsent(host, () => _Target(host)..stdout = _systemOutput);
    return await (pendingPreparation ?? Future.value(target));
  }
}

TerminalHistorySnapshot _terminalSnapshot(
  String id, {
  HostId? host = _host,
  String output = 'window result',
  int generation = 1,
  int historyRevision = 1,
  Object? binding,
  TerminalAiPrompt prompt = TerminalAiPrompt.unknown,
}) => TerminalHistorySnapshot(
  session: TerminalHistorySession(
    sessionId: SessionId(id),
    target: host == null ? const LocalTerminalAiTarget(LocalShellKind.pwsh) : SshTerminalAiTarget(host),
    label: 'window-$id',
    generation: generation,
    historyRevision: historyRevision,
    binding: binding ?? Object(),
  ),
  directory: host == null ? r'C:\work' : '/work',
  prompt: prompt,
  history: [
    TerminalAiHistoryEntry(
      text: 'printf window-result',
      at: DateTime.utc(2026, 11, 12),
      generation: generation,
      output: output,
      resultStatus: TerminalAiHistoryResultStatus.available,
      exitCode: 0,
      boundary: TerminalAiHistoryBoundary.osc133,
    ),
  ],
);

class _TerminalHistory implements TerminalHistoryReader {
  _TerminalHistory(this.snapshots, {this.focusedSession});
  final List<TerminalHistorySnapshot> snapshots;
  final unavailable = <SessionId>{};
  final reads = <SessionId>[], screenReads = <SessionId>[];
  @override
  SessionId? focusedSession;

  @override
  List<TerminalHistorySession> get sessions => [
    for (final snapshot in snapshots)
      if (!unavailable.contains(snapshot.session.sessionId)) snapshot.session,
  ];

  @override
  bool isCurrent(TerminalHistorySession expected) =>
      !unavailable.contains(expected.sessionId) && snapshots.any((snapshot) => identical(snapshot.session, expected));

  @override
  TerminalHistorySnapshot? read(TerminalHistorySession expected) {
    if (!isCurrent(expected)) return null;
    reads.add(expected.sessionId);
    return snapshots.firstWhere((snapshot) => identical(snapshot.session, expected));
  }

  @override
  TerminalScreenSnapshot? readScreen(TerminalHistorySession expected, {int maxLines = 200, int maxBytes = 32768}) {
    final snapshot = read(expected);
    if (snapshot == null) return null;
    screenReads.add(expected.sessionId);
    final text = snapshot.history.map((entry) => entry.output).where((text) => text.isNotEmpty).join('\n');
    return TerminalScreenSnapshot(
      session: expected,
      text: text,
      firstLine: 0,
      lastLine: text.isEmpty ? 0 : text.split('\n').length - 1,
      truncated: false,
    );
  }
}

class _Journal implements OperationJournal {
  final records = <OperationRecord>[];
  var loads = 0;
  bool failIntent = false, failLoad = false, failTerminal = false;
  Completer<void>? pendingIntent, pendingTerminal;
  var intentAttempts = 0, terminalAttempts = 0;

  @override
  Future<List<OperationRecord>> load() async {
    loads++;
    if (failLoad) throw StateError('simulated corrupt journal');
    return List.unmodifiable(records);
  }

  @override
  Future<void> record(OperationRecord record) async {
    if (record.state == OperationState.intent) {
      intentAttempts++;
      if (pendingIntent case final pending?) await pending.future;
      if (failIntent) throw StateError('simulated disk failure');
    } else {
      terminalAttempts++;
      if (pendingTerminal case final pending?) await pending.future;
      if (failTerminal) throw StateError('simulated terminal journal failure');
    }
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
  _Harness(
    _Script script, {
    bool tools = true,
    bool approveDiagnostics = true,
    _Script? review,
    OutputStore? outputs,
    Map<HostId, String> Function()? hostRoutes,
    TerminalHistoryReader? terminalHistory,
    AgentResourceReader? resources,
    List<Capability> extraCapabilities = const [],
    String? language,
  }) : model = _Model(script, review: review) {
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
        (args, _) async => runtime.listHosts(args.raw),
        agentExposed: true,
        inputSchema: _schema({
          'offset': {'type': 'integer', 'minimum': 0, 'maximum': 1000},
        }, []),
      ),
      FunctionCapability(
        'agent.terminals',
        Effect.query,
        (args, _) async => runtime.listTerminals(args.raw),
        agentExposed: true,
        inputSchema: _schema({
          'offset': {'type': 'integer', 'minimum': 0, 'maximum': 1000},
        }, []),
      ),
      FunctionCapability(
        'agent.terminalHistory',
        Effect.query,
        (args, _) async => runtime.readTerminalHistory(args.raw),
        agentExposed: true,
        inputSchema: _schema({
          'sessionId': {'type': 'string', 'minLength': 1, 'maxLength': 128},
        }, []),
      ),
      FunctionCapability(
        'agent.terminalScreen',
        Effect.query,
        (args, _) async => runtime.readTerminalScreen(args.raw),
        agentExposed: true,
        inputSchema: _schema({
          'sessionId': {'type': 'string', 'minLength': 1, 'maxLength': 128},
          'maxLines': {'type': 'integer', 'minimum': 1, 'maximum': 200},
        }, []),
      ),
      FunctionCapability(
        'agent.diagnose',
        Effect.connect,
        (args, context) => runtime.diagnose(args.raw, context),
        agentExposed: true,
        inputSchema: _schema(
          {
            'hostId': {'type': 'string', 'minLength': 1, 'maxLength': 128},
            'template': {'type': 'string', 'enum': DiagnosticTemplate.values.map((template) => template.name).toList()},
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
            'purpose': {'type': 'string', 'minLength': 1, 'maxLength': 160},
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
      FunctionCapability(
        'agent.jobs.start',
        Effect.remoteWrite,
        (args, context) => runtime.startJob(args.raw, context),
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
        'agent.jobs.read',
        Effect.query,
        (args, _) async => runtime.readJob(args.raw),
        agentExposed: true,
        inputSchema: _schema(
          {
            'jobId': {'type': 'string', 'minLength': 1, 'maxLength': 128},
            'offset': {'type': 'integer', 'minimum': 0},
          },
          ['jobId'],
        ),
      ),
      FunctionCapability(
        'agent.jobs.status',
        Effect.query,
        (args, _) async => runtime.jobStatus(args.raw),
        agentExposed: true,
        inputSchema: _schema(
          {
            'jobId': {'type': 'string', 'minLength': 1, 'maxLength': 128},
          },
          ['jobId'],
        ),
      ),
      FunctionCapability(
        'agent.jobs.stop',
        Effect.localChange,
        (args, _) async => runtime.stopJob(args.raw),
        agentExposed: true,
        inputSchema: _schema(
          {
            'jobId': {'type': 'string', 'minLength': 1, 'maxLength': 128},
          },
          ['jobId'],
        ),
      ),
      ...extraCapabilities,
    ]);
    runtime = AgentRuntime(
      model: model,
      backend: backend,
      journal: journal,
      dispatcher: dispatcher,
      outputs: outputs,
      hostRoutes: hostRoutes ?? () => routes,
      terminalHistory: terminalHistory,
      resources: resources,
      language: language == null ? null : () => language,
      configuration: () => (enabled: enabled, profile: profile, revision: revision),
    );
    if (approveDiagnostics) {
      // Non-permission fixtures approve fixed reads; commands stay manual.
      AgentApproval? lastRead;
      runtime.addListener(() {
        final pending = runtime.approval;
        if (pending != null && pending.template != null && !identical(lastRead, pending)) {
          lastRead = pending;
          runtime.approve(true, expected: pending);
        }
      });
    }
  }

  final _Model model;
  final backend = _Backend();
  final journal = _Journal();
  final routes = <HostId, String>{_host: 'route-a', _other: 'route-b'};
  late final AgentRuntime runtime;
  late ModelProfile profile;
  bool enabled = true;
  int revision = 0;

  Future<void> start({Iterable<HostId> hosts = const [_host]}) =>
      runtime.start('check the selected host', AgentScope(hosts: hosts));

  Future<Result<Object?>> dispatch(String capability, Map<String, Object?> args) => runtime.dispatcher.dispatch(
    capability,
    args,
    RequestContext(Origin.agent, authority: runtime, cancellation: model.cancellations.last),
  );

  Future<void> close() async {
    runtime.stop();
    await runtime.settled.timeout(const Duration(seconds: 2));
    runtime.dispose();
  }
}

class _Resources implements AgentResourceReader {
  _Resources({this.hosts = const [_host]});
  final List<HostId> hosts;
  var binding = 'resource-a', reads = 0;
  void Function(int)? onRead;
  @override
  AgentResourceSnapshot resolve(String capability, Map<String, Object?> args) {
    onRead?.call(++reads);
    return AgentResourceSnapshot(hosts: hosts, binding: binding, details: {'resource': binding});
  }
}

class _RouteHosts extends HostsNotifier {
  static Host hostProfile(HostId id, {String address = 'example.invalid', String label = ''}) =>
      Host(id: id, label: label, address: address, username: 'tester');

  @override
  List<Host> build() => [hostProfile(_host), hostProfile(_other)];

  void replace(List<Host> hosts) => state = hosts;
}

class _RouteTrust implements HostTrustService {
  @override
  int get revision => 0;
  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError('unexpected trust call');
}

class _RouteCredentials implements ConnectionCredentials {
  @override
  int get revision => 0;
  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError('unexpected credential call');
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

Stream<ModelEvent> _reviewReply(String decision) async* {
  yield ModelMessageComplete(ModelMessage(ModelRole.assistant, text: jsonEncode({'decision': decision})));
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

AgentScope _conversationScope({
  String id = 'conversation-a',
  HostId focus = _host,
  AgentPermissionMode mode = AgentPermissionMode.observe,
}) => AgentScope(
  hosts: [focus],
  conversationId: id,
  defaultHost: _host,
  defaultHostRoute: 'route-a',
  permissionMode: mode,
);

Stream<ModelEvent> _diagnoseOther(ModelRequest request, CancellationToken _, int _) async* {
  if (_results(request).isEmpty) {
    yield ModelMessageComplete(
      ModelMessage(
        ModelRole.assistant,
        calls: [
          ModelCall('list', 'host_list', {}),
          ModelCall('remote', 'diagnostics_collect', {'hostId': _other.value, 'template': 'systemSummary'}),
        ],
      ),
    );
  } else {
    yield ModelMessageComplete(ModelMessage(ModelRole.assistant, text: 'done'));
  }
}

void main() {
  for (final capability in ['session.close', 'workspace.split', 'transfer.cancel', 'forward.stop']) {
    test('$capability approval is bound to the resolved resource', () async {
      final resource = _Resources();
      var invoked = false;
      final tool = AgentRuntime.toolIds.entries.firstWhere((entry) => entry.value == capability).key;
      final h = _Harness(
        (_, _, i) => _oneCall(_call(tool, {}), i),
        resources: resource,
        extraCapabilities: [
          FunctionCapability(capability, capability == 'workspace.split' ? Effect.connect : Effect.localChange, (
            _,
            _,
          ) async {
            invoked = true;
            return const Ok(null);
          }, agentExposed: true),
        ],
      );
      addTearDown(h.close);
      final work = h.start();
      await _until(() => h.runtime.approval != null);
      expect(invoked, isFalse);
      expect(h.runtime.approval!.command, contains('resource-a'));
      resource.binding = 'resource-b';
      h.runtime.approve(true, expected: h.runtime.approval!);
      await work;
      expect(invoked, isFalse);
      expect(_result(h.model.requests.last), {'error': 'scopeChanged'});
    });
  }

  test('a resource changed in the revalidation microtask cannot reach its handler', () async {
    final resource = _Resources();
    var invoked = false;
    final h = _Harness(
      (_, _, i) => _oneCall(_call('session_close', {}), i),
      resources: resource,
      extraCapabilities: [
        FunctionCapability('session.close', Effect.localChange, (_, _) async {
          invoked = true;
          return const Ok(null);
        }, agentExposed: true),
      ],
    );
    addTearDown(h.close);
    resource.onRead = (read) {
      if (read == 2) scheduleMicrotask(() => resource.binding = 'changed-after-revalidation');
    };
    final work = h.start();
    await _until(() => h.runtime.approval != null);
    h.runtime.approve(true, expected: h.runtime.approval!);
    await work;
    expect(resource.reads, greaterThanOrEqualTo(3));
    expect(invoked, isFalse);
    expect(_result(h.model.requests.last), {'error': 'scopeChanged'});
  });

  test('resource host resolution cannot silently authorize another host', () async {
    final resource = _Resources(hosts: const [_other]);
    var invoked = false;
    final h = _Harness(
      (_, _, i) => _oneCall(_call('workspace_split', {}), i),
      resources: resource,
      extraCapabilities: [
        FunctionCapability('workspace.split', Effect.connect, (_, _) async {
          invoked = true;
          return const Ok(null);
        }, agentExposed: true),
      ],
    );
    addTearDown(h.close);
    await h.start();
    expect(invoked, isFalse);
    expect(h.runtime.approval, isNull);
    expect(_result(h.model.requests.last), {'error': 'hostSelectionRequired'});
    expect(h.backend.prepared, isEmpty);
  });

  test('missing resource reader fails closed before resource approval', () async {
    var invoked = false;
    final h = _Harness(
      (_, _, i) => _oneCall(_call('session_reconnect', {}), i),
      extraCapabilities: [
        FunctionCapability('session.reconnect', Effect.connect, (_, _) async {
          invoked = true;
          return const Ok(null);
        }, agentExposed: true),
      ],
    );
    addTearDown(h.close);
    await h.start();
    expect(invoked, isFalse);
    expect(h.runtime.approval, isNull);
    expect(_result(h.model.requests.last), {'error': 'outsideScope'});
  });

  test('host approval summary and review include every validated non-secret field', () async {
    final args = <String, Object?>{
      'address': 'new.invalid',
      'auth': 'key',
      'methods': ['key', 'password'],
      'allowInteractive': true,
      'legacy': true,
      'inherit': ['port'],
      'proxy': {'kind': 'socks5', 'address': 'proxy.invalid', 'port': 1080, 'username': 'proxy-user'},
      'label': 'host-${'x' * 1500}',
    };
    Map<String, Object?> schema(Object? value) => switch (value) {
      String() => {'type': 'string'},
      bool() => {'type': 'boolean'},
      int() => {'type': 'integer'},
      List() => {
        'type': 'array',
        'items': {'type': 'string'},
      },
      Map() => {
        'type': 'object',
        'properties': {for (final e in value.entries) e.key as String: schema(e.value)},
      },
      _ => throw StateError('unsupported test field'),
    };
    final h = _Harness(
      (_, _, i) => _oneCall(_call('hosts_create', args), i),
      review: (_, _, _) => _reviewReply('ask'),
      extraCapabilities: [
        FunctionCapability(
          'host.create',
          Effect.localChange,
          (_, _) async => const Ok(null),
          agentExposed: true,
          inputSchema: _schema({for (final e in args.entries) e.key: schema(e.value)}, args.keys.toList()),
        ),
      ],
    );
    addTearDown(h.close);
    final work = h.runtime.start(
      'create the host using all supplied fields',
      AgentScope(hosts: const [_host], permissionMode: AgentPermissionMode.review),
    );
    await _until(() => h.runtime.approval != null);
    expect(jsonDecode(h.runtime.approval!.command), args);
    final reviewText = h.model.reviewRequests.single.messages.single.text;
    expect(reviewText, contains('proxy.invalid'));
    expect(reviewText, contains('allowInteractive'));
    expect(reviewText, contains('inherit'));
    expect(reviewText, contains('legacy'));
    expect(reviewText, contains('x' * 1500));
    h.runtime.approve(false, expected: h.runtime.approval!);
    await work;
  });

  test('invalid application tool schema stops instead of asking the model to repeat it', () async {
    var invoked = false;
    final h = _Harness(
      (_, _, i) => _oneCall(_call('settings_patch', {}), i),
      extraCapabilities: [
        FunctionCapability(
          'settings.patch',
          Effect.localChange,
          (_, _) async {
            invoked = true;
            return const Ok(null);
          },
          agentExposed: true,
          inputSchema: const {
            'type': 'object',
            'additionalProperties': {'type': 'string'},
          },
        ),
      ],
    );
    addTearDown(h.close);
    await h.start();
    expect(h.runtime.error, 'invalidSchema');
    expect(h.model.requests, hasLength(1));
    expect(h.runtime.approval, isNull);
    expect(invoked, isFalse);
  });

  for (final failIntent in [false, true]) {
    test('file mutation persists intent after approval before invoke, failIntent=$failIntent', () async {
      var invoked = false;
      late _Harness h;
      h = _Harness(
        (_, _, i) => _oneCall(_call('files_mkdir', {'hostId': _host.value, 'path': '/owned'}), i),
        extraCapabilities: [
          FunctionCapability(
            'file.mkdir',
            Effect.remoteWrite,
            (_, _) async {
              invoked = true;
              expect(h.journal.records.last.state, OperationState.intent);
              return const Ok(null);
            },
            agentExposed: true,
            inputSchema: _schema(
              {
                'hostId': {'type': 'string'},
                'path': {'type': 'string'},
              },
              ['hostId', 'path'],
            ),
          ),
        ],
      );
      h.journal.failIntent = failIntent;
      addTearDown(h.close);
      final work = h.start();
      await _until(() => h.runtime.approval != null);
      expect(h.journal.records, isEmpty);
      h.runtime.approve(true, expected: h.runtime.approval!);
      await work;
      expect(invoked, !failIntent);
      expect(h.runtime.error, isNull);
      if (failIntent) expect(h.model.requests.last.messages.last.text, contains('journalFailed'));
      if (!failIntent) expect(h.journal.records.map((r) => r.state), [OperationState.intent, OperationState.completed]);
    });
  }

  test('each file page needs its own approval even for the same path and repeated offset', () async {
    const offsets = [0, 16, 0];
    final reads = <int>[];
    final h = _Harness(
      (_, _, index) async* {
        if (index < offsets.length) {
          yield ModelMessageComplete(
            _call('files_read', {
              'hostId': _host.value,
              'path': '/tmp/page.txt',
              'offset': offsets[index],
            }, 'read-$index'),
          );
        } else {
          yield ModelMessageComplete(ModelMessage(ModelRole.assistant, text: 'done'));
        }
      },
      extraCapabilities: [
        FunctionCapability(
          'file.read',
          Effect.query,
          (args, _) async {
            reads.add(args.require<int>('offset'));
            return const Ok({'text': 'page'});
          },
          agentExposed: true,
          inputSchema: _schema(
            {
              'hostId': {'type': 'string'},
              'path': {'type': 'string'},
              'offset': {'type': 'integer', 'minimum': 0},
            },
            ['hostId', 'path', 'offset'],
          ),
        ),
      ],
    );
    addTearDown(h.close);
    final work = h.start();
    AgentApproval? previous;
    for (final (index, offset) in offsets.indexed) {
      await _until(() => h.runtime.approval != null && !identical(h.runtime.approval, previous));
      final pending = h.runtime.approval!;
      expect(pending.capability, 'file.read');
      expect(jsonDecode(pending.command), containsPair('offset', offset));
      expect(reads, offsets.take(index));
      previous = pending;
      h.runtime.approve(true, expected: pending);
    }
    await work;
    expect(reads, offsets);
    expect(h.runtime.phase, AgentPhase.completed);
    expect(h.backend.prepared, isEmpty);
  });

  for (final capability in ['file.write', 'transfer.enqueue']) {
    for (final invalidation in ['route', 'configuration', 'cancellation']) {
      test('$capability keeps frozen authority after completion until $invalidation changes', () async {
        final transfer = capability == 'transfer.enqueue';
        final args = transfer
            ? {'fromHostId': _host.value, 'toHostId': _host.value, 'from': '/tmp/a', 'to': '/tmp/b'}
            : {'hostId': _host.value, 'path': '/tmp/a', 'text': 'bounded text'};
        RequestContext? captured;
        final h = _Harness(
          (_, _, index) => _oneCall(_call(transfer ? 'transfer_enqueue' : 'files_write', args), index),
          extraCapabilities: [
            FunctionCapability(
              capability,
              Effect.remoteWrite,
              (_, context) async {
                captured = context;
                expect(context.isCurrent, isTrue);
                return const Ok({'accepted': true});
              },
              agentExposed: true,
              inputSchema: _schema({
                for (final key in args.keys) key: {'type': 'string'},
              }, args.keys.toList()),
            ),
          ],
        );
        addTearDown(h.close);
        await h.runtime.start(
          'accept queued work',
          AgentScope(hosts: const [_host], permissionMode: AgentPermissionMode.auto),
        );
        expect(h.runtime.busy, isFalse);
        expect(h.runtime.phase, AgentPhase.completed);
        expect(captured, isNotNull);
        expect(captured!.authorizationIsCurrent, isNotNull);
        expect(captured!.isCurrent, isTrue, reason: 'natural completion does not revoke accepted work');
        if (invalidation == 'route') {
          h.routes[_host] = 'changed-route';
        } else if (invalidation == 'configuration') {
          h.revision++;
        } else {
          captured!.cancellation!.cancel();
        }
        expect(captured!.isCurrent, isFalse);
      });
    }
  }

  test('current terminal context is shared by default and focus changes do not retarget reads', () async {
    final current = _terminalSnapshot('window-a', output: 'focused-window-result');
    final other = _terminalSnapshot('window-b', output: 'other-window-result');
    final terminal = _TerminalHistory([current, other], focusedSession: current.session.sessionId);
    final h = _Harness((_, _, index) async* {
      terminal.focusedSession = other.session.sessionId;
      yield* _oneCall(_call('terminal_history_read', {}), index);
    }, terminalHistory: terminal);
    addTearDown(h.close);
    await h.runtime.start('explain the current window', _conversationScope());
    final input = jsonDecode(h.model.requests.first.messages.single.text) as Map;
    final context = input['currentTerminal'] as Map;
    expect(context['sessionId'], 'window-a');
    expect(context['directory'], '/work');
    expect(context['prompt'], 'unknown');
    expect((context['history'] as List).single['result']['text'], 'focused-window-result');
    expect(_requestText(h.model.requests.first), isNot(contains('other-window-result')));
    expect(_result(h.model.requests.last)['sessionId'], 'window-a');
    expect(terminal.reads, isNotEmpty);
    expect(terminal.reads.every((id) => id == current.session.sessionId), isTrue);
    expect(h.runtime.approval, isNull);
    expect(h.backend.prepared, isEmpty);
    expect(h.backend.target.probes, 0);
    expect(h.backend.target.commands, isEmpty);
  });

  for (final mode in AgentPermissionMode.values) {
    test('$mode requires manual approval before reading another window on the same host', () async {
      final current = _terminalSnapshot('window-a', output: 'focused-window-result');
      final other = _terminalSnapshot('window-b', output: 'approved-other-window-result');
      final terminal = _TerminalHistory([current, other], focusedSession: current.session.sessionId);
      final h = _Harness(
        (_, _, index) async* {
          if (index == 0) {
            yield ModelMessageComplete(
              ModelMessage(
                ModelRole.assistant,
                calls: [
                  ModelCall('windows', 'terminal_list', {}),
                  for (var read = 0; read < 2; read++)
                    ModelCall('read-$read', 'terminal_history_read', {'sessionId': 'window-b'}),
                ],
              ),
            );
          } else {
            yield ModelMessageComplete(ModelMessage(ModelRole.assistant, text: 'explained'));
          }
        },
        terminalHistory: terminal,
        review: (_, _, _) => _reviewReply('allow'),
      );
      addTearDown(h.close);
      var prompts = 0;
      AgentApproval? last;
      h.runtime.addListener(() {
        final pending = h.runtime.approval;
        if (pending != null && !identical(last, pending)) {
          last = pending;
          prompts++;
        }
      });
      final work = h.runtime.start('compare both windows', _conversationScope(mode: mode));
      await _until(() => h.runtime.approval != null);
      expect(h.runtime.approval!.capability, 'agent.terminalHistory');
      expect(h.runtime.approval!.target, contains('window-b'));
      expect(terminal.reads, isNot(contains(other.session.sessionId)));
      expect(h.model.reviewRequests, isEmpty);
      expect(h.backend.prepared, isEmpty);
      expect(h.runtime.hostApproval, isNull);
      h.runtime.approve(true, expected: h.runtime.approval!);
      await work;
      expect(prompts, 1);
      final directory = _result(h.model.requests.last)['sessions'] as List;
      expect(directory.map((entry) => entry['sessionId']), ['window-a', 'window-b']);
      for (var read = 1; read <= 2; read++) {
        final result = _result(h.model.requests.last, read);
        expect(result['sessionId'], 'window-b');
        expect((result['history'] as List).single['result']['text'], 'approved-other-window-result');
      }
      expect(h.model.reviewRequests, isEmpty);
      expect(h.backend.prepared, isEmpty);
      expect(h.backend.target.probes, 0);
      expect(h.backend.target.commands, isEmpty);
      expect(h.journal.records, isEmpty);
      expect(h.runtime.executions.every((execution) => execution.sharedText == null), isTrue);
    });
  }

  for (final mode in AgentPermissionMode.values) {
    test('$mode asks a person before every terminal screen read', () async {
      final current = _terminalSnapshot('window-a', output: 'visible-screen-text');
      final terminal = _TerminalHistory([current], focusedSession: current.session.sessionId);
      final h = _Harness(
        (_, _, index) async* {
          if (index == 0) {
            yield ModelMessageComplete(
              ModelMessage(
                ModelRole.assistant,
                calls: [
                  for (var read = 0; read < 2; read++)
                    ModelCall('screen-$read', 'terminal_screen_read', const {'maxLines': 40}),
                ],
              ),
            );
          } else {
            yield ModelMessageComplete(ModelMessage(ModelRole.assistant, text: 'described'));
          }
        },
        terminalHistory: terminal,
        review: (_, _, _) => _reviewReply('allow'),
      );
      addTearDown(h.close);
      var prompts = 0;
      AgentApproval? last;
      h.runtime.addListener(() {
        final pending = h.runtime.approval;
        if (pending != null && !identical(last, pending)) {
          last = pending;
          prompts++;
        }
      });
      final work = h.runtime.start('describe the visible screen', _conversationScope(mode: mode));
      AgentApproval? handled;
      for (var read = 0; read < 2; read++) {
        await _until(() => h.runtime.approval != null && !identical(h.runtime.approval, handled));
        handled = h.runtime.approval!;
        expect(handled.capability, 'agent.terminalScreen');
        expect(handled.target, contains('window-a'));
        expect(handled.command, isEmpty);
        h.runtime.approve(true, expected: handled);
      }
      await work;
      expect(prompts, 2);
      expect(h.model.reviewRequests, isEmpty);
      expect(terminal.screenReads, [current.session.sessionId, current.session.sessionId]);
      for (var read = 0; read < 2; read++) {
        final result = _result(h.model.requests.last, read);
        expect(result['sessionId'], 'window-a');
        expect(result['text'], 'visible-screen-text');
        expect(result['truncated'], isFalse);
      }
      expect(h.runtime.hostApproval, isNull);
      expect(h.backend.prepared, isEmpty);
      expect(h.backend.target.commands, isEmpty);
    });
  }

  test('auto mode still asks for a screen read and a denial is not retried', () async {
    final current = _terminalSnapshot('window-a', output: 'visible-screen-text');
    final terminal = _TerminalHistory([current], focusedSession: current.session.sessionId);
    final h = _Harness((_, _, index) async* {
      if (index == 0) {
        yield ModelMessageComplete(
          ModelMessage(
            ModelRole.assistant,
            calls: [for (var read = 0; read < 2; read++) ModelCall('screen-$read', 'terminal_screen_read', const {})],
          ),
        );
      } else {
        yield ModelMessageComplete(ModelMessage(ModelRole.assistant, text: 'declined'));
      }
    }, terminalHistory: terminal);
    addTearDown(h.close);
    var prompts = 0;
    AgentApproval? last;
    h.runtime.addListener(() {
      final pending = h.runtime.approval;
      if (pending != null && !identical(last, pending)) {
        last = pending;
        prompts++;
      }
    });
    final work = h.runtime.start('look at the screen', _conversationScope(mode: AgentPermissionMode.auto));
    await _until(() => h.runtime.approval != null);
    h.runtime.approve(false, expected: h.runtime.approval!);
    await work;
    expect(prompts, 1);
    expect(terminal.screenReads, isEmpty);
    for (var read = 0; read < 2; read++) {
      expect(_result(h.model.requests.last, read)['error'], 'denied');
    }
  });

  test('declining another window suppresses repeated prompts without reading its history', () async {
    final current = _terminalSnapshot('window-a');
    final other = _terminalSnapshot('window-b', output: 'declined-window-result');
    final terminal = _TerminalHistory([current, other], focusedSession: current.session.sessionId);
    final h = _Harness((_, _, index) async* {
      if (index == 0) {
        yield ModelMessageComplete(
          ModelMessage(
            ModelRole.assistant,
            calls: [
              for (var read = 0; read < 2; read++)
                ModelCall('read-$read', 'terminal_history_read', {'sessionId': 'window-b'}),
            ],
          ),
        );
      } else {
        yield ModelMessageComplete(ModelMessage(ModelRole.assistant, text: 'declined'));
      }
    }, terminalHistory: terminal);
    addTearDown(h.close);
    var prompts = 0;
    AgentApproval? last;
    h.runtime.addListener(() {
      final pending = h.runtime.approval;
      if (pending != null && !identical(last, pending)) {
        last = pending;
        prompts++;
      }
    });
    final work = h.runtime.start('inspect another window', _conversationScope());
    await _until(() => h.runtime.approval != null);
    h.runtime.approve(false, expected: h.runtime.approval!);
    await work;
    expect(prompts, 1);
    expect(_result(h.model.requests.last), {'error': 'denied'});
    expect(_result(h.model.requests.last, 1), {'error': 'denied'});
    expect(terminal.reads, isNot(contains(other.session.sessionId)));
    expect(h.model.requests.every((request) => !_requestText(request).contains('declined-window-result')), isTrue);
    expect(h.backend.prepared, isEmpty);
  });

  test('a history revision change while approval is pending cannot authorize the old window snapshot', () async {
    final current = _terminalSnapshot('window-a');
    final other = _terminalSnapshot('window-b', output: 'stale-window-result');
    final terminal = _TerminalHistory([current, other], focusedSession: current.session.sessionId);
    final h = _Harness(
      (_, _, index) => _oneCall(_call('terminal_history_read', {'sessionId': 'window-b'}), index),
      terminalHistory: terminal,
    );
    addTearDown(h.close);
    final work = h.runtime.start('inspect another window', _conversationScope());
    await _until(() => h.runtime.approval != null);
    terminal.snapshots[1] = _terminalSnapshot('window-b', historyRevision: 2, binding: other.session.binding);
    h.runtime.approve(true, expected: h.runtime.approval!);
    await work;
    expect(_result(h.model.requests.last), {'error': 'scopeChanged'});
    expect(terminal.reads, isNot(contains(other.session.sessionId)));
    expect(h.model.requests.every((request) => !_requestText(request).contains('stale-window-result')), isTrue);
    expect(h.backend.prepared, isEmpty);
  });

  test('Stop invalidates a pending window approval and stale consent cannot approve another turn', () async {
    final current = _terminalSnapshot('window-a');
    final other = _terminalSnapshot('window-b', output: 'stopped-window-result');
    final terminal = _TerminalHistory([current, other], focusedSession: current.session.sessionId);
    final h = _Harness(
      (request, _, _) =>
          _oneCall(_call('terminal_history_read', {'sessionId': 'window-b'}), _results(request).isEmpty ? 0 : 1),
      terminalHistory: terminal,
    );
    addTearDown(h.close);
    final first = h.runtime.start('inspect another window', _conversationScope());
    await _until(() => h.runtime.approval != null);
    final stale = h.runtime.approval!;
    h.runtime.stop();
    await first;
    expect(terminal.reads, isNot(contains(other.session.sessionId)));
    final second = h.runtime.start('inspect another window again', _conversationScope());
    await _until(() => h.runtime.approval != null);
    final pending = h.runtime.approval!;
    h.runtime.approve(true, expected: stale);
    await Future<void>.delayed(Duration.zero);
    expect(h.runtime.approval, same(pending));
    expect(terminal.reads, isNot(contains(other.session.sessionId)));
    h.runtime.approve(false, expected: pending);
    await second;
    expect(_result(h.model.requests.last), {'error': 'denied'});
    expect(h.backend.prepared, isEmpty);
  });

  for (final change in ['close', 'reconnect', 'history', 'binding']) {
    test('$change invalidates shared terminal context before another model request', () async {
      final current = _terminalSnapshot('window-a', output: 'original-window-result');
      final terminal = _TerminalHistory([current], focusedSession: current.session.sessionId);
      final h = _Harness((_, _, _) async* {
        if (change == 'close') {
          terminal.unavailable.add(current.session.sessionId);
        } else {
          terminal.snapshots[0] = _terminalSnapshot(
            'window-a',
            generation: change == 'reconnect' ? 2 : 1,
            historyRevision: change == 'history' ? 2 : 1,
            binding: change == 'binding' ? Object() : current.session.binding,
          );
        }
        yield ModelMessageComplete(_call('host_list', {}));
      }, terminalHistory: terminal);
      addTearDown(h.close);
      await h.runtime.start('explain this window', _conversationScope());
      expect(h.model.requests, hasLength(1));
      expect(h.runtime.error, 'scopeChanged');
      expect(h.backend.prepared, isEmpty);
      expect(h.journal.records, isEmpty);
    });
  }

  test('local terminal context needs no SSH host or backend preparation', () async {
    final current = _terminalSnapshot('local-window', host: null, output: 'local-window-result');
    final terminal = _TerminalHistory([current], focusedSession: current.session.sessionId);
    final h = _Harness((_, _, index) => _oneCall(_call('terminal_history_read', {}), index), terminalHistory: terminal);
    addTearDown(h.close);
    await h.runtime.start('explain this local terminal', AgentScope(permissionMode: AgentPermissionMode.observe));
    final context = (jsonDecode(h.model.requests.first.messages.single.text) as Map)['currentTerminal'] as Map;
    expect(context['sessionId'], 'local-window');
    expect(context['targetKind'], 'local');
    expect(context['shellKind'], 'pwsh');
    expect(context.containsKey('hostId'), isFalse);
    expect(_result(h.model.requests.last)['sessionId'], 'local-window');
    expect(h.runtime.approval, isNull);
    expect(h.runtime.hostApproval, isNull);
    expect(h.backend.prepared, isEmpty);
    expect(h.backend.target.probes, 0);
    expect(h.backend.target.commands, isEmpty);
  });

  test('terminal directory paginates the frozen window set without sharing history', () async {
    final terminal = _TerminalHistory([
      for (var index = 0; index < 35; index++) _terminalSnapshot('window-$index', output: 'private-window-$index'),
    ]);
    final h = _Harness((_, _, index) async* {
      if (index == 0) {
        terminal.snapshots.add(_terminalSnapshot('new-window', output: 'new-window-private-output'));
        terminal.unavailable.add(const SessionId('window-34'));
        yield ModelMessageComplete(
          ModelMessage(
            ModelRole.assistant,
            calls: [
              ModelCall('first-page', 'terminal_list', {}),
              ModelCall('second-page', 'terminal_list', {'offset': 32}),
            ],
          ),
        );
      } else {
        yield ModelMessageComplete(ModelMessage(ModelRole.assistant, text: 'listed'));
      }
    }, terminalHistory: terminal);
    addTearDown(h.close);
    await h.runtime.start('list connected windows', AgentScope(discoverHosts: true));
    final first = _result(h.model.requests.last), second = _result(h.model.requests.last, 1);
    expect(first['total'], 34);
    expect(first['nextOffset'], 32);
    expect(first['sessions'] as List, hasLength(32));
    expect(second['total'], 34);
    expect(second['nextOffset'], isNull);
    expect(second['sessions'] as List, hasLength(2));
    final entries = [...first['sessions'] as List, ...second['sessions'] as List];
    expect(entries.map((entry) => entry['sessionId']).toSet(), hasLength(34));
    expect(entries.any((entry) => entry['sessionId'] == 'new-window'), isFalse);
    expect(entries.any((entry) => entry['sessionId'] == 'window-34'), isFalse);
    for (final entry in entries) {
      expect((entry as Map).keys, isNot(contains('history')));
      expect(entry.keys, isNot(contains('directory')));
      expect(entry.keys, isNot(contains('draft')));
      expect(entry.keys, isNot(contains('binding')));
    }
    expect(terminal.reads, isEmpty);
    expect(h.model.requests.every((request) => !_requestText(request).contains('private-window-')), isTrue);
    expect(h.backend.prepared, isEmpty);
  });

  test('answer-only regeneration does not attach or read the focused terminal', () async {
    final current = _terminalSnapshot('window-a', output: 'not-for-regeneration');
    final terminal = _TerminalHistory([current], focusedSession: current.session.sessionId);
    final h = _Harness((_, _, _) async* {
      yield ModelMessageComplete(ModelMessage(ModelRole.assistant, text: 'answered from history'));
    }, terminalHistory: terminal);
    addTearDown(h.close);
    await h.runtime.startConversation('answer again', _conversationScope(), const [], answerOnly: true);
    expect(h.model.requests.single.tools, isEmpty);
    expect(_requestText(h.model.requests.single), isNot(contains('not-for-regeneration')));
    expect(terminal.reads, isEmpty);
  });

  test('unfinished terminal query tools restore as interrupted reads', () {
    for (final capability in ['agent.terminals', 'agent.terminalHistory']) {
      for (final state in [null, 'pending', 'running']) {
        expect(AgentExecution.restoredState(capability, state), 'interrupted');
      }
    }
    expect(AgentExecution.restoredState('agent.execute', 'running'), 'outcomeUnknown');
  });

  for (final mode in AgentPermissionMode.values) {
    test('$mode requires host consent before preparing another host', () async {
      final remote = mode == AgentPermissionMode.observe
          ? _call('diagnostics_collect', {'hostId': _other.value, 'template': 'systemSummary'})
          : _call('command_execute', _command(host: _other.value));
      final h = _Harness(
        (request, _, _) async* {
          if (_results(request).isEmpty) {
            yield ModelMessageComplete(
              ModelMessage(
                ModelRole.assistant,
                calls: [
                  ModelCall('list', 'host_list', {}),
                  ModelCall('remote', remote.calls.single.name, remote.calls.single.arguments),
                ],
              ),
            );
          } else {
            yield ModelMessageComplete(ModelMessage(ModelRole.assistant, text: 'done'));
          }
        },
        approveDiagnostics: false,
        review: (_, _, _) => _reviewReply('ask'),
      );
      addTearDown(h.close);
      final work = h.runtime.start('also inspect the other host', _conversationScope(mode: mode));
      await _until(() => h.runtime.hostApproval != null);
      final pending = h.runtime.hostApproval!;
      expect(pending.hostId, _other);
      expect(pending.target, 'unselected host');
      expect(pending.conversationId, 'conversation-a');
      expect(h.backend.prepared, isEmpty);
      expect(h.backend.target.probes, 0);
      expect(h.runtime.approval, isNull);
      expect(h.model.reviewRequests, isEmpty);
      h.runtime.decideHost(pending, true);
      if (mode != AgentPermissionMode.auto) {
        await _until(() => h.runtime.approval != null);
        if (mode == AgentPermissionMode.observe) {
          expect(h.runtime.approval!.template, 'systemSummary');
          expect(h.backend.prepared, isEmpty);
        } else {
          expect(h.backend.others[_other]!.commands, isEmpty);
        }
        h.runtime.approve(true, expected: h.runtime.approval!);
      }
      await work;
      expect(h.backend.prepared, [_other]);
      expect(h.backend.others[_other]!.commands, hasLength(1));
      expect(h.runtime.hostApproval, isNull);
    });
  }

  test('separate hosts prompt once each and retain consent across turns and conversation switching', () async {
    const third = HostId('host-c');
    final h = _Harness((request, _, _) async* {
      if (_results(request).isEmpty) {
        yield ModelMessageComplete(
          ModelMessage(
            ModelRole.assistant,
            calls: [
              ModelCall('list', 'host_list', {}),
              for (final (index, host) in [_other, third, _other].indexed)
                ModelCall('host-$index', 'diagnostics_collect', {'hostId': host.value, 'template': 'systemSummary'}),
            ],
          ),
        );
      } else {
        yield ModelMessageComplete(ModelMessage(ModelRole.assistant, text: 'done'));
      }
    });
    addTearDown(h.close);
    h.backend.hosts = [...h.backend.hosts, const AgentHost(third, 'third host')];
    h.routes[third] = 'route-c';
    var prompts = 0;
    AgentHostApproval? last;
    h.runtime.addListener(() {
      final pending = h.runtime.hostApproval;
      if (pending != null && !identical(last, pending)) {
        last = pending;
        prompts++;
      }
    });
    final work = h.runtime.start('inspect both other hosts', _conversationScope());
    await _until(() => h.runtime.hostApproval?.hostId == _other);
    h.runtime.decideHost(h.runtime.hostApproval!, true);
    await _until(() => h.runtime.hostApproval?.hostId == third);
    expect(h.backend.prepared, [_other]);
    h.runtime.decideHost(h.runtime.hostApproval!, true);
    await work;
    expect(prompts, 2);
    expect(h.backend.others[_other]!.commands, hasLength(2));
    // Restoring another chat and returning only rebuilds readable text.
    h.runtime.restoreConversation(const []);
    await h.runtime.start('plain other conversation', AgentScope(conversationId: 'conversation-b'));
    h.runtime.restoreConversation(const []);
    await h.runtime.start('inspect again', _conversationScope(focus: _other));
    expect(prompts, 2);
    expect(h.backend.others[_other]!.commands, hasLength(4));
    expect(h.backend.others[third]!.commands, hasLength(2));
  });

  test('later focused terminal does not silently become the conversation default', () async {
    var execute = false;
    final h = _Harness((request, _, _) async* {
      if (execute && _results(request).isEmpty) {
        yield ModelMessageComplete(_call('diagnostics_collect', {'hostId': _other.value, 'template': 'systemSummary'}));
      } else {
        yield ModelMessageComplete(ModelMessage(ModelRole.assistant, text: 'done'));
      }
    });
    addTearDown(h.close);
    await h.runtime.start('initial question', _conversationScope());
    execute = true;
    final work = h.runtime.start('inspect this terminal', _conversationScope(focus: _other));
    await _until(() => h.runtime.hostApproval != null);
    final input = jsonDecode(h.model.requests.last.messages.single.text) as Map;
    expect(input['focusedHost'], _other.value);
    expect(input['defaultHost'], _host.value);
    expect((input['authorizedHosts'] as List).map((host) => host['id']), [_host.value]);
    expect(h.backend.prepared, isEmpty);
    h.runtime.decideHost(h.runtime.hostApproval!, false);
    await work;
  });

  test('no-focus conversation lists hosts freely and requires consent for its first target', () async {
    final h = _Harness(_diagnoseOther);
    addTearDown(h.close);
    final work = h.runtime.start('inspect host B', AgentScope(discoverHosts: true, conversationId: 'unfocused'));
    await _until(() => h.runtime.hostApproval != null);
    expect(h.backend.prepared, isEmpty);
    expect(h.runtime.hostApproval!.hostId, _other);
    h.runtime.decideHost(h.runtime.hostApproval!, false);
    await work;
    expect(h.runtime.resolvedHost, isNull);
  });

  test('declining a host suppresses repeated prompts in the same turn and performs no probes', () async {
    final h = _Harness((request, _, _) async* {
      if (_results(request).isEmpty) {
        yield ModelMessageComplete(
          ModelMessage(
            ModelRole.assistant,
            calls: [
              ModelCall('list', 'host_list', {}),
              for (var index = 0; index < 2; index++)
                ModelCall('remote-$index', 'diagnostics_collect', {
                  'hostId': _other.value,
                  'template': 'systemSummary',
                }),
            ],
          ),
        );
      } else {
        yield ModelMessageComplete(ModelMessage(ModelRole.assistant, text: 'declined'));
      }
    });
    addTearDown(h.close);
    final work = h.runtime.start('inspect host B', _conversationScope());
    await _until(() => h.runtime.hostApproval != null);
    h.runtime.decideHost(h.runtime.hostApproval!, false);
    await work;
    expect(_result(h.model.requests.last, 1), {'error': 'denied'});
    expect(_result(h.model.requests.last, 2), {'error': 'denied'});
    expect(h.backend.prepared, isEmpty);
  });

  test('Stop closes a pending host decision and stale consent cannot approve another turn', () async {
    final h = _Harness(_diagnoseOther);
    addTearDown(h.close);
    final first = h.runtime.start('inspect B', _conversationScope());
    await _until(() => h.runtime.hostApproval != null);
    final stale = h.runtime.hostApproval!;
    h.runtime.stop();
    expect(h.runtime.hostApproval, isNull);
    await first;
    final second = h.runtime.start('inspect B again', _conversationScope());
    await _until(() => h.runtime.hostApproval != null);
    final current = h.runtime.hostApproval!;
    h.runtime.decideHost(stale, true);
    await Future<void>.delayed(Duration.zero);
    expect(identical(h.runtime.hostApproval, current), isTrue);
    expect(h.backend.prepared, isEmpty);
    h.runtime.decideHost(current, false);
    await second;
  });

  test('a route changed during a pending confirmation cannot be approved by its stale dialog', () async {
    final h = _Harness(_diagnoseOther);
    addTearDown(h.close);
    final work = h.runtime.start('inspect B', _conversationScope());
    await _until(() => h.runtime.hostApproval != null);
    h.routes[_other] = 'changed-route';
    h.runtime.decideHost(h.runtime.hostApproval!, true);
    await work;
    expect(h.backend.prepared, isEmpty);
    expect(h.runtime.error, 'scopeChanged');
    expect(h.runtime.hostApproval, isNull);
    final retry = h.runtime.start('inspect changed B', _conversationScope());
    await _until(() => h.runtime.hostApproval != null);
    h.runtime.decideHost(h.runtime.hostApproval!, false);
    await retry;
  });

  for (final invalidation in ['route', 'model', 'credentials', 'deleted', 'new conversation']) {
    test('$invalidation requires host confirmation again', () async {
      final h = _Harness(_diagnoseOther);
      addTearDown(h.close);
      final first = h.runtime.start('inspect B', _conversationScope());
      await _until(() => h.runtime.hostApproval != null);
      h.runtime.decideHost(h.runtime.hostApproval!, true);
      await first;
      switch (invalidation) {
        case 'route':
          h.routes[_other] = 'revised-route';
        case 'model':
          h.revision++;
        case 'credentials':
          h.runtime.invalidateHostApprovals();
        case 'deleted':
          h.runtime.forgetConversation('conversation-a');
        case 'new conversation':
          break;
      }
      final next = h.runtime.start(
        'inspect B again',
        _conversationScope(id: invalidation == 'new conversation' ? 'new' : 'conversation-a'),
      );
      await _until(() => h.runtime.hostApproval != null);
      expect(h.runtime.hostApproval!.hostId, _other);
      expect(h.backend.prepared, [_other]);
      h.runtime.decideHost(h.runtime.hostApproval!, false);
      await next;
      expect(h.backend.prepared, [_other]);
    });
  }

  for (final target in [_host, _other]) {
    test('composition route round-trip permanently revokes consent for ${target.value}', () async {
      final hosts = _RouteHosts();
      final container = ProviderContainer(
        overrides: [
          ...appOverrides(),
          hostsProvider.overrideWith(() => hosts),
          hostTrustProvider.overrideWithValue(_RouteTrust()),
          connectionCredentialsProvider.overrideWithValue(_RouteCredentials()),
        ],
      );
      addTearDown(container.dispose);
      final routes = container.read(agentConversationRoutesProvider);
      final initial = routes();
      final h = _Harness((request, _, _) async* {
        if (_results(request).isEmpty) {
          yield ModelMessageComplete(
            ModelMessage(
              ModelRole.assistant,
              calls: [
                ModelCall('list', 'host_list', {}),
                ModelCall('diagnose', 'diagnostics_collect', {'hostId': target.value, 'template': 'systemSummary'}),
              ],
            ),
          );
        } else {
          yield ModelMessageComplete(ModelMessage(ModelRole.assistant, text: 'done'));
        }
      }, hostRoutes: routes);
      addTearDown(h.close);
      h.backend.target.stdout = _systemOutput;
      AgentScope scope(String id) => AgentScope(
        hosts: const [_host],
        conversationId: id,
        defaultHost: _host,
        defaultHostRoute: initial[_host],
        permissionMode: AgentPermissionMode.observe,
      );
      final first = h.runtime.start('inspect target', scope('original'));
      if (target == _other) {
        await _until(() => h.runtime.hostApproval != null);
        h.runtime.decideHost(h.runtime.hostApproval!, true);
      }
      await first;
      expect(h.backend.prepared, [target]);

      // No request or fingerprint read sees the intermediate route.
      hosts.replace([
        for (final id in [_host, _other])
          _RouteHosts.hostProfile(id, address: id == target ? 'changed.invalid' : 'example.invalid'),
      ]);
      hosts.replace([_RouteHosts.hostProfile(_host), _RouteHosts.hostProfile(_other)]);
      expect(routes()[target], isNot(initial[target]));
      final unchanged = target == _host ? _other : _host;
      expect(routes()[unchanged], initial[unchanged]);

      final retry = h.runtime.start('inspect target again', scope('original'));
      await _until(() => h.runtime.hostApproval != null);
      expect(h.runtime.hostApproval!.hostId, target);
      expect(h.backend.prepared, [target]);
      h.runtime.decideHost(h.runtime.hostApproval!, false);
      await retry;

      if (target == _host) {
        h.runtime.forgetConversation('original');
        final restored = h.runtime.start('restore original default', scope('original'));
        await _until(() => h.runtime.hostApproval != null);
        expect(h.runtime.hostApproval!.hostId, _host);
        expect(h.backend.prepared, [_host]);
        h.runtime.decideHost(h.runtime.hostApproval!, false);
        await restored;
      }
    });
  }

  test('restored default with a different route requires confirmation before preparing', () async {
    final h = _Harness((request, _, _) async* {
      if (_results(request).isEmpty) {
        yield ModelMessageComplete(_call('diagnostics_collect', {'hostId': _host.value, 'template': 'systemSummary'}));
      } else {
        yield ModelMessageComplete(ModelMessage(ModelRole.assistant, text: 'done'));
      }
    });
    addTearDown(h.close);
    h.routes[_host] = 'new-route-a';
    final work = h.runtime.start('inspect default', _conversationScope());
    await _until(() => h.runtime.hostApproval != null);
    expect(h.runtime.hostApproval!.hostId, _host);
    expect(h.backend.prepared, isEmpty);
    h.runtime.decideHost(h.runtime.hostApproval!, false);
    await work;
  });

  test('observe omits command tools and refuses a forged direct dispatch before connecting', () async {
    final entered = Completer<void>();
    final h = _Harness((_, cancel, _) async* {
      entered.complete();
      await cancel.whenCancelled;
    });
    addTearDown(h.close);
    final work = h.runtime.start(
      'inspect selected host',
      AgentScope(hosts: const [_host], permissionMode: AgentPermissionMode.observe),
    );
    await entered.future;
    final request = h.model.requests.single;
    expect(request.tools.map((tool) => tool.name), isNot(contains('command_execute')));
    expect(request.tools.map((tool) => tool.name), contains('diagnostics_collect'));
    expect(jsonDecode(request.messages.single.text)['permissionMode'], 'observe');
    final result = await h.runtime.dispatcher.dispatch(
      'agent.execute',
      _command(),
      RequestContext(Origin.agent, authority: h.runtime),
    );
    expect(result, isA<Err<Object?>>());
    expect((result as Err<Object?>).error.code, 'notExposed');
    expect(h.backend.prepared, isEmpty);
    expect(h.runtime.approval, isNull);
    h.runtime.stop();
    await work;
  });

  for (final mode in [AgentPermissionMode.observe, AgentPermissionMode.confirm]) {
    for (final template in DiagnosticTemplate.values) {
      test('$mode declining ${template.name} prevents preparation, probes and repeated read prompts', () async {
        final h = _Harness(
          (_, _, index) => _oneCall(
            ModelMessage(
              ModelRole.assistant,
              calls: [
                for (var index = 0; index < 2; index++)
                  ModelCall('read-$index', 'diagnostics_collect', {'hostId': _host.value, 'template': template.name}),
              ],
            ),
            index,
          ),
          approveDiagnostics: false,
        );
        addTearDown(h.close);
        var prompts = 0;
        AgentApproval? last;
        h.runtime.addListener(() {
          final pending = h.runtime.approval;
          if (pending != null && !identical(last, pending)) {
            last = pending;
            prompts++;
          }
        });
        final work = h.runtime.start(
          'inspect the selected host',
          AgentScope(hosts: const [_host], permissionMode: mode),
        );
        await _until(() => h.runtime.approval != null);
        final read = h.runtime.approval!;
        expect(read.capability, 'agent.diagnose');
        expect(read.template, template.name);
        expect(read.command, diagnosticCommand(template));
        expect(read.target, 'selected host');
        expect(read.cwd, '/');
        expect(h.backend.prepared, isEmpty);
        expect(h.backend.target.probes, 0);
        expect(h.backend.target.commands, isEmpty);
        h.runtime.approve(false, expected: read);
        await work;
        expect(prompts, 1);
        expect(_result(h.model.requests.last, 0), {'error': 'denied'});
        expect(_result(h.model.requests.last, 1), {'error': 'denied'});
        expect(h.backend.prepared, isEmpty);
        expect(h.backend.target.probes, 0);
        expect(h.backend.target.commands, isEmpty);
        expect(h.journal.records, isEmpty);
      });
    }

    test('$mode read approval automatically shares only the bounded diagnostic projection', () async {
      final h = _Harness(
        (_, _, index) =>
            _oneCall(_call('diagnostics_collect', {'hostId': _host.value, 'template': 'systemSummary'}), index),
        approveDiagnostics: false,
      );
      addTearDown(h.close);
      h.backend.target.stdout = '$_systemOutput$_privateOutput\n';
      final work = h.runtime.start('inspect the selected host', AgentScope(hosts: const [_host], permissionMode: mode));
      await _until(() => h.runtime.approval != null);
      expect(h.backend.prepared, isEmpty);
      h.runtime.approve(true, expected: h.runtime.approval!);
      await work;
      expect(h.backend.prepared, [_host]);
      expect(h.backend.target.probes, 1);
      expect(h.backend.target.commands, hasLength(1));
      final execution = h.runtime.executions.single;
      expect(execution.output!.stdout, contains(_privateOutput));
      expect(execution.sharedText, isNot(contains(_privateOutput)));
      expect(jsonDecode(execution.sharedText!), containsPair('system', 'Linux'));
      expect(h.model.requests, hasLength(2));
      expect(_result(h.model.requests.last)['data'], containsPair('system', 'Linux'));
      expect(_result(h.model.requests.last).containsKey('text'), isFalse);
      expect(_requestText(h.model.requests.last), isNot(contains(_privateOutput)));
      expect(h.journal.records, isEmpty);
    });
  }

  test('auto executes and shares only a bounded projection without approval cards', () async {
    final h = _Harness((request, _, index) async* {
      if (index == 0) {
        yield ModelMessageComplete(_call('command_execute', _command()));
      } else if (index == 1) {
        final handle = _result(request)['handle'];
        yield ModelMessageComplete(
          ModelMessage(
            ModelRole.assistant,
            calls: [
              ModelCall('same-host', 'output_read', {'hostId': _host.value, 'handle': handle}),
              ModelCall('other-host', 'output_read', {'hostId': _other.value, 'handle': handle}),
            ],
          ),
        );
      } else {
        yield ModelMessageComplete(ModelMessage(ModelRole.assistant, text: 'done'));
      }
    }, approveDiagnostics: false);
    addTearDown(h.close);
    h.backend.target.stdout = '${List.filled(20000, 'x').join()}$_privateOutput';
    var actionCards = 0;
    h.runtime.addListener(() {
      if (h.runtime.approval != null) actionCards++;
    });
    await h.runtime.start(
      'run selected command',
      AgentScope(hosts: const [_host], permissionMode: AgentPermissionMode.auto),
    );
    expect(h.runtime.permissionMode, AgentPermissionMode.auto);
    expect(actionCards, 0);
    expect(h.backend.prepared, [_host]);
    expect(h.backend.target.commands, hasLength(1));
    expect(h.journal.records.map((record) => record.state), [OperationState.intent, OperationState.completed]);
    final shared = _result(h.model.requests[1])['text'] as String;
    expect(shared, isNotEmpty);
    expect(utf8.encode(jsonEncode(shared)).length, lessThanOrEqualTo(6500));
    expect(h.backend.target.stdout.startsWith(shared), isTrue);
    expect(h.runtime.executions.first.output!.stdout, contains(_privateOutput));
    expect(h.runtime.executions.first.sharedText, shared);
    expect(_result(h.model.requests.last, 1)['text'], shared);
    expect(_result(h.model.requests.last, 2), {'error': 'outsideScope'});
    expect(h.model.requests.every((request) => !_requestText(request).contains(_privateOutput)), isTrue);
  });

  test('auto shares the fixed diagnostic projection without raw stdout or approval cards', () async {
    final h = _Harness(
      (_, _, index) =>
          _oneCall(_call('diagnostics_collect', {'hostId': _host.value, 'template': 'systemSummary'}), index),
      approveDiagnostics: false,
    );
    addTearDown(h.close);
    h.backend.target.stdout = '$_systemOutput$_privateOutput\n';
    var cards = 0;
    h.runtime.addListener(() {
      if (h.runtime.approval != null) cards++;
    });
    await h.runtime.start(
      'inspect selected host',
      AgentScope(hosts: const [_host], permissionMode: AgentPermissionMode.auto),
    );
    expect(cards, 0);
    expect(h.backend.target.commands, hasLength(1));
    expect(_result(h.model.requests.last)['data'], containsPair('system', 'Linux'));
    expect(_requestText(h.model.requests.last), isNot(contains(_privateOutput)));
    expect(h.journal.records, isEmpty);
  });

  for (final diagnostic in [true, false]) {
    final tool = diagnostic ? 'diagnostics_collect' : 'command_execute';
    final call = diagnostic
        ? _call(tool, {'hostId': _host.value, 'template': 'systemSummary'})
        : _call(tool, _command());

    test('review allow authorizes $tool and its projection through isolated metadata requests', () async {
      final reviewStates = <({int prepared, int commands})>[];
      late _Harness h;
      h = _Harness(
        (_, _, index) => _oneCall(
          ModelMessage(ModelRole.assistant, calls: call.calls, opaque: 'private-agent-protocol-state'),
          index,
        ),
        approveDiagnostics: false,
        review: (_, _, _) {
          reviewStates.add((prepared: h.backend.prepared.length, commands: h.backend.target.commands.length));
          return _reviewReply('allow');
        },
      );
      addTearDown(h.close);
      h.backend.target.stdout = diagnostic ? '$_systemOutput$_privateOutput\n' : _privateOutput;
      var cards = 0;
      h.runtime.addListener(() {
        if (h.runtime.approval != null) cards++;
      });
      await h.runtime.start(
        'inspect this selected host',
        AgentScope(hosts: const [_host], permissionMode: AgentPermissionMode.review),
      );
      expect(cards, 0);
      expect(h.runtime.phase, AgentPhase.completed);
      expect(h.model.requests, hasLength(2));
      expect(h.model.reviewRequests, hasLength(1));
      expect(reviewStates.single, (prepared: diagnostic ? 0 : 1, commands: 0));
      expect(h.backend.prepared, [_host]);
      expect(h.backend.target.commands, hasLength(1));
      final access = h.model.reviewRequests.first;
      expect(access.messages.single.text, contains('"kind":"access"'));
      expect(access.messages.single.text, contains('"hostId":"host-a"'));
      expect(access.messages.single.text, contains('"capabilityVersion":1'));
      expect(access.messages.single.text, contains('"timeoutSeconds":${diagnostic ? 15 : 60}'));
      if (diagnostic) expect(access.messages.single.text, contains('"templateVersion":1'));
      expect(access.messages.single.text, isNot(contains('"kind":"share"')));
      expect(
        access.messages.single.text,
        contains(jsonEncode(diagnostic ? diagnosticCommand(DiagnosticTemplate.systemSummary) : 'printf result')),
      );
      for (final request in h.model.reviewRequests) {
        expect(request.profile.model, h.profile.model);
        expect(request.profile.tools, isFalse);
        expect(request.profile.maxOutputTokens, lessThanOrEqualTo(256));
        expect(request.tools, isEmpty);
        expect(request.messages, hasLength(1));
        expect(request.messages.single.role, ModelRole.user);
        expect(request.messages.single.calls, isEmpty);
        expect(request.messages.single.opaque, isNull);
        expect(_requestText(request), contains('inspect this selected host'));
        expect(_requestText(request), contains('selected host'));
        expect(_requestText(request), isNot(contains(h.backend.target.display)));
        expect(_requestText(request), isNot(contains(_privateOutput)));
        expect(_requestText(request), isNot(contains('private-agent-protocol-state')));
      }
      final result = _result(h.model.requests.last);
      if (diagnostic) {
        expect(result['data'], containsPair('system', 'Linux'));
        expect(_requestText(h.model.requests.last), isNot(contains(_privateOutput)));
        expect(h.journal.records, isEmpty);
      } else {
        expect(result['text'], _privateOutput);
        expect(h.journal.records.map((record) => record.state), [OperationState.intent, OperationState.completed]);
      }
    });

    test('review deny prevents $tool without opening a manual approval', () async {
      final h = _Harness(
        (_, _, index) => _oneCall(call, index),
        approveDiagnostics: false,
        review: (_, _, _) => _reviewReply('deny'),
      );
      addTearDown(h.close);
      var cards = 0;
      h.runtime.addListener(() {
        if (h.runtime.approval != null) cards++;
      });
      await h.runtime.start(
        'inspect this selected host',
        AgentScope(hosts: const [_host], permissionMode: AgentPermissionMode.review),
      );
      expect(cards, 0);
      expect(h.model.reviewRequests, hasLength(1));
      expect(h.backend.target.commands, isEmpty);
      expect(h.journal.records, isEmpty);
      expect(h.backend.target.probes, 0);
      expect(_result(h.model.requests.last), {'error': 'denied'});
      if (diagnostic) {
        expect(h.backend.prepared, isEmpty);
        expect(h.backend.target.probes, 0);
      }
    });
  }

  for (final response in ['ask', 'invalid', 'error']) {
    test('review $response falls back to exact manual read approval including its bounded result', () async {
      final h = _Harness(
        (_, _, index) =>
            _oneCall(_call('diagnostics_collect', {'hostId': _host.value, 'template': 'systemSummary'}), index),
        approveDiagnostics: false,
        review: (_, _, _) async* {
          if (response == 'error') throw const ModelFailure('network');
          if (response == 'invalid') {
            yield ModelMessageComplete(ModelMessage(ModelRole.assistant, text: '{"decision":"allow","reason":"safe"}'));
          } else {
            yield* _reviewReply('ask');
          }
        },
      );
      addTearDown(h.close);
      h.backend.target.stdout = _systemOutput;
      final work = h.runtime.start(
        'inspect selected host',
        AgentScope(hosts: const [_host], permissionMode: AgentPermissionMode.review),
      );
      await _until(() => h.runtime.approval != null);
      expect(h.runtime.approval!.template, 'systemSummary');
      expect(h.runtime.approval!.command, diagnosticCommand(DiagnosticTemplate.systemSummary));
      expect(h.backend.prepared, isEmpty);
      expect(h.backend.target.probes, 0);
      expect(h.backend.target.commands, isEmpty);
      expect(h.model.reviewRequests, hasLength(1));
      h.runtime.approve(true, expected: h.runtime.approval!);
      await work;
      expect(h.backend.target.commands, hasLength(1));
      expect(h.model.requests, hasLength(2));
      expect(h.model.reviewRequests, hasLength(1));
      expect(jsonDecode(h.runtime.executions.single.sharedText!), containsPair('system', 'Linux'));
      expect(_result(h.model.requests.last)['data'], containsPair('system', 'Linux'));
      expect(_result(h.model.requests.last).containsKey('output'), isFalse);
    });
  }

  test('review approves the command once and output_read only rereads its bounded result', () async {
    final h = _Harness(
      (request, _, index) async* {
        if (index == 0) {
          yield ModelMessageComplete(_call('command_execute', _command()));
        } else if (index == 1) {
          final handle = _result(request)['handle'];
          yield ModelMessageComplete(_call('output_read', {'hostId': _host.value, 'handle': handle}, 'read'));
        } else {
          yield ModelMessageComplete(ModelMessage(ModelRole.assistant, text: 'done'));
        }
      },
      approveDiagnostics: false,
      review: (_, _, index) => _reviewReply(index == 0 ? 'allow' : 'deny'),
    );
    addTearDown(h.close);
    await h.runtime.start(
      'run selected command',
      AgentScope(hosts: const [_host], permissionMode: AgentPermissionMode.review),
    );
    expect(h.backend.target.commands, hasLength(1));
    expect(h.model.reviewRequests, hasLength(1));
    expect(h.model.reviewRequests.every((request) => !_requestText(request).contains(_privateOutput)), isTrue);
    expect(_result(h.model.requests[1])['text'], _privateOutput);
    expect(_result(h.model.requests[1]).containsKey('output'), isFalse);
    expect(_result(h.model.requests.last, 1)['text'], _privateOutput);
    expect(h.runtime.executions.first.sharedText, _privateOutput);
  });

  for (final diagnostic in [true, false]) {
    test('Stop cancels a pending ${diagnostic ? 'diagnostic' : 'command'} review and ignores a late allow', () async {
      final lateDecision = Completer<void>();
      final call = diagnostic
          ? _call('diagnostics_collect', {'hostId': _host.value, 'template': 'systemSummary'})
          : _call('command_execute', _command());
      final h = _Harness(
        (_, _, index) => _oneCall(call, index),
        approveDiagnostics: false,
        review: (_, _, _) async* {
          await lateDecision.future;
          yield* _reviewReply('allow');
        },
      );
      addTearDown(h.close);
      addTearDown(() {
        if (!lateDecision.isCompleted) lateDecision.complete();
      });
      final work = h.runtime.start(
        'inspect selected host',
        AgentScope(hosts: const [_host], permissionMode: AgentPermissionMode.review),
      );
      await _until(() => h.model.reviewRequests.isNotEmpty);
      expect(h.runtime.reviewing, isTrue);
      expect(h.backend.prepared, diagnostic ? isEmpty : [_host]);
      h.runtime.stop();
      await work;
      expect(h.runtime.phase, AgentPhase.cancelled);
      expect(h.model.reviewCancellations.single.isCancelled, isTrue);
      expect(h.model.requests, hasLength(1));
      lateDecision.complete();
      await pumpEventQueue();
      expect(h.backend.prepared, diagnostic ? isEmpty : [_host]);
      expect(h.backend.target.probes, 0);
      expect(h.backend.target.commands, isEmpty);
      expect(h.journal.records, isEmpty);
      expect(h.runtime.approval, isNull);
      expect(h.runtime.reviewing, isFalse);
      expect(h.model.requests, hasLength(1));
    });
  }

  test('a cancelled reviewer cannot replace or clear a new turn approval during late cleanup', () async {
    final lateDecision = Completer<void>();
    final h = _Harness(
      (_, cancel, index) async* {
        if (index == 0) {
          yield ModelMessageComplete(
            _call('diagnostics_collect', {'hostId': _host.value, 'template': 'systemSummary'}),
          );
        } else {
          await cancel.whenCancelled;
        }
      },
      approveDiagnostics: false,
      review: (_, _, _) async* {
        await lateDecision.future;
        yield* _reviewReply('allow');
      },
    );
    addTearDown(h.close);
    addTearDown(() {
      if (!lateDecision.isCompleted) lateDecision.complete();
    });
    Future<void>? nextTurn;
    Future<Result<Object?>>? nextDispatch;
    AgentApproval? nextApproval;
    var restart = false;
    h.runtime.addListener(() {
      if (!restart || h.runtime.busy) return;
      restart = false;
      // Re-enter at the first idle notification while the old policy can still be unwinding.
      nextTurn = h.runtime.start('inspect storage instead', AgentScope(hosts: const [_host]));
      nextDispatch = h.runtime.dispatcher.dispatch('agent.diagnose', {
        'hostId': _host.value,
        'template': 'storageCapacity',
      }, RequestContext(Origin.agent, authority: h.runtime));
      nextApproval = h.runtime.approval;
    });
    final oldTurn = h.runtime.start(
      'inspect system information',
      AgentScope(hosts: const [_host], permissionMode: AgentPermissionMode.review),
    );
    await _until(() => h.model.reviewRequests.isNotEmpty);
    restart = true;
    h.runtime.stop();
    await oldTurn;
    expect(nextApproval, isNotNull);
    expect(nextApproval!.template, 'storageCapacity');
    lateDecision.complete();
    await pumpEventQueue();
    expect(h.runtime.approval, same(nextApproval));
    expect(h.runtime.permissionMode, AgentPermissionMode.confirm);
    expect(h.backend.prepared, isEmpty);
    expect(h.backend.target.probes, 0);
    expect(h.backend.target.commands, isEmpty);
    expect(h.journal.records, isEmpty);
    h.runtime.approve(false, expected: nextApproval!);
    final result = await nextDispatch!;
    expect(result, isA<Err<Object?>>());
    expect((result as Err<Object?>).error.code, 'denied');
    h.runtime.stop();
    await nextTurn!;
    expect(h.model.requests, hasLength(2));
    expect(h.model.reviewRequests, hasLength(1));
  });

  test('auto still blocks execution when intent cannot be persisted', () async {
    final h = _Harness((_, _, index) => _oneCall(_call('command_execute', _command()), index));
    addTearDown(h.close);
    h.journal.failIntent = true;
    await h.runtime.start(
      'run selected command',
      AgentScope(hosts: const [_host], permissionMode: AgentPermissionMode.auto),
    );
    expect(h.backend.target.commands, isEmpty);
    expect(h.runtime.approval, isNull);
    expect(_result(h.model.requests.last)['error'], 'journalFailed');
  });

  test('command purpose is carried through approval to the execution card', () async {
    final h = _Harness(
      (_, _, index) => _oneCall(_call('command_execute', {..._command(), 'purpose': 'Check disk usage'}), index),
    );
    addTearDown(h.close);
    final work = h.start();
    await _until(() => h.runtime.approval != null);
    expect(h.runtime.approval!.purpose, 'Check disk usage');
    h.runtime.approve(true, expected: h.runtime.approval!);
    await work;
    expect(h.runtime.executions.single.purpose, 'Check disk usage');
    expect(h.backend.target.commands, hasLength(1));
  });

  test('user-visible model text follows the frozen UI language', () async {
    final chinese = _Harness((_, _, _) async* {
      yield ModelMessageComplete(ModelMessage(ModelRole.assistant, text: 'ok'));
    }, language: 'zh');
    addTearDown(chinese.close);
    await chinese.start();
    expect(chinese.model.requests.single.system, contains('Simplified Chinese'));

    final english = _Harness((_, _, _) async* {
      yield ModelMessageComplete(ModelMessage(ModelRole.assistant, text: 'ok'));
    }, language: 'en');
    addTearDown(english.close);
    await english.start();
    expect(english.model.requests.single.system, contains('in English'));
  });

  test('default scope requires confirmation and context occupancy survives completion until clear', () async {
    final h = _Harness((_, _, index) => _oneCall(_call('command_execute', _command()), index));
    addTearDown(h.close);
    expect(h.runtime.contextUsedTokens, 0);
    expect(h.runtime.contextWindow, 0);
    expect(h.runtime.contextUsageRatio, 0);
    final work = h.start();
    await _until(() => h.runtime.approval != null);
    expect(h.runtime.permissionMode, AgentPermissionMode.confirm);
    expect(h.backend.target.commands, isEmpty);
    expect(h.runtime.contextWindow, h.profile.contextWindow);
    expect(h.runtime.contextUsedTokens, greaterThan(0));
    expect(h.runtime.contextUsageRatio, greaterThan(0));
    h.runtime.approve(false, expected: h.runtime.approval!);
    await work;
    expect(h.runtime.contextUsedTokens, greaterThan(0));
    h.runtime.clear();
    expect(h.runtime.contextUsedTokens, 0);
    expect(h.runtime.contextWindow, 0);
    expect(h.runtime.permissionMode, AgentPermissionMode.confirm);
  });

  test('context estimate includes complete response text and resets when history is restored', () async {
    final entered = Completer<void>(), finish = Completer<void>();
    final h = _Harness((_, _, _) async* {
      yield const ModelTextDelta('streamed response');
      entered.complete();
      await finish.future;
      yield ModelMessageComplete(ModelMessage(ModelRole.assistant, text: 'streamed response with completed text'));
    });
    addTearDown(h.close);
    final work = h.start();
    await entered.future;
    final streamed = h.runtime.contextUsedTokens;
    expect(streamed, greaterThan(0));
    finish.complete();
    await work;
    expect(h.runtime.contextUsedTokens, greaterThan(streamed));
    expect(h.runtime.contextUsageRatio, inInclusiveRange(0, 1));
    h.runtime.restoreConversation([ConversationEntry(kind: ConversationEntryKind.user, text: 'old text')]);
    expect(h.runtime.contextUsedTokens, 0);
    expect(h.runtime.contextWindow, 0);
  });

  test('compaction keeps the newest complete tool group and records older outcomes as untrusted text', () {
    final profile = ModelProfile(
      protocol: ModelProtocol.openai,
      endpoint: 'https://model.example.invalid/v1',
      model: 'small-window',
      contextWindow: 8000,
      maxOutputTokens: 1000,
    );
    final context = AgentContext(input: 'keep the exact current goal', goalInput: 'keep the exact current goal');
    context.add(
      ModelMessage(
        ModelRole.assistant,
        text: 'prior proposed work',
        calls: [
          ModelCall('old-effect', 'command_execute', {'command': 'never run this again'}),
        ],
      ),
    );
    context.add(
      ModelMessage(
        ModelRole.tool,
        toolCallId: 'old-effect',
        text: jsonEncode({'exitCode': 0, 'text': List.filled(7000, 'x').join(), 'handle': 'old-evidence'}),
      ),
    );
    final latest = ModelMessage(
      ModelRole.assistant,
      calls: [
        ModelCall('latest-a', 'output_read', {'handle': 'current-evidence'}),
        ModelCall('latest-b', 'host_list', {}),
      ],
    );
    final firstResult = ModelMessage(ModelRole.tool, toolCallId: 'latest-a', text: '{"text":"recent approved data"}');
    final secondResult = ModelMessage(ModelRole.tool, toolCallId: 'latest-b', text: '[]');
    context
      ..add(latest)
      ..add(firstResult)
      ..add(secondResult);

    expect(context.prepare(profile, 'system permissions stay fixed', const []), isTrue);
    expect(context.messages.skip(1), [latest, firstResult, secondResult]);
    final root = jsonDecode(context.messages.first.text) as Map;
    expect(root['currentRequest'], 'keep the exact current goal');
    final summary = root['contextSummary'] as Map;
    expect(summary['untrustedData'], isTrue);
    expect(summary['truncated'], isTrue);
    expect(jsonEncode(summary), contains('old-effect'));
    expect(jsonEncode(summary), contains('exitCode'));
    expect(jsonEncode(summary), isNot(contains('never run this again')));
    expect(jsonEncode(summary), isNot(contains('old-evidence')));
    expect(summary['protocolRestarted'], isFalse);
  });

  test('runtime compacts a long approved projection without repeating side effects or losing its goal', () async {
    final selected = List.filled(6400, 's').join();
    final h = _Harness((_, _, index) async* {
      if (index == 0) {
        yield ModelMessageComplete(_call('command_execute', _command(), 'executed-once'));
      } else {
        yield ModelMessageComplete(ModelMessage(ModelRole.assistant, text: 'result preserved'));
      }
    });
    addTearDown(h.close);
    h.profile = ModelProfile(
      protocol: h.profile.protocol,
      endpoint: h.profile.endpoint,
      model: h.profile.model,
      tools: true,
      contextWindow: 12000,
      maxOutputTokens: 1000,
    );
    h.backend.target.stdout = selected;
    var compactNotifications = 0, approvals = 0;
    AgentApproval? seen;
    h.runtime.addListener(() {
      if (h.runtime.contextCompacted) compactNotifications++;
      if (h.runtime.approval case final approval?) {
        if (!identical(seen, approval)) {
          seen = approval;
          approvals++;
        }
      }
    });
    final turn = h.start();
    await _until(() => h.runtime.approval != null);
    h.runtime.approve(true, expected: h.runtime.approval!);
    await turn;

    expect(h.runtime.phase, AgentPhase.completed);
    expect(h.runtime.contextCompacted, isTrue);
    final timeline = h.runtime.timeline, notice = timeline.indexWhere((entry) => entry is AgentContextNotice);
    expect(timeline.whereType<AgentContextNotice>(), hasLength(1));
    expect(timeline[notice - 1], isA<AgentExecution>());
    expect((timeline[notice + 1] as AgentChatEntry).text, 'result preserved');
    expect(h.runtime.contextUsedTokens, greaterThan(0));
    expect(h.runtime.contextUsageRatio, inInclusiveRange(0, 1));
    expect(compactNotifications, greaterThan(0));
    expect(h.backend.target.commands, hasLength(1));
    expect(approvals, 1);
    expect(h.journal.records.map((record) => record.state), [OperationState.intent, OperationState.completed]);
    expect(h.model.requests, hasLength(2));
    final second = h.model.requests.last;
    expect(_requestText(second), contains('check the selected host'));
    expect(_requestText(second), contains('host-a'));
    expect(_requestText(second), isNot(contains(_privateOutput)));
    expect(_requestText(second), contains('executed-once'));
    expect(_requestText(second), contains('exitCode'));
    expect(second.messages, hasLength(1), reason: 'an oversized complete group becomes plain data as a whole');
    expect(second.messages.single.calls, isEmpty);
    expect(second.messages.single.role, ModelRole.user);
    expect((jsonDecode(second.messages.single.text) as Map)['contextSummary'], containsPair('truncated', true));
    expect(h.runtime.executions.single.sharedText, selected);
    h.runtime.clear();
    expect(h.runtime.contextCompacted, isFalse);
  });

  test('compaction restarts opaque protocol context with data and leaves unmatched groups unusable', () async {
    final opaque = Object();
    final h = _Harness((_, _, index) async* {
      if (index == 0) {
        yield ModelMessageComplete(
          ModelMessage(ModelRole.assistant, opaque: opaque, calls: [ModelCall('old-signed-call', 'host_list', {})]),
        );
      } else {
        yield ModelMessageComplete(ModelMessage(ModelRole.assistant, text: 'fresh protocol context'));
      }
    });
    addTearDown(h.close);
    h.profile = ModelProfile(
      protocol: ModelProtocol.anthropic,
      endpoint: h.profile.endpoint,
      model: h.profile.model,
      tools: true,
      contextWindow: 32768,
    );
    await h.start();
    expect(h.runtime.phase, AgentPhase.completed);
    expect(h.runtime.contextCompacted, isTrue);
    final request = h.model.requests.last;
    expect(request.messages, hasLength(1));
    expect(request.messages.every((message) => message.opaque == null && message.calls.isEmpty), isTrue);
    final summary = (jsonDecode(request.messages.single.text) as Map)['contextSummary'] as Map;
    expect(summary['protocolRestarted'], isTrue);
    expect(h.backend.target.commands, isEmpty);

    final context = AgentContext(input: 'goal', goalInput: 'goal');
    context.add(ModelMessage(ModelRole.assistant, opaque: opaque, calls: [ModelCall('pending', 'host_list', {})]));
    expect(
      () => context.prepare(h.profile, '', const []),
      throwsA(isA<AgentFailure>().having((failure) => failure.code, 'code', 'protocol')),
    );
  });

  test('context compaction can shrink authorized prior history but cannot drop the current goal', () {
    final profile = ModelProfile(
      protocol: ModelProtocol.openai,
      endpoint: 'https://model.example.invalid/v1',
      model: 'small-window',
      contextWindow: 6000,
      maxOutputTokens: 1000,
    );
    final previous = {
      'entries': [
        {'kind': 'assistant', 'text': List.filled(10000, 'h').join()},
      ],
      'truncated': false,
    };
    final context = AgentContext(
      input: jsonEncode({'goal': 'current exact user goal', 'conversationHistory': previous}),
      goalInput: 'current exact user goal',
      previous: previous,
    );
    expect(context.prepare(profile, 'fixed constraints', const []), isTrue);
    final root = jsonDecode(context.messages.single.text) as Map;
    expect(root['currentRequest'], 'current exact user goal');
    expect(root['contextSummary'], containsPair('truncated', true));
    expect(jsonEncode(root['contextSummary']), contains('conversationHistory'));

    final tooLarge = List.filled(10000, 'g').join();
    final oversized = AgentContext(input: tooLarge, goalInput: tooLarge);
    expect(
      () => oversized.prepare(profile, 'fixed constraints', const []),
      throwsA(isA<AgentFailure>().having((failure) => failure.code, 'code', 'contextLimit')),
    );
  });

  test('restoring history only rebuilds readable entries and clears raw buffers', () async {
    final h = _Harness((_, _, _) async* {
      yield ModelMessageComplete(ModelMessage(ModelRole.assistant, text: 'unused'));
    });
    addTearDown(h.close);
    final output = h.runtime.outputs.create('old-owner', _host, h.profile.identity, 0);
    h.runtime.outputs.append(output, false, Uint8List.fromList(utf8.encode(_privateOutput)));
    h.runtime.outputs.share(output, 'previously approved projection');

    h.runtime.restoreConversation(const [
      ConversationEntry(kind: ConversationEntryKind.user, text: 'previous question'),
      ConversationEntry(kind: ConversationEntryKind.assistant, text: 'previous answer'),
      ConversationEntry(
        kind: ConversationEntryKind.execution,
        text: 'previously approved projection',
        capability: 'agent.execute',
        state: 'completed',
        exitCode: 0,
        truncated: true,
      ),
      ConversationEntry(
        kind: ConversationEntryKind.execution,
        text: '',
        capability: 'agent.diagnose',
        state: 'running',
      ),
    ]);

    expect(h.runtime.phase, AgentPhase.idle);
    expect(h.runtime.busy, isFalse);
    expect(h.runtime.messages.map((entry) => [entry.role, entry.text]), [
      ['user', 'previous question'],
      ['assistant', 'previous answer'],
    ]);
    expect(h.runtime.timeline, hasLength(4));
    final restored = h.runtime.executions.first;
    expect(restored.archived, isTrue);
    expect(restored.output, isNull);
    expect(restored.target, isEmpty);
    expect(restored.command, isEmpty);
    expect(restored.cwd, isEmpty);
    expect(restored.sharedText, 'previously approved projection');
    expect(restored.historyTruncated, isTrue);
    expect(restored.exitCode, 0);
    expect(h.runtime.executions.last.state, 'interrupted');
    expect(h.runtime.executions.last.sharedText, isNull);
    expect(h.runtime.outputs.count, 0);
    expect(h.runtime.approval, isNull);
    expect(h.model.requests, isEmpty);
    expect(h.backend.prepared, isEmpty);
    expect(h.backend.target.commands, isEmpty);
    expect(h.journal.records, isEmpty);
  });

  test('restoring tool records preserves stopped states and interrupts unfinished reads without replay', () async {
    final h = _Harness((_, _, _) async* {
      yield ModelMessageComplete(ModelMessage(ModelRole.assistant, text: 'unused'));
    });
    addTearDown(h.close);
    h.runtime.restoreConversation(const [
      ConversationEntry(kind: ConversationEntryKind.execution, text: '', capability: 'agent.hosts', state: 'completed'),
      ConversationEntry(kind: ConversationEntryKind.execution, text: '', capability: 'agent.output', state: 'running'),
      ConversationEntry(
        kind: ConversationEntryKind.execution,
        text: '',
        capability: 'agent.execute',
        state: 'cancelled',
      ),
      ConversationEntry(
        kind: ConversationEntryKind.execution,
        text: '',
        capability: 'agent.diagnose',
        state: 'pending',
      ),
    ]);
    expect(h.runtime.executions.map((entry) => entry.toolName), [
      'host_list',
      'output_read',
      'command_execute',
      'diagnostics_collect',
    ]);
    expect(h.runtime.executions.map((entry) => entry.state), ['completed', 'interrupted', 'cancelled', 'interrupted']);
    expect(h.runtime.executions.every((entry) => entry.archived && entry.output == null), isTrue);
    expect(h.model.requests, isEmpty);
    expect(h.backend.prepared, isEmpty);
    expect(h.backend.target.commands, isEmpty);
  });

  test('a new conversation turn uses plain history data without old protocol state or evidence rights', () async {
    final opaque = Object();
    late String oldHandle;
    final h = _Harness((request, _, index) async* {
      if (index == 0) {
        yield ModelMessageComplete(
          ModelMessage(
            ModelRole.assistant,
            calls: [ModelCall('old-call', 'command_execute', _command(command: 'printf private-command'))],
          ),
        );
      } else if (index == 1) {
        oldHandle = _result(request)['handle'] as String;
        yield ModelMessageComplete(ModelMessage(ModelRole.assistant, text: 'first answer', opaque: opaque));
      } else if (index == 2) {
        yield ModelMessageComplete(_call('output_read', {'hostId': 'host-a', 'handle': oldHandle}, 'new-read'));
      } else {
        yield ModelMessageComplete(ModelMessage(ModelRole.assistant, text: 'the previous handle is unavailable'));
      }
    });
    addTearDown(h.close);
    h.backend.target.stdout = 'approved bounded result';
    final first = h.runtime.startConversation('first question', AgentScope(hosts: const [_host]), const []);
    await _until(() => h.runtime.approval != null);
    final oldApproval = h.runtime.approval!;
    h.runtime.approve(true, expected: oldApproval);
    await first;
    expect(h.runtime.executions.single.sharedText, 'approved bounded result');
    expect(h.runtime.executions.single.output!.stdout, 'approved bounded result');
    final entries = [
      for (final entry in h.runtime.timeline)
        switch (entry) {
          AgentChatEntry(:final role, :final text) => ConversationEntry(
            kind: role == 'user' ? ConversationEntryKind.user : ConversationEntryKind.assistant,
            text: text,
          ),
          AgentExecution(:final capability, :final state, :final exitCode, :final sharedText) => ConversationEntry(
            kind: ConversationEntryKind.execution,
            text: sharedText ?? '',
            capability: capability,
            state: state,
            exitCode: exitCode,
          ),
          AgentContextNotice() => null,
        },
    ].nonNulls.toList();

    h.runtime.restoreConversation(entries);
    h.runtime.approve(true, expected: oldApproval);
    await h.runtime.startConversation('follow-up question', AgentScope(hosts: const [_host]), entries);

    final request = h.model.requests[2];
    expect(request.messages, hasLength(1));
    expect(request.messages.single.role, ModelRole.user);
    expect(request.messages.single.calls, isEmpty);
    expect(request.messages.single.toolCallId, isNull);
    expect(request.messages.single.opaque, isNull);
    final input = jsonDecode(request.messages.single.text) as Map;
    expect(input['goal'], 'follow-up question');
    final history = input['conversationHistory'] as Map;
    expect(history['truncated'], isFalse);
    expect(history['entries'], contains(containsPair('text', 'approved bounded result')));
    expect(_requestText(request), contains('first answer'));
    expect(_requestText(request), isNot(contains('private-command')));
    expect(_requestText(request), isNot(contains(_privateOutput)));
    expect(_requestText(request), isNot(contains(oldHandle)));
    expect(_requestText(request), isNot(contains('old-call')));
    expect(_requestText(request), isNot(contains('stale selection')));
    expect(_result(h.model.requests.last), {'error': 'unavailable'});
    expect(h.backend.target.commands, hasLength(1));
    expect(h.runtime.messages.where((entry) => entry.role == 'user').map((entry) => entry.text), [
      'first question',
      'follow-up question',
    ]);
    expect(h.runtime.executions.first.archived, isTrue);
    expect(h.runtime.executions.first.output, isNull);
    expect(h.runtime.executions.last.toolName, 'output_read');
    expect(h.runtime.executions.last.state, 'failed');
    expect(h.runtime.outputs.count, 0);
    expect(h.runtime.phase, AgentPhase.completed);
  });

  test('conversation history uses bounded JSON data and marks omitted entries', () async {
    final h = _Harness((_, _, _) async* {
      yield ModelMessageComplete(ModelMessage(ModelRole.assistant, text: 'answer'));
    }, tools: false);
    addTearDown(h.close);
    final history = [
      for (var index = 0; index < 40; index++)
        ConversationEntry(kind: ConversationEntryKind.user, text: 'history-$index'),
    ];
    await h.runtime.startConversation('new question', AgentScope(), history);
    var data = (jsonDecode(h.model.requests.last.messages.single.text) as Map)['conversationHistory'] as Map;
    expect(data['truncated'], isTrue);
    expect(data['entries'], hasLength(32));
    expect((data['entries'] as List).first, containsPair('text', 'history-8'));
    expect(utf8.encode(jsonEncode(data)).length, lessThanOrEqualTo(16384));

    final large = List.filled(16000, 'x').join();
    await h.runtime.startConversation('another question', AgentScope(), [
      ConversationEntry(kind: ConversationEntryKind.user, text: 'older text'),
      ConversationEntry(kind: ConversationEntryKind.assistant, text: large),
      const ConversationEntry(kind: ConversationEntryKind.user, text: 'latest text'),
    ]);
    data = (jsonDecode(h.model.requests.last.messages.single.text) as Map)['conversationHistory'] as Map;
    expect(utf8.encode(jsonEncode(data)).length, lessThanOrEqualTo(16384));
    expect(data['entries'], contains(containsPair('text', 'latest text')));
    expect((data['entries'] as List).map((entry) => (entry as Map)['text']), contains(large));

    await h.runtime.startConversation('an oversized prior item', AgentScope(), [
      ConversationEntry(kind: ConversationEntryKind.assistant, text: '$large$large'),
    ]);
    data = (jsonDecode(h.model.requests.last.messages.single.text) as Map)['conversationHistory'] as Map;
    expect(data['truncated'], isTrue);
    expect(data['entries'], isEmpty, reason: 'whole entries are omitted; text is not silently cut midway');
  });

  test('direct start remains a fresh turn after restored or continued history', () async {
    final h = _Harness((_, _, _) async* {
      yield ModelMessageComplete(ModelMessage(ModelRole.assistant, text: 'answer'));
    }, tools: false);
    addTearDown(h.close);
    const entries = [ConversationEntry(kind: ConversationEntryKind.user, text: 'old private context')];
    h.runtime.restoreConversation(entries);
    await h.runtime.startConversation('continued question', AgentScope(), entries);
    expect(_requestText(h.model.requests.last), contains('old private context'));

    await h.runtime.start('fresh question', AgentScope());

    expect(h.model.requests.last.messages.single.text, 'fresh question');
    expect(_requestText(h.model.requests.last), isNot(contains('old private context')));
    expect(h.runtime.messages.map((entry) => entry.text), ['fresh question', 'answer']);
    expect(h.runtime.executions, isEmpty);
  });

  test('history restore and conversation start cannot replace an active approval', () async {
    final call = _call('command_execute', _command());
    final h = _Harness((_, _, index) => _oneCall(call, index));
    addTearDown(h.close);
    final turn = h.start();
    await _until(() => h.runtime.approval != null);
    final approval = h.runtime.approval;
    final timeline = h.runtime.timeline;
    const other = [ConversationEntry(kind: ConversationEntryKind.user, text: 'another conversation')];
    h.runtime.restoreConversation(other);
    await h.runtime.startConversation('replacement question', AgentScope(), other);
    expect(h.runtime.approval, same(approval));
    expect(h.runtime.timeline, timeline);
    expect(h.model.requests, hasLength(1));
    expect(h.backend.target.commands, isEmpty);
    h.runtime.stop();
    await turn;
  });

  test('all received calls have one safe timeline record and Stop settles the unstarted calls', () async {
    final h = _Harness(
      (_, _, index) => _oneCall(
        ModelMessage(
          ModelRole.assistant,
          calls: [
            ModelCall('list', 'host_list', {}),
            ModelCall('command', 'command_execute', _command(command: 'printf synthetic-private-command')),
            ModelCall('read', 'output_read', {'hostId': _host.value, 'handle': 'synthetic-private-handle'}),
          ],
        ),
        index,
      ),
    );
    addTearDown(h.close);
    final turn = h.start();
    await _until(() => h.runtime.approval != null);
    final records = h.runtime.executions;
    expect(records.map((entry) => entry.toolName), ['host_list', 'command_execute', 'output_read']);
    expect(records.map((entry) => entry.state), ['completed', 'running', 'pending']);
    expect(records.map((entry) => entry.id).toSet(), hasLength(3));
    expect(records.every((entry) => entry.command.isEmpty && entry.cwd.isEmpty && entry.target.isEmpty), isTrue);
    expect(records.every((entry) => entry.sharedText == null && entry.output == null), isTrue);

    h.runtime.stop();
    await turn;
    expect(h.runtime.executions, records);
    expect(records.map((entry) => entry.state), ['completed', 'cancelled', 'cancelled']);
    expect(h.backend.target.commands, isEmpty);
    expect(h.journal.records, isEmpty);
    expect(h.model.requests, hasLength(1));
  });

  test('host listing and shared output reads retain names and status without copying result data', () async {
    final h = _Harness((request, _, index) async* {
      if (index == 0) {
        yield ModelMessageComplete(
          ModelMessage(
            ModelRole.assistant,
            calls: [
              ModelCall('list', 'host_list', {}),
              ModelCall('diagnose', 'diagnostics_collect', {'hostId': _host.value, 'template': 'systemSummary'}),
            ],
          ),
        );
      } else if (index == 1) {
        final handle = _result(request, 1)['handle'];
        yield ModelMessageComplete(_call('output_read', {'hostId': _host.value, 'handle': handle}, 'read'));
      } else {
        yield ModelMessageComplete(ModelMessage(ModelRole.assistant, text: 'done'));
      }
    });
    addTearDown(h.close);
    h.backend.target.stdout = _systemOutput;
    await h.start();
    expect(h.runtime.executions.map((entry) => entry.toolName), ['host_list', 'diagnostics_collect', 'output_read']);
    expect(h.runtime.executions.every((entry) => entry.state == 'completed'), isTrue);
    expect(h.runtime.executions.where((entry) => entry.output != null), hasLength(1));
    expect(h.runtime.executions.where((entry) => entry.sharedText != null), hasLength(1));
    expect(h.runtime.executions.first.command, isEmpty);
    expect(h.runtime.executions.last.command, isEmpty);
    expect(h.backend.target.commands, hasLength(1));
  });

  test('fixed diagnosis flows through dispatch and returns paired structured evidence', () async {
    final call = _call('diagnostics_collect', {'hostId': 'host-a', 'template': 'systemSummary'});
    final h = _Harness((_, _, index) => _oneCall(call, index));
    addTearDown(h.close);
    h.backend.target.stdout = _systemOutput;

    await h.start();

    expect(h.runtime.phase, AgentPhase.completed);
    expect(h.model.requests, hasLength(2));
    expect(h.model.requests.first.tools.map((tool) => tool.name), contains('diagnostics_collect'));
    expect(h.model.requests.first.tools.map((tool) => tool.name), contains('command_execute'));
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
    expect(jsonDecode(h.runtime.executions.single.sharedText!), result['data']);
    expect(h.runtime.timeline, [
      h.runtime.messages[0],
      h.runtime.messages[1],
      h.runtime.executions.single,
      h.runtime.messages[2],
    ]);
    expect(() => h.runtime.timeline.clear(), throwsUnsupportedError);
  });

  test('large storage evidence remains valid structured JSON and explicitly truncates entries', () async {
    final call = _call('diagnostics_collect', {'hostId': 'host-a', 'template': 'storageCapacity'});
    final h = _Harness((_, _, index) => _oneCall(call, index));
    addTearDown(h.close);
    final longPath = List.filled(100, r'\"').join();
    h.backend.target.stdout =
        '@@storage\nFilesystem Type 1024-blocks Used Available Capacity Mounted on\n'
        '${[for (var i = 0; i < 90; i++) '/dev/disk$i ext4 1000 400 600 40% /mount-$i-$longPath'].join('\n')}\n';
    await h.start();
    expect(h.runtime.phase, AgentPhase.completed);
    final result = _result(h.model.requests.last);
    expect(result['truncated'], isTrue);
    expect(utf8.encode(_results(h.model.requests.last).single.text).length, lessThanOrEqualTo(8192));
    final data = (result['data'] as Map).cast<String, Object?>();
    expect(data['filesystems'], isNotEmpty);
    expect((data['filesystems'] as List).length, lessThan(90));
    expect(jsonDecode(h.runtime.executions.single.sharedText!), data);
    expect(utf8.encode(jsonEncode(h.runtime.executions.single.sharedText)).length, lessThanOrEqualTo(6500));
    expect(h.runtime.executions.single.historyTruncated, isTrue);
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
    expect(h.backend.target.probes, 0);
    expect(h.journal.records, isEmpty);
    expect(h.runtime.approval!.command, 'printf original');
    // The caller's mutable source is no longer the model call or its bound approval.
    source['command'] = 'printf replaced';
    h.runtime.approve(true, expected: h.runtime.approval!);
    await turn;
    expect(h.backend.target.commands, hasLength(1));
    expect(h.backend.target.commands.single, contains('printf original'));
    expect(h.backend.target.commands.single, isNot(contains('printf replaced')));
    expect(h.backend.target.commands.single, startsWith('sh -c '));
    expect(h.backend.target.commands.single, contains(' || exit\nprintf original'));
    expect(h.backend.target.commands.single, isNot(contains("cd -- '/tmp/owner's directory'")));
    expect(h.backend.target.deadlines.single, const Duration(seconds: 60));
    expect(h.journal.loads, 0);
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
    expect(h.runtime.approval!.timeoutSeconds, 1);
    h.runtime.approve(true, expected: h.runtime.approval!);
    await turn;
    expect(h.backend.target.commands, hasLength(1));
    expect(h.backend.target.deadlines.single, const Duration(seconds: 1));
    expect(h.runtime.phase, AgentPhase.completed);
    expect(h.journal.records.last.state, OperationState.completed);
    expect(_result(h.model.requests.last), containsPair('exitCode', 0));
  });

  for (final tool in ['command_execute', 'job_start']) {
    for (final seconds in [1, 300, null]) {
      test('$tool manual approval displays normalized timeout ${seconds ?? 60}', () async {
        final h = _Harness((_, _, index) => _oneCall(_call(tool, {..._command(), 'timeoutSeconds': ?seconds}), index));
        addTearDown(h.close);
        final work = h.start();
        await _until(() => h.runtime.approval != null);
        expect(h.runtime.approval!.command, 'printf result');
        expect(h.runtime.approval!.timeoutSeconds, seconds ?? 60);
        expect(h.backend.target.commands, isEmpty);
        h.runtime.approve(true, expected: h.runtime.approval!);
        await work;
        expect(h.backend.target.deadlines.single, Duration(seconds: seconds ?? 60));
      });
    }
  }

  test('approval callbacks from a prior turn cannot approve a newer request', () async {
    final call = _call('command_execute', _command());
    final h = _Harness((_, _, index) => _oneCall(call, index % 2));
    addTearDown(h.close);
    final first = h.start();
    await _until(() => h.runtime.approval != null);
    final oldApproval = h.runtime.approval!;
    h.runtime.approve(true, expected: oldApproval);
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
    await second;
    expect(h.backend.target.commands, hasLength(2));
    expect(h.model.requests, hasLength(4));
    expect(_result(h.model.requests.last)['text'], _privateOutput);
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
    expect(h.backend.target.probes, 0);
    expect(h.journal.records, isEmpty);
    expect(h.backend.target.releases, 1);
    expect(_results(h.model.requests.last).single.toolCallId, 'call-a');
    expect(_results(h.model.requests.last).single.isError, isTrue);
    expect(_result(h.model.requests.last), {'error': 'denied'});
    expect(h.runtime.executions.single.toolName, 'command_execute');
    expect(h.runtime.executions.single.state, 'failed');
    expect(h.runtime.executions.single.failure, 'denied');
    expect(h.runtime.executions.single.command, isEmpty);
    expect(h.runtime.executions.single.output, isNull);
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

  test('approved command output is shared automatically and can be reread without another approval', () async {
    final call = _call('command_execute', _command());
    final h = _Harness((request, _, index) async* {
      if (index == 0) {
        yield ModelMessageComplete(call);
      } else if (index == 1) {
        final handle = _result(request)['handle'] as String;
        yield ModelMessageComplete(_call('output_read', {'hostId': 'host-a', 'handle': handle}, 'read-a'));
      } else {
        yield ModelMessageComplete(ModelMessage(ModelRole.assistant, text: 'bounded result received'));
      }
    });
    addTearDown(h.close);
    final turn = h.start();
    await _until(() => h.runtime.approval != null);
    h.runtime.approve(true, expected: h.runtime.approval!);
    await turn;
    expect(h.model.requests, hasLength(3));
    expect(_result(h.model.requests.last), containsPair('text', _privateOutput));
    expect(h.runtime.executions.first.sharedText, _privateOutput);
    expect(h.runtime.executions.last.toolName, 'output_read');
    expect(h.runtime.executions.last.sharedText, isNull);
    expect(h.runtime.executions.last.state, 'completed');
    expect(_result(h.model.requests.last, 1), containsPair('text', _privateOutput));
    expect(_results(h.model.requests.last).last.toolCallId, 'read-a');
  });

  test('only the bounded approved projection is sent and cross-host evidence reads fail', () async {
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
    h.backend.target.stdout = '${'x' * 20000}$_privateOutput';
    final turn = h.start();
    await _until(() => h.runtime.approval != null);
    h.runtime.approve(true, expected: h.runtime.approval!);
    await turn;
    expect(h.model.requests, hasLength(3));
    final shared = h.runtime.executions.first.sharedText!;
    expect(shared, isNotEmpty);
    expect(utf8.encode(jsonEncode(shared)).length, lessThanOrEqualTo(6500));
    expect(_requestText(h.model.requests.last), contains(shared));
    expect(h.runtime.executions.map((entry) => entry.toolName), [
      'command_execute',
      'output_read',
      'output_read',
      'output_read',
    ]);
    expect(h.runtime.executions.skip(1).map((entry) => entry.state), ['completed', 'failed', 'failed']);
    expect(h.runtime.executions.skip(1).every((entry) => entry.sharedText == null && entry.output == null), isTrue);
    expect(_requestText(h.model.requests.last), isNot(contains(_privateOutput)));
    expect(_result(h.model.requests.last), containsPair('text', shared));
    expect(_result(h.model.requests.last, 1), containsPair('text', shared));
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

    final newTurn = h.start(hosts: const []);
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

  for (final fails in [false, true]) {
    test('an old execution ${fails ? 'failure' : 'result'} cannot affect a new turn after Stop', () async {
      final nextReply = Completer<void>();
      final pending = Completer<int?>();
      final h = _Harness((_, cancel, index) async* {
        if (index == 0) {
          await cancel.whenCancelled;
        } else {
          await nextReply.future;
          yield ModelMessageComplete(ModelMessage(ModelRole.assistant, text: 'new task done'));
        }
      });
      addTearDown(h.close);
      addTearDown(() {
        if (!pending.isCompleted) pending.complete(null);
        if (!nextReply.isCompleted) nextReply.complete();
      });
      h.backend.target.pendingExecution = pending.future;
      final oldTurn = h.runtime.start(
        'run the approved command',
        AgentScope(hosts: const [_host], permissionMode: AgentPermissionMode.auto),
      );
      await _until(() => h.model.requests.isNotEmpty);
      final operation = h.runtime.dispatcher.dispatch(
        'agent.execute',
        _command(),
        RequestContext(Origin.agent, authority: h.runtime, cancellation: h.model.cancellations.single),
      );
      await _until(() => h.backend.target.commands.isNotEmpty);
      final oldExecution = h.runtime.executions.single;
      final oldOutput = oldExecution.output!;
      final received = oldOutput.length;
      h.runtime.stop();
      await oldTurn;

      final newTurn = h.start(hosts: const []);
      await _until(() => h.model.requests.length == 2);
      final newToken = h.model.cancellations.last;
      h.backend.target.current = false;
      h.backend.target.writeOutput!(false, Uint8List.fromList(utf8.encode('late output')));
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(newToken.isCancelled, isFalse, reason: 'the old execution watcher owns only the old token');
      if (fails) {
        pending.completeError(const AgentFailure('connectionFailed'));
      } else {
        pending.complete(0);
      }
      expect(await operation, isA<Err<Object?>>());
      expect(oldOutput.length, received);
      expect(oldExecution.sharedText, isNull);
      expect(h.runtime.outputs.count, 0);
      expect(h.runtime.executions, isEmpty);
      expect(h.runtime.error, isNull);
      expect(h.runtime.phase, AgentPhase.streaming);
      expect(newToken.isCancelled, isFalse);
      expect(h.journal.records.last.state, fails ? OperationState.outcomeUnknown : OperationState.completed);

      nextReply.complete();
      await newTurn;
      expect(h.runtime.phase, AgentPhase.completed);
      expect(h.runtime.error, isNull);
      expect(h.runtime.messages.last.text, 'new task done');
      expect(h.model.requests, hasLength(2));
    });
  }

  test('Stop after execution finishes prevents result sharing and preserves its known terminal state', () async {
    final call = _call('command_execute', _command());
    final h = _Harness((_, _, index) => _oneCall(call, index));
    addTearDown(h.close);
    var stopped = false;
    h.runtime.addListener(() {
      if (!stopped && h.runtime.executions.any((entry) => entry.state == 'completed')) {
        stopped = true;
        h.runtime.stop();
      }
    });
    final turn = h.start();
    await _until(() => h.runtime.approval != null);
    h.runtime.approve(true, expected: h.runtime.approval!);
    await turn;
    expect(h.runtime.phase, AgentPhase.cancelled);
    expect(h.runtime.executions.single.exitCode, 0);
    expect(h.runtime.executions.single.state, 'completed');
    expect(h.runtime.executions.single.sharedText, isNull);
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
    expect(_result(h.model.requests.last), {'error': 'journalFailed'});
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
      ModelCall('outside', 'command_execute', _command(host: 'fabricated')),
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
    expect(h.runtime.executions.map((entry) => entry.toolName), [null, 'command_execute', 'command_execute']);
    expect(h.runtime.executions.every((entry) => entry.state == 'failed'), isTrue);
    expect(h.runtime.executions.first.capability, 'agent.unknown');
    expect(h.runtime.executions.every((entry) => entry.command.isEmpty && entry.output == null), isTrue);
  });

  test('discovery lists the frozen saved hosts and asks for an unspecified target without connecting', () async {
    final h = _Harness((_, _, index) async* {
      if (index == 0) {
        yield ModelMessageComplete(_call('host_list', {}));
      } else {
        yield ModelMessageComplete(ModelMessage(ModelRole.assistant, text: 'Which server should I check?'));
      }
    });
    addTearDown(h.close);
    await h.runtime.start('check disk space', AgentScope(discoverHosts: true));
    final request = h.model.requests.first;
    final input = jsonDecode(request.messages.single.text) as Map;
    expect(input['targetSelection'], 'discoverFromUserRequest');
    expect(input['authorizedHosts'], isEmpty);
    expect(request.system, contains('ask the user rather than guess a host'));
    expect(_result(h.model.requests.last), {
      'hosts': [
        {'id': 'host-a', 'alias': 'selected host'},
        {'id': 'host-b', 'alias': 'unselected host'},
      ],
      'total': 2,
      'nextOffset': null,
    });
    expect(h.runtime.resolvedHost, isNull);
    expect(h.backend.prepared, isEmpty);
    expect(h.runtime.phase, AgentPhase.completed);
  });

  test('discovered saved host still requires a fresh exact command approval', () async {
    final h = _Harness((_, _, index) async* {
      if (index == 0) {
        yield ModelMessageComplete(_call('host_list', {}));
      } else if (index == 1) {
        yield ModelMessageComplete(_call('command_execute', _command()));
      } else {
        yield ModelMessageComplete(ModelMessage(ModelRole.assistant, text: 'command finished'));
      }
    });
    addTearDown(h.close);
    final work = h.runtime.start('run printf result on selected host', AgentScope(discoverHosts: true));
    await _until(() => h.runtime.hostApproval != null);
    expect(h.backend.prepared, isEmpty);
    expect(h.backend.target.probes, 0);
    h.runtime.decideHost(h.runtime.hostApproval!, true);
    await _until(() => h.runtime.approval != null);
    expect(h.runtime.resolvedHost, _host);
    expect(h.backend.prepared, [_host]);
    expect(h.backend.target.commands, isEmpty);
    expect(h.journal.records, isEmpty);
    h.runtime.approve(true, expected: h.runtime.approval!);
    await work;
    expect(h.backend.target.commands, hasLength(1));
    expect(h.journal.records.map((record) => record.state), [OperationState.intent, OperationState.completed]);
    expect(h.runtime.phase, AgentPhase.completed);
  });

  test('discovery requires listing before preparing a saved target', () async {
    final h = _Harness((_, _, index) => _oneCall(_call('command_execute', _command()), index));
    addTearDown(h.close);
    await h.runtime.start('use selected host', AgentScope(discoverHosts: true));
    expect(_result(h.model.requests.last), {'error': 'hostSelectionRequired'});
    expect(h.runtime.resolvedHost, isNull);
    expect(h.backend.prepared, isEmpty);
    expect(h.runtime.approval, isNull);
  });

  test('a failed connection does not authorize a second host without its own confirmation', () async {
    final h = _Harness((_, _, index) async* {
      if (index == 0) {
        yield ModelMessageComplete(_call('host_list', {}));
      } else if (index == 1) {
        yield ModelMessageComplete(_call('command_execute', _command()));
      } else if (index == 2) {
        yield ModelMessageComplete(_call('command_execute', _command(host: 'host-b')));
      } else {
        yield ModelMessageComplete(ModelMessage(ModelRole.assistant, text: 'connection failed'));
      }
    });
    addTearDown(h.close);
    h.backend.prepareFailure = const AgentFailure('connectionFailed');
    final work = h.runtime.start('use selected host', AgentScope(discoverHosts: true));
    await _until(() => h.runtime.hostApproval != null);
    h.runtime.decideHost(h.runtime.hostApproval!, true);
    await _until(() => h.runtime.hostApproval?.hostId == _other);
    expect(h.backend.prepared, [_host]);
    h.runtime.decideHost(h.runtime.hostApproval!, false);
    await work;
    expect(h.runtime.resolvedHost, _host);
    expect(h.backend.prepared, [_host]);
    expect(_result(h.model.requests[2], 1), {'error': 'connectionFailed'});
    expect(_result(h.model.requests.last, 2), {'error': 'denied'});
    expect(h.backend.target.commands, isEmpty);
  });

  test('discovery never adds hosts created after the turn snapshot or fabricated IDs', () async {
    const added = HostId('host-added');
    late final _Harness h;
    h = _Harness((_, _, index) async* {
      if (index == 0) {
        h.backend.hosts = const [
          AgentHost(_host, 'changed alias'),
          AgentHost(_other, 'unselected host'),
          AgentHost(added, 'new host'),
        ];
        yield ModelMessageComplete(_call('host_list', {}));
      } else if (index == 1) {
        yield ModelMessageComplete(
          ModelMessage(
            ModelRole.assistant,
            calls: [
              ModelCall('new-host', 'command_execute', _command(host: added.value)),
              ModelCall('fake-host', 'command_execute', _command(host: 'fabricated')),
            ],
          ),
        );
      } else {
        yield ModelMessageComplete(ModelMessage(ModelRole.assistant, text: 'need a saved target'));
      }
    });
    addTearDown(h.close);
    await h.runtime.start('use new host', AgentScope(discoverHosts: true));
    expect(_result(h.model.requests[1]), {
      'hosts': [
        {'id': 'host-a', 'alias': 'selected host'},
        {'id': 'host-b', 'alias': 'unselected host'},
      ],
      'total': 2,
      'nextOffset': null,
    });
    expect(_result(h.model.requests.last, 1), {'error': 'outsideScope'});
    expect(_result(h.model.requests.last, 2), {'error': 'outsideScope'});
    expect(h.runtime.resolvedHost, isNull);
    expect(h.backend.prepared, isEmpty);
  });

  test('focused target is the default and an unlisted different target cannot prepare', () async {
    final h = _Harness((_, _, index) => _oneCall(_call('command_execute', _command(host: 'host-b')), index));
    addTearDown(h.close);
    final work = h.runtime.start('check the focused server', AgentScope(hosts: const [_host], discoverHosts: true));
    expect(h.runtime.resolvedHost, _host);
    await work;
    final input = jsonDecode(h.model.requests.first.messages.single.text) as Map;
    expect(input['targetSelection'], 'focusedHost');
    expect(input['authorizedHosts'], [
      {'id': 'host-a', 'alias': 'selected host'},
    ]);
    expect(_result(h.model.requests.last), {'error': 'hostSelectionRequired'});
    expect(h.backend.prepared, isEmpty);
    h.runtime.clear();
    expect(h.runtime.resolvedHost, isNull);
  });

  test('discovery refuses an oversized host snapshot before making a model request', () async {
    final h = _Harness((_, _, _) async* {
      yield ModelMessageComplete(ModelMessage(ModelRole.assistant, text: 'unused'));
    });
    addTearDown(h.close);
    h.backend.hosts = [for (var index = 0; index < 1001; index++) AgentHost(HostId('host-$index'), 'host $index')];
    await h.runtime.start('check server', AgentScope(discoverHosts: true));
    expect(h.runtime.error, 'scopeLimit');
    expect(h.model.requests, isEmpty);
    expect(h.backend.prepared, isEmpty);
    expect(h.runtime.busy, isFalse);
  });

  test('host projection includes all saved IDs and aliases without connecting', () async {
    final call = _call('host_list', {});
    final h = _Harness((_, _, index) => _oneCall(call, index));
    addTearDown(h.close);
    await h.start();
    expect(_result(h.model.requests.last), {
      'hosts': [
        {'id': 'host-a', 'alias': 'selected host'},
        {'id': 'host-b', 'alias': 'unselected host'},
      ],
      'total': 2,
      'nextOffset': null,
    });
    expect(h.runtime.hostApproval, isNull);
    expect(h.backend.prepared, isEmpty);
  });

  for (final escaped in [false, true]) {
    test('host pages preserve all 1000 aliases within the encoded budget, escaped=$escaped', () async {
      final ready = Completer<void>(), finish = Completer<void>();
      final h = _Harness((_, _, _) async* {
        ready.complete();
        await finish.future;
        yield ModelMessageComplete(ModelMessage(ModelRole.assistant, text: 'done'));
      });
      addTearDown(h.close);
      addTearDown(() {
        if (!finish.isCompleted) finish.complete();
      });
      h.backend.hosts = [
        for (var index = 0; index < 1000; index++)
          AgentHost(HostId('host-$index'), escaped ? '${r'\"' * 110}中-$index' : 'host $index'),
      ];
      final work = h.runtime.start('list saved hosts', AgentScope(discoverHosts: true));
      await ready.future;
      final found = <Object?>[];
      var offset = 0, pages = 0;
      while (true) {
        final result = await h.dispatch('agent.hosts', {'offset': offset});
        expect(result, isA<Ok<Object?>>());
        final data = ((result as Ok<Object?>).value as Map).cast<String, Object?>();
        final page = data['hosts'] as List;
        expect(page, isNotEmpty);
        expect(page.length, lessThanOrEqualTo(32));
        expect(utf8.encode(jsonEncode(data)).length, lessThanOrEqualTo(4096));
        expect(data['total'], 1000);
        found.addAll(page);
        pages++;
        expect(pages, lessThanOrEqualTo(1000));
        if (data['nextOffset'] == null) break;
        expect(data['nextOffset'], offset + page.length);
        offset = data['nextOffset'] as int;
      }
      expect(found, [
        for (final host in h.backend.hosts) {'id': host.id.value, 'alias': host.label},
      ]);
      expect(pages, greaterThan(1));
      expect(h.backend.prepared, isEmpty);
      expect(h.runtime.hostApproval, isNull);
      finish.complete();
      await work;
      expect(h.runtime.phase, AgentPhase.completed);
    });
  }

  test('chat without a selected host has no tools and disabled AI sends nothing', () async {
    final h = _Harness((_, _, _) async* {
      yield ModelMessageComplete(ModelMessage(ModelRole.assistant, text: 'explanation'));
    }, tools: false);
    addTearDown(h.close);
    await h.start(hosts: const []);
    expect(h.runtime.phase, AgentPhase.completed);
    expect(h.model.requests.single.tools, isEmpty);
    expect(h.backend.prepared, isEmpty);
    h.enabled = false;
    await h.start(hosts: const []);
    expect(h.model.requests, hasLength(1));
    expect(h.runtime.error, 'notConfigured');
  });

  test('selected scope makes all reviewed tools available without selecting a mode', () async {
    final h = _Harness((_, _, _) async* {
      yield ModelMessageComplete(ModelMessage(ModelRole.assistant, text: 'I can answer without a tool.'));
    });
    addTearDown(h.close);
    h.journal.failLoad = true;
    h.backend.hosts = const [AgentHost(_host, 'scope-data-only-alias'), AgentHost(_other, 'unselected host')];
    await h.start();
    final request = h.model.requests.single;
    expect(
      request.tools.map((tool) => tool.name),
      unorderedEquals([
        for (final entry in AgentRuntime.toolIds.entries)
          if (h.runtime.dispatcher[entry.value] != null) entry.key,
      ]),
    );
    final data = jsonDecode(request.messages.single.text) as Map;
    expect(data['goal'], 'check the selected host');
    expect(data['authorizedHosts'], [
      {'id': 'host-a', 'alias': 'scope-data-only-alias'},
    ]);
    expect(request.system, isNot(contains('scope-data-only-alias')));
    expect(_requestText(request), isNot(contains('unselected host')));
    expect(h.runtime.phase, AgentPhase.completed);
    expect(h.backend.prepared, isEmpty);
    expect(h.journal.loads, 0, reason: 'a broken execution journal cannot block a direct answer');
  });

  test('no selected host is plain chat even with a tool-capable model', () async {
    final h = _Harness((_, _, _) async* {
      yield ModelMessageComplete(ModelMessage(ModelRole.assistant, text: 'a direct answer'));
    });
    addTearDown(h.close);
    await h.start(hosts: const []);
    expect(h.model.requests.single.tools, isEmpty);
    expect(h.model.requests.single.messages.single.text, 'check the selected host');
    expect(h.backend.prepared, isEmpty);
    expect(h.journal.loads, 0);
    expect(h.runtime.phase, AgentPhase.completed);
  });

  test('a text-only profile never sends selected hosts or offers remote tools', () async {
    final h = _Harness((_, _, _) async* {
      yield ModelMessageComplete(ModelMessage(ModelRole.assistant, text: 'a direct answer'));
    }, tools: false);
    addTearDown(h.close);
    await h.start();
    final request = h.model.requests.single;
    expect(request.tools, isEmpty);
    expect(request.messages.single.text, 'check the selected host');
    expect(_requestText(request), isNot(contains('host-a')));
    expect(h.backend.prepared, isEmpty);
    expect(h.runtime.phase, AgentPhase.completed);
  });

  test('connection and support failures keep safe paired error codes', () async {
    for (final code in ['hostTrustRequired', 'authenticationRequired', 'connectionFailed', 'unsupported']) {
      final call = _call('diagnostics_collect', {'hostId': 'host-a', 'template': 'systemSummary'});
      final h = _Harness((_, _, index) => _oneCall(call, index));
      try {
        if (code == 'unsupported') {
          h.backend.target.probeFailure = AgentFailure(code);
        } else {
          h.backend.prepareFailure = AgentFailure(code);
        }
        await h.start();
        expect(h.runtime.error, code);
        expect(_result(h.model.requests.last), {'error': code});
        expect(_results(h.model.requests.last).single.toolCallId, 'call-a');
        expect(_results(h.model.requests.last).single.isError, isTrue);
        expect(h.backend.target.commands, isEmpty);
      } finally {
        await h.close();
      }
    }
  });

  test('a nonzero exit is a known failed execution and remains failed after Stop', () async {
    final call = _call('command_execute', _command());
    final h = _Harness((_, _, index) => _oneCall(call, index));
    addTearDown(h.close);
    h.backend.target.result = 7;
    var stopped = false;
    h.runtime.addListener(() {
      if (!stopped && h.runtime.executions.any((entry) => entry.exitCode == 7)) {
        stopped = true;
        h.runtime.stop();
      }
    });
    final turn = h.start();
    await _until(() => h.runtime.approval != null);
    h.runtime.approve(true, expected: h.runtime.approval!);
    await turn;
    expect(h.runtime.executions.single.exitCode, 7);
    expect(h.runtime.phase, AgentPhase.cancelled);
    expect(h.runtime.executions.single.state, 'failed');
    expect(h.journal.records.last.state, OperationState.failed);
  });

  testWidgets('streaming text is coalesced then final completion flushes immediately', (tester) async {
    final events = StreamController<ModelEvent>();
    final h = _Harness((_, _, _) => events.stream);
    addTearDown(h.close);
    final turn = h.start(hosts: const []);
    await tester.pump();
    var notifications = 0;
    h.runtime.addListener(() => notifications++);
    for (var i = 0; i < 20; i++) {
      events.add(const ModelTextDelta('x'));
    }
    await tester.pump();
    expect(notifications, 0);
    await tester.pump(const Duration(milliseconds: 49));
    expect(notifications, 0);
    await tester.pump(const Duration(milliseconds: 1));
    expect(notifications, 1);
    expect(h.runtime.messages.last.text, List.filled(20, 'x').join());
    events.add(ModelMessageComplete(ModelMessage(ModelRole.assistant, text: 'final text')));
    unawaited(events.close());
    await tester.pump();
    await turn;
    expect(h.runtime.messages.last.text, 'final text');
    expect(h.runtime.phase, AgentPhase.completed);
    final finalNotifications = notifications;
    await tester.pump(const Duration(milliseconds: 100));
    expect(notifications, finalNotifications, reason: 'no delayed refresh survives the terminal state');
  });

  testWidgets('streaming output refreshes before execution ends and coalesces chunks', (tester) async {
    final call = _call('command_execute', _command());
    final h = _Harness((_, _, index) => _oneCall(call, index));
    addTearDown(h.close);
    h.backend.target.block = true;
    final turn = h.start();
    await tester.pump();
    expect(h.runtime.approval, isNotNull);
    h.runtime.approve(true, expected: h.runtime.approval!);
    await tester.pump();
    expect(h.runtime.executions.single.state, 'running');
    var notifications = 0;
    h.runtime.addListener(() => notifications++);
    for (var i = 0; i < 20; i++) {
      h.backend.target.writeOutput!(false, Uint8List.fromList(utf8.encode('chunk')));
    }
    await tester.pump(const Duration(milliseconds: 49));
    expect(notifications, 0);
    await tester.pump(const Duration(milliseconds: 1));
    expect(notifications, 1);
    expect(h.runtime.executions.single.state, 'running');
    expect(h.runtime.executions.single.output!.stdout, contains(List.filled(20, 'chunk').join()));
    h.runtime.stop();
    await tester.pump();
    await turn;
    final finalNotifications = notifications;
    await tester.pump(const Duration(milliseconds: 100));
    expect(notifications, finalNotifications);
  });

  test('disposing a runtime cancels only its turn and leaves the shared model usable', () async {
    final otherReady = Completer<void>(), otherFinish = Completer<void>();
    final h = _Harness((_, cancel, index) async* {
      if (index == 0) {
        await cancel.whenCancelled;
        throw const ModelFailure('cancelled');
      }
      otherReady.complete();
      await otherFinish.future;
      yield ModelMessageComplete(ModelMessage(ModelRole.assistant, text: 'independent result'));
    });
    var disposed = false;
    addTearDown(() async {
      if (!disposed) h.runtime.dispose();
      if (!otherFinish.isCompleted) otherFinish.complete();
      await h.runtime.settled;
      h.model.close();
    });
    final turn = h.start(hosts: const []);
    await _until(() => h.model.requests.length == 1);
    final otherCancel = CancellationToken();
    final other = h.model
        .stream(
          ModelRequest(
            profile: h.profile,
            system: '',
            messages: [ModelMessage(ModelRole.user, text: 'independent request')],
          ),
          otherCancel,
        )
        .toList();
    await otherReady.future;

    h.runtime.dispose();
    disposed = true;
    await turn;
    expect(h.model.cancellations.first.isCancelled, isTrue);
    expect(h.runtime.phase, AgentPhase.cancelled);
    expect(h.model.closes, 0);
    expect(otherCancel.isCancelled, isFalse);

    otherFinish.complete();
    final events = await other;
    expect((events.single as ModelMessageComplete).message.text, 'independent result');
    expect(h.model.closes, 0);
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
        await h.start();
        expect(h.runtime.phase, AgentPhase.failed);
        expect(h.runtime.error, callsPerMessage == 1 ? 'stepLimit' : 'toolLimit');
        expect(
          h.model.requests,
          hasLength(callsPerMessage == 1 ? AgentRuntime.maxModelRequests : AgentRuntime.maxToolCalls ~/ 8 + 1),
        );
        expect(h.backend.prepared, isEmpty);
      } finally {
        await h.close();
      }
    }
  });

  test('reviews share the model-request budget and fall back to manual decisions before the final answer', () async {
    final h = _Harness((_, _, index) async* {
      yield ModelMessageComplete(
        ModelMessage(
          ModelRole.assistant,
          calls: [
            for (var i = 0; i < 8; i++)
              ModelCall('read-$index-$i', 'diagnostics_collect', {'hostId': _host.value, 'template': 'systemSummary'}),
          ],
        ),
      );
    }, review: (_, _, _) => _reviewReply('allow'));
    addTearDown(h.close);
    h.backend.target.stdout = _systemOutput;
    final manualReads = <AgentApproval>{};
    h.runtime.addListener(() {
      if (h.runtime.approval case final pending?) {
        if (manualReads.add(pending)) h.runtime.approve(true, expected: pending);
      }
    });
    await h.runtime.start(
      'inspect this host',
      AgentScope(hosts: const [_host], permissionMode: AgentPermissionMode.review),
    );
    expect(h.runtime.phase, AgentPhase.failed);
    expect(h.runtime.error, 'stepLimit');
    expect(h.model.requests.length + h.model.reviewRequests.length, AgentRuntime.maxModelRequests);
    expect(manualReads, isNotEmpty);
    expect(h.backend.target.commands, hasLength(64));
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
    await h.start();
    expect(h.runtime.error, 'toolLimit');
    expect(h.backend.prepared, isEmpty);
    expect(h.backend.target.commands, isEmpty);
  });

  test('jobs and active tools share three slots while job controls remain available', () async {
    const third = HostId('host-c');
    final ready = Completer<void>(), finishTurn = Completer<void>(), finishRead = Completer<void>();
    final finishJobs = [for (var index = 0; index < 3; index++) Completer<int?>()];
    var reads = 0;
    final h = _Harness(
      (_, _, _) async* {
        ready.complete();
        await finishTurn.future;
        yield ModelMessageComplete(ModelMessage(ModelRole.assistant, text: 'done'));
      },
      extraCapabilities: [
        FunctionCapability(
          'file.read',
          Effect.query,
          (_, _) async {
            reads++;
            await finishRead.future;
            return const Ok({'text': 'page'});
          },
          agentExposed: true,
          inputSchema: _schema(
            {
              'hostId': {'type': 'string'},
              'path': {'type': 'string'},
            },
            ['hostId', 'path'],
          ),
        ),
      ],
    );
    addTearDown(h.close);
    addTearDown(() {
      if (!finishRead.isCompleted) finishRead.complete();
      if (!finishTurn.isCompleted) finishTurn.complete();
      for (final finish in finishJobs) {
        if (!finish.isCompleted) finish.complete(0);
      }
    });
    h.backend.hosts = const [AgentHost(_host, 'a'), AgentHost(_other, 'b'), AgentHost(third, 'c')];
    h.routes[third] = 'route-c';
    final targets = [h.backend.target, _Target(_other), _Target(third)];
    for (final (index, target) in targets.indexed) {
      target.pendingExecution = finishJobs[index].future;
      if (target.hostId != _host) h.backend.others[target.hostId] = target;
    }
    final work = h.runtime.start(
      'run bounded work',
      AgentScope(hosts: const [_host, _other, third], permissionMode: AgentPermissionMode.auto),
    );
    await ready.future;
    final jobs = <String>[];
    for (final host in [_host, _other]) {
      final result = await h.dispatch('agent.jobs.start', _command(host: host.value));
      expect(result, isA<Ok<Object?>>());
      jobs.add(((result as Ok<Object?>).value as Map)['jobId'] as String);
    }
    final reading = h.dispatch('file.read', {'hostId': third.value, 'path': '/tmp/a'});
    await _until(() => reads == 1);
    final fourth = await h.dispatch('agent.jobs.start', _command(host: third.value));
    expect((fourth as Err<Object?>).error.code, 'busy');
    expect(targets.last.commands, isEmpty);
    final extraRead = await h.dispatch('file.read', {'hostId': third.value, 'path': '/tmp/b'});
    expect((extraRead as Err<Object?>).error.code, 'busy');
    expect(reads, 1);
    for (final capability in ['agent.jobs.read', 'agent.jobs.status', 'agent.jobs.stop']) {
      expect(await h.dispatch(capability, {'jobId': jobs.first}), isA<Ok<Object?>>());
    }
    expect(targets.first.tokens.single.isCancelled, isTrue);
    finishRead.complete();
    expect(await reading, isA<Ok<Object?>>());
    expect(await h.dispatch('agent.jobs.start', _command(host: third.value)), isA<Ok<Object?>>());
    expect(targets.last.commands, hasLength(1));
    final full = await h.dispatch('file.read', {'hostId': third.value, 'path': '/tmp/c'});
    expect((full as Err<Object?>).error.code, 'busy');
    for (final finish in finishJobs) {
      finish.complete(0);
    }
    await _until(() => h.journal.terminalAttempts == 3);
    finishTurn.complete();
    await work;
    expect(targets.every((target) => target.releases == 1), isTrue);
  });

  for (final blocker in ['agent.execute', 'agent.jobs.start', 'file.write']) {
    for (final contender in ['agent.execute', 'file.write']) {
      test('$blocker blocks concurrent $contender on the same host', () async {
        final ready = Completer<void>(), finishTurn = Completer<void>();
        final finishCommand = Completer<int?>(), finishWrite = Completer<void>();
        var writes = 0;
        final h = _Harness(
          (_, _, _) async* {
            ready.complete();
            await finishTurn.future;
            yield ModelMessageComplete(ModelMessage(ModelRole.assistant, text: 'done'));
          },
          extraCapabilities: [
            FunctionCapability(
              'file.write',
              Effect.remoteWrite,
              (_, _) async {
                writes++;
                await finishWrite.future;
                return const Ok(null);
              },
              agentExposed: true,
              inputSchema: _schema(
                {
                  'hostId': {'type': 'string'},
                  'path': {'type': 'string'},
                  'text': {'type': 'string'},
                },
                ['hostId', 'path', 'text'],
              ),
            ),
          ],
        );
        addTearDown(h.close);
        addTearDown(() {
          if (!finishCommand.isCompleted) finishCommand.complete(0);
          if (!finishWrite.isCompleted) finishWrite.complete();
          if (!finishTurn.isCompleted) finishTurn.complete();
        });
        h.backend.target.pendingExecution = finishCommand.future;
        final work = h.runtime.start(
          'serialize host writes',
          AgentScope(hosts: const [_host], permissionMode: AgentPermissionMode.auto),
        );
        await ready.future;
        Map<String, Object?> arguments(String capability) =>
            capability == 'file.write' ? {'hostId': _host.value, 'path': '/tmp/a', 'text': 'bounded'} : _command();
        final first = h.dispatch(blocker, arguments(blocker));
        await _until(() => blocker == 'file.write' ? writes == 1 : h.backend.target.commands.length == 1);
        final result = await h.dispatch(contender, arguments(contender));
        expect((result as Err<Object?>).error.code, 'busy');
        expect(writes, blocker == 'file.write' ? 1 : 0);
        expect(h.backend.target.commands, hasLength(blocker == 'file.write' ? 0 : 1));
        finishCommand.complete(0);
        finishWrite.complete();
        expect(await first, isA<Ok<Object?>>());
        finishTurn.complete();
        await work;
        expect(h.runtime.phase, AgentPhase.completed);
      });
    }
  }

  test('a known job exit with a failed final journal is not reported as a completed turn', () async {
    final h = _Harness((_, _, index) => _oneCall(_call('job_start', _command()), index));
    addTearDown(h.close);
    h.journal.failTerminal = true;
    await h.runtime.start('run a job', _conversationScope(mode: AgentPermissionMode.auto));
    expect(h.runtime.phase, AgentPhase.failed);
    expect(h.runtime.error, 'journalFailed');
    expect(h.runtime.executions.single.state, 'completed');
    expect(h.runtime.executions.single.exitCode, 0);
    expect(h.runtime.executions.single.failure, 'journalFailed');
  });

  test('background job runs one approved command and shares bounded output', () async {
    final h = _Harness((request, _, index) async* {
      if (index == 0) {
        yield ModelMessageComplete(
          _call('job_start', {'hostId': _host.value, 'cwd': '/tmp', 'command': 'printf job-output'}, 'job'),
        );
      } else if (index == 1) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        final jobId = _result(request)['jobId'];
        yield ModelMessageComplete(
          ModelMessage(
            ModelRole.assistant,
            calls: [
              ModelCall('read', 'job_read', {'jobId': jobId, 'offset': 0}),
              ModelCall('status', 'job_status', {'jobId': jobId}),
            ],
          ),
        );
      } else {
        yield ModelMessageComplete(ModelMessage(ModelRole.assistant, text: 'done'));
      }
    });
    addTearDown(h.close);
    final work = h.runtime.start('run in the background', _conversationScope(mode: AgentPermissionMode.confirm));
    await _until(() => h.runtime.approval != null);
    expect(h.runtime.approval!.capability, 'agent.jobs.start');
    expect(h.runtime.approval!.command, 'printf job-output');
    h.runtime.approve(true, expected: h.runtime.approval!);
    await work;
    expect(h.backend.target.commands, hasLength(1));
    expect(h.backend.target.commands.single, contains('printf job-output'));
    final read = _result(h.model.requests.last, 1);
    expect(read['state'], 'completed');
    expect(read['exitCode'], 0);
    expect(read['text'], _privateOutput);
    expect(read['eof'], isTrue);
    expect(read['nextOffset'], isNull);
    expect(_result(h.model.requests.last, 2)['bytes'], utf8.encode(_privateOutput).length);
    final execution = h.runtime.executions.singleWhere((entry) => entry.capability == 'agent.jobs.start');
    expect(execution.output!.stdout, _privateOutput);
    expect(execution.state, 'completed');
    expect(execution.exitCode, 0);
    expect(execution.sharedText, _privateOutput);
    expect(h.journal.records.map((record) => record.state), [OperationState.intent, OperationState.completed]);
  });

  test('command output filters complete secret and control lines before taking its bounded excerpt', () async {
    final h = _Harness((request, _, index) => _oneCall(_call('command_execute', _command()), index));
    addTearDown(h.close);
    h.backend.target.stdout = '${'x' * 8190} api_key=synthetic-private\nplain\n\x1b[31mhidden\n';
    await h.runtime.start('run a command', _conversationScope(mode: AgentPermissionMode.auto));
    final result = _result(h.model.requests.last);
    expect(result['text'], 'plain\n');
    expect(result['filtered'], isTrue);
    expect(h.runtime.executions.single.output!.stdout, contains('synthetic-private'));
    expect(_requestText(h.model.requests.last), isNot(contains('synthetic-private')));
    expect(_requestText(h.model.requests.last), isNot(contains('hidden')));
  });

  test('background job output filters secrets split across chunks and omits control lines', () async {
    final finish = Completer<int?>(), started = Completer<void>(), release = Completer<void>();
    String? jobId;
    final h = _Harness((request, _, index) async* {
      if (index == 0) {
        yield ModelMessageComplete(_call('job_start', _command(), 'job'));
      } else {
        jobId = _result(request)['jobId'] as String;
        started.complete();
        await release.future;
        yield ModelMessageComplete(ModelMessage(ModelRole.assistant, text: 'done'));
      }
    });
    addTearDown(h.close);
    h.backend.target
      ..stdout = ''
      ..pendingExecution = finish.future;
    final work = h.runtime.start('stream filtered output', _conversationScope(mode: AgentPermissionMode.auto));
    await started.future;
    Map<String, Object?> read() => ((h.runtime.readJob({'jobId': jobId!}) as Ok<Object?>).value as Map).cast();
    void emit(String text) => h.backend.target.writeOutput!(false, Uint8List.fromList(utf8.encode(text)));
    emit('api_');
    expect(read()['text'], isEmpty);
    emit('key=synthetic-private\n');
    emit('-----BEGIN OPENSSH PRIVATE KEY-----\nsynthetic-key-body\n-----END OPENSSH PRIVATE KEY-----\n');
    emit('safe\n\x1b[31mhidden\n');
    emit('tail');
    expect(read()['text'], 'safe\n');
    expect(read()['filtered'], isTrue);
    finish.complete(0);
    await _until(() => read()['done'] == true);
    expect(read()['text'], 'safe\ntail');
    release.complete();
    await work;
  });

  test('background job pages remain append-only as stdout arrives after stderr', () async {
    final finish = Completer<int?>(), started = Completer<void>(), release = Completer<void>();
    String? jobId;
    final h = _Harness((request, _, index) async* {
      if (index == 0) {
        yield ModelMessageComplete(_call('job_start', _command(), 'job'));
      } else {
        jobId = _result(request)['jobId'] as String;
        started.complete();
        await release.future;
        yield ModelMessageComplete(ModelMessage(ModelRole.assistant, text: 'done'));
      }
    });
    addTearDown(h.close);
    h.backend.target
      ..stdout = 'first\n'
      ..pendingExecution = finish.future;
    final work = h.runtime.start('stream a job', _conversationScope(mode: AgentPermissionMode.auto));
    await started.future;
    Map<String, Object?> read([int offset = 0]) =>
        ((h.runtime.readJob({'jobId': jobId!, 'offset': offset}) as Ok<Object?>).value as Map).cast();
    final first = read();
    expect(first['text'], 'first\n');
    expect(first['eof'], isFalse);
    expect(first['nextOffset'], 6);
    h.backend.target.writeOutput!(true, Uint8List.fromList(utf8.encode('warning\n')));
    final second = read(first['nextOffset'] as int);
    expect(second['text'], '\n[stderr]\nwarning\n');
    h.backend.target.writeOutput!(false, Uint8List.fromList(utf8.encode('later\n')));
    final third = read(second['nextOffset'] as int);
    expect(third['text'], '\n[stdout]\nlater\n');
    expect(read()['text'], '${first['text']}${second['text']}${third['text']}');
    expect(read(third['nextOffset'] as int)['nextOffset'], third['nextOffset']);
    finish.complete(0);
    await _until(() => read()['done'] == true);
    expect(read(third['nextOffset'] as int)['eof'], isTrue);
    expect(read(third['nextOffset'] as int)['nextOffset'], isNull);
    release.complete();
    await work;
  });

  test('background job UTF-8 chunks and page offsets preserve whole characters and bounded memory', () async {
    final finish = Completer<int?>(), started = Completer<void>(), release = Completer<void>();
    String? jobId;
    final h = _Harness((request, _, index) async* {
      if (index == 0) {
        yield ModelMessageComplete(_call('job_start', _command(), 'job'));
      } else {
        jobId = _result(request)['jobId'] as String;
        started.complete();
        await release.future;
        yield ModelMessageComplete(ModelMessage(ModelRole.assistant, text: 'done'));
      }
    });
    addTearDown(h.close);
    h.backend.target
      ..stdout = ''
      ..pendingExecution = finish.future;
    final work = h.runtime.start('stream UTF-8', _conversationScope(mode: AgentPermissionMode.auto));
    await started.future;
    Map<String, Object?> read([int offset = 0]) =>
        ((h.runtime.readJob({'jobId': jobId!, 'offset': offset}) as Ok<Object?>).value as Map).cast();
    final chinese = utf8.encode('中');
    h.backend.target.writeOutput!(false, Uint8List.fromList(chinese.take(2).toList()));
    expect(read()['text'], isEmpty);
    h.backend.target.writeOutput!(false, Uint8List.fromList([chinese.last, 10]));
    expect(read()['text'], '中\n');
    h.backend.target.writeOutput!(false, Uint8List.fromList(utf8.encode('${'中' * 6000}\n' * 5)));
    final page = read();
    expect(page['truncated'], isTrue);
    expect(page['bytes'] as int, lessThanOrEqualTo(65536));
    expect(utf8.encode(jsonEncode(page)).length, lessThanOrEqualTo(4096));
    expect(page['text'], isNot(contains('�')));
    final offset = page['nextOffset'] as int;
    expect(utf8.encode(page['text'] as String).length, offset);
    expect(read(offset)['text'], isNot(contains('�')));
    expect(h.runtime.readJob({'jobId': jobId!, 'offset': 1}), isA<Err<Object?>>());
    finish.complete(0);
    await _until(() => read()['done'] == true);
    release.complete();
    await work;
  });

  for (final failure in [const ExecError(ExecFailure.timedOut), StateError('transport lost')]) {
    test('a submitted background job with $failure keeps an unknown outcome', () async {
      final finish = Completer<int?>(), started = Completer<void>(), release = Completer<void>();
      String? jobId;
      final h = _Harness((request, _, index) async* {
        if (index == 0) {
          yield ModelMessageComplete(_call('job_start', _command(), 'job'));
        } else {
          jobId = _result(request)['jobId'] as String;
          started.complete();
          await release.future;
          yield ModelMessageComplete(ModelMessage(ModelRole.assistant, text: 'inspect the job'));
        }
      });
      addTearDown(h.close);
      h.backend.target.pendingExecution = finish.future;
      final work = h.runtime.start('start a job', _conversationScope(mode: AgentPermissionMode.auto));
      await started.future;
      finish.completeError(failure);
      await _until(() => h.journal.records.any((r) => r.state == OperationState.outcomeUnknown));
      final status = (h.runtime.jobStatus({'jobId': jobId!}) as Ok<Object?>).value as Map;
      expect(status['state'], 'outcomeUnknown');
      expect(status['exitCode'], isNull);
      expect(h.backend.target.commands, hasLength(1));
      release.complete();
      await work;
    });
  }

  test('a job cancelled during intent persistence never reaches the remote target', () async {
    final gate = Completer<void>();
    final h = _Harness((request, _, index) => _oneCall(_call('job_start', _command(), 'job'), index));
    addTearDown(h.close);
    h.journal.pendingIntent = gate;
    final work = h.runtime.start('start then stop', _conversationScope(mode: AgentPermissionMode.auto));
    await _until(() => h.journal.intentAttempts == 1);
    h.runtime.stop();
    gate.complete();
    await work;
    expect(h.backend.target.commands, isEmpty);
    expect(h.journal.records.map((r) => r.state), [OperationState.intent, OperationState.failed]);
  });

  test('job exit and journal failure settle before a clean next turn can start', () async {
    final finish = Completer<int?>(), started = Completer<void>(), release = Completer<void>();
    final h = _Harness((request, _, index) async* {
      if (index == 0) {
        yield ModelMessageComplete(_call('job_start', _command(), 'job'));
      } else if (index == 1) {
        started.complete();
        yield ModelMessageComplete(ModelMessage(ModelRole.assistant, text: 'job started'));
      } else {
        await release.future;
        yield ModelMessageComplete(ModelMessage(ModelRole.assistant, text: 'new answer'));
      }
    });
    addTearDown(h.close);
    addTearDown(() {
      if (!finish.isCompleted) finish.complete(0);
      if (!release.isCompleted) release.complete();
    });
    h.backend.target.pendingExecution = finish.future;
    final first = h.runtime.start('start a job', _conversationScope(mode: AgentPermissionMode.auto));
    var settled = false;
    unawaited(
      first.then((_) {
        settled = true;
      }),
    );
    await started.future;
    await _until(() => h.backend.target.tokens.single.isCancelled);
    expect(settled, isFalse);
    expect(h.runtime.busy, isTrue);
    expect(h.backend.target.releases, 0);
    await h.runtime.start('too early', _conversationScope(mode: AgentPermissionMode.auto));
    expect(h.model.requests, hasLength(2));
    h.journal.failTerminal = true;
    finish.completeError(StateError('late transport loss'));
    await first;
    expect(h.journal.terminalAttempts, 1);
    expect(h.runtime.error, 'journalFailed');
    expect(h.runtime.phase, AgentPhase.outcomeUnknown);
    expect(h.runtime.executions.single.failure, 'journalFailed');
    expect(h.backend.target.releases, 1);
    h.journal.failTerminal = false;
    final second = h.runtime.start('a new question', _conversationScope(mode: AgentPermissionMode.auto));
    await _until(() => h.model.requests.length == 3);
    expect(h.runtime.busy, isTrue);
    expect(h.runtime.error, isNull);
    expect(h.runtime.executions, isEmpty);
    release.complete();
    await second;
    expect(h.runtime.error, isNull);
    expect(h.runtime.messages.last.text, 'new answer');
    expect(h.backend.target.commands, hasLength(1));
  });

  test('settled waits for job exit and terminal journal before releasing its target', () async {
    final finish = Completer<int?>(), persist = Completer<void>();
    final h = _Harness((_, _, index) => _oneCall(_call('job_start', _command(), 'job'), index));
    addTearDown(h.close);
    addTearDown(() {
      if (!finish.isCompleted) finish.complete(0);
      if (!persist.isCompleted) persist.complete();
    });
    h.backend.target
      ..stdout = 'known job output\n'
      ..pendingExecution = finish.future;
    h.journal.pendingTerminal = persist;
    final work = h.runtime.start('finish and persist', _conversationScope(mode: AgentPermissionMode.auto));
    var settled = false;
    unawaited(
      h.runtime.settled.then((_) {
        settled = true;
      }),
    );
    await _until(() => h.backend.target.tokens.isNotEmpty && h.backend.target.tokens.single.isCancelled);
    final execution = h.runtime.executions.single;
    expect(execution.output, isNotNull);
    expect(execution.state, 'running');
    expect(h.runtime.busy, isTrue);
    expect(settled, isFalse);
    expect(h.backend.target.releases, 0);
    finish.completeError(StateError('channel closed after cancellation'));
    await _until(() => h.journal.terminalAttempts == 1);
    expect(execution.state, 'outcomeUnknown');
    expect(execution.sharedText, 'known job output\n');
    expect(h.journal.records.map((record) => record.state), [OperationState.intent]);
    expect(h.runtime.busy, isTrue);
    expect(settled, isFalse);
    expect(h.backend.target.releases, 0);
    persist.complete();
    await work;
    await h.runtime.settled;
    expect(settled, isTrue);
    expect(h.journal.records.map((record) => record.state), [OperationState.intent, OperationState.outcomeUnknown]);
    expect(h.runtime.executions.single, same(execution));
    expect(h.runtime.phase, AgentPhase.outcomeUnknown);
    expect(h.runtime.busy, isFalse);
    expect(h.backend.target.releases, 1);
  });

  test('stopping a background job cancels its command without replaying it', () async {
    final h = _Harness((request, _, index) async* {
      if (index == 0) {
        yield ModelMessageComplete(
          _call('job_start', {'hostId': _host.value, 'cwd': '/tmp', 'command': 'sleep 30'}, 'job'),
        );
      } else if (index == 1) {
        final jobId = _result(request)['jobId'];
        yield ModelMessageComplete(
          ModelMessage(
            ModelRole.assistant,
            calls: [
              ModelCall('stop', 'job_stop', {'jobId': jobId}),
            ],
          ),
        );
      } else if (index == 2) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        final jobId = _result(request, 0)['jobId'];
        yield ModelMessageComplete(
          ModelMessage(
            ModelRole.assistant,
            calls: [
              ModelCall('status', 'job_status', {'jobId': jobId}),
            ],
          ),
        );
      } else {
        yield ModelMessageComplete(ModelMessage(ModelRole.assistant, text: 'stopped'));
      }
    });
    addTearDown(h.close);
    h.backend.target.block = true;
    final work = h.runtime.start('start then stop it', _conversationScope(mode: AgentPermissionMode.confirm));
    await _until(() => h.runtime.approval != null);
    h.runtime.approve(true, expected: h.runtime.approval!);
    await work;
    expect(h.backend.target.commands, hasLength(1));
    expect(_result(h.model.requests.last, 2)['state'], 'outcomeUnknown');
    expect(h.journal.records.map((record) => record.state), [OperationState.intent, OperationState.outcomeUnknown]);
  });
}

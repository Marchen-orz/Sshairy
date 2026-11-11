import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sshairy/app/composition.dart';
import 'package:sshairy/features/ai/application/context.dart';
import 'package:sshairy/features/ai/application/providers.dart' show agentConversationRoutesProvider;
import 'package:sshairy/features/connections/api.dart' show HostTrustService, hostTrustProvider;
import 'package:sshairy/features/credentials/api.dart' show ConnectionCredentials, connectionCredentialsProvider;
import 'package:sshairy/features/hosts/api.dart' show Host, HostsNotifier, hostsProvider;
import 'package:sshairy/features/ai/application/output_store.dart';
import 'package:sshairy/features/ai/application/runtime.dart';
import 'package:sshairy/features/ai/domain/agent.dart';
import 'package:sshairy/features/ai/domain/conversation.dart';
import 'package:sshairy/features/ai/domain/model.dart';
import 'package:sshairy/features/capabilities/api.dart';
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
    return result;
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

class _Journal implements OperationJournal {
  final records = <OperationRecord>[];
  var loads = 0;
  bool failIntent = false, failLoad = false;

  @override
  Future<List<OperationRecord>> load() async {
    loads++;
    if (failLoad) throw StateError('simulated corrupt journal');
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
  _Harness(_Script script, {bool tools = true, OutputStore? outputs, Map<HostId, String> Function()? hostRoutes})
    : model = _Model(script) {
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
      hostRoutes: hostRoutes ?? () => routes,
      configuration: () => (enabled: enabled, profile: profile, revision: revision),
    );
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

  Future<void> close() async {
    runtime.stop();
    await runtime.settled.timeout(const Duration(seconds: 2));
    runtime.dispose();
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
  for (final mode in AgentPermissionMode.values) {
    test('$mode requires host consent before preparing another host', () async {
      final remote = mode == AgentPermissionMode.observe
          ? _call('diagnostics_collect', {'hostId': _other.value, 'template': 'systemSummary'})
          : _call('command_execute', _command(host: _other.value));
      final h = _Harness((request, _, _) async* {
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
      });
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
      h.runtime.decideHost(pending, true);
      if (mode == AgentPermissionMode.confirm) {
        await _until(() => h.runtime.approval != null);
        expect(h.backend.others[_other]!.commands, isEmpty);
        h.runtime.approve(true, expected: h.runtime.approval!);
      }
      if (mode != AgentPermissionMode.observe) {
        await _until(() => h.runtime.dataRequest != null);
        h.runtime.shareOutput(null, expected: h.runtime.dataRequest!);
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

  test('observe still permits fixed diagnostics on the frozen host', () async {
    final h = _Harness(
      (_, _, index) =>
          _oneCall(_call('diagnostics_collect', {'hostId': _host.value, 'template': 'systemSummary'}), index),
    );
    addTearDown(h.close);
    h.backend.target.stdout = _systemOutput;
    await h.runtime.start(
      'inspect selected host',
      AgentScope(hosts: const [_host], permissionMode: AgentPermissionMode.observe),
    );
    expect(h.backend.target.commands, hasLength(1));
    expect(h.runtime.approval, isNull);
    expect(h.runtime.phase, AgentPhase.completed);
    expect(h.journal.records, isEmpty);
  });

  test('auto executes without command approval but keeps intent and a separate output decision', () async {
    final h = _Harness((_, _, index) => _oneCall(_call('command_execute', _command()), index));
    addTearDown(h.close);
    final work = h.runtime.start(
      'run selected command',
      AgentScope(hosts: const [_host], permissionMode: AgentPermissionMode.auto),
    );
    await _until(() => h.runtime.dataRequest != null);
    expect(h.runtime.permissionMode, AgentPermissionMode.auto);
    expect(h.runtime.approval, isNull);
    expect(h.backend.target.commands, hasLength(1));
    expect(h.journal.records.map((record) => record.state), [OperationState.intent, OperationState.completed]);
    expect(h.model.requests, hasLength(1));
    h.runtime.shareOutput(null, expected: h.runtime.dataRequest!);
    await work;
    expect(_requestText(h.model.requests.last), isNot(contains(_privateOutput)));
    expect(_result(h.model.requests.last)['output'], 'withheld');
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
      contextWindow: 7000,
      maxOutputTokens: 1000,
    );
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
    await _until(() => h.runtime.dataRequest != null);
    h.runtime.shareOutput(selected, expected: h.runtime.dataRequest!);
    await turn;

    expect(h.runtime.phase, AgentPhase.completed);
    expect(h.runtime.contextCompacted, isTrue);
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
    expect(h.runtime.executions.last.state, 'outcomeUnknown');
    expect(h.runtime.executions.last.sharedText, isNull);
    expect(h.runtime.outputs.count, 0);
    expect(h.runtime.approval, isNull);
    expect(h.runtime.dataRequest, isNull);
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
    expect(h.runtime.executions.map((entry) => entry.state), [
      'completed',
      'interrupted',
      'cancelled',
      'outcomeUnknown',
    ]);
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
    final first = h.runtime.startConversation('first question', AgentScope(hosts: const [_host]), const []);
    await _until(() => h.runtime.approval != null);
    final oldApproval = h.runtime.approval!;
    h.runtime.approve(true, expected: oldApproval);
    await _until(() => h.runtime.dataRequest != null);
    final oldData = h.runtime.dataRequest!;
    h.runtime.shareOutput('approved summary', expected: oldData);
    await first;
    expect(h.runtime.executions.single.sharedText, 'approved summary');
    expect(h.runtime.executions.single.output!.stdout, _privateOutput);
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
        },
    ];

    h.runtime.restoreConversation(entries);
    h.runtime.approve(true, expected: oldApproval);
    h.runtime.shareOutput('stale selection', expected: oldData);
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
    expect(history['entries'], contains(containsPair('text', 'approved summary')));
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
    final longPath = List.filled(100, 'a').join();
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
    expect(h.runtime.executions.first.sharedText, isNull);
    expect(h.runtime.executions.last.toolName, 'output_read');
    expect(h.runtime.executions.last.sharedText, isNull);
    expect(h.runtime.executions.last.state, 'failed');
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
    expect(h.runtime.executions.first.sharedText, 'user selected summary');
    expect(h.runtime.executions.map((entry) => entry.toolName), [
      'command_execute',
      'output_read',
      'output_read',
      'output_read',
    ]);
    expect(h.runtime.executions.skip(1).map((entry) => entry.state), ['completed', 'failed', 'failed']);
    expect(h.runtime.executions.skip(1).every((entry) => entry.sharedText == null && entry.output == null), isTrue);
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
    expect(jsonDecode(_results(h.model.requests.last).single.text), [
      {'id': 'host-a', 'alias': 'selected host'},
      {'id': 'host-b', 'alias': 'unselected host'},
    ]);
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
    await _until(() => h.runtime.dataRequest != null);
    h.runtime.shareOutput(null, expected: h.runtime.dataRequest!);
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
    expect(jsonDecode(_results(h.model.requests[1]).single.text), [
      {'id': 'host-a', 'alias': 'selected host'},
      {'id': 'host-b', 'alias': 'unselected host'},
    ]);
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
    final data = jsonDecode(_results(h.model.requests.last).single.text);
    expect(data, [
      {'id': 'host-a', 'alias': 'selected host'},
      {'id': 'host-b', 'alias': 'unselected host'},
    ]);
    expect(h.runtime.hostApproval, isNull);
    expect(h.backend.prepared, isEmpty);
  });

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
    expect(request.tools.map((tool) => tool.name), unorderedEquals(AgentRuntime.toolIds.keys));
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
    final turn = h.start();
    await _until(() => h.runtime.approval != null);
    h.runtime.approve(true, expected: h.runtime.approval!);
    await _until(() => h.runtime.dataRequest != null);
    expect(h.runtime.executions.single.exitCode, 7);
    expect(h.runtime.executions.single.state, 'failed');
    expect(h.journal.records.last.state, OperationState.failed);
    h.runtime.stop();
    await turn;
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
    await h.start();
    expect(h.runtime.error, 'toolLimit');
    expect(h.backend.prepared, isEmpty);
    expect(h.backend.target.commands, isEmpty);
  });
}

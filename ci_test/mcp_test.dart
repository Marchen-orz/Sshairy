import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/app/composition.dart';
import 'package:sshairy/app/mcp/controller.dart';
import 'package:sshairy/app/mcp/storage.dart';
import 'package:sshairy/features/ai/api.dart';
import 'package:sshairy/features/capabilities/api.dart';
import 'package:sshairy/features/credentials/api.dart';
import 'package:sshairy/features/settings/api.dart';
import 'package:sshairy/foundation/cancellation.dart';
import 'package:sshairy/foundation/data_dir.dart';
import 'package:sshairy/foundation/ids.dart';
import 'package:sshairy/foundation/secret.dart';

final _first = HostId('first');
final _second = HostId('second');
const _args = {'hostId': 'first', 'template': 'systemSummary'};

void main() {
  late _Harness h;
  setUp(() async {
    h = _Harness();
    addTearDown(h.close);
  });

  test('loopback authentication and the real capability catalog restrict external tools and templates', () async {
    await h.start();
    expect((await h.post('initialize', bearer: 'bad')).status, 401);
    expect((await h.post('initialize', origin: 'http://localhost')).status, 403);
    expect((await h.post('initialize', host: 'localhost')).status, 403);
    final session = await h.open();
    final other = (await h.controller.pair(McpClient.codex)).reveal();
    expect((await h.post('tools/list', session: session, bearer: other)).status, 404);
    final catalog = (await h.post('tools/list', session: session)).body!['result'] as Map;
    final tools = (catalog['tools'] as List).cast<Map>();
    expect(tools.map((tool) => tool['name']), ['host_list', 'diagnostics_collect']);
    final schema = tools.last['inputSchema'] as Map;
    expect(schema['properties']['template']['enum'], ['systemSummary', 'storageCapacity']);
    final internal = h.controller.dispatcher['agent.diagnose']!.inputSchema;
    expect((internal['properties'] as Map)['template']['enum'], contains('processSummary'));
    expect(await h.error(session, name: 'command_execute'), 'notExposed');
    expect(await h.error(session, arguments: {..._args, 'template': 'processSummary'}), 'invalidArgument');
    expect(await h.error(session, arguments: {..._args, 'command': 'unrecognized'}), 'invalidArgument');
    expect(h.backend.prepared, 0);
    expect(h.controller.approval, isNull);
  });

  test('host confirmation happens before prepare, is reused in-session, and is reset in another session', () async {
    await h.start();
    final session = await h.open();
    final pending = h.tool(session);
    final approval = await h.approval();
    expect(h.backend.prepared, 0);
    h.controller.decide(approval, true);
    final first = await pending;
    expect(first['isError'], false);
    expect(first['structuredContent']['data']['system'], 'Linux');
    expect(jsonEncode(first), isNot(contains('ignored-private-output')));
    expect((await h.tool(session, arguments: {..._args, 'template': 'storageCapacity'}))['isError'], false);
    expect(h.backend.prepared, 2);
    expect(h.reviewed, 0);
    final next = h.error(await h.open());
    h.controller.decide(await h.approval(), false);
    expect(await next, 'hostDenied');
    expect(h.backend.prepared, 2);
    final records = await h.records();
    expect(records.where((row) => row['stage'] == 'starting'), hasLength(2));
    expect(records.where((row) => row['outcome'] == 'hostDenied').single['hostDecision'], 'denied');
    expect(jsonEncode(records), isNot(contains(h.token)));
    expect(jsonEncode(records), isNot(contains('ignored-private-output')));
  });

  test('model mode requires host approval and a fresh explicit model allow for each tool call', () async {
    await h.start(mode: McpApprovalMode.model);
    final session = await h.open();
    final denied = h.error(session);
    final approval = await h.approval();
    expect(h.reviewed, 0);
    h.controller.decide(approval, true);
    expect(await denied, 'reviewDenied');
    expect(h.backend.prepared, 0);
    h.decision = AgentReviewDecision.ask;
    expect(await h.error(session), 'reviewUnavailable');
    expect(h.backend.prepared, 0);
    h.decision = AgentReviewDecision.allow;
    expect((await h.tool(session))['isError'], false);
    expect((await h.tool(session, name: 'host_list', arguments: {}))['isError'], false);
    expect(h.reviewed, 4);
    expect(h.backend.prepared, 1);
    expect(h.controller.approval, isNull);
  });

  test('automatic scope covers selected routes and listener restart does not restore an invalidated grant', () async {
    final scope = {'first': h.digests[_first]!};
    await h.start(mode: McpApprovalMode.automatic, scope: scope);
    final session = await h.open();
    final listed = await h.tool(session, name: 'host_list', arguments: {});
    expect(listed['structuredContent']['hosts'], [
      {'id': 'first', 'alias': 'Primary'},
    ]);
    expect(await h.error(session, arguments: {..._args, 'hostId': 'second'}), 'outsideScope');
    expect((await h.tool(session))['isError'], false);
    expect(h.reviewed, 0);
    expect(h.controller.approval, isNull);
    h.routes[_first] = 'changed';
    expect(await h.error(session), 'outsideScope');
    h.controller.configure((enabled: false, port: 0, mode: McpApprovalMode.automatic, hosts: scope));
    await h.start(mode: McpApprovalMode.automatic, scope: scope);
    expect(await h.error(await h.open()), 'outsideScope');
    expect(h.backend.prepared, 1);
  });

  test('client revocation cancels in-flight work and rejects the previous token', () async {
    await h.start(mode: McpApprovalMode.automatic, scope: {'first': h.digests[_first]!});
    final session = await h.open();
    h.backend.block = true;
    final pending = h.error(session);
    await h.backend.started.future.timeout(const Duration(seconds: 5));
    final old = h.token;
    await h.controller.revoke(McpClient.claude);
    expect(await pending, 'cancelled');
    expect((await h.post('tools/list', session: session, bearer: old)).status, 401);
    expect((await h.records()).first['outcome'], 'cancelled');
    expect(h.backend.releases, 1);
    expect((await h.controller.pair(McpClient.claude)).reveal(), isNot(old));
  });

  test('MCP settings round-trip and cannot be changed through Agent settings', () async {
    final store = h.container.read(settingsProvider.notifier);
    final defaults = h.container.read(settingsProvider);
    expect(defaults.get(SettingKeys.mcpEnabled), false);
    expect(defaults.get(SettingKeys.mcpMode), McpApprovalMode.host);
    final scope = {'first': h.digests[_first]!};
    await store.set(SettingKeys.mcpHosts, scope);
    final reloaded = Settings.fromJson(
      jsonDecode(File('${h.dir.path}/settings.json').readAsStringSync()) as Map<String, dynamic>,
    );
    expect(reloaded.get(SettingKeys.mcpHosts), scope);
    for (final key in <SettingDef<Object?>>[
      SettingKeys.mcpEnabled,
      SettingKeys.mcpPort,
      SettingKeys.mcpMode,
      SettingKeys.mcpHosts,
    ]) {
      expect(key.agentExposed, false);
    }
  });

  test('audit failure fails closed before diagnostic execution', () async {
    await h.start(mode: McpApprovalMode.automatic, scope: {'first': h.digests[_first]!});
    File('${h.dir.path}/mcp-audit').createSync();
    expect(await h.error(await h.open()), 'auditUnavailable');
    expect(h.backend.prepared, 0);
  });

  test('Skill installation is reversible per client and preserves an edited file', () {
    final skills = McpSkills(environment: {Platform.isWindows ? 'USERPROFILE' : 'HOME': h.dir.path});
    for (final client in McpClient.values) {
      expect(skills.status(client), SkillStatus.absent);
      skills.setInstalled(client, true);
      expect(skills.status(client), SkillStatus.installed);
    }
    skills.setInstalled(McpClient.codex, false);
    expect(skills.status(McpClient.codex), SkillStatus.absent);
    final file = File('${h.dir.path}/.claude/skills/sshairy/SKILL.md');
    expect(file.readAsStringSync(), sshairySkill);
    file.writeAsStringSync('user-owned content');
    expect(skills.status(McpClient.claude), SkillStatus.conflict);
    expect(() => skills.setInstalled(McpClient.claude, false), throwsA(isA<FileSystemException>()));
    expect(file.readAsStringSync(), 'user-owned content');
    expect(skills.status(McpClient.deepseek), SkillStatus.installed);
  });
}

class _Harness {
  _Harness() {
    container = ProviderContainer(overrides: [dataDirProvider.overrideWithValue(dir.path), ...appOverrides()]);
    controller = McpController(
      dispatcher: container.read(capabilityDispatcherProvider),
      backend: () => backend,
      routes: () => routes,
      routeDigests: () => digests,
      review: (_, _) async {
        reviewed++;
        return decision;
      },
      audit: McpAudit(dir.path),
      credentials: _MemoryCredentials(),
    );
  }

  final dir = Directory.systemTemp.createTempSync('sshairy-mcp-');
  final http = HttpClient()..findProxy = (_) => 'DIRECT';
  final backend = _Backend();
  final routes = {_first: 'first-route', _second: 'second-route'};
  final digests = {_first: 'a' * 64, _second: 'b' * 64};
  late final ProviderContainer container;
  late final McpController controller;
  late String token;
  int reviewed = 0, _id = 0;
  var decision = AgentReviewDecision.deny;

  Future<void> start({McpApprovalMode mode = McpApprovalMode.host, Map<String, String> scope = const {}}) async {
    controller.configure((enabled: true, port: 0, mode: mode, hosts: scope));
    await _until(() => controller.running || controller.failed);
    expect(controller.running, true);
    token = (await controller.pair(McpClient.claude)).reveal();
  }

  Future<McpHostApproval> approval() async {
    await _until(() => controller.approval != null);
    return controller.approval!;
  }

  Future<void> _until(bool Function() ready) async {
    final end = DateTime.now().add(const Duration(seconds: 4));
    while (!ready()) {
      if (DateTime.now().isAfter(end)) throw TimeoutException('MCP state did not arrive');
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  Future<({int status, Map<String, dynamic>? body, String? session})> post(
    String method, {
    String? session,
    String? bearer,
    String? origin,
    String? host,
    bool notification = false,
    Map<String, Object?> params = const {},
  }) async {
    final request = await http.postUrl(Uri.parse(controller.url));
    request.headers.contentType = ContentType.json;
    request.headers.set('Accept', 'application/json, text/event-stream');
    request.headers.set('Authorization', 'Bearer ${bearer ?? token}');
    if (origin != null) request.headers.set('Origin', origin);
    if (host != null) request.headers.set('Host', host);
    if (session != null) {
      request.headers.set('Mcp-Session-Id', session);
      request.headers.set('Mcp-Protocol-Version', '2025-11-25');
    }
    request.write(jsonEncode({'jsonrpc': '2.0', if (!notification) 'id': ++_id, 'method': method, 'params': params}));
    final response = await request.close();
    final text = await utf8.decoder.bind(response).join();
    return (
      status: response.statusCode,
      body: text.isEmpty ? null : jsonDecode(text) as Map<String, dynamic>,
      session: response.headers.value('Mcp-Session-Id'),
    );
  }

  Future<String> open() async {
    final init = await post('initialize', params: {'protocolVersion': '2025-11-25'});
    expect(init.status, 200);
    expect(init.body!['result']['protocolVersion'], '2025-11-25');
    final session = init.session!;
    expect((await post('notifications/initialized', session: session, notification: true)).status, 202);
    return session;
  }

  Future<Map<String, dynamic>> tool(
    String session, {
    String name = 'diagnostics_collect',
    Map<String, Object?> arguments = _args,
  }) async {
    final response = await post('tools/call', session: session, params: {'name': name, 'arguments': arguments});
    expect(response.status, 200);
    return response.body!['result'] as Map<String, dynamic>;
  }

  Future<String> error(
    String session, {
    String name = 'diagnostics_collect',
    Map<String, Object?> arguments = _args,
  }) async {
    final result = await tool(session, name: name, arguments: arguments);
    expect(result['isError'], true);
    return result['content'][0]['text'] as String;
  }

  Future<List<Map>> records() async => [for (final line in await controller.audit.recent()) jsonDecode(line) as Map];

  Future<void> close() async {
    http.close(force: true);
    await controller.shutdown();
    controller.dispose();
    container.dispose();
    dir.deleteSync(recursive: true);
  }
}

class _MemoryCredentials implements McpCredentials {
  final _values = <String, Secret>{};
  @override
  Future<Secret?> read(String client) async => _values[client];
  @override
  Future<void> save(String client, Secret value) async => _values[client] = value;
  @override
  Future<void> clear(String client) async => _values.remove(client);
}

class _Backend implements AgentBackend {
  int prepared = 0, releases = 0;
  bool block = false;
  final started = Completer<void>();

  @override
  List<AgentHost> get hosts => [AgentHost(_first, 'Primary'), AgentHost(_second, 'Secondary')];

  @override
  Future<AgentTarget> prepare(HostId host, CancellationToken cancel) async {
    prepared++;
    return _Target(this, host);
  }
}

class _Target implements AgentTarget {
  _Target(this.backend, this.hostId);
  final _Backend backend;
  @override
  final HostId hostId;
  @override
  final identity = 'fake-connection', display = 'fake';
  @override
  bool current = true;

  @override
  Future<bool> supportsPosix(CancellationToken cancel) async => true;

  @override
  Future<int?> execute(
    String command,
    void Function(bool, Uint8List) output, {
    required Duration timeout,
    required CancellationToken cancel,
  }) async {
    if (backend.block) {
      backend.started.complete();
      await cancel.whenCancelled;
    }
    final sample = command.contains('df -kPTl')
        ? '@@storage\nFilesystem Type 1024-blocks Used Available Capacity Mounted on\n/dev/sda ext4 1000 400 600 40% /\n'
        : '@@system\nLinux\n@@memory\nMemTotal: 100000 kB\nPrivateToken: ignored-private-output\n';
    output(false, Uint8List.fromList(utf8.encode(sample)));
    return 0;
  }

  @override
  void release() {
    current = false;
    backend.releases++;
  }
}

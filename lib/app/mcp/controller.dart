import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/ai/api.dart';
import '../../features/capabilities/api.dart';
import '../../features/credentials/api.dart';
import '../../features/hosts/api.dart';
import '../../features/settings/api.dart';
import '../../features/terminal/api.dart';
import '../../foundation/cancellation.dart';
import '../../foundation/data_dir.dart';
import '../../foundation/ids.dart';
import '../../foundation/result.dart';
import '../../foundation/secret.dart';
import '../ai_terminal_hosts.dart';
import 'http.dart';
import 'storage.dart';

const mcpDiagnosticTemplates = DiagnosticTemplate.values;

typedef McpConfig = ({bool enabled, int port, McpApprovalMode mode, Map<String, String> hosts});

final mcpRouteDigestsProvider = Provider<Map<HostId, String>>(
  (ref) => {
    for (final host in aiTerminalHosts(ref.watch(hostsProvider)))
      host.id: conversationRouteFingerprint(
        host.signature,
        trustRevision: 0,
        credentialRevision: 0,
        securitySession: 'mcp',
      ),
  },
);
McpConfig _config(Settings settings) => (
  enabled: settings.get(SettingKeys.mcpEnabled),
  port: settings.get(SettingKeys.mcpPort),
  mode: settings.get(SettingKeys.mcpMode),
  hosts: settings.get(SettingKeys.mcpHosts),
);

final mcpClientsProvider = Provider<McpClients>((_) => McpClients());

final mcpControllerProvider = Provider<McpController>((ref) {
  final controller = McpController(
    dispatcher: ref.read(capabilityDispatcherProvider),
    backend: () => ref.read(agentBackendProvider),
    routes: ref.read(agentConversationRoutesProvider),
    terminalHistory: ref.read(agentTerminalHistoryProvider),
    routeDigests: () => ref.read(mcpRouteDigestsProvider),
    review: (operation, cancel) async {
      final config = ref.read(aiConfigurationProvider);
      final profile = config.enabled ? config.profileForReview ?? config.profile : null;
      if (profile == null) return AgentReviewDecision.ask;
      return AgentReviewer(ref.read(aiModelProvider)).review(
        profile: profile,
        goal: 'Review this read-only request from a paired local client. Host and terminal access are authorized separately.',
        operation: operation,
        cancel: cancel,
      );
    },
    audit: McpAudit(ref.read(dataDirProvider)),
    credentials: ref.read(mcpCredentialsProvider),
    clients: ref.read(mcpClientsProvider),
  );
  ref.listen(settingsProvider, (_, settings) => controller.configure(_config(settings)), fireImmediately: true);
  ref.listen(aiConfigurationProvider, (_, _) => controller.invalidateReview());
  final keys = ref.read(aiCredentialsProvider).changes.listen((_) => controller.invalidateReview());
  ref.onDispose(keys.cancel);
  ref.onDispose(controller.dispose);
  return controller;
});

sealed class McpApproval {
  McpApproval(this.client, this._key, this._isCurrent);

  final McpClient client;
  final Object _key;
  final bool Function() _isCurrent;
  final _waiters = <CancellationToken>{};
  final _answer = Completer<bool>();
}

final class McpConnectionApproval extends McpApproval {
  McpConnectionApproval(McpClient client, this._token, bool Function() isCurrent) : super(client, _token, isCurrent);
  final Secret _token;
}

final class McpHostApproval extends McpApproval {
  McpHostApproval(this.session, this.host, this.grantKey, bool Function() isCurrent)
    : super(session.client, (session, grantKey), isCurrent);

  final AgentHost host;
  final McpSession session;
  final String grantKey;
}

final class McpTerminalApproval extends McpApproval {
  McpTerminalApproval(this.session, this.terminal, this.maxLines, Object key, bool Function() isCurrent)
    : super(session.client, key, isCurrent);

  final McpSession session;
  final TerminalHistorySession terminal;
  final int? maxLines;
}

class McpController extends ChangeNotifier {
  McpController({
    required this.dispatcher,
    required this.backend,
    required this.routes,
    required this.routeDigests,
    required this.review,
    required this.audit,
    required this.credentials,
    this.terminalHistory,
    McpClients? clients,
  }) : clients = clients ?? McpClients();

  final CapabilityDispatcher dispatcher;
  final AgentBackend Function() backend;
  final Map<HostId, String> Function() routes, routeDigests;
  final Future<AgentReviewDecision> Function(Map<String, Object?>, CancellationToken) review;
  final McpAudit audit;
  final McpCredentials credentials;
  final McpClients clients;
  final TerminalHistoryReader? terminalHistory;
  final _tokens = <McpClient, Secret>{};
  final _revoked = <McpClient>{};
  final _changing = <McpClient>{};
  final _approvedClients = <McpClient>{};
  final _clientUpdateFailed = <McpClient>{};
  final _approvals = <McpApproval>[];
  final _active = <Future<Map<String, Object?>>>{};
  final _autoRoutes = <HostId, String>{};
  late McpConfig _settings;
  McpHttp? _http;
  Future<void> _sync = Future.value();
  int _generation = 0;
  bool _configured = false, _disposed = false, _paused = false;
  bool failed = false;

  bool get running => _http != null;
  String get url => 'http://127.0.0.1:${_http?.port ?? _settings.port}/mcp';
  McpApproval? get approval => _approvals.firstOrNull;
  bool paired(McpClient client) => _tokens.containsKey(client) || _revoked.contains(client);
  bool clientUpdateFailed(McpClient client) => _clientUpdateFailed.contains(client);

  Future<bool> _confirmClient(McpClient client, CancellationToken cancel) async {
    final token = _tokens[client];
    if (token == null) return false;
    if (_approvedClients.contains(client)) return true;
    final generation = _generation;
    return _ask(
      McpConnectionApproval(client, token, () => generation == _generation && identical(_tokens[client], token)),
      cancel,
    );
  }

  bool inAutomaticScope(HostId id, Map<HostId, String> current) =>
      _autoRoutes[id] != null && _autoRoutes[id] == current[id];

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void configure(McpConfig next) {
    if (_configured &&
        next.enabled == _settings.enabled &&
        next.port == _settings.port &&
        next.mode == _settings.mode &&
        mapEquals(next.hosts, _settings.hosts)) {
      return;
    }
    final previous = _configured ? _settings.hosts : const <String, String>{};
    if (!mapEquals(previous, next.hosts)) {
      final current = routes(), digests = routeDigests();
      _autoRoutes.removeWhere((id, _) => next.hosts[id.value] != previous[id.value]);
      for (final entry in next.hosts.entries) {
        if (previous[entry.key] == entry.value) continue;
        final id = HostId(entry.key);
        final binding = current[id];
        if (binding != null && digests[id] == entry.value) _autoRoutes[id] = binding;
      }
    }
    final listen = !_configured || next.enabled != _settings.enabled || next.port != _settings.port;
    _settings = next;
    _configured = true;
    if (listen) {
      _restart();
    } else {
      // Mode and scope changes only end current grants; the listener and address stay up.
      _http?.revoke();
      _notify();
    }
  }

  void _restart() {
    final generation = ++_generation;
    final old = _http;
    _http = null;
    final stopped = old?.close();
    failed = false;
    bool current() => !_disposed && generation == _generation && !_paused;
    bool live() => current() && _settings.enabled;
    _sync = _sync.then((_) async {
      try {
        await stopped;
        if (!current()) return;
        for (final client in McpClient.values) {
          if (_changing.contains(client)) continue;
          final value = await credentials.read(client.name);
          if (!current()) return;
          if (_changing.contains(client)) continue;
          final stored = value?.reveal();
          final approved = stored?.endsWith(':approved') ?? false;
          // The old suffix recorded a notification, not permission to connect.
          final raw = approved
              ? stored!.substring(0, stored.length - ':approved'.length)
              : stored?.endsWith(':seen') == true
              ? stored!.substring(0, stored.length - ':seen'.length)
              : stored;
          if (!_revoked.contains(client) && raw != null && mcpTokenPattern.hasMatch(raw)) {
            if (_tokens[client]?.reveal() != raw) _approvedClients.remove(client);
            _tokens[client] = Secret(raw);
            if (approved) _approvedClients.add(client);
          } else {
            _tokens.remove(client);
            _approvedClients.remove(client);
          }
        }
        if (!live()) {
          _notify();
          return;
        }
        final listener = await McpHttp.bind(_settings.port);
        if (!live()) {
          await listener.close(force: true);
          return;
        }
        _http = McpHttp(listener, _authenticate, _tools, _call, _closeSession, _confirmClient);
        for (final entry in _tokens.entries) {
          try {
            clients.refresh(entry.key, url, entry.value.reveal());
            _clientUpdateFailed.remove(entry.key);
          } on Object {
            _clientUpdateFailed.add(entry.key);
          }
        }
      } on Object {
        if (live()) failed = true;
      }
      _notify();
    });
    _notify();
  }

  void invalidateReview() {
    if (_configured && _settings.mode == McpApprovalMode.model) _http?.revoke();
  }

  Future<void> shutdown() async {
    _paused = true;
    if (_configured) _restart();
    await _sync;
    await Future.wait(_active.toList());
  }

  void resume() {
    _paused = false;
    if (_configured) _restart();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(shutdown());
    super.dispose();
  }

  Future<void> connect(McpClient client) async {
    if (!running) throw StateError('MCP disabled');
    if (!_changing.add(client)) throw StateError('MCP credential change pending');
    final generation = _generation;
    final existing = _tokens[client];
    final token = existing ?? Secret(mcpRandomToken());
    try {
      if (existing == null) await credentials.save(client.name, token);
      if (_disposed || generation != _generation || !running) throw StateError('MCP unavailable');
      clients.connect(client, url, token.reveal());
      _tokens[client] = token;
      _revoked.remove(client);
      _clientUpdateFailed.remove(client);
    } on Object {
      if (existing == null) {
        _revoked.add(client);
        await credentials.clear(client.name);
        _revoked.remove(client);
      }
      rethrow;
    } finally {
      _changing.remove(client);
      _notify();
    }
  }

  Future<void> disconnect(McpClient client) async {
    if (!_changing.add(client)) throw StateError('MCP credential change pending');
    _revoked.add(client);
    _tokens.remove(client);
    _approvedClients.remove(client);
    _http?.revoke(client);
    _notify();
    try {
      try {
        await credentials.clear(client.name);
        _revoked.remove(client);
      } finally {
        clients.disconnect(client);
        _clientUpdateFailed.remove(client);
      }
    } finally {
      _changing.remove(client);
      _notify();
    }
  }

  McpClient? _authenticate(String header) {
    if (!header.startsWith('Bearer ') || header.length != 50) return null;
    final supplied = header.substring(7);
    for (final entry in _tokens.entries) {
      final expected = entry.value.reveal();
      var difference = 0;
      for (var i = 0; i < expected.length; i++) {
        difference |= expected.codeUnitAt(i) ^ supplied.codeUnitAt(i);
      }
      if (difference == 0) return entry.key;
    }
    return null;
  }

  Iterable<AgentTool> get _exposed => agentTools.where((tool) {
    final capability = dispatcher[tool.capability];
    return capability != null &&
        capability.externalAgentExposed &&
        capability.agentExposed &&
        capability.effect != Effect.security;
  });

  List<Map<String, Object?>> _tools() => [
    for (final tool in _exposed)
      {
        'name': tool.name,
        'description': switch (tool.capability) {
          'agent.hosts' => 'List available saved host IDs and aliases in pages.',
          'agent.terminalHistory' => 'Read bounded history for the specified sessionId after local approval.',
          'agent.terminalScreen' => 'Read visible text for the specified sessionId after approving this read locally.',
          _ => tool.description,
        },
        'inputSchema': dispatcher[tool.capability]!.inputSchemaFor(Origin.externalAgent),
        'annotations': {'readOnlyHint': tool.readOnly},
      },
  ];

  Future<Map<String, Object?>> _call(McpSession session, Map<String, Object?> params, CancellationToken cancel) {
    final work = _dispatch(session, params, cancel);
    _active.add(work);
    return work.whenComplete(() => _active.remove(work));
  }

  Future<Map<String, Object?>> _dispatch(
    McpSession session,
    Map<String, Object?> params,
    CancellationToken cancel,
  ) async {
    final tool = _exposed.where((tool) => tool.name == params['name']).firstOrNull;
    final authority = McpCall(this, session, _settings.mode, cancel, tool?.name);
    final context = RequestContext(
      Origin.externalAgent,
      authority: authority,
      cancellation: cancel,
      authorizationIsCurrent: () => session.current,
    );
    try {
      authority.operation = context.operationId;
      try {
        await authority.record('received', tool?.name, 'pending');
      } on Object {
        return mcpToolResult('auditUnavailable', error: true);
      }
      String outcome = 'failed';
      Object? value;
      try {
        final args = params['arguments'] ?? const <String, Object?>{};
        final result = tool == null
            ? const Err<Object?>(AppError('notExposed'))
            : args is! Map<String, Object?>
            ? const Err<Object?>(AppError('invalidArgument'))
            : await dispatcher.dispatch(tool.capability, args, context);
        switch (result) {
          case Ok(value: final value2):
            value = value2;
            outcome = 'completed';
          case Err(:final error):
            outcome = error.code;
        }
      } on AgentFailure catch (error) {
        outcome = error.code;
      } on Object {
        outcome = 'failed';
      }
      if (!context.isCurrent) outcome = 'cancelled';
      if (outcome == 'completed' && !authority.bound) outcome = 'scopeChanged';
      try {
        await authority.record('finished', tool?.name, outcome);
      } on Object {
        return mcpToolResult('auditUnavailable', error: true);
      }
      if (outcome == 'completed' && !authority.bound) {
        try {
          await authority.record('withheld', tool?.name, context.isCurrent ? 'scopeChanged' : 'cancelled');
        } on Object {
          return mcpToolResult('auditUnavailable', error: true);
        }
        return mcpToolResult('scopeChanged', error: true);
      }
      return outcome == 'completed' ? mcpToolResult(value) : mcpToolResult(outcome, error: true);
    } finally {
      authority._target?.release();
    }
  }

  Future<bool> _confirm(McpSession session, AgentHost host, String binding, CancellationToken cancel) async {
    final key = '${host.id.value}:$binding';
    if (session.grants[key] case final value?) return value;
    return _ask(McpHostApproval(session, host, key, () => session.current && routes()[host.id] == binding), cancel);
  }

  Future<bool> _ask(McpApproval request, CancellationToken cancel) async {
    if (cancel.isCancelled || !request._isCurrent()) return false;
    final existing = _approvals
        .where((item) => item.runtimeType == request.runtimeType && item._key == request._key)
        .firstOrNull;
    if (existing == null && _approvals.length >= 8) return false;
    final pending = existing ?? request;
    if (existing == null) _approvals.add(pending);
    pending._waiters.add(cancel);
    if (pending._waiters.length == 1) _notify();
    try {
      return await Future.any([pending._answer.future, cancel.whenCancelled.then((_) => false)]);
    } finally {
      pending._waiters.remove(cancel);
      if (pending._waiters.isEmpty && _approvals.remove(pending)) {
        pending._answer.complete(false);
        _notify();
      }
    }
  }

  void decide(McpApproval item, bool allowed) {
    if (!_approvals.remove(item)) return;
    final current = item._isCurrent() && item._waiters.any((token) => !token.isCancelled);
    if (current) {
      switch (item) {
        case McpHostApproval(:final session, :final grantKey):
          session.grants[grantKey] = allowed;
        case McpTerminalApproval(:final session, :final terminal, maxLines: null):
          session.terminalGrants[terminal.sessionId] = (terminal: terminal, allowed: allowed);
        case McpConnectionApproval(:final client, :final _token) when allowed:
          _approvedClients.add(client);
          unawaited(credentials.save(client.name, Secret('${_token.reveal()}:approved')).catchError((Object _) {}));
        default:
          break;
      }
    }
    item._answer.complete(allowed && current);
    _notify();
  }

  void _closeSession(McpSession session) {
    for (final item in _approvals.toList()) {
      if (switch (item) {
        McpHostApproval(session: final expected) ||
        McpTerminalApproval(session: final expected) => identical(expected, session),
        _ => false,
      }) {
        decide(item, false);
      }
    }
  }
}

/// An authority for one operation. It shares no Airy chat state or output handles.
class McpCall implements AgentAuthority {
  McpCall(this._owner, this._session, this._mode, this._cancel, this._tool);
  final McpController _owner;
  final McpSession _session;
  final McpApprovalMode _mode;
  final CancellationToken _cancel;
  final String? _tool;
  late final OperationId operation;
  AgentHost? _host;
  String? _route;
  DiagnosticTemplate? _template;
  AgentTarget? _target;
  Map<HostId, String>? _listedRoutes;
  TerminalHistorySession? _terminal;
  List<TerminalHistorySession> _listedTerminals = const [];
  int? _exitCode;
  String _hostDecision = 'notRequired', _modelDecision = 'notRequired';

  bool get bound {
    if (!_session.current || _cancel.isCancelled || !(_target?.current ?? true)) return false;
    if (_terminal case final terminal?) {
      if (!_terminalCurrent(terminal)) return false;
    }
    if (!_listedTerminals.every(_terminalCurrent)) return false;
    if (_host == null && _listedRoutes == null) return true;
    final current = _owner.routes();
    if (_host case final host?) return current[host.id] == _route;
    return _listedRoutes!.entries.every((entry) => current[entry.key] == entry.value);
  }

  List<AgentHost> _hosts(Map<HostId, String> routes) => [
    for (final host in _owner.backend().hosts)
      if (routes.containsKey(host.id) &&
          (_mode != McpApprovalMode.automatic || _owner.inAutomaticScope(host.id, routes)))
        host,
  ];

  bool _terminalCurrent(TerminalHistorySession terminal) {
    if (_owner.terminalHistory?.isCurrent(terminal) != true) return false;
    if (terminal.target case SshTerminalAiTarget(:final hostId)) {
      final routes = _owner.routes();
      return routes.containsKey(hostId) &&
          (_mode != McpApprovalMode.automatic || _owner.inAutomaticScope(hostId, routes));
    }
    return _mode != McpApprovalMode.automatic;
  }

  bool? _terminalGrant(TerminalHistorySession terminal) {
    final grant = _session.terminalGrants[terminal.sessionId];
    if (grant == null) return null;
    if (!_terminalCurrent(grant.terminal)) {
      _session.terminalGrants.remove(terminal.sessionId);
      return null;
    }
    return grant.allowed;
  }

  Future<Result<void>> _authorizeTerminal(Map<String, Object?> args, {required bool screen}) async {
    final terminal = _owner.terminalHistory?.sessions
        .where((session) => session.sessionId.value == args['sessionId'] && _terminalCurrent(session))
        .firstOrNull;
    if (terminal == null) return const Err(AppError('outsideScope'));
    _terminal = terminal;
    final maxLines = screen ? (args['maxLines'] as num?)?.toInt() ?? 200 : null;
    final key = screen ? operation.value : (_session, terminal.sessionId, terminal.generation, terminal.binding);
    final accepted =
        (!screen ? _terminalGrant(terminal) : null) ??
        await _owner._ask(
          McpTerminalApproval(_session, terminal, maxLines, key, () => _session.current && _terminalCurrent(terminal)),
          _cancel,
        );
    if (!bound) return const Err(AppError('scopeChanged'));
    return accepted ? const Ok(null) : const Err(AppError('denied'));
  }

  Future<void> record(String stage, String? tool, String outcome) => _owner.audit.append({
    'session': _session.auditId,
    'client': _session.client.name,
    'operation': operation.value,
    'tool': tool ?? 'unavailable',
    'host': _host?.id.value,
    'terminal': _terminal?.sessionId.value,
    'template': _template?.name,
    'mode': _mode.name,
    'hostDecision': _hostDecision,
    'modelDecision': _modelDecision,
    if (_exitCode != null) 'exitCode': _exitCode,
    'stage': stage,
    'outcome': outcome,
  });

  @override
  Future<Result<void>> authorize(Capability capability, Map<String, Object?> args, RequestContext context) async {
    if (!bound) return const Err(AppError('scopeChanged'));
    if (capability.id == 'agent.diagnose') {
      _template = DiagnosticTemplate.values.asNameMap()[args['template']];
      if (!mcpDiagnosticTemplates.contains(_template)) {
        return const Err(AppError('notExposed'));
      }
      final routes = _owner.routes();
      _host = _hosts(routes).where((host) => host.id.value == args['hostId']).firstOrNull;
      final host = _host;
      if (host == null) return const Err(AppError('outsideScope'));
      _route = routes[host.id];
      if (_route == null) return const Err(AppError('outsideScope'));
      if (_mode == McpApprovalMode.automatic) {
        _hostDecision = 'scope';
      } else {
        final accepted = await _owner._confirm(_session, host, _route!, _cancel);
        _hostDecision = accepted ? 'approved' : 'denied';
        if (!bound) return const Err(AppError('scopeChanged'));
        if (!accepted) return const Err(AppError('hostDenied'));
      }
    } else if (capability.id == 'agent.terminalHistory' || capability.id == 'agent.terminalScreen') {
      final allowed = await _authorizeTerminal(args, screen: capability.id == 'agent.terminalScreen');
      if (allowed is Err<void>) return allowed;
    } else if (capability.id != 'agent.hosts' && capability.id != 'agent.terminals') {
      return const Err(AppError('notExposed'));
    }
    if (_mode == McpApprovalMode.model) {
      _modelDecision = 'pending';
      final verdict = await _owner.review({
        'capability': capability.id,
        'version': capability.version,
        if (_template != null) 'template': _template!.name,
        if (_host != null) 'hostId': _host!.id.value,
        if (args['offset'] case final num offset) 'offset': offset,
        if (_terminal case final terminal?) 'sessionId': terminal.sessionId.value,
        if (args['maxLines'] case final num maxLines) 'maxLines': maxLines,
      }, _cancel);
      _modelDecision = verdict.name;
      if (!bound) return const Err(AppError('scopeChanged'));
      if (verdict != AgentReviewDecision.allow) {
        return Err(AppError(verdict == AgentReviewDecision.deny ? 'reviewDenied' : 'reviewUnavailable'));
      }
    }
    try {
      await record('starting', _tool, 'allowed');
    } on Object {
      return const Err(AppError('auditUnavailable'));
    }
    return revalidate(capability, args, context);
  }

  @override
  Future<Result<void>> revalidate(Capability capability, Map<String, Object?> args, RequestContext context) async =>
      context.operationId == operation && bound ? const Ok(null) : const Err(AppError('scopeChanged'));

  Result<Object?> listHosts(Map<String, Object?> args) {
    final routes = _owner.routes();
    final hosts = _hosts(routes);
    _listedRoutes = {for (final host in hosts) host.id: routes[host.id]!};
    return agentHostPage(hosts, (args['offset'] as num?)?.toInt() ?? 0);
  }

  Result<Object?> listTerminals(Map<String, Object?> args) {
    final sessions = _owner.terminalHistory?.sessions.where(_terminalCurrent).toList() ?? const [];
    final offset = (args['offset'] as num?)?.toInt() ?? 0;
    final page = _listedTerminals = sessions.skip(offset).take(32).toList();
    return Ok({
      'sessions': [
        for (final terminal in page)
          {...agentTerminalMetadata(terminal), 'current': false, 'requiresApproval': _terminalGrant(terminal) != true},
      ],
      'total': sessions.length,
      'nextOffset': offset + page.length < sessions.length ? offset + page.length : null,
    });
  }

  Result<Object?> readTerminal({int? maxLines}) {
    final terminal = _terminal;
    if (terminal == null || !bound) return const Err(AppError('scopeChanged'));
    final reader = _owner.terminalHistory!;
    if (maxLines == null) {
      final snapshot = reader.read(terminal);
      if (snapshot == null) return const Err(AppError('scopeChanged'));
      return Ok(agentTerminalHistoryData(snapshot));
    }
    final snapshot = reader.readScreen(terminal, maxLines: maxLines);
    if (snapshot == null) return const Err(AppError('scopeChanged'));
    if (terminalAiSensitiveText(snapshot.text)) return const Err(AppError('sensitive'));
    return Ok(agentTerminalScreenData(snapshot));
  }

  Future<Result<Object?>> diagnose(RequestContext context) async {
    if (!bound) return const Err(AppError('scopeChanged'));
    final host = _host!, template = _template!;
    final target = await _owner.backend().prepare(host.id, _cancel);
    _target = target;
    Timer? watch;
    try {
      if (!bound || !target.current || target.hostId != host.id) return const Err(AppError('scopeChanged'));
      watch = Timer.periodic(const Duration(milliseconds: 200), (_) {
        if (!bound || !target.current) _cancel.cancel();
      });
      final output = OutputStore(totalLimit: 65537, itemLimit: 65537);
      final item = output.create(operation.value, host.id, _session.auditId, 0);
      _exitCode = await runAgentDiagnostic(target, template, (stderr, bytes) {
        if (!stderr) output.append(item, false, bytes);
      }, _cancel);
      if (!bound || !target.current) return const Err(AppError('scopeChanged'));
      final data = item.truncated
          ? {'supported': false, 'status': 'outputLimit'}
          : agentDiagnosticProjection(template, item.stdout);
      return Ok({
        'executionId': context.operationId.value,
        'template': template.name,
        'version': 1,
        'exitCode': _exitCode,
        'data': data,
        'truncated': item.truncated || data['truncated'] == true,
      });
    } finally {
      watch?.cancel();
    }
  }
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../features/ai/api.dart' show LocalGrant;
import '../../features/capabilities/api.dart' show CapabilitySchema;
import '../../features/terminal/api.dart';
import '../../foundation/cancellation.dart';
import '../../foundation/ids.dart';
import 'storage.dart';

const _versions = ['2025-11-25', '2025-06-18', '2025-03-26'];

class McpSession {
  McpSession(this.client, this.version, this._idleTimeout, this._elapsed) : _started = _elapsed() {
    _lastActivity = _started;
  }

  static const _maxAge = Duration(hours: 24);
  final McpClient client;
  final String version, id = mcpRandomToken();
  final auditId = mcpRandomToken().substring(0, 16);
  final grants = <String, bool>{};
  final localGrants = <String, LocalGrant>{};
  final terminalGrants = <SessionId, ({TerminalHistorySession terminal, bool allowed})>{};
  final requests = <Object, CancellationToken>{};
  final Duration _idleTimeout, _started;
  final Duration Function() _elapsed;
  late Duration _lastActivity;
  bool initialized = false, closed = false;

  bool get current => _currentAt(_elapsed());

  bool _currentAt(Duration now) => !closed && now - _lastActivity < _idleTimeout && now - _started < _maxAge;

  bool _touch() {
    final now = _elapsed();
    if (!_currentAt(now)) return false;
    _lastActivity = now;
    return true;
  }

  void close() {
    if (closed) return;
    closed = true;
    for (final token in requests.values) {
      token.cancel();
    }
    grants.clear();
    localGrants.clear();
    terminalGrants.clear();
  }
}

class McpHttp {
  McpHttp(
    this._server,
    this.authenticate,
    this.tools,
    this.call,
    this.onClose,
    this.confirmConnection, {
    required this.sessionIdleTimeout,
    Duration Function()? elapsed,
  }) {
    final clock = Stopwatch()..start();
    _elapsed = elapsed ?? () => clock.elapsed;
    _server.listen((request) => unawaited(_serve(request)), onError: (Object _) {});
    _sweep = Timer.periodic(const Duration(seconds: 30), (_) {
      for (final session in _sessions.values.toList()) {
        if (!session.current) _drop(session);
      }
    });
  }

  final HttpServer _server;
  final McpClient? Function(String) authenticate;
  final List<Map<String, Object?>> Function() tools;
  final Future<Map<String, Object?>> Function(McpSession, Map<String, Object?>, CancellationToken) call;
  final void Function(McpSession) onClose;
  final Future<bool> Function(McpClient, CancellationToken) confirmConnection;
  final _sessions = <String, McpSession>{};
  late final Timer _sweep;
  late final Duration Function() _elapsed;
  Duration sessionIdleTimeout;
  var _active = 0, _closed = false;

  int get port => _server.port;

  static Future<HttpServer> bind(int port) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    server.idleTimeout = const Duration(seconds: 10);
    return server;
  }

  void revoke([McpClient? client]) {
    for (final session in _sessions.values.toList()) {
      if (client == null || session.client == client) _drop(session);
    }
  }

  void _drop(McpSession session) {
    if (_sessions.remove(session.id) == null) return;
    session.close();
    onClose(session);
  }

  Future<void> close() async {
    _closed = true;
    _sweep.cancel();
    revoke();
    await _server.close(force: true);
  }

  Future<void> _serve(HttpRequest request) async {
    final response = request.response;
    CancellationToken? active;
    McpSession? session;
    response.done.then<void>((_) {}, onError: (Object _) => active?.cancel());
    void status(int code) => response.statusCode = code;
    void write(Object? id, {Object? result, int? code, String? message}) {
      response.headers.contentType = ContentType.json;
      response.write(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': id,
          if (code == null) 'result': result else 'error': {'code': code, 'message': message},
        }),
      );
    }

    void sessionNotFound() {
      status(HttpStatus.notFound);
      write(null, code: -32000, message: 'MCP session not found. Reinitialize without Mcp-Session-Id.');
    }

    String? header(String name) => request.headers.value(name);
    try {
      response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
      if (_closed) return status(HttpStatus.serviceUnavailable);
      if (header('host') != '127.0.0.1:${_server.port}' || header('origin') != null) {
        return status(HttpStatus.forbidden);
      }
      if (request.uri.path != '/mcp' || request.uri.hasQuery) return status(HttpStatus.notFound);
      final authorization = header(HttpHeaders.authorizationHeader);
      final client = authorization == null ? null : authenticate(authorization);
      if (client == null) return status(HttpStatus.unauthorized);
      final sessionId = header('mcp-session-id');
      session = sessionId == null ? null : _sessions[sessionId];
      if (sessionId != null && (session == null || !session.current || session.client != client)) {
        return sessionNotFound();
      }
      final version = header('mcp-protocol-version');
      if (version != null && (!_versions.contains(version) || (session != null && version != session.version))) {
        return status(HttpStatus.badRequest);
      }
      if (request.method == 'DELETE' && session != null) {
        _drop(session);
        return status(HttpStatus.noContent);
      }
      if (request.method != 'POST') {
        response.headers.set(HttpHeaders.allowHeader, 'POST, DELETE');
        return status(HttpStatus.methodNotAllowed);
      }
      if (request.headers.contentType?.mimeType != 'application/json') {
        return status(HttpStatus.unsupportedMediaType);
      }
      if (_active >= 16) return status(HttpStatus.tooManyRequests);
      _active++;
      try {
        final body = <int>[];
        await for (final chunk in request.timeout(const Duration(seconds: 5))) {
          if (body.length + chunk.length > CapabilitySchema.maxBytes + 2048) {
            return status(HttpStatus.requestEntityTooLarge);
          }
          body.addAll(chunk);
        }
        if (_closed || authenticate(authorization!) != client) return status(HttpStatus.unauthorized);
        if (session != null && !session.current) return sessionNotFound();
        Object? decoded;
        try {
          decoded = jsonDecode(utf8.decode(body));
        } on FormatException {
          return write(null, code: -32700, message: 'Parse error');
        }
        if (decoded is! Map<String, Object?> || decoded['jsonrpc'] != '2.0' || decoded['method'] is! String) {
          return write(null, code: -32600, message: 'Invalid request');
        }
        final id = decoded['id'];
        if (decoded.containsKey('id') && !(id is int || id is String && id.length <= 128)) {
          return write(null, code: -32600, message: 'Invalid request ID');
        }
        final params = decoded['params'] ?? const <String, Object?>{};
        if (params is! Map<String, Object?>) return write(id, code: -32602, message: 'Invalid params');
        final method = decoded['method'];
        if (method == 'initialize' && id != null && session == null) {
          final requested = params['protocolVersion'];
          if (requested is! String) return write(id, code: -32602, message: 'Invalid protocol version');
          if (_sessions.length >= 16) {
            return write(id, code: -32000, message: 'Too many sessions');
          }
          final negotiated = _versions.contains(requested) ? requested : _versions.first;
          final opened = McpSession(client, negotiated, sessionIdleTimeout, _elapsed);
          _sessions[opened.id] = opened;
          final cancel = active = CancellationToken();
          final timer = Timer(const Duration(seconds: 55), cancel.cancel);
          opened.requests[id] = cancel;
          var accepted = false;
          try {
            accepted =
                await confirmConnection(client, cancel) &&
                !cancel.isCancelled &&
                !_closed &&
                authenticate(authorization) == client &&
                opened._touch();
          } finally {
            timer.cancel();
            opened.requests.remove(id);
            if (!accepted) _drop(opened);
          }
          if (!accepted) return write(id, code: -32000, message: 'Connection not approved');
          response.headers.set('Mcp-Session-Id', opened.id);
          write(
            id,
            result: {
              'protocolVersion': negotiated,
              'capabilities': {'tools': {}},
              'serverInfo': {'name': 'sshairy', 'version': '1.0.0'},
            },
          );
          return;
        }
        if (session == null) return status(HttpStatus.badRequest);
        if (id == null) {
          if (method == 'notifications/initialized') session.initialized = true;
          if (method == 'notifications/cancelled') session.requests[params['requestId']]?.cancel();
          return status(HttpStatus.accepted);
        }
        if (method == 'ping') return write(id, result: {});
        if (!session.initialized) return write(id, code: -32000, message: 'Session not initialized');
        if (method == 'tools/list') {
          if (!session._touch()) return sessionNotFound();
          return write(id, result: {'tools': tools()});
        }
        if (method != 'tools/call') return write(id, code: -32601, message: 'Method not found');
        if (session.requests.containsKey(id) || session.requests.length >= 3) {
          return write(id, code: -32000, message: 'Too many or duplicate requests');
        }
        if (!session._touch()) return sessionNotFound();
        final cancel = active = CancellationToken();
        final seconds = params['name'] == 'command_execute' && params['arguments'] is Map
            ? (params['arguments'] as Map)['timeoutSeconds']
            : null;
        final timeout = params['name'] == 'command_execute' ? 55 + (seconds is int ? seconds.clamp(1, 300) : 60) : 55;
        final timer = Timer(Duration(seconds: timeout), cancel.cancel);
        session.requests[id] = cancel;
        try {
          final response = await call(session, params, cancel);
          // Cancellation withholds data but cannot establish the outcome of a submitted write.
          final unknown =
              response['isError'] == true && (response['content'] as List).single['text'] == 'outcomeUnknown';
          final current = !cancel.isCancelled && session._touch();
          final result = !current && !unknown ? mcpToolResult('cancelled', error: true) : response;
          write(id, result: result);
        } finally {
          session.requests.remove(id);
          timer.cancel();
        }
      } finally {
        _active--;
      }
    } on Object {
      active?.cancel();
      status(HttpStatus.badRequest);
    } finally {
      try {
        await response.close();
      } on Object {
        active?.cancel();
      }
    }
  }
}

Map<String, Object?> mcpToolResult(Object? value, {bool error = false}) => {
  'isError': error,
  'content': [
    {'type': 'text', 'text': error ? value : jsonEncode(value)},
  ],
  if (!error && value is Map<String, Object?>) 'structuredContent': value,
};

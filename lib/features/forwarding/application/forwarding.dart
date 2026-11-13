import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../foundation/cancellation.dart';
import '../../../foundation/data_dir.dart';
import '../../../foundation/json_file.dart';
import '../../connections/api.dart';
import '../../hosts/api.dart';
import '../adapters/runtime.dart';
import '../domain/forward.dart';
import '../domain/socks5.dart';
import 'relay.dart';
import 'runtime.dart';

final forwardRuntimeProvider = Provider<ForwardRuntime>((_) => const IoForwardRuntime());
final forwardsProvider = NotifierProvider<Forwards, List<ForwardState>>(Forwards.new);

/// Longest a local listener gets to release its port.
const _closeTimeout = Duration(seconds: 5);

/// How long a refusal reply gets to reach a SOCKS5 client before its connection is dropped.
const _replyTimeout = Duration(seconds: 2);

/// Owns every forward rule and, while one runs, its listener, its own lease on the server connection and the
/// connections passing through (docs/MODULES.md §5). Closing a terminal never touches these.
class Forwards extends Notifier<List<ForwardState>> {
  late final _file = JsonFile(
    '${ref.read(dataDirProvider)}/forwards.json',
    backups: true,
    validate: (json) {
      if (json['forwards'] is! List) throw const FormatException('invalid forwards');
      final ids = <ForwardId>{};
      for (final entry in json['forwards'] as List) {
        final rule = ForwardRule.fromJson((entry as Map).cast<String, dynamic>());
        if (!ids.add(rule.id)) throw const FormatException('duplicate forward');
      }
    },
  );
  late final _runtime = ref.read(forwardRuntimeProvider);
  final _runs = <ForwardId, _Run>{};
  Future<void> _pending = Future.value();
  var _disposed = false;
  var _autoStarted = false;
  var _closing = false;

  /// Answers host key and secret questions; the app swaps in dialogs once there is a window.
  ConnectPrompts prompts = const _NoPrompts();

  @override
  List<ForwardState> build() {
    ref.onDispose(_dispose);
    return [
      for (final entry in _file.read()?['forwards'] as List<dynamic>? ?? const [])
        if (_parse(entry) case final rule?) ForwardState(rule),
    ];
  }

  static ForwardRule? _parse(Object? entry) {
    try {
      return ForwardRule.fromJson(entry as Map<String, dynamic>);
    } on Object {
      return null;
    }
  }

  /// Completes once every change issued so far is on disk.
  Future<void> get saved => _pending.then((_) => _file.idle);

  ForwardState? byId(ForwardId id) => state.where((s) => s.rule.id == id).firstOrNull;

  /// Opaque local identity for approvals; a stopped/restarted listener is a different resource.
  Object? resourceBinding(ForwardId id) => _runs[id]?.lease ?? _runs[id] ?? byId(id)?.rule;

  /// Listening beyond loopback needs the user's explicit yes, unless the saved rule already listens there.
  bool needsExposureConfirmation(ForwardRule rule) {
    final saved = byId(rule.id)?.rule;
    return rule.exposed && !(saved != null && saved.exposed && saved.listenAddress == rule.listenAddress);
  }

  /// Rules that hold a listener or a lease, or are working towards or away from one, cannot change.
  /// [exposureConfirmed] says the user agreed to [needsExposureConfirmation].
  Future<void> save(
    ForwardRule rule, {
    bool exposureConfirmed = false,
    bool checkExpected = false,
    ForwardRule? expected,
  }) => _persist((rules) {
    if (checkExpected && !identical(rules.where((r) => r.id == rule.id).firstOrNull, expected)) {
      throw const ForwardError(ForwardErrors.conflict);
    }
    rule.validate();
    if (_runs.containsKey(rule.id)) throw const ForwardError(ForwardErrors.busy);
    if (!exposureConfirmed && needsExposureConfirmation(rule)) {
      throw const ForwardError(ForwardErrors.exposureUnconfirmed);
    }
    final index = rules.indexWhere((r) => r.id == rule.id);
    return index < 0 ? [...rules, rule] : ([...rules]..[index] = rule);
  });

  Future<void> delete(ForwardId id, {bool checkExpected = false, ForwardRule? expected}) => _persist((rules) {
    if (checkExpected && !identical(rules.where((r) => r.id == id).firstOrNull, expected)) {
      throw const ForwardError(ForwardErrors.conflict);
    }
    if (_runs.containsKey(id)) throw const ForwardError(ForwardErrors.busy);
    return [
      for (final r in rules)
        if (r.id != id) r,
    ];
  });

  Future<void> _persist(List<ForwardRule> Function(List<ForwardRule> rules) change) {
    final next = _pending.then((_) async {
      final rules = change([for (final s in state) s.rule]);
      await _file.write({
        'schemaVersion': 1,
        'forwards': [for (final r in rules) r.toJson()],
      });
      final current = {for (final s in state) s.rule.id: s};
      state = [
        for (final r in rules)
          if (current[r.id] case final s? when identical(s.rule, r)) s else ForwardState(r),
      ];
    });
    _pending = next.catchError((Object _) {});
    return next;
  }

  /// Starts the rule and returns once it listens or has failed; the result says which. A rule that already runs is
  /// left alone. Request cancellation owns only a new startup, until its listener is handed to this manager.
  Future<ForwardState> start(
    ForwardId id, {
    CancellationToken? cancel,
    DateTime? deadline,
    bool Function()? isCurrent,
  }) async {
    void checkRequest() {
      if (cancel?.isCancelled ?? false) throw const ForwardError('cancelled');
      if (deadline != null && !DateTime.now().isBefore(deadline)) {
        throw const ForwardError('deadlineExceeded');
      }
      var current = false;
      try {
        current = isCurrent?.call() ?? true;
      } on Object {
        // A failed authority check cannot allow a listener to be created.
      }
      if (!current) throw const ForwardError('scopeChanged');
    }

    checkRequest();
    if (_closing) throw const ForwardError(ForwardErrors.busy);
    final known = byId(id) ?? (throw const ForwardError(ForwardErrors.unknown));
    final existing = _runs[id];
    if (existing != null) {
      if (existing.phase == ForwardPhase.stopping || existing.phase == ForwardPhase.stopFailed) {
        throw const ForwardError(ForwardErrors.busy);
      }
      final waiting = cancel == null
          ? existing.opening ?? Future<void>.value()
          : Future.any<void>([
              existing.opening ?? Future<void>.value(),
              cancel.whenCancelled.then<void>((_) => throw const ForwardError('cancelled')),
            ]);
      await (deadline == null
          ? waiting
          : waiting.timeout(
              deadline.difference(DateTime.now()),
              onTimeout: () => throw const ForwardError('deadlineExceeded'),
            ));
      checkRequest();
      return byId(id) ?? known;
    }
    final run = _Run(known.rule);
    var handedOff = false;
    void cancelStartup() {
      if (!handedOff) run.cancel.cancel();
    }

    final cancellation = cancel?.whenCancelled.asStream().listen((_) => cancelStartup());
    final timer = deadline == null ? null : Timer(deadline.difference(DateTime.now()), cancelStartup);
    _runs[id] = run;
    _go(run, ForwardPhase.starting);
    try {
      await (run.opening = _open(
        run,
        checkRequest: () {
          checkRequest();
          if (isCurrent != null && run.lease?.isCurrent == false) throw const ForwardError('scopeChanged');
        },
        onStarted: () => handedOff = true,
      ));
      if (!handedOff) checkRequest();
      return byId(id) ?? known;
    } on Object {
      if (_runs[id] == run && run.cancel.isCancelled) {
        await (run.stopping ??= _stop(run).whenComplete(() => run.stopping = null));
      }
      rethrow;
    } finally {
      timer?.cancel();
      await cancellation?.cancel();
    }
  }

  /// Stops the rule and returns once its listener is confirmed released and the lease is returned. When the server
  /// cannot confirm that, the phase is stopFailed and everything is kept; stopping again retries.
  Future<ForwardState> stop(ForwardId id) async {
    final run = _runs[id];
    if (run != null) await (run.stopping ??= _stop(run).whenComplete(() => run.stopping = null));
    return byId(id) ?? (throw const ForwardError(ForwardErrors.unknown));
  }

  /// Starts every rule marked autoStart, once, outside the build that asked for it.
  Future<void> autoStart() async {
    if (_autoStarted) return;
    _autoStarted = true;
    await Future<void>.delayed(Duration.zero);
    await Future.wait([
      for (final s in state)
        if (s.rule.autoStart && !_runs.containsKey(s.rule.id))
          start(s.rule.id).then<void>((_) {}, onError: (Object _) {}),
    ]);
  }

  /// Stops everything and waits for pending saves, for quitting.
  Future<void> shutdown() async {
    _closing = true;
    await Future.wait([for (final id in _runs.keys.toList()) stop(id)]);
    await _pending;
    await _file.idle;
    if (_runs.isNotEmpty) throw const ForwardError(ForwardErrors.stopFailed);
  }

  void resumeAfterShutdown() => _closing = false;

  void _dispose() {
    _disposed = true;
    for (final run in _runs.values) {
      run.retry?.cancel();
      run.cancel.cancel();
      unawaited(_teardown(run));
    }
  }

  Future<void> _open(_Run run, {void Function()? checkRequest, void Function()? onStarted}) async {
    final rule = run.rule;
    try {
      checkRequest?.call();
      final host =
          ref.read(hostsProvider.notifier).byId(rule.hostId) ?? (throw const ForwardError(ForwardErrors.hostMissing));
      final lease = await ref
          .read(connectionManagerProvider)
          .acquire(host, prompts, purpose: LeasePurpose.forward, cancel: run.cancel);
      run.lease = lease;
      if (run.cancel.isCancelled) return;
      checkRequest?.call();
      if (rule.kind == ForwardKind.remote) {
        final remote = run.remote = await lease.listen(rule.listenAddress, rule.listenPort);
        if (run.cancel.isCancelled) return;
        checkRequest?.call();
        run.port = remote.port;
        run.accepting = remote.connections.listen((tunnel) => unawaited(_serveRemote(run, tunnel)));
      } else {
        final listener = run.listener = await _runtime.listen(rule.listenAddress, rule.listenPort);
        if (run.cancel.isCancelled) return;
        checkRequest?.call();
        run.port = listener.port;
        run.accepting = listener.connections.listen((local) => unawaited(_serveLocal(run, local)));
      }
      run.attempt = 0;
      run.reconnecting = false;
      onStarted?.call();
      _go(run, ForwardPhase.running, port: run.port);
      lease.done.whenComplete(() => _lost(run, lease)).ignore();
    } on Object catch (e) {
      if (run.cancel.isCancelled) return;
      await _failed(run, e);
    }
  }

  /// Opening did not work out: release what was taken, then retry (only after a lost connection, only for network
  /// failures) or settle as failed.
  Future<void> _failed(_Run run, Object error) async {
    final (code, detail) = _describe(error);
    final released = await _teardown(run);
    if (run.cancel.isCancelled) return;
    if (!released) return _go(run, ForwardPhase.stopFailed, port: run.port, error: ForwardErrors.stopFailed);
    if (run.reconnecting && code == ConnectFailure.network.name) return _retry(run, code, detail);
    _go(run, ForwardPhase.failed, error: code, detail: detail);
    _runs.remove(run.rule.id);
  }

  /// The server connection is gone: so are the remote listener and every channel.
  Future<void> _lost(_Run run, TransportLease lease) async {
    if (run.lease != lease || _runs[run.rule.id] != run) return;
    if (run.cancel.isCancelled) {
      // A stop that could not be confirmed is settled by the connection going away.
      if (run.phase == ForwardPhase.stopFailed) await stop(run.rule.id);
      return;
    }
    final released = await _teardown(run);
    if (run.cancel.isCancelled) return;
    if (!released) return _go(run, ForwardPhase.stopFailed, port: run.port, error: ForwardErrors.stopFailed);
    run.reconnecting = run.rule.autoReconnect;
    if (run.reconnecting) return _retry(run, ForwardErrors.connectionLost, '');
    _go(run, ForwardPhase.failed, error: ForwardErrors.connectionLost);
    _runs.remove(run.rule.id);
  }

  void _retry(_Run run, String code, String detail) {
    if (run.attempt >= forwardRetryDelays.length) {
      _go(run, ForwardPhase.failed, error: code, detail: detail);
      _runs.remove(run.rule.id);
      return;
    }
    _go(run, ForwardPhase.reconnecting);
    run.retry = Timer(forwardRetryDelays[run.attempt++], () {
      run.retry = null;
      if (!run.cancel.isCancelled) run.opening = _open(run);
    });
  }

  Future<void> _stop(_Run run) async {
    run.retry?.cancel();
    run.cancel.cancel();
    _go(run, ForwardPhase.stopping, port: run.port);
    await run.opening;
    if (!await _teardown(run)) {
      return _go(run, ForwardPhase.stopFailed, port: run.port, error: ForwardErrors.stopFailed);
    }
    _go(run, ForwardPhase.stopped);
    _runs.remove(run.rule.id);
  }

  Future<bool> _teardown(_Run run) => run.tearingDown ??= _release(run).whenComplete(() => run.tearingDown = null);

  /// Stops accepting, drops the connections, releases the listeners and returns the lease. The lease and a remote
  /// listener that could not be confirmed released stay, because the port may still be open on the server; a lost
  /// connection counts as confirmation.
  Future<bool> _release(_Run run) async {
    final accepting = run.accepting;
    run.accepting = null;
    await accepting?.cancel();
    for (final connection in [...run.connections]) {
      connection.destroy();
    }
    var released = true;
    if (run.listener case final listener?) {
      try {
        await listener.close().timeout(_closeTimeout);
        run.listener = null;
      } on Object {
        released = false;
      }
    }
    if (run.remote case final remote?) {
      if ((run.lease?.lost ?? true) || await remote.close()) {
        run.remote = null;
      } else {
        released = false;
      }
    }
    if (released) {
      run.lease?.release();
      run.lease = null;
    }
    return released;
  }

  // One connection through the rule. Its failure ends only itself: the rule keeps listening.

  _Connection? _admit(_Run run) {
    if (run.cancel.isCancelled) return null;
    if (run.connections.length >= forwardMaxConnections) {
      _note(run, ForwardErrors.limit);
      return null;
    }
    final connection = _Connection();
    run.connections.add(connection);
    _flush(run);
    return connection;
  }

  Future<void> _serveLocal(_Run run, LocalConnection local) async {
    final connection = _admit(run);
    if (connection == null) return local.destroy();
    connection.local = local;
    final socks = run.rule.kind == ForwardKind.dynamic;
    var requested = false;
    try {
      var host = run.rule.destinationAddress, port = run.rule.destinationPort;
      Stream<Uint8List>? incoming;
      if (socks) {
        final (request, rest) = await socksNegotiate(local, forwardDialTimeout);
        (host, port, incoming) = (request.host, request.port, rest);
        requested = true;
      }
      final lease = run.lease;
      if (connection.cancel.isCancelled || lease == null) return;
      final tunnel = connection.tunnel = await lease.connectTo(host, port);
      if (connection.cancel.isCancelled) return;
      if (socks) local.sink.add(Socks5Reply.of(Socks5Reply.succeeded));
      await relay(local, tunnel, localIn: incoming);
    } on Object catch (e) {
      if (!connection.cancel.isCancelled) {
        final (code, detail) = _describeConnection(e);
        _note(run, code, detail);
        if (requested) {
          local.sink.add(
            Socks5Reply.of(code == ForwardErrors.timeout ? Socks5Reply.hostUnreachable : Socks5Reply.refused),
          );
        }
        // Whatever refusal was queued has to leave before the connection is dropped.
        if (socks) await local.flush().timeout(_replyTimeout).then<void>((_) {}, onError: (Object _) {});
      }
    } finally {
      _finish(run, connection);
    }
  }

  Future<void> _serveRemote(_Run run, Tunnel tunnel) async {
    final connection = _admit(run);
    if (connection == null) return tunnel.destroy();
    connection.tunnel = tunnel;
    try {
      final local = await _runtime.connect(
        run.rule.destinationAddress,
        run.rule.destinationPort,
        timeout: forwardDialTimeout,
        cancel: connection.cancel,
      );
      connection.local = local;
      if (connection.cancel.isCancelled) return;
      await relay(local, tunnel);
    } on Object catch (e) {
      if (!connection.cancel.isCancelled) _note(run, _describeConnection(e).$1, _describeConnection(e).$2);
    } finally {
      _finish(run, connection);
    }
  }

  void _finish(_Run run, _Connection connection) {
    connection.destroy();
    run.connections.remove(connection);
    _flush(run);
  }

  /// The latest error of a single connection, shown while the rule keeps running.
  void _note(_Run run, String code, [String detail = '']) {
    if (run.error == code && run.detail == detail) return;
    run.error = code;
    run.detail = detail;
    _flush(run);
  }

  static (String, String) _describe(Object e) => switch (e) {
    ForwardError() => (e.code, e.detail),
    ConnectError(kind: ConnectFailure.network, detail: 'forward refused') => (ForwardErrors.refused, ''),
    ConnectError() => (e.kind.name, e.detail),
    _ => (ConnectFailure.network.name, '$e'),
  };

  static (String, String) _describeConnection(Object e) => switch (e) {
    ForwardError() => (e.code, e.detail),
    ConnectError(detail: 'channel open timed out') => (ForwardErrors.timeout, ''),
    ConnectError() => (ForwardErrors.targetFailed, e.detail),
    _ => (ForwardErrors.targetFailed, '$e'),
  };

  void _go(_Run run, ForwardPhase phase, {int? port, String? error, String detail = ''}) {
    run.phase = phase;
    run.port = port;
    run.error = error;
    run.detail = detail;
    _flush(run);
  }

  void _flush(_Run run) {
    if (_disposed || _runs[run.rule.id] != run) return;
    final next = ForwardState(
      run.rule,
      phase: run.phase,
      port: run.port,
      error: run.error,
      detail: run.detail,
      connections: run.connections.length,
    );
    state = [for (final s in state) s.rule.id == run.rule.id ? next : s];
  }
}

/// One start of a rule and everything it holds.
class _Run {
  _Run(this.rule);

  final ForwardRule rule;

  /// Fires when the user stops the rule; nothing started afterwards may linger.
  final cancel = CancellationToken();
  final connections = <_Connection>{};
  ForwardPhase phase = ForwardPhase.starting;
  int? port;
  String? error;
  String detail = '';
  TransportLease? lease;
  LocalListener? listener;
  RemoteListener? remote;
  StreamSubscription<Object>? accepting;
  Timer? retry;
  Future<void>? opening, stopping;
  Future<bool>? tearingDown;
  var attempt = 0;

  /// The last open followed a lost connection, so network failures retry.
  var reconnecting = false;
}

class _Connection {
  /// Fires when this connection is dropped, which also abandons a dial in progress.
  final cancel = CancellationToken();
  LocalConnection? local;
  Tunnel? tunnel;

  void destroy() {
    cancel.cancel();
    local?.destroy();
    tunnel?.destroy();
  }
}

/// Without a window nobody can be asked, so a new host key is refused and no secret is supplied.
class _NoPrompts implements ConnectPrompts {
  const _NoPrompts();

  @override
  Future<TrustChoice> hostKey(HostKeyPrompt prompt) async => TrustChoice.reject;

  @override
  Future<SecretAnswer?> secret(SecretRequest request) async => null;
}

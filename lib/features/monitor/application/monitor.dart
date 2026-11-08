import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../../foundation/ids.dart';
import '../../../foundation/result.dart';
import '../../connections/api.dart';
import '../../hosts/api.dart';
import '../domain/stats.dart';

enum MonitorState { waiting, live, offline, unsupported, failed }

/// SIGTERM asks a process to exit; SIGKILL cannot be caught.
enum ProcessSignal { term, kill }

/// Polls one connected host with [statsCommand] over an exec lease (docs/MODULES.md §8, ADR-14). It never dials:
/// with no live connection to the host it reports [MonitorState.offline] and looks again on the next tick.
class ServerMonitor extends ChangeNotifier {
  ServerMonitor(this._connections, this.host, {Duration interval = const Duration(seconds: 3)})
    : _interval = interval; // ignore: prefer_initializing_formals, a private named parameter is not allowed

  final ConnectionManager _connections;
  final Host host;

  static const historyLength = 60;
  static const _timeout = Duration(seconds: 10);
  static const _limit = 1 << 20;

  /// The key of the history summed over every interface but `lo`.
  static const allInterfaces = '';

  var state = MonitorState.waiting;
  StatsSnapshot? snapshot;

  /// Oldest first, at most [historyLength]; 0–1 for cpu and memory.
  final cpu = <double>[], memory = <double>[];

  /// Bytes per second by interface, [allInterfaces] for the sum.
  final rx = <String, List<double>>{}, tx = <String, List<double>>{};

  /// Utilization, 0–1, by [Gpu.id].
  final gpuUtilization = <String, List<double>>{};

  TransportLease? _lease;
  Timer? _timer;
  StreamSubscription<HostId>? _connected;
  StatsSample? _previous;
  DateTime? _previousAt;
  Duration _interval;
  var _running = false, _busy = false, _disposed = false, _gpuVisible = false, _processViews = 0;
  var _generation = 0;
  var _connectionPending = false;

  bool get running => _running;
  Duration get interval => _interval;

  /// A new interval applies from the next tick; a shorter one cuts the current wait short.
  set interval(Duration value) {
    if (value == _interval) return;
    _interval = value;
    if (_running && _timer != null) {
      _timer!.cancel();
      _timer = Timer(value, _tick);
    }
  }

  /// The graphics queries are slower than the rest, so they run only while the GPU page is shown.
  set gpuVisible(bool value) {
    if (value == _gpuVisible) return;
    _gpuVisible = value;
    if (value) refresh();
  }

  /// Adds owners and command lines to every sample until the returned callback is called.
  VoidCallback watchProcesses() {
    _processViews++;
    refresh();
    var done = false;
    return () {
      if (done) return;
      done = true;
      _processViews--;
    };
  }

  void start() {
    if (_running || _disposed) return;
    _running = true;
    _generation++;
    _connected = _connections.connected.listen((id) {
      if (id != host.id) return;
      if (_busy) {
        _connectionPending = true;
      } else {
        refresh();
      }
    });
    _tick();
  }

  /// Samples now instead of at the next tick, unless a sample is already on its way.
  void refresh() {
    if (!_running || _busy) return;
    _timer?.cancel();
    _tick();
  }

  /// Stops polling and hands the lease back; history is kept so a tab switched back to is not blank.
  void stop() {
    _running = false;
    _generation++;
    _connectionPending = false;
    unawaited(_connected?.cancel());
    _connected = null;
    _timer?.cancel();
    _timer = null;
    _drop();
  }

  void _drop() {
    _lease?.release();
    _lease = null;
    _previous = null;
  }

  void _set(MonitorState next) {
    if (state == next) return;
    state = next;
    if (!_disposed) notifyListeners();
  }

  Future<void> _tick() async {
    if (!_running || _busy) return;
    _busy = true;
    final generation = _generation;
    try {
      await _poll(generation);
    } finally {
      _busy = false;
      final again = generation != _generation || (_connectionPending && state != MonitorState.live);
      _connectionPending = false;
      if (_running && state != MonitorState.unsupported) {
        if (again) {
          unawaited(_tick());
        } else {
          _timer = Timer(_interval, _tick);
        }
      }
    }
  }

  Future<TransportLease?> _acquire({int? generation}) async {
    var lease = _lease;
    if (lease != null && !lease.lost) return lease;
    _drop();
    if (!_connections.hosts.any((h) => h.id == host.id)) return null;
    try {
      lease = await _connections.acquire(host, const _Refuse(), purpose: LeasePurpose.exec);
    } on Object {
      return null;
    }
    if (!_running || (generation != null && generation != _generation)) {
      lease.release();
      return null;
    }
    _lease = lease;
    lease.done.then((_) {
      if (identical(_lease, lease)) {
        _drop();
        _set(MonitorState.offline);
      }
    });
    return lease;
  }

  Future<void> _poll(int generation) async {
    final lease = await _acquire(generation: generation);
    if (!_running || generation != _generation) return;
    if (lease == null) return _set(MonitorState.offline);
    final ExecResult result;
    try {
      final command = statsCommand(processes: _processViews > 0, gpu: _gpuVisible);
      result = await lease.exec(command, limit: _limit).timeout(_timeout);
    } on Object {
      if (!_running || generation != _generation) return;
      if (lease.lost) {
        _drop();
        return _set(MonitorState.offline);
      }
      return _set(MonitorState.failed);
    }
    if (!_running || generation != _generation || !identical(_lease, lease) || lease.lost) return;
    final sample = parseStats(utf8.decode(result.stdout, allowMalformed: true));
    if (!sample.supported) {
      _drop();
      return _set(MonitorState.unsupported);
    }
    final now = DateTime.now();
    final snap = diffStats(_previous, sample, _previousAt == null ? Duration.zero : now.difference(_previousAt!));
    _previous = sample;
    _previousAt = now;
    snapshot = snap;
    void push(List<double> list, double? v) {
      if (v == null) return;
      list.add(v);
      if (list.length > historyLength) list.removeAt(0);
    }

    push(cpu, snap.cpu);
    push(memory, snap.memory);
    push(rx.putIfAbsent(allInterfaces, () => []), snap.rxPerSecond);
    push(tx.putIfAbsent(allInterfaces, () => []), snap.txPerSecond);
    for (final MapEntry(key: name, value: rate) in snap.interfaceRates.entries) {
      push(rx.putIfAbsent(name, () => []), rate.rx);
      push(tx.putIfAbsent(name, () => []), rate.tx);
    }
    for (final g in sample.gpus) {
      push(gpuUtilization.putIfAbsent(g.id, () => []), g.utilization);
    }
    state = MonitorState.live;
    if (!_disposed) notifyListeners();
  }

  /// Sends [signal] to [pid] on the host, over the same lease as the samples (docs/MODULES.md §8). Not a
  /// capability: only the process window calls it, after the user confirmed. The command is built from an integer
  /// and an enum; pids 0 and 1 and negative ones, which address groups or init, are refused.
  Future<Result<void>> signal(int pid, ProcessSignal signal) async {
    if (pid <= 1) return Err(AppError('invalidArgument', detail: '$pid'));
    final lease = await _acquire();
    if (lease == null) return const Err(AppError('offline'));
    final name = switch (signal) {
      ProcessSignal.term => 'TERM',
      ProcessSignal.kill => 'KILL',
    };
    final ExecResult result;
    try {
      result = await lease.exec('kill -s $name $pid', limit: 4096).timeout(_timeout);
    } on Object catch (e) {
      return Err(AppError('failed', detail: '$e', retryable: true));
    }
    if (result.exitCode != 0) {
      return Err(AppError('failed', detail: utf8.decode(result.stderr, allowMalformed: true).trim()));
    }
    refresh();
    return const Ok(null);
  }

  @override
  void dispose() {
    stop();
    _disposed = true;
    super.dispose();
  }
}

/// The monitor runs in the background: it never asks about host keys or secrets.
class _Refuse implements ConnectPrompts {
  const _Refuse();

  @override
  Future<TrustChoice> hostKey(HostKeyPrompt prompt) async => TrustChoice.reject;

  @override
  Future<SecretAnswer?> secret(SecretRequest request) async => null;
}

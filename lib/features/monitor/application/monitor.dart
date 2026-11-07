import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../connections/api.dart';
import '../../hosts/api.dart';
import '../domain/stats.dart';

enum MonitorState { waiting, live, offline, unsupported, failed }

/// Polls one connected host with [statsCommand] over an exec lease (docs/MODULES.md §8, ADR-14). It never dials:
/// with no live connection to the host it reports [MonitorState.offline] and looks again on the next tick.
class ServerMonitor extends ChangeNotifier {
  ServerMonitor(this._connections, this.host, {this.interval = const Duration(seconds: 3)});

  final ConnectionManager _connections;
  final Host host;
  final Duration interval;

  static const historyLength = 60;
  static const _timeout = Duration(seconds: 10);
  static const _limit = 256 * 1024;

  var state = MonitorState.waiting;
  StatsSnapshot? snapshot;

  /// Oldest first, at most [historyLength]; 0–1 for cpu and memory, bytes per second for the network.
  final cpu = <double>[], memory = <double>[], rx = <double>[], tx = <double>[];

  TransportLease? _lease;
  Timer? _timer;
  StatsSample? _previous;
  DateTime? _previousAt;
  var _running = false, _busy = false, _disposed = false;

  bool get running => _running;

  void start() {
    if (_running || _disposed) return;
    _running = true;
    _tick();
  }

  /// Stops polling and hands the lease back; history is kept so a tab switched back to is not blank.
  void stop() {
    _running = false;
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
    try {
      await _poll();
    } finally {
      _busy = false;
      if (_running && state != MonitorState.unsupported) _timer = Timer(interval, _tick);
    }
  }

  Future<void> _poll() async {
    var lease = _lease;
    if (lease == null || lease.lost) {
      _drop();
      if (!_connections.hosts.any((h) => h.id == host.id)) return _set(MonitorState.offline);
      try {
        lease = await _connections.acquire(host, const _Refuse(), purpose: LeasePurpose.exec);
      } on Object {
        return _set(MonitorState.offline);
      }
      if (!_running) return lease.release();
      _lease = lease;
      lease.done.then((_) {
        if (identical(_lease, lease)) {
          _drop();
          _set(MonitorState.offline);
        }
      });
    }
    final ExecResult result;
    try {
      result = await lease.exec(statsCommand, limit: _limit).timeout(_timeout);
    } on Object {
      if (lease.lost) {
        _drop();
        return _set(MonitorState.offline);
      }
      return _set(MonitorState.failed);
    }
    if (!_running) return;
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
    push(rx, snap.rxPerSecond);
    push(tx, snap.txPerSecond);
    state = MonitorState.live;
    if (!_disposed) notifyListeners();
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

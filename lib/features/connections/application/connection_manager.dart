import 'dart:async';

import '../../../foundation/cancellation.dart';
import '../../hosts/api.dart';
import '../domain/known_keys.dart';
import '../domain/prompts.dart';
import '../domain/transport.dart';

/// Dials and authenticates one transport. [cancel] fires when nobody waits for it any more.
typedef Dial = Future<Transport> Function(Host host, ConnectPrompts prompts, CancellationToken cancel);

enum LeasePurpose { terminal, files, forward, exec }

/// Owns every transport and shares one between users of the same host and login (docs/CONTRACTS.md §2,
/// docs/MODULES.md §2). Concurrent acquires join one dial; a transport without leases is parked for [park],
/// then closed.
class ConnectionManager {
  ConnectionManager(this._dial, {this.park = const Duration(seconds: 60)});

  final Dial _dial;
  Duration park;
  final _pool = <String, _Entry>{};
  final _detached = <_Entry>{};
  var _closed = false;

  /// What must match for two users to share a transport. Holds references, never secrets.
  static String keyOf(Host h) =>
      [h.id.value, KnownKeys.endpoint(h.address, h.port), h.username, h.auth.name, h.keyPath ?? ''].join('\u0000');

  /// Hosts that currently have a live or dialling transport.
  Set<Host> get hosts => {for (final e in [..._pool.values, ..._detached]) e.host};

  /// One waiter cancelling only stops its own wait; the dial goes on while anyone else still waits.
  Future<TransportLease> acquire(
    Host host,
    ConnectPrompts prompts, {
    LeasePurpose purpose = LeasePurpose.terminal,
    CancellationToken? cancel,
  }) async {
    if (_closed) throw const ConnectError(ConnectFailure.cancelled);
    final key = keyOf(host);
    var entry = _pool[key];
    if (entry != null && (entry.transport?.isClosed ?? false)) {
      _forget(entry);
      entry = null;
    }
    final reused = entry?.transport != null;
    entry ??= _start(key, host, prompts);
    entry.waiters++;
    entry.parkTimer?.cancel();
    try {
      final Transport transport;
      if (cancel == null) {
        transport = await entry.ready;
      } else {
        transport = await Future.any([
          entry.ready,
          cancel.whenCancelled.then<Transport>((_) => throw const ConnectError(ConnectFailure.cancelled)),
        ]);
      }
      if (transport.isClosed) throw const ConnectError(ConnectFailure.network, 'connection closed');
      final lease = TransportLease._(this, entry, transport, purpose, reused);
      entry.leases.add(lease);
      return lease;
    } finally {
      entry.waiters--;
      _idle(entry);
    }
  }

  /// Acquires a lease and opens a channel on it. A reused transport that cannot open one (gone stale, or out of
  /// channels) is set aside and a fresh one is dialled once; nothing has run on the server at that point.
  Future<(TransportLease, T)> open<T>(
    Host host,
    ConnectPrompts prompts,
    Future<T> Function(TransportLease lease) channel, {
    LeasePurpose purpose = LeasePurpose.terminal,
    CancellationToken? cancel,
  }) async {
    for (var attempt = 0;; attempt++) {
      final lease = await acquire(host, prompts, purpose: purpose, cancel: cancel);
      try {
        return (lease, await channel(lease));
      } on Object catch (e) {
        final entry = lease._entry;
        lease.release();
        if (!lease.reused || attempt > 0) {
          throw e is ConnectError ? e : ConnectError(ConnectFailure.network, '$e');
        }
        _detach(entry);
      }
    }
  }

  /// Closes every transport to [host], with whatever runs on it.
  void disconnect(Host host) {
    for (final e in [..._pool.values, ..._detached]) {
      if (e.host.id == host.id && keyOf(e.host) == keyOf(host)) _close(e);
    }
  }

  void closeAll() {
    _closed = true;
    for (final e in [..._pool.values, ..._detached]) {
      _close(e);
    }
  }

  _Entry _start(String key, Host host, ConnectPrompts prompts) {
    final entry = _Entry(key, host);
    _pool[key] = entry;
    entry.ready = _dial(host, prompts, entry.dialCancel).then((t) {
      if (entry.dialCancel.isCancelled || _closed) {
        t.close();
        throw const ConnectError(ConnectFailure.cancelled);
      }
      entry.transport = t;
      t.done.whenComplete(() => _forget(entry)).ignore();
      return t;
    });
    entry.ready.then((_) {}, onError: (Object _) => _forget(entry));
    return entry;
  }

  void _release(TransportLease lease) {
    lease._entry.leases.remove(lease);
    _idle(lease._entry);
  }

  /// Parks or closes a transport nobody uses; abandons a dial nobody waits for.
  void _idle(_Entry e) {
    if (e.waiters > 0 || e.leases.isNotEmpty) return;
    if (e.transport == null) {
      e.dialCancel.cancel();
      _forget(e);
    } else if (_detached.contains(e) || park == Duration.zero) {
      _close(e);
    } else {
      e.parkTimer?.cancel();
      e.parkTimer = Timer(park, () => _close(e));
    }
  }

  void _detach(_Entry e) {
    if (_pool[e.key] == e) _pool.remove(e.key);
    _detached.add(e);
    _idle(e);
  }

  void _close(_Entry e) {
    e.dialCancel.cancel();
    e.transport?.close();
    _forget(e);
  }

  void _forget(_Entry e) {
    e.parkTimer?.cancel();
    if (_pool[e.key] == e) _pool.remove(e.key);
    _detached.remove(e);
  }
}

class _Entry {
  _Entry(this.key, this.host);

  final String key;
  final Host host;
  final dialCancel = CancellationToken();
  late final Future<Transport> ready;
  Transport? transport;
  final leases = <TransportLease>{};
  var waiters = 0;
  Timer? parkTimer;
}

/// A claim on a shared transport. Channels opened through it belong to the caller, who closes them before
/// [release]; releasing twice is harmless.
class TransportLease {
  TransportLease._(this._owner, this._entry, this._transport, this.purpose, this.reused);

  final ConnectionManager _owner;
  final _Entry _entry;
  final Transport _transport;
  final LeasePurpose purpose;

  /// The transport was already up when this lease was taken.
  final bool reused;
  var _released = false;

  Host get host => _entry.host;

  /// Completes when the transport is lost.
  Future<void> get done => _transport.done;
  bool get lost => _transport.isClosed;

  Future<ShellChannel> openShell({required int cols, required int rows}) => _use().openShell(cols: cols, rows: rows);

  Future<ExecResult> exec(String command, {int limit = 1 << 20}) => _use().exec(command, limit: limit);

  void release() {
    if (_released) return;
    _released = true;
    _owner._release(this);
  }

  Transport _use() {
    if (_released) throw StateError('lease already released');
    return _transport;
  }
}

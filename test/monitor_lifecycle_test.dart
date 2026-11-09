import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/features/connections/api.dart';
import 'package:sshairy/features/hosts/api.dart';
import 'package:sshairy/features/monitor/application/monitor.dart';
import 'package:sshairy/foundation/cancellation.dart';
import 'package:sshairy/foundation/ids.dart';
import 'package:sshairy/foundation/result.dart';

import 'connection_manager_test.dart' show FakeTransport, NoPrompts;
import 'monitor_test.dart' show sample;

class _Server extends FakeTransport {
  var samples = 0, active = 0, peak = 0, cancelled = 0, timedOut = 0;
  Completer<void>? gate;
  final calls = <({CancellationToken? cancel, Duration? timeout})>[];

  @override
  Future<ExecResult> exec(String command, {int limit = 0, Duration? timeout, CancellationToken? cancel}) async {
    samples++;
    calls.add((cancel: cancel, timeout: timeout));
    active++;
    if (active > peak) peak = active;
    try {
      if (gate case final pending?) {
        final waiting = Future.any<void>([
          pending.future,
          if (cancel != null) cancel.whenCancelled.then((_) => throw const ExecError(ExecFailure.cancelled)),
        ]);
        await (timeout == null
            ? waiting
            : waiting.timeout(timeout, onTimeout: () => throw const ExecError(ExecFailure.timedOut)));
      }
      return ExecResult(Uint8List.fromList(utf8.encode(sample(user: 100 + samples * 10))), Uint8List(0), 0);
    } on ExecError catch (error) {
      if (error.kind == ExecFailure.cancelled) cancelled++;
      if (error.kind == ExecFailure.timedOut) timedOut++;
      rethrow;
    } finally {
      active--;
    }
  }
}

void main() {
  const host = Host(id: HostId('h'), label: 'host', address: 'server.example', username: 'u');
  const other = Host(id: HostId('other'), label: 'other', address: 'other.example', username: 'u');

  for (final seconds in [1, 3, 10]) {
    testWidgets('connection samples immediately with a $seconds second interval', (tester) async {
      final servers = <_Server>[];
      final manager = ConnectionManager((_, _, _) async {
        final server = _Server();
        servers.add(server);
        return server;
      }, park: Duration.zero);
      final monitor = ServerMonitor(manager, host, interval: Duration(seconds: seconds));
      addTearDown(manager.closeAll);
      addTearDown(monitor.dispose);
      monitor.start();
      await tester.pump();
      expect(monitor.state, MonitorState.offline);
      expect(servers, isEmpty, reason: 'monitoring never initiates a connection');

      await manager.acquire(host, NoPrompts());
      await tester.pump();
      expect(servers.single.samples, 1, reason: 'no timer advance is needed after authentication');
      expect(monitor.state, MonitorState.live);
      await manager.acquire(host, NoPrompts());
      await tester.pump();
      expect(servers.single.samples, 1, reason: 'reusing a lease does not announce another connection');
      await tester.pump(Duration(seconds: seconds));
      expect(servers.single.samples, 2);

      servers.single.close();
      await tester.pump();
      expect(monitor.state, MonitorState.offline);
      await manager.acquire(host, NoPrompts());
      await tester.pump();
      expect(servers, hasLength(2));
      expect(servers.last.samples, 1, reason: 'reconnection also bypasses the interval');
      expect(monitor.state, MonitorState.live);
      monitor.stop();
    });
  }

  testWidgets('hidden monitoring ignores connections and samples immediately when shown again', (tester) async {
    final server = _Server();
    final manager = ConnectionManager((_, _, _) async => server, park: Duration.zero);
    final monitor = ServerMonitor(manager, host, interval: const Duration(seconds: 10));
    addTearDown(manager.closeAll);
    addTearDown(monitor.dispose);
    monitor.start();
    await tester.pump();
    monitor.stop();
    await manager.acquire(host, NoPrompts());
    await tester.pump();
    expect(server.samples, 0);
    monitor.start();
    await tester.pump();
    expect(server.samples, 1);
    monitor.stop();
  });

  testWidgets('a reconnect during an old sample gets a fresh sample as soon as the old request settles', (
    tester,
  ) async {
    final old = _Server()..gate = Completer<void>();
    final fresh = _Server();
    var dials = 0;
    final manager = ConnectionManager((_, _, _) async => dials++ == 0 ? old : fresh, park: Duration.zero);
    final monitor = ServerMonitor(manager, host, interval: const Duration(seconds: 10));
    addTearDown(manager.closeAll);
    addTearDown(monitor.dispose);
    await manager.acquire(host, NoPrompts());
    monitor.start();
    await tester.pump();
    expect(old.samples, 1);
    old.close();
    await tester.pump();
    await manager.acquire(host, NoPrompts());
    await tester.pump();
    old.gate!.complete();
    await tester.pump();
    expect(fresh.samples, 1, reason: 'no refresh interval elapses after the old request completes');
    expect(monitor.state, MonitorState.live);
    expect(monitor.cpu, isEmpty, reason: 'the old transport sample is discarded');
    monitor.stop();
  });

  testWidgets('returning during an old sample discards it and starts a new sample', (tester) async {
    final server = _Server()..gate = Completer<void>();
    final manager = ConnectionManager((_, _, _) async => server, park: Duration.zero);
    final monitor = ServerMonitor(manager, host, interval: const Duration(seconds: 10));
    addTearDown(manager.closeAll);
    addTearDown(monitor.dispose);
    await manager.acquire(host, NoPrompts());
    monitor.start();
    await tester.pump();
    monitor.stop();
    monitor.start();
    server.gate!.complete();
    await tester.pump();
    expect(server.samples, 2);
    expect(monitor.state, MonitorState.live);
    expect(monitor.cpu, isEmpty, reason: 'the previous generation cannot seed a rate');
    monitor.stop();
  });

  testWidgets('timed out samples finish before polling again and stop cancels the current sample', (tester) async {
    final server = _Server()..gate = Completer<void>();
    final manager = ConnectionManager((_, _, _) async => server, park: Duration.zero);
    final monitor = ServerMonitor(manager, host, interval: const Duration(seconds: 1));
    addTearDown(manager.closeAll);
    addTearDown(monitor.dispose);
    final terminal = await manager.acquire(host, NoPrompts());
    addTearDown(terminal.release);
    monitor.start();
    await tester.pump();
    expect(server.active, 1);
    expect(server.calls.single.timeout, const Duration(seconds: 10));
    expect(server.calls.single.cancel, isNotNull);

    await tester.pump(const Duration(seconds: 10));
    expect(server.timedOut, 1);
    expect(server.active, 0);
    expect(monitor.state, MonitorState.failed);
    await tester.pump(const Duration(seconds: 1));
    expect(server.samples, 2);
    expect(server.active, 1);
    expect(server.peak, 1, reason: 'a timed out sample has finished before another starts');

    monitor.stop();
    expect(server.calls.last.cancel!.isCancelled, isTrue);
    await tester.pump();
    expect(server.active, 0);
    expect(server.cancelled, 1);
    await tester.pump(const Duration(seconds: 30));
    expect(server.samples, 2);
    expect(server.isClosed, isFalse, reason: 'the terminal still owns the shared connection');
    server.gate!.complete();
    await tester.pump();
    expect(monitor.snapshot, isNull);
  });

  testWidgets('stopping cancels a pending process operation and sample without closing another lease', (tester) async {
    final server = _Server()..gate = Completer<void>();
    final manager = ConnectionManager((_, _, _) async => server, park: Duration.zero);
    final monitor = ServerMonitor(manager, host);
    addTearDown(manager.closeAll);
    addTearDown(monitor.dispose);
    final terminal = await manager.acquire(host, NoPrompts());
    addTearDown(terminal.release);
    monitor.start();
    await tester.pump();
    final signal = monitor.signal(400, ProcessSignal.term);
    await tester.pump();
    expect(server.active, 2);
    expect(server.calls.every((call) => call.timeout == const Duration(seconds: 10)), isTrue);
    monitor.stop();
    expect(server.calls.every((call) => call.cancel!.isCancelled), isTrue);
    await tester.pump();
    expect(await signal, isA<Err<void>>());
    expect(server.active, 0);
    expect(server.cancelled, 2);
    expect(server.isClosed, isFalse);
    server.gate!.complete();
    await tester.pump();
  });

  testWidgets('a connection to another host does not wake the offline monitor', (tester) async {
    final manager = ConnectionManager((_, _, _) async => _Server(), park: Duration.zero);
    final monitor = ServerMonitor(manager, host, interval: const Duration(seconds: 10));
    addTearDown(manager.closeAll);
    addTearDown(monitor.dispose);
    monitor.start();
    await tester.pump();
    var notices = 0;
    monitor.addListener(() => notices++);
    await manager.acquire(other, NoPrompts());
    await tester.pump();
    expect(notices, 0);
    expect(manager.hosts.map((h) => h.id), [other.id]);
    expect(monitor.snapshot, isNull);
    monitor.stop();
  });
}

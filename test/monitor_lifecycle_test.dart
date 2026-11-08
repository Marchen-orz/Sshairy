import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/features/connections/api.dart';
import 'package:sshairy/features/hosts/api.dart';
import 'package:sshairy/features/monitor/application/monitor.dart';
import 'package:sshairy/foundation/ids.dart';

import 'connection_manager_test.dart' show FakeTransport, NoPrompts;
import 'monitor_test.dart' show sample;

class _Server extends FakeTransport {
  var samples = 0;
  Completer<void>? gate;

  @override
  Future<ExecResult> exec(String command, {int limit = 0}) async {
    samples++;
    await gate?.future;
    return ExecResult(Uint8List.fromList(utf8.encode(sample(user: 100 + samples * 10))), Uint8List(0), 0);
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

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/features/connections/api.dart';
import 'package:sshairy/features/connections/domain/transport.dart';
import 'package:sshairy/features/hosts/api.dart';
import 'package:sshairy/foundation/cancellation.dart';
import 'package:sshairy/foundation/file_system.dart';
import 'package:sshairy/foundation/ids.dart';

class FakeTransport implements Transport {
  final _done = Completer<void>();
  var failShell = false;
  var shells = 0;

  @override
  Future<void> get done => _done.future;
  @override
  bool get isClosed => _done.isCompleted;

  @override
  Future<ShellChannel> openShell({required int cols, required int rows}) async {
    if (failShell) throw StateError('channel refused');
    shells++;
    return FakeShell();
  }

  @override
  Future<ExecResult> exec(String command, {int limit = 0}) async => ExecResult(Uint8List(0), Uint8List(0), 0);

  @override
  Future<FileSystem> openFiles() => throw UnimplementedError();

  @override
  Future<Tunnel> connectTo(String host, int port) => throw UnimplementedError();

  @override
  Future<RemoteListener> listen(String host, int port) => throw UnimplementedError();

  @override
  void close() {
    if (!_done.isCompleted) _done.complete();
  }
}

class FakeShell implements ShellChannel {
  @override
  Stream<Uint8List> get stdout => const Stream.empty();
  @override
  Stream<Uint8List> get stderr => const Stream.empty();
  @override
  Future<void> get done => Completer<void>().future;
  @override
  void write(Uint8List data) {}
  @override
  void resize(int cols, int rows) {}
  @override
  void close() {}
}

class NoPrompts implements ConnectPrompts {
  @override
  Future<TrustChoice> hostKey(HostKeyPrompt prompt) async => TrustChoice.reject;
  @override
  Future<SecretAnswer?> secret(SecretRequest request) async => null;
}

void main() {
  const host = Host(id: HostId('h'), label: 'h', address: 'example.com', username: 'u');
  final prompts = NoPrompts();
  late List<FakeTransport> dialled;
  late List<Completer<void>> gates;
  late List<CancellationToken> cancels;

  Future<Transport> dial(Host h, ConnectPrompts p, CancellationToken cancel) async {
    final gate = Completer<void>();
    gates.add(gate);
    cancels.add(cancel);
    await gate.future;
    final t = FakeTransport();
    dialled.add(t);
    return t;
  }

  setUp(() {
    dialled = [];
    gates = [];
    cancels = [];
  });

  test('concurrent acquires join one dial and share its transport', () async {
    final m = ConnectionManager(dial);
    final a = m.acquire(host, prompts), b = m.acquire(host, prompts);
    await pumpEventQueue();
    expect(gates, hasLength(1));
    gates.single.complete();
    final [la, lb] = await Future.wait([a, b]);
    expect(dialled, hasLength(1));
    expect(la.reused || lb.reused, isFalse, reason: 'both waited for the dial');
    final lc = await m.acquire(host, prompts);
    expect(lc.reused, isTrue);
    expect(gates, hasLength(1));
  });

  test('another login is another transport', () async {
    final m = ConnectionManager(dial);
    m.acquire(host, prompts).ignore();
    m.acquire(const Host(id: HostId('h'), label: 'h', address: 'example.com', username: 'root'), prompts).ignore();
    await pumpEventQueue();
    expect(gates, hasLength(2));
  });

  test('the last release parks the transport, and a new lease in time keeps it', () async {
    final m = ConnectionManager(dial, park: const Duration(milliseconds: 100));
    final first = m.acquire(host, prompts);
    await pumpEventQueue();
    gates.single.complete();
    final lease = await first;
    lease.release();
    lease.release();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    final again = await m.acquire(host, prompts);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(dialled.single.isClosed, isFalse);
    again.release();
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(dialled.single.isClosed, isTrue);
    expect(m.hosts, isEmpty);
  });

  test('park zero closes at once', () async {
    final m = ConnectionManager(dial, park: Duration.zero);
    final f = m.acquire(host, prompts);
    await pumpEventQueue();
    gates.single.complete();
    (await f).release();
    expect(dialled.single.isClosed, isTrue);
  });

  test('one waiter cancelling leaves the shared dial running; the last one stops it', () async {
    final m = ConnectionManager(dial);
    final c1 = CancellationToken(), c2 = CancellationToken();
    final a = m.acquire(host, prompts, cancel: c1), b = m.acquire(host, prompts, cancel: c2);
    await pumpEventQueue();
    c1.cancel();
    await expectLater(a, throwsA(isA<ConnectError>().having((e) => e.kind, 'kind', ConnectFailure.cancelled)));
    expect(cancels.single.isCancelled, isFalse);
    c2.cancel();
    await expectLater(b, throwsA(isA<ConnectError>()));
    expect(cancels.single.isCancelled, isTrue);
    gates.single.complete();
    await pumpEventQueue();
    expect(dialled.single.isClosed, isTrue, reason: 'a dial that finishes after everyone left is closed');
  });

  test('a reused transport that cannot open a channel is set aside and dialled again once', () async {
    final m = ConnectionManager(dial);
    final first = m.open(host, prompts, (l) => l.openShell(cols: 80, rows: 24));
    await pumpEventQueue();
    gates.single.complete();
    final (keep, _) = await first;
    dialled.single.failShell = true;

    final second = m.open(host, prompts, (l) => l.openShell(cols: 80, rows: 24));
    await pumpEventQueue();
    expect(gates, hasLength(2));
    gates.last.complete();
    final (lease, _) = await second;
    expect(dialled, hasLength(2));
    expect(dialled.first.isClosed, isFalse, reason: 'the first shell still uses it');
    keep.release();
    expect(dialled.first.isClosed, isTrue, reason: 'set aside transports close with their last lease');
    lease.release();
  });

  test('a fresh transport failing to open a channel is not retried', () async {
    final m = ConnectionManager(dial);
    final f = m.open(host, prompts, (l) => Future<void>.error(StateError('no')));
    await pumpEventQueue();
    gates.single.complete();
    await expectLater(f, throwsA(isA<ConnectError>()));
    expect(gates, hasLength(1));
  });

  test('a lost transport is not handed out again', () async {
    final m = ConnectionManager(dial);
    final f = m.acquire(host, prompts);
    await pumpEventQueue();
    gates.single.complete();
    await f;
    dialled.single.close();
    await pumpEventQueue();
    m.acquire(host, prompts).ignore();
    await pumpEventQueue();
    expect(gates, hasLength(2));
  });

  test('a failed dial is not kept', () async {
    var calls = 0;
    final m = ConnectionManager((h, p, c) async {
      calls++;
      throw const ConnectError(ConnectFailure.auth);
    });
    await expectLater(m.acquire(host, prompts), throwsA(isA<ConnectError>()));
    await expectLater(m.acquire(host, prompts), throwsA(isA<ConnectError>()));
    expect(calls, 2);
  });
}

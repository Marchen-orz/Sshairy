import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/app/capabilities/forwarding.dart';
import 'package:sshairy/features/connections/api.dart';
import 'package:sshairy/features/capabilities/api.dart';
import 'package:sshairy/foundation/result.dart';
import 'package:sshairy/features/connections/domain/transport.dart';
import 'package:sshairy/features/forwarding/api.dart';
import 'package:sshairy/features/forwarding/application/forwarding.dart' show forwardRuntimeProvider;
import 'package:sshairy/features/forwarding/application/relay.dart';
import 'package:sshairy/features/forwarding/application/runtime.dart';
import 'package:sshairy/features/forwarding/domain/socks5.dart';
import 'package:sshairy/features/hosts/api.dart';
import 'package:sshairy/foundation/cancellation.dart';
import 'package:sshairy/foundation/data_dir.dart';
import 'package:sshairy/foundation/file_system.dart';
import 'package:sshairy/foundation/ids.dart';

/// Both ends of a byte pipe, as a socket or an SSH channel would show them.
class Pipe {
  Pipe() {
    _out.stream.listen(
      written.addAll,
      onDone: () {
        outEnded = true;
        _settle();
      },
    );
  }

  final _in = StreamController<Uint8List>();
  final _out = StreamController<List<int>>();
  final _done = Completer<void>();

  /// What the code under test wrote.
  final written = <int>[];
  var destroyed = false, inEnded = false, outEnded = false;

  /// The other side sends [data].
  void send(List<int> data) => _in.add(Uint8List.fromList(data));

  /// The other side will send nothing more.
  void endInput() {
    inEnded = true;
    if (!_in.isClosed) _in.close();
    _settle();
  }

  /// The other side is gone entirely.
  void drop() {
    endInput();
    if (!_done.isCompleted) _done.complete();
  }

  void _settle() {
    if (inEnded && outEnded && !_done.isCompleted) _done.complete();
  }

  Stream<Uint8List> get stream => _in.stream;
  StreamSink<List<int>> get sink => _out.sink;
  Future<void> get done => _done.future;
  Future<void> flush() async {}

  void destroy() {
    destroyed = true;
    if (!_in.isClosed) _in.close();
    if (!_done.isCompleted) _done.complete();
  }
}

class FakeLocal extends Pipe implements LocalConnection {}

class FakeTunnel extends Pipe implements Tunnel {
  @override
  Future<void> close() => _out.close();
}

class FakeListener implements LocalListener {
  FakeListener(this.port);

  @override
  final int port;
  final incoming = StreamController<LocalConnection>();
  var closed = false;

  @override
  Stream<LocalConnection> get connections => incoming.stream;

  @override
  Future<void> close() async => closed = true;
}

class FakeRuntime implements ForwardRuntime {
  final listeners = <FakeListener>[];
  final dials = <(String, int)>[];
  final targets = <FakeLocal>[];
  Object? listenError, connectError;

  @override
  Future<LocalListener> listen(String address, int port) async {
    if (listenError case final e?) throw e;
    final listener = FakeListener(port == 0 ? 40000 : port);
    listeners.add(listener);
    return listener;
  }

  @override
  Future<LocalConnection> connect(
    String host,
    int port, {
    required Duration timeout,
    required CancellationToken cancel,
  }) async {
    dials.add((host, port));
    if (connectError case final e?) throw e;
    final local = FakeLocal();
    targets.add(local);
    return local;
  }
}

class FakeRemote implements RemoteListener {
  FakeRemote(this.server, this.port);

  final Server server;
  @override
  final int port;
  final incoming = StreamController<Tunnel>();
  var closes = 0;

  @override
  Stream<Tunnel> get connections => incoming.stream;

  @override
  Future<bool> close() async {
    closes++;
    return server.remoteCloses;
  }
}

/// One SSH connection to the fake server.
class ServerConnection implements Transport {
  ServerConnection(this.server);

  final Server server;
  final _done = Completer<void>();
  final dials = <(String, int)>[];
  final tunnels = <FakeTunnel>[];
  FakeRemote? remote;

  @override
  Future<void> get done => _done.future;
  @override
  bool get isClosed => _done.isCompleted;

  @override
  Future<Tunnel> connectTo(String host, int port) async {
    dials.add((host, port));
    await server.openGate?.future;
    if (server.openError case final e?) throw e;
    final tunnel = FakeTunnel();
    tunnels.add(tunnel);
    return tunnel;
  }

  @override
  Future<RemoteListener> listen(String host, int port) async {
    if (server.listenError case final e?) throw e;
    return remote = FakeRemote(server, port == 0 ? 4000 : port);
  }

  @override
  void close() {
    if (!_done.isCompleted) _done.complete();
  }

  @override
  Future<ShellChannel> openShell({required int cols, required int rows, Map<String, String> environment = const {}}) =>
      throw UnimplementedError();
  @override
  Future<FileSystem> openFiles() => throw UnimplementedError();
  @override
  Future<ExecResult> exec(String command, {int limit = 0, Duration? timeout, CancellationToken? cancel}) =>
      throw UnimplementedError();
}

/// What the server does, for every connection made to it.
class Server {
  final connections = <ServerConnection>[];
  Completer<void>? dialGate, openGate;
  Object? dialError, listenError, openError;
  var remoteCloses = true;

  ServerConnection get connection => connections.last;

  Future<Transport> dial(Host host, ConnectPrompts prompts, CancellationToken cancel) async {
    await dialGate?.future;
    if (dialError case final e?) throw e;
    final connection = ServerConnection(this);
    connections.add(connection);
    return connection;
  }
}

class _NoPrompts implements ConnectPrompts {
  @override
  Future<TrustChoice> hostKey(HostKeyPrompt prompt) async => TrustChoice.reject;
  @override
  Future<SecretAnswer?> secret(SecretRequest request) async => null;
}

const _host = Host(id: HostId('h'), label: 'h', address: 'example.com', username: 'u');

class _Hosts extends HostsNotifier {
  @override
  List<Host> build() => [_host];
}

Matcher forwardError(String code) => throwsA(isA<ForwardError>().having((e) => e.code, 'code', code));

/// What a SOCKS5 server answers to a client that sends [bytes]; 'closed' when it just hangs up.
Object? refusal(List<int> bytes) {
  try {
    Socks5Handshake().feed(bytes);
  } on Socks5Error catch (e) {
    return e.reply ?? 'closed';
  }
  return null;
}

void main() {
  group('rules', () {
    test('survive a round trip and reject bad fields', () {
      const rule = ForwardRule(
        id: ForwardId('r'),
        hostId: HostId('h'),
        label: 'db',
        kind: ForwardKind.remote,
        listenAddress: '::1',
        listenPort: 9000,
        destinationAddress: 'db',
        destinationPort: 5432,
        autoStart: true,
      );
      expect(ForwardRule.fromJson(rule.toJson()).toJson(), rule.toJson());
      expect(rule.endpoint, '[::1]:9000');
      expect(rule.destination, 'db:5432');
      expect(
        const ForwardRule(
          id: ForwardId('d'),
          hostId: HostId('h'),
          kind: ForwardKind.dynamic,
          listenPort: 1080,
        ).toJson(),
        isNot(contains('destinationPort')),
      );
      ForwardRule bad({int listen = 1, int destination = 1, String address = 'a'}) => ForwardRule(
        id: const ForwardId('r'),
        hostId: const HostId('h'),
        listenPort: listen,
        destinationAddress: address,
        destinationPort: destination,
      );
      expect(bad().validate, returnsNormally);
      expect(bad(listen: 70000).validate, throwsArgumentError);
      expect(bad(destination: 0).validate, throwsArgumentError);
      expect(bad(address: 'a b').validate, throwsArgumentError);
    });

    test('only loopback addresses stay private', () {
      for (final a in ['127.0.0.1', '127.8.8.8', '::1', 'localhost']) {
        expect(isLoopback(a), isTrue, reason: a);
      }
      for (final a in ['0.0.0.0', '::', '192.168.1.2', 'example.com', '127.0.0']) {
        expect(isLoopback(a), isFalse, reason: a);
      }
    });
  });

  group('socks5', () {
    test('reads a domain request that arrives in pieces', () {
      final handshake = Socks5Handshake();
      final name = 'example.com'.codeUnits;
      final request = [5, 1, 0, 3, name.length, ...name, 0x01, 0xbb, 9, 9];
      expect(handshake.feed([5]), isNull);
      expect(handshake.feed([1, 0]), [5, 0]);
      expect(handshake.feed(request.sublist(0, 7)), isNull);
      expect(handshake.request, isNull);
      handshake.feed(request.sublist(7));
      expect(handshake.request?.host, 'example.com');
      expect(handshake.request?.port, 443);
      expect(handshake.rest, [9, 9]);
    });

    test('reads IPv4 and IPv6 requests', () {
      final v4 = Socks5Handshake()..feed([5, 1, 0, 5, 1, 0, 1, 10, 0, 0, 7, 0, 80]);
      expect((v4.request?.host, v4.request?.port), ('10.0.0.7', 80));
      final v6 = Socks5Handshake()..feed([5, 1, 0, 5, 1, 0, 4, ...List.filled(15, 0), 1, 0x1f, 0x90]);
      expect((v6.request?.host, v6.request?.port), ('0:0:0:0:0:0:0:1', 8080));
    });

    test('refuses what it does not serve', () {
      expect(refusal([5, 1, 2]), [5, 0xff]);
      expect(refusal([5, 1, 0, 5, 2, 0, 1, 0, 0, 0, 0, 0, 80]), Socks5Reply.of(Socks5Reply.commandUnsupported));
      expect(refusal([5, 1, 0, 5, 1, 0, 9, 0, 0]), Socks5Reply.of(Socks5Reply.addressUnsupported));
      expect(refusal([5, 1, 0, 5, 1, 0, 1, 1, 2, 3, 4, 0, 0]), Socks5Reply.of(Socks5Reply.failure));
      expect(refusal([4, 1, 0]), 'closed');
    });
  });

  group('relay', () {
    test('copies both ways and keeps the other direction open after a half-close', () async {
      final local = FakeLocal(), tunnel = FakeTunnel();
      final finished = relay(local, tunnel);
      local.send([1, 2]);
      tunnel.send([3]);
      await pumpEventQueue();
      expect(tunnel.written, [1, 2]);
      expect(local.written, [3]);

      local.endInput();
      await pumpEventQueue();
      expect(tunnel.outEnded, isTrue);
      tunnel.send([4]);
      await pumpEventQueue();
      expect(local.written, [3, 4]);
      expect((tunnel.destroyed, local.destroyed), (false, false));

      tunnel.endInput();
      await finished;
      expect((tunnel.destroyed, local.destroyed), (true, true));
    });

    test('hangs up on a client that stays connected after the channel is gone', () async {
      final local = FakeLocal(), tunnel = FakeTunnel();
      final finished = relay(local, tunnel);
      tunnel.send([7]);
      tunnel.drop();
      await finished;
      expect(local.written, [7]);
      expect(local.destroyed, isTrue);
    });
  });

  group('manager', () {
    late Directory dir;
    late Server server;
    late FakeRuntime runtime;
    late ConnectionManager manager;
    late ProviderContainer container;
    late Forwards forwards;

    ProviderContainer open() => ProviderContainer(
      overrides: [
        dataDirProvider.overrideWithValue(dir.path),
        hostsProvider.overrideWith(_Hosts.new),
        connectionManagerProvider.overrideWithValue(manager),
        forwardRuntimeProvider.overrideWithValue(runtime),
      ],
    );

    ForwardRule rule(
      String id, {
      ForwardKind kind = ForwardKind.local,
      String address = '127.0.0.1',
      int port = 8080,
      HostId hostId = const HostId('h'),
      bool autoStart = false,
      bool autoReconnect = false,
    }) => ForwardRule(
      id: ForwardId(id),
      hostId: hostId,
      kind: kind,
      listenAddress: address,
      listenPort: port,
      destinationAddress: kind == ForwardKind.remote ? '127.0.0.1' : 'db',
      destinationPort: kind == ForwardKind.remote ? 3000 : 5432,
      autoStart: autoStart,
      autoReconnect: autoReconnect,
    );

    ForwardState stateOf(String id) => forwards.byId(ForwardId(id))!;

    Future<ForwardState> begin(ForwardRule r) async {
      await forwards.save(r);
      return forwards.start(r.id);
    }

    Future<void> until(bool Function() test) async {
      final end = DateTime.now().add(const Duration(seconds: 5));
      while (!test()) {
        if (DateTime.now().isAfter(end)) fail('timed out');
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }

    setUp(() {
      dir = Directory.systemTemp.createTempSync('sshairy_fwd');
      server = Server();
      runtime = FakeRuntime();
      manager = ConnectionManager(server.dial, park: Duration.zero);
      container = open();
      forwards = container.read(forwardsProvider.notifier);
    });

    tearDown(() async {
      await forwards.shutdown();
      container.dispose();
      manager.closeAll();
      dir.deleteSync(recursive: true);
    });

    for (final action in ['save', 'delete']) {
      test('queued Agent forward.$action cannot replace a newer UI rule', () async {
        await forwards.save(rule('r'));
        final ui = forwards.save(rule('r', port: 8081));
        final cap = container
            .read(Provider((ref) => forwardCapabilities(ref)))
            .firstWhere((c) => c.id == 'forward.$action');
        final pending = cap.invoke(
          action == 'save' ? rule('r', port: 8082).toJson() : {'id': 'r'},
          RequestContext(Origin.agent),
        );
        await ui;
        expect(await pending, isA<Err<Object?>>().having((e) => e.error.code, 'code', 'conflict'));
        expect(forwards.byId(const ForwardId('r'))!.rule.listenPort, 8081);
      });
    }

    test('queued Agent forward creation cannot overwrite a concurrently created ID', () async {
      final ui = forwards.save(rule('new', port: 8081));
      final cap = container.read(Provider((ref) => forwardCapabilities(ref))).firstWhere((c) => c.id == 'forward.save');
      final pending = cap.invoke(rule('new', port: 8082).toJson(), RequestContext(Origin.agent));
      await ui;
      expect(await pending, isA<Err<Object?>>().having((e) => e.error.code, 'code', 'conflict'));
      expect(forwards.byId(const ForwardId('new'))!.rule.listenPort, 8081);
    });

    test('a local forward carries data to its destination and releases everything on stop', () async {
      final started = await begin(rule('l'));
      expect((started.phase, started.port), (ForwardPhase.running, 8080));
      final client = FakeLocal();
      runtime.listeners.single.incoming.add(client);
      await pumpEventQueue();
      expect(server.connection.dials, [('db', 5432)]);
      expect(stateOf('l').connections, 1);

      final tunnel = server.connection.tunnels.single;
      client.send([1, 2, 3]);
      tunnel.send([9]);
      await pumpEventQueue();
      expect(tunnel.written, [1, 2, 3]);
      expect(client.written, [9]);

      final stopped = await forwards.stop(ForwardId('l'));
      expect((stopped.phase, stopped.connections), (ForwardPhase.stopped, 0));
      expect(runtime.listeners.single.closed, isTrue);
      expect((client.destroyed, tunnel.destroyed), (true, true));
      expect(server.connection.isClosed, isTrue);
    });

    test('starting twice uses one listener and one connection', () async {
      await forwards.save(rule('l'));
      await Future.wait([forwards.start(const ForwardId('l')), forwards.start(const ForwardId('l'))]);
      expect(runtime.listeners, hasLength(1));
      expect(server.connections, hasLength(1));
    });

    test('a dynamic forward answers SOCKS5 and then relays what follows the request', () async {
      await begin(rule('d', kind: ForwardKind.dynamic, port: 1080));
      final client = FakeLocal();
      runtime.listeners.single.incoming.add(client);
      client.send([5, 1, 0]);
      await pumpEventQueue();
      expect(client.written, [5, 0]);

      final name = 'example.com'.codeUnits;
      client.send([5, 1, 0, 3, name.length, ...name, 0x01, 0xbb, 7, 7]);
      await pumpEventQueue();
      expect(server.connection.dials, [('example.com', 443)]);
      expect(client.written.skip(2), Socks5Reply.of(Socks5Reply.succeeded));
      expect(server.connection.tunnels.single.written, [7, 7]);
    });

    test('a failed dial or a bad handshake ends only that connection', () async {
      await begin(rule('d', kind: ForwardKind.dynamic, port: 1080));
      final listener = runtime.listeners.single;

      server.openError = const ConnectError(ConnectFailure.network, 'channel open timed out');
      final slow = FakeLocal();
      listener.incoming.add(slow);
      slow.send([5, 1, 0, 5, 1, 0, 1, 10, 0, 0, 7, 0, 80]);
      await pumpEventQueue();
      expect(slow.written.skip(2), Socks5Reply.of(Socks5Reply.hostUnreachable));
      expect(slow.destroyed, isTrue);
      expect((stateOf('d').phase, stateOf('d').error), (ForwardPhase.running, ForwardErrors.timeout));

      server.openError = const ConnectError(ConnectFailure.network, 'closed by peer');
      final refused = FakeLocal();
      listener.incoming.add(refused);
      refused.send([5, 1, 0, 5, 1, 0, 1, 10, 0, 0, 7, 0, 80]);
      await pumpEventQueue();
      expect(refused.written.skip(2), Socks5Reply.of(Socks5Reply.refused));
      expect(stateOf('d').error, ForwardErrors.targetFailed);

      final rude = FakeLocal();
      listener.incoming.add(rude);
      rude.send([4, 1, 0]);
      await pumpEventQueue();
      expect(rude.destroyed, isTrue);
      expect((stateOf('d').phase, stateOf('d').error), (ForwardPhase.running, ForwardErrors.handshake));
      expect(stateOf('d').connections, 0);
    });

    test('a remote forward dials its destination here for each connection the server hands over', () async {
      await begin(rule('r', kind: ForwardKind.remote, port: 9000));
      final remote = server.connection.remote!;
      final tunnel = FakeTunnel();
      remote.incoming.add(tunnel);
      await pumpEventQueue();
      expect(runtime.dials, [('127.0.0.1', 3000)]);
      tunnel.send([1]);
      runtime.targets.single.send([2]);
      await pumpEventQueue();
      expect(runtime.targets.single.written, [1]);
      expect(tunnel.written, [2]);

      runtime.connectError = const ForwardError(ForwardErrors.targetFailed);
      final failing = FakeTunnel();
      remote.incoming.add(failing);
      await pumpEventQueue();
      expect(failing.destroyed, isTrue);
      expect((stateOf('r').phase, stateOf('r').error), (ForwardPhase.running, ForwardErrors.targetFailed));

      await forwards.stop(const ForwardId('r'));
      expect(remote.closes, 1);
      expect(server.connection.isClosed, isTrue);
    });

    test('a server that refuses the listener, a busy port and a missing host each fail with their own code', () async {
      server.listenError = const ConnectError(ConnectFailure.network, 'forward refused');
      var s = await begin(rule('r', kind: ForwardKind.remote, port: 9000));
      expect((s.phase, s.error), (ForwardPhase.failed, ForwardErrors.refused));
      expect(server.connection.isClosed, isTrue);

      runtime.listenError = const ForwardError(ForwardErrors.addressInUse);
      s = await begin(rule('l'));
      expect((s.phase, s.error), (ForwardPhase.failed, ForwardErrors.addressInUse));
      expect(server.connection.isClosed, isTrue);

      s = await begin(rule('x', hostId: const HostId('gone'), port: 8081));
      expect((s.phase, s.error), (ForwardPhase.failed, ForwardErrors.hostMissing));

      server.dialError = const ConnectError(ConnectFailure.hostKeyRejected);
      s = await begin(rule('k', port: 8082));
      expect((s.phase, s.error), (ForwardPhase.failed, ConnectFailure.hostKeyRejected.name));
      await forwards.delete(const ForwardId('k'));
    });

    test('stopping while still dialling leaves no connection behind', () async {
      server.dialGate = Completer<void>();
      await forwards.save(rule('l'));
      final starting = forwards.start(const ForwardId('l'));
      await pumpEventQueue();
      expect(stateOf('l').phase, ForwardPhase.starting);

      expect((await forwards.stop(const ForwardId('l'))).phase, ForwardPhase.stopped);
      await starting;
      server.dialGate!.complete();
      await pumpEventQueue();
      expect(server.connection.isClosed, isTrue);
      expect(runtime.listeners, isEmpty);
    });

    test('a stop the server cannot confirm keeps the lease and refuses start, save and delete', () async {
      server.remoteCloses = false;
      final r = rule('r', kind: ForwardKind.remote, port: 9000);
      await begin(r);
      final stopped = await forwards.stop(r.id);
      expect((stopped.phase, stopped.error), (ForwardPhase.stopFailed, ForwardErrors.stopFailed));
      expect(server.connection.isClosed, isFalse);
      await expectLater(forwards.start(r.id), forwardError(ForwardErrors.busy));
      await expectLater(forwards.delete(r.id), forwardError(ForwardErrors.busy));
      await expectLater(forwards.save(r), forwardError(ForwardErrors.busy));

      server.remoteCloses = true;
      expect((await forwards.stop(r.id)).phase, ForwardPhase.stopped);
      expect(server.connection.isClosed, isTrue);
      await forwards.delete(r.id);
      expect(forwards.state, isEmpty);
    });

    test('losing the connection settles an unconfirmed stop', () async {
      server.remoteCloses = false;
      final r = rule('r', kind: ForwardKind.remote, port: 9000);
      await begin(r);
      await forwards.stop(r.id);
      expect(stateOf('r').phase, ForwardPhase.stopFailed);

      server.connection.close();
      await until(() => stateOf('r').phase == ForwardPhase.stopped);
      await forwards.delete(r.id);
    });

    test('a lost connection fails the rule and frees the port', () async {
      await begin(rule('l'));
      server.connection.close();
      await until(() => stateOf('l').phase == ForwardPhase.failed);
      expect(stateOf('l').error, ForwardErrors.connectionLost);
      expect(runtime.listeners.single.closed, isTrue);
      await forwards.delete(const ForwardId('l'));
    });

    test('autoReconnect listens again on a new connection', () async {
      await begin(rule('l', autoReconnect: true));
      server.connection.close();
      await until(() => stateOf('l').phase == ForwardPhase.reconnecting);
      await until(() => stateOf('l').phase == ForwardPhase.running);
      expect(server.connections, hasLength(2));
      expect(runtime.listeners, hasLength(2));
      expect(runtime.listeners.first.closed, isTrue);
    });

    test('a manual stop cancels a pending reconnect', () async {
      await begin(rule('l', autoReconnect: true));
      server.connection.close();
      await until(() => stateOf('l').phase == ForwardPhase.reconnecting);
      expect((await forwards.stop(const ForwardId('l'))).phase, ForwardPhase.stopped);
      await Future<void>.delayed(forwardRetryDelays.first + const Duration(milliseconds: 300));
      expect(server.connections, hasLength(1));
      expect(stateOf('l').phase, ForwardPhase.stopped);
    });

    test('closing a terminal does not stop a forward, and stopping a forward does not close the terminal', () async {
      final terminal = await manager.acquire(_host, _NoPrompts());
      await begin(rule('l'));
      terminal.release();
      await pumpEventQueue();
      expect(stateOf('l').phase, ForwardPhase.running);
      expect(server.connection.isClosed, isFalse);

      final second = await manager.acquire(_host, _NoPrompts());
      await forwards.stop(const ForwardId('l'));
      expect(server.connection.isClosed, isFalse);
      second.release();
      expect(server.connection.isClosed, isTrue);
    });

    test('at most 128 connections at once; the rest are dropped and the rule keeps running', () async {
      server.openGate = Completer<void>();
      await begin(rule('l'));
      final clients = [for (var i = 0; i < forwardMaxConnections + 2; i++) FakeLocal()];
      for (final c in clients) {
        runtime.listeners.single.incoming.add(c);
      }
      await pumpEventQueue();
      expect(stateOf('l').connections, forwardMaxConnections);
      expect(stateOf('l').error, ForwardErrors.limit);
      expect(clients.take(forwardMaxConnections).any((c) => c.destroyed), isFalse);
      expect(clients.skip(forwardMaxConnections).every((c) => c.destroyed), isTrue);

      server.openGate!.complete();
      await pumpEventQueue();
      expect(server.connection.tunnels, hasLength(forwardMaxConnections));
      expect(stateOf('l').phase, ForwardPhase.running);
    });

    test('listening beyond loopback needs a yes once, and rules survive a restart', () async {
      final exposed = rule('e', address: '0.0.0.0');
      expect(forwards.needsExposureConfirmation(exposed), isTrue);
      await expectLater(forwards.save(exposed), forwardError(ForwardErrors.exposureUnconfirmed));
      expect(forwards.state, isEmpty);
      await forwards.save(exposed, exposureConfirmed: true);
      expect(forwards.needsExposureConfirmation(exposed), isFalse);
      expect(stateOf('e').rule.exposed, isTrue);

      final reopened = open();
      addTearDown(reopened.dispose);
      expect([for (final s in reopened.read(forwardsProvider)) s.rule.toJson()], [exposed.toJson()]);
    });

    test('autoStart starts only the marked rules, once', () async {
      await forwards.save(rule('a', autoStart: true));
      await forwards.save(rule('b', port: 8081));
      await forwards.autoStart();
      expect((stateOf('a').phase, stateOf('b').phase), (ForwardPhase.running, ForwardPhase.stopped));

      await forwards.stop(const ForwardId('a'));
      await forwards.autoStart();
      expect(stateOf('a').phase, ForwardPhase.stopped);
    });

    test('forwarding is offered to the agent only through approved capabilities', () {
      final capabilities = container.read(Provider((ref) => forwardCapabilities(ref)));
      expect([
        for (final c in capabilities)
          if (c.agentExposed) c.id,
      ], containsAll(['forward.list', 'forward.save', 'forward.start', 'forward.stop']));
    });
  });
}

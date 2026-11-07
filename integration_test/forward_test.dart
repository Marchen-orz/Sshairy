// Real server only (docs/TESTING.md §2). The server side is one throwaway python http.server on a high loopback port
// (with a hard `timeout`), a 2 MiB random file under ~/sshairy-test/fwd, and the remote listeners the rules open.
// Everything is removed in `finally`, and the ports are checked to be free again.
import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sshairy/features/forwarding/api.dart';
import 'package:sshairy/features/hosts/api.dart';

import 'support/server.dart';

const _bindProbe =
    'python3 -c \'import socket,sys; s=socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); '
    's.bind(("127.0.0.1", int(sys.argv[1])))\'';

const _fetchProbe =
    'python3 -c \'import hashlib,sys,urllib.request; '
    'd=urllib.request.urlopen("http://127.0.0.1:%s/blob" % sys.argv[1], timeout=30).read(); '
    'print(hashlib.sha256(d).hexdigest(), len(d))\'';

/// Reads a socket the way a protocol client does: a number of bytes now, or everything until the peer closes.
class _Reader {
  _Reader(Socket socket) {
    socket.listen(
      (data) {
        _buffer.addAll(data);
        _wake();
      },
      onDone: () {
        _done = true;
        _wake();
      },
      onError: (Object _) {
        _done = true;
        _wake();
      },
    );
  }

  final _buffer = <int>[];
  var _done = false;
  Completer<void>? _waiting;

  void _wake() {
    _waiting?.complete();
    _waiting = null;
  }

  Future<void> _more() => (_waiting ??= Completer<void>()).future.timeout(const Duration(seconds: 30));

  Future<List<int>> take(int count) async {
    while (_buffer.length < count) {
      if (_done) throw StateError('closed after ${_buffer.length} of $count bytes');
      await _more();
    }
    final out = _buffer.sublist(0, count);
    _buffer.removeRange(0, count);
    return out;
  }

  Future<Uint8List> rest() async {
    while (!_done) {
      await _more();
    }
    final out = Uint8List.fromList(_buffer);
    _buffer.clear();
    return out;
  }
}

String _hashOf(List<int> bytes) => sha256.convert(bytes).toString();

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('forwarding: local, dynamic and remote rules carry real traffic and release their ports', (tester) async {
    final server = TestServer.fromEnvironment();
    final dir = await Directory.systemTemp.createTemp('sshairy-fwd-');
    final container = appContainer(dir);
    final hosts = container.read(hostsProvider.notifier);
    final forwards = container.read(forwardsProvider.notifier);
    forwards.prompts = ScriptedPrompts(server);

    final random = Random.secure();
    int pick() => 41000 + random.nextInt(8000);
    final webPort = pick(), closedPort = webPort + 1, remotePort = webPort + 2;

    // The same bytes on both sides: a random file made on the server, and a local web server for the remote rule.
    final blob = Uint8List.fromList(List.generate(2 << 20, (_) => random.nextInt(256)));
    final blobHash = _hashOf(blob);
    final web = await HttpServer.bind('127.0.0.1', 0);
    web.listen((request) {
      request.response.contentLength = blob.length;
      request.response.add(blob);
      request.response.close();
    });

    final host = server.host('fwd-host', const AuthPolicy(allowInteractive: false));
    await hosts.save(host);
    final prompts = ScriptedPrompts(server);
    Future<String> remote(String script) => container.exec(hosts.byId(host.id)!, prompts, script);
    Future<bool> remoteFree(int port) async =>
        (await remote('$_bindProbe $port && echo free || echo busy')).trim() == 'free';
    Future<bool> localFree(int port) async {
      try {
        await (await ServerSocket.bind('127.0.0.1', port)).close();
        return true;
      } on SocketException {
        return false;
      }
    }

    var serverReady = false;
    try {
      for (final port in [webPort, closedPort, remotePort]) {
        expect(await remoteFree(port), isTrue, reason: 'port $port must be idle on the server; run the test again');
      }
      serverReady = true;
      final setup = await remote(
        'set -e; mkdir -p ~/sshairy-test/fwd; cd ~/sshairy-test/fwd; head -c 2097152 /dev/urandom > blob; '
        "sha256sum blob | cut -d' ' -f1; "
        '(setsid timeout 900 python3 -m http.server $webPort --bind 127.0.0.1 >/dev/null 2>&1 </dev/null & echo \$! > ../fwd.pid); '
        'sleep 1; cat ../fwd.pid',
      );
      final lines = setup.trim().split('\n');
      final serverHash = lines[0].trim();
      expect(serverHash, hasLength(64));

      Future<ForwardState> run(ForwardRule rule) async {
        await forwards.save(rule);
        final state = await forwards.start(rule.id);
        expect(state.phase, ForwardPhase.running, reason: '${rule.title}: ${state.error} ${state.detail}');
        return state;
      }

      Future<void> halt(ForwardId id) async {
        final state = await forwards.stop(id);
        expect(state.phase, ForwardPhase.stopped, reason: '${state.error} ${state.detail}');
      }

      Future<String> download(int port) async {
        final client = HttpClient();
        try {
          final response = await (await client.getUrl(Uri.parse('http://127.0.0.1:$port/blob'))).close();
          final digest = await sha256.bind(response).first;
          return digest.toString();
        } finally {
          client.close(force: true);
        }
      }

      Future<void> settle(ForwardId id, [int connections = 0]) async {
        final deadline = DateTime.now().add(const Duration(seconds: 10));
        while (forwards.byId(id)!.connections != connections && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        expect(forwards.byId(id)!.connections, connections, reason: 'connections of $id');
      }

      // Local: a loopback listener, eight downloads at once, a refused destination, and the port given back.
      const local = ForwardId('local');
      final localRule = ForwardRule(id: local, hostId: host.id, listenPort: 0, destinationPort: webPort);
      final localPort = (await run(localRule)).port!;
      expect(await download(localPort), serverHash, reason: 'one download through the local forward');
      final parallel = await Future.wait([for (var i = 0; i < 8; i++) download(localPort)]);
      expect(parallel.every((h) => h == serverHash), isTrue, reason: 'eight parallel downloads');
      await settle(local);

      final lan = [
        for (final i in await NetworkInterface.list(type: InternetAddressType.IPv4))
          for (final a in i.addresses)
            if (!a.isLoopback) a,
      ].firstOrNull;
      if (lan != null) {
        await expectLater(
          Socket.connect(lan, localPort, timeout: const Duration(seconds: 3)),
          throwsA(anything),
          reason: 'a loopback rule must not answer on ${lan.address}',
        );
      }
      await halt(local);
      expect(await localFree(localPort), isTrue, reason: 'local port released after stop');

      const refused = ForwardId('refused');
      final refusedPort = (await run(
        ForwardRule(id: refused, hostId: host.id, listenPort: 0, destinationPort: closedPort),
      )).port!;
      final probe = await Socket.connect('127.0.0.1', refusedPort);
      probe.add([1, 2, 3]);
      await probe.drain<void>().then<void>((_) {}, onError: (Object _) {}).timeout(const Duration(seconds: 15));
      probe.destroy();
      final afterRefusal = forwards.byId(refused)!;
      expect(afterRefusal.phase, ForwardPhase.running, reason: 'a refused destination must not stop the rule');
      expect(afterRefusal.error, ForwardErrors.targetFailed);
      await halt(refused);

      // A port somebody else already listens on is reported as such, and the other listener is left alone.
      final taken = await ServerSocket.bind('127.0.0.1', 0);
      try {
        const clash = ForwardId('clash');
        await forwards.save(ForwardRule(id: clash, hostId: host.id, listenPort: taken.port, destinationPort: webPort));
        final clashed = await forwards.start(clash);
        expect(clashed.phase, isNot(ForwardPhase.running), reason: 'the port is taken');
        expect(clashed.error, ForwardErrors.addressInUse);
        final still = await Socket.connect('127.0.0.1', taken.port);
        still.destroy();
        expect(forwards.byId(clash)!.active, isFalse, reason: 'a failed start leaves nothing running');
      } finally {
        await taken.close();
      }

      // Dynamic: SOCKS5 by name, by IPv4, and a refusal that is answered with code 5.
      const socksId = ForwardId('dynamic');
      final socksPort = (await run(ForwardRule(id: socksId, hostId: host.id, kind: ForwardKind.dynamic, listenPort: 0)))
          .port!;

      Future<({List<int> reply, Uint8List body})> socks(List<int> address, int target) async {
        final socket = await Socket.connect('127.0.0.1', socksPort);
        final reader = _Reader(socket);
        try {
          socket.add([5, 1, 0]);
          expect(await reader.take(2), [5, 0]);
          socket.add([5, 1, 0, ...address, target >> 8, target & 0xff]);
          final reply = await reader.take(10);
          if (reply[1] == 0) socket.add('GET /blob HTTP/1.0\r\n\r\n'.codeUnits);
          return (reply: reply, body: await reader.rest());
        } finally {
          socket.destroy();
        }
      }

      Uint8List payload(Uint8List response) {
        final split = String.fromCharCodes(response.take(2000)).indexOf('\r\n\r\n');
        return Uint8List.sublistView(response, split + 4);
      }

      final byName = await socks([3, 9, ...'localhost'.codeUnits], webPort);
      expect(byName.reply[1], 0, reason: 'SOCKS5 by name');
      expect(_hashOf(payload(byName.body)), serverHash);
      final byAddress = await socks([1, 127, 0, 0, 1], webPort);
      expect(byAddress.reply[1], 0, reason: 'SOCKS5 by IPv4');
      expect(_hashOf(payload(byAddress.body)), serverHash);
      final closed = await socks([1, 127, 0, 0, 1], closedPort);
      expect(closed.reply[1], 5, reason: 'a destination that refuses is answered with 5');
      expect(forwards.byId(socksId)!.phase, ForwardPhase.running);
      await settle(socksId);
      await halt(socksId);
      expect(await localFree(socksPort), isTrue, reason: 'SOCKS port released after stop');

      // Remote: the server reaches this machine's web server through its own loopback port.
      const reverse = ForwardId('reverse');
      await run(
        ForwardRule(
          id: reverse,
          hostId: host.id,
          kind: ForwardKind.remote,
          listenPort: remotePort,
          destinationPort: web.port,
        ),
      );
      expect((await remote('$_fetchProbe $remotePort')).trim(), '$blobHash ${blob.length}', reason: 'remote forward');
      await settle(reverse);
      await halt(reverse);
      expect(await remoteFree(remotePort), isTrue, reason: 'remote port released after stop');

      // Remote with port 0 asks the server to choose; what the app reports is looked at, not assumed.
      const zero = ForwardId('zero');
      await forwards.save(
        ForwardRule(id: zero, hostId: host.id, kind: ForwardKind.remote, listenPort: 0, destinationPort: web.port),
      );
      final zeroState = await forwards.start(zero);
      // ignore: avoid_print
      print('remote port 0 -> phase=${zeroState.phase} port=${zeroState.port} error=${zeroState.error}');
      if (zeroState.phase == ForwardPhase.running) {
        final stopped = await forwards.stop(zero);
        // ignore: avoid_print
        print('remote port 0 stop -> phase=${stopped.phase} error=${stopped.error}');
      }

      // A rule that is still running when the app quits is stopped by shutdown.
      const quit = ForwardId('quit');
      final quitPort = (await run(ForwardRule(id: quit, hostId: host.id, listenPort: 0, destinationPort: webPort)))
          .port!;
      await forwards.shutdown();
      expect(await localFree(quitPort), isTrue, reason: 'shutdown releases the listener');
      expect(forwards.state.every((s) => !s.active), isTrue, reason: 'nothing is left active after shutdown');
    } finally {
      if (serverReady) {
        String cleaned;
        try {
          cleaned = await remote(
            'kill \$(cat ~/sshairy-test/fwd.pid 2>/dev/null) 2>/dev/null; sleep 1; '
            'rm -rf ~/sshairy-test/fwd ~/sshairy-test/fwd.pid; rmdir ~/sshairy-test 2>/dev/null; '
            'for p in $webPort $closedPort $remotePort; do $_bindProbe \$p && echo free || echo busy; done; '
            '[ -e ~/sshairy-test ] && echo left || echo gone',
          );
        } on Object catch (e) {
          cleaned = 'cleanup failed: $e';
        }
        await web.close(force: true);
        for (final h in List.of(hosts.library.hosts)) {
          await hosts.delete(h);
        }
        container.dispose();
        await dir.delete(recursive: true).then((_) {}, onError: (Object _) {});
        expect(
          cleaned.trim().split('\n').where((l) => l == 'busy'),
          isEmpty,
          reason: 'server ports free again: $cleaned',
        );
      } else {
        await web.close(force: true);
        container.dispose();
        await dir.delete(recursive: true).then((_) {}, onError: (Object _) {});
      }
    }
  });
}

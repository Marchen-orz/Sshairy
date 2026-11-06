// Real server only; the same environment variables as app_test.dart. No server files or services are changed.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sshairy/features/connections/api.dart';
import 'package:sshairy/features/connections/adapters/ssh.dart';
import 'package:sshairy/features/credentials/api.dart';
import 'package:sshairy/features/hosts/api.dart';
import 'package:sshairy/foundation/ids.dart';
import 'package:sshairy/foundation/secret.dart';

class _MemorySecrets extends SecretStore {
  @override
  Future<Secret?> read(String ref) async => null;
  @override
  Future<void> write(String ref, Secret value) async => throw StateError('test must not save credentials');
}

class _Prompts implements ConnectPrompts {
  _Prompts(this.password);
  final Secret password;
  final fingerprints = <String, String>{};
  final endpoints = <String>{};

  @override
  Future<TrustChoice> hostKey(HostKeyPrompt p) async {
    endpoints.add(p.endpoint);
    // The loopback target is this same server; every subsequent hop must present the same public key.
    final expected = fingerprints[p.type];
    if (expected != null && p.fingerprint != expected) return TrustChoice.reject;
    fingerprints[p.type] = p.fingerprint;
    return TrustChoice.once;
  }

  @override
  Future<SecretAnswer?> secret(SecretRequest request) async =>
      request.kind == SecretKind.password ? SecretAnswer(password) : null;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('routes: jump trust, shared leases, direct tunnel and confirmed remote stop', (tester) async {
    final target = Platform.environment['SSHAIRY_TEST_TARGET'];
    final value = Platform.environment['SSHAIRY_TEST_PASSWORD'];
    if (target == null || value == null) fail('Set SSHAIRY_TEST_TARGET and SSHAIRY_TEST_PASSWORD');
    final parsed = parseQuickConnect(target)!;
    final gateway = parsed.copyWith(id: const HostId('gateway'));
    final inner = Host(
      id: const HostId('inner'),
      label: 'loopback',
      address: '127.0.0.1',
      port: parsed.port,
      username: parsed.username,
      jumpHostId: gateway.id,
    );
    final dir = await Directory.systemTemp.createTemp('sshairy-routes-');
    late final ConnectionManager manager;
    final dialer = SshDialer(
      HostTrustService(dir.path),
      _MemorySecrets(),
      () => (timeout: const Duration(seconds: 20), keepAlive: const Duration(seconds: 30)),
      (_) => null,
      (route, prompts, cancel) => manager.acquireRoute(route, prompts, cancel: cancel),
    );
    manager = ConnectionManager.routed(dialer.dial, (id) => id == gateway.id ? gateway : null, park: Duration.zero);
    final prompts = _Prompts(Secret(value));
    try {
      final shellLease = await manager.acquire(gateway, prompts);
      final downstream = await manager.acquire(inner, prompts);
      final output = await downstream.exec('printf sshairy-jump-ok');
      expect(output.exitCode, 0);
      expect(utf8.decode(output.stdout), 'sshairy-jump-ok');
      expect(prompts.endpoints, hasLength(2));
      expect(manager.hosts, hasLength(2));
      shellLease.release();
      expect(downstream.lost, isFalse);
      final again = await manager.acquire(gateway, prompts);
      expect(again.reused, isTrue, reason: 'the downstream transport holds the gateway lease');

      final tunnel = await again.connectTo('127.0.0.1', parsed.port);
      final banner = await tunnel.stream.map(utf8.decode).joinUntilNewline();
      expect(banner, contains('SSH-2.0-'));
      tunnel.destroy();

      final listener = await again.listen('127.0.0.1', 0);
      final accepted = <Tunnel>[];
      final subscription = listener.connections.listen((channel) {
        accepted.add(channel);
        channel.stream.listen(
          channel.sink.add,
          onDone: () => channel.close(),
          onError: (Object _) => channel.destroy(),
        );
      });
      try {
        final reply = await again.exec(
          'python3 -c "import socket; s=socket.create_connection((\'127.0.0.1\',${listener.port}),5); s.sendall(b\'sshairy-forward-ok\'); print(s.recv(64).decode()); s.close()"',
        );
        expect(reply.exitCode, 0);
        expect(utf8.decode(reply.stdout).trim(), 'sshairy-forward-ok');
        expect(await listener.close(), isTrue);
        final closed = await again.exec(
          'python3 -c "import socket; s=socket.socket(); s.settimeout(2); print(s.connect_ex((\'127.0.0.1\',${listener.port})) != 0); s.close()"',
        );
        expect(utf8.decode(closed.stdout).trim(), 'True');
      } finally {
        await listener.close();
        for (final channel in accepted) {
          channel.destroy();
        }
        await subscription.cancel();
      }
      downstream.release();
      expect(again.lost, isFalse);
      expect((await again.exec('printf sshairy-alive')).exitCode, 0);
      again.release();
    } finally {
      manager.closeAll();
      await dir.delete(recursive: true);
    }
  });
}

extension on Stream<String> {
  Future<String> joinUntilNewline() async {
    final buffer = StringBuffer();
    await for (final chunk in timeout(const Duration(seconds: 10))) {
      buffer.write(chunk);
      if (buffer.toString().contains('\n')) return buffer.toString();
    }
    return buffer.toString();
  }
}

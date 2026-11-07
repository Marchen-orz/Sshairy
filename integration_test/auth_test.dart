// Real server only; the same environment variables as app_test.dart. No server files or services are changed.
// A throwaway key that the server does not know stands in for "the key is refused": the password-only, key-then-
// password and key-only policies of docs/HOST_INHERITANCE.md are checked against the server's real answers.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sshairy/features/connections/adapters/ssh.dart';
import 'package:sshairy/features/connections/api.dart';
import 'package:sshairy/features/credentials/api.dart';
import 'package:sshairy/features/hosts/api.dart';
import 'package:sshairy/foundation/ids.dart';
import 'package:sshairy/foundation/secret.dart';

class _NoSecrets implements ConnectionCredentials {
  @override
  int get revision => 0;
  @override
  Future<Secret?> read(SecretRef ref) async => null;
  @override
  Future<void> remember(SecretRef ref, Secret value) async => throw StateError('test must not save credentials');
}

class _Prompts implements ConnectPrompts {
  _Prompts(this.password);
  final Secret password;
  var passwordAsked = 0;

  @override
  Future<TrustChoice> hostKey(HostKeyPrompt p) async => TrustChoice.once;

  @override
  Future<SecretAnswer?> secret(SecretRequest request) async {
    if (request.kind != SecretKind.password) return null;
    passwordAsked++;
    return SecretAnswer(password);
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('auth: password only, key then password, and a refused key alone', (tester) async {
    final target = Platform.environment['SSHAIRY_TEST_TARGET'];
    final value = Platform.environment['SSHAIRY_TEST_PASSWORD'];
    if (target == null || value == null) fail('Set SSHAIRY_TEST_TARGET and SSHAIRY_TEST_PASSWORD');
    final parsed = parseQuickConnect(target)!;
    final dir = await Directory.systemTemp.createTemp('sshairy-auth-');
    final keyFile = '${dir.path}/unknown_key';
    final keygen = await Process.run('ssh-keygen', ['-q', '-t', 'ed25519', '-N', '', '-f', keyFile]);
    if (keygen.exitCode != 0) fail('ssh-keygen is needed to make a key the server does not know');

    Host host(String id, AuthPolicy policy) => Host(
      id: HostId(id),
      label: id,
      address: parsed.address,
      port: parsed.port,
      username: parsed.username,
      authPolicy: policy,
    );

    late final ConnectionManager manager;
    final dialer = SshDialer(
      HostTrustService(dir.path),
      _NoSecrets(),
      () => (timeout: const Duration(seconds: 20), keepAlive: const Duration(seconds: 30)),
      (_) => null,
      (route, prompts, cancel) => manager.acquireRoute(route, prompts, cancel: cancel),
    );
    manager = ConnectionManager.routed(dialer.dial, (_) => null, park: Duration.zero);
    final prompts = _Prompts(Secret(value));

    Future<String> run(Host h) async {
      final lease = await manager.acquire(h, prompts);
      try {
        final result = await lease.exec('printf sshairy-auth-ok');
        expect(result.exitCode, 0);
        return utf8.decode(result.stdout);
      } finally {
        lease.release();
      }
    }

    try {
      expect(await run(host('pw', const AuthPolicy(allowInteractive: false))), 'sshairy-auth-ok');
      expect(prompts.passwordAsked, 1);

      expect(
        await run(host('both', AuthPolicy(methods: [AuthKind.key, AuthKind.password], keyPath: keyFile))),
        'sshairy-auth-ok',
        reason: 'the server refuses the key, so the password that follows it is used',
      );
      expect(prompts.passwordAsked, 2);

      await expectLater(
        run(host('key', AuthPolicy(methods: [AuthKind.key], keyPath: keyFile))),
        throwsA(isA<ConnectError>().having((e) => e.kind, 'kind', ConnectFailure.auth)),
      );
      expect(prompts.passwordAsked, 2, reason: 'a key-only host never asks for a password');
    } finally {
      manager.closeAll();
      await dir.delete(recursive: true);
    }
  });
}

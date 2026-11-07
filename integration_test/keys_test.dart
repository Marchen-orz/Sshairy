// Real server only (docs/TESTING.md §2). The author allowed this test to append throwaway public keys to
// ~/.ssh/authorized_keys. Every line carries a marker, is removed again in `finally`, and the file's size and mode
// are compared with what they were before. Nothing else on the server is touched.
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sshairy/features/connections/api.dart';
import 'package:sshairy/features/credentials/api.dart';
import 'package:sshairy/features/hosts/api.dart';
import 'package:sshairy/foundation/result.dart';
import 'package:sshairy/foundation/secret.dart';

import 'support/server.dart';

const _file = r'$HOME/.ssh/authorized_keys';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('keys: file and stored keys log in, passphrases are asked, the server is left as found', (tester) async {
    final server = TestServer.fromEnvironment();
    final dir = await Directory.systemTemp.createTemp('sshairy-keys-');
    final marker = 'sshairy-it-${Random.secure().nextInt(1 << 32).toRadixString(36)}';
    final container = appContainer(dir);
    final hosts = container.read(hostsProvider.notifier);
    final keys = container.read(keysProvider.notifier);

    // Throwaway keys made by OpenSSH itself, so the formats are not our own invention.
    Future<({String path, String pub})> keygen(String name, List<String> type, [String passphrase = '']) async {
      final path = '${dir.path}/$name';
      final run = await Process.run('ssh-keygen', ['-q', ...type, '-N', passphrase, '-C', marker, '-f', path]);
      if (run.exitCode != 0) fail('ssh-keygen failed for $name');
      return (path: path, pub: (await File('$path.pub').readAsString()).trim());
    }

    final ed = await keygen('ed', ['-t', 'ed25519']);
    final rsa = await keygen('rsa', ['-t', 'rsa', '-b', '3072']);
    final ecdsa = await keygen('ecdsa', ['-t', 'ecdsa', '-b', '256']);
    final locked = await keygen('locked', ['-t', 'ed25519'], 'first-passphrase');
    final locked2 = await keygen('locked2', ['-t', 'ed25519'], 'second-passphrase');

    final control = server.host('control', const AuthPolicy(allowInteractive: false));
    final controlPrompts = ScriptedPrompts(server);
    await hosts.save(control);
    Future<String> remote(String script) => container.exec(hosts.byId(control.id)!, controlPrompts, script);

    final before = (await remote('stat -c "%s %a" $_file 2>/dev/null || echo absent')).trim();
    var installed = false;
    try {
      final generated = await keys.generate('it-gen');
      Future<void> store(String label, String path, {String? passphrase, bool remember = false}) async {
        final result = await keys.import(
          label,
          path,
          passphrase: passphrase == null ? null : Secret(passphrase),
          remember: remember,
        );
        expect(result, isA<Ok<SshKey>>(), reason: 'importing $label: ${result is Err<SshKey> ? result.error : ''}');
      }

      await store('it-rsa', rsa.path);
      await store('it-locked', locked.path, passphrase: 'first-passphrase', remember: true);
      await store('it-locked2', locked2.path, passphrase: 'second-passphrase');

      final lines = [ed, rsa, ecdsa, locked, locked2].map((k) => k.pub).toList()..add('${generated.publicKey} $marker');
      installed = true;
      await remote(
        'umask 077; mkdir -p ~/.ssh; touch $_file; '
        '[ -s $_file ] && [ -n "\$(tail -c1 $_file)" ] && echo >> $_file; '
        "printf '%s\\n' ${lines.map((l) => "'$l'").join(' ')} >> $_file",
      );

      SshKey stored(String label) => container.read(keysProvider).firstWhere((k) => k.label == label);

      // Each case is one saved host, one fresh connection and the answers the app was given.
      Future<ScriptedPrompts> login(String id, AuthPolicy policy, {List<String> passphrases = const []}) async {
        final host = server.host(id, policy);
        await hosts.save(host);
        final prompts = ScriptedPrompts(server, passphrases: passphrases);
        final output = await container.exec(hosts.byId(host.id)!, prompts, 'printf sshairy-key-ok');
        expect(output, 'sshairy-key-ok', reason: id);
        return prompts;
      }

      AuthPolicy file(String path, {List<AuthKind> methods = const [AuthKind.key]}) =>
          AuthPolicy(methods: methods, keyPath: path, allowInteractive: false);
      AuthPolicy inStore(String label) =>
          AuthPolicy(methods: const [AuthKind.key], keyId: stored(label).id, allowInteractive: false);

      for (final (id, path) in [('file-ed25519', ed.path), ('file-rsa', rsa.path), ('file-ecdsa', ecdsa.path)]) {
        final prompts = await login(id, file(path));
        expect((prompts.passwordAsked, prompts.passphraseAsked), (0, 0), reason: '$id needs no questions');
      }

      final both = await login('key-then-password', file(ed.path, methods: [AuthKind.key, AuthKind.password]));
      expect(both.passwordAsked, 0, reason: 'the accepted key makes the password unnecessary');

      final locked1 = await login('file-locked', file(locked.path), passphrases: ['first-passphrase']);
      expect(locked1.passphraseAsked, 1);

      final wrong = server.host('file-wrong-passphrase', file(locked.path));
      await hosts.save(wrong);
      await expectLater(
        container.exec(hosts.byId(wrong.id)!, ScriptedPrompts(server, passphrases: ['not-it']), 'true'),
        throwsA(isA<ConnectError>().having((e) => e.kind, 'kind', ConnectFailure.keyFile)),
      );

      for (final label in ['it-gen', 'it-rsa']) {
        final prompts = await login('store-$label', inStore(label));
        expect((prompts.passwordAsked, prompts.passphraseAsked), (0, 0), reason: label);
      }
      final remembered = await login('store-locked', inStore('it-locked'));
      expect(remembered.passphraseAsked, 0, reason: 'the passphrase was kept when the key was imported');
      final asked = await login('store-locked2', inStore('it-locked2'), passphrases: ['second-passphrase']);
      expect(asked.passphraseAsked, 1, reason: 'this one was imported without keeping its passphrase');
    } finally {
      final results = <String>[];
      if (installed) {
        results.add(
          await remote(
            'grep -v -F "$marker" $_file > "\$HOME/.ssh/.it.$marker" || true; '
            'cat "\$HOME/.ssh/.it.$marker" > $_file; rm -f "\$HOME/.ssh/.it.$marker"; '
            'grep -c -F "$marker" $_file || true',
          ),
        );
      }
      final after = (await remote('stat -c "%s %a" $_file 2>/dev/null || echo absent')).trim();
      for (final host in List.of(hosts.library.hosts)) {
        await hosts.delete(host);
      }
      for (final key in List.of(container.read(keysProvider))) {
        await keys.delete(key);
      }
      container.dispose();
      await dir.delete(recursive: true).then((_) {}, onError: (Object _) {});
      expect(results.every((r) => r.trim() == '0'), isTrue, reason: 'no marker line may remain on the server');
      expect(after, before, reason: 'authorized_keys must be back to its original size and mode');
    }
  });

  testWidgets('keys: a removed key no longer logs in', (tester) async {
    final server = TestServer.fromEnvironment();
    final dir = await Directory.systemTemp.createTemp('sshairy-keys-gone-');
    final container = appContainer(dir);
    try {
      final path = '${dir.path}/never-installed';
      final run = await Process.run('ssh-keygen', ['-q', '-t', 'ed25519', '-N', '', '-f', path]);
      if (run.exitCode != 0) fail('ssh-keygen failed');
      final host = server.host(
        'gone',
        AuthPolicy(methods: const [AuthKind.key], keyPath: path, allowInteractive: false),
      );
      final hosts = container.read(hostsProvider.notifier);
      await hosts.save(host);
      await expectLater(
        container.exec(hosts.byId(host.id)!, ScriptedPrompts(server), 'true'),
        throwsA(isA<ConnectError>().having((e) => e.kind, 'kind', ConnectFailure.auth)),
      );
    } finally {
      container.dispose();
      await dir.delete(recursive: true).then((_) {}, onError: (Object _) {});
    }
  });
}

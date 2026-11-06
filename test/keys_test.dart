import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/features/credentials/adapters/key_codec.dart';
import 'package:sshairy/features/credentials/api.dart';
import 'package:sshairy/foundation/data_dir.dart';
import 'package:sshairy/foundation/result.dart';
import 'package:sshairy/foundation/secret.dart';

class MemorySecrets implements SecretStore {
  final values = <String, String>{};

  @override
  Future<Secret?> read(String ref) async => values[ref] == null ? null : Secret(values[ref]!);
  @override
  Future<void> write(String ref, Secret value) async => values[ref] = value.reveal();
  @override
  Future<void> delete(String ref) async => values.remove(ref);
}

/// ssh-keygen ships with Windows 10+ and every Linux desktop; it is the reference for formats and fingerprints.
final keygen = () {
  try {
    Process.runSync('ssh-keygen', ['-?']);
    return true;
  } on ProcessException {
    return false;
  }
}();

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('sshairy-keys'));
  tearDown(() => dir.deleteSync(recursive: true));

  String sshKeygen(List<String> args) {
    final r = Process.runSync('ssh-keygen', args);
    if (r.exitCode != 0) fail('ssh-keygen ${args.join(' ')}: ${r.stderr}');
    return (r.stdout as String).trim();
  }

  test('a generated key is one OpenSSH reads, with the same public key and fingerprint', () {
    final pem = KeyCodec.generateEd25519(comment: 'sshairy');
    final info = KeyCodec.inspect(pem, comment: 'sshairy');
    expect(info.algorithm, 'ssh-ed25519');
    expect(info.fingerprint, startsWith('SHA256:'));
    expect(info.fingerprint, isNot(endsWith('=')));
    expect(SSHKeyPair.fromPem(pem).single.type, 'ssh-ed25519');

    final file = File('${dir.path}/gen')..writeAsStringSync(pem);
    if (Platform.isLinux || Platform.isMacOS) Process.runSync('chmod', ['600', file.path]);
    expect(sshKeygen(['-y', '-f', file.path]).split(' ').take(2), info.publicKey.split(' ').take(2));
    expect(sshKeygen(['-l', '-f', file.path]), contains(info.fingerprint));
  }, skip: !keygen);

  test('keys from ssh-keygen: algorithms, encryption and fingerprints match', () {
    for (final (type, bits) in [('ed25519', null), ('rsa', '2048'), ('ecdsa', '256')]) {
      final path = '${dir.path}/$type';
      sshKeygen(['-q', '-t', type, if (bits != null) ...['-b', bits], '-N', 'pass phrase', '-C', 'c', '-f', path]);
      final pem = File(path).readAsStringSync();
      expect(KeyCodec.isEncrypted(pem), isTrue);
      expect(() => KeyCodec.inspect(pem), throwsA(isA<KeyCodecException>().having((e) => e.problem, 'problem', KeyProblem.needsPassphrase)));
      expect(
        () => KeyCodec.inspect(pem, passphrase: 'wrong'),
        throwsA(isA<KeyCodecException>().having((e) => e.problem, 'problem', KeyProblem.wrongPassphrase)),
      );
      final info = KeyCodec.inspect(pem, passphrase: 'pass phrase');
      expect(sshKeygen(['-l', '-f', '$path.pub']), contains(info.fingerprint), reason: type);
      expect(info.publicKey.split(' ').take(2), File('$path.pub').readAsStringSync().split(' ').take(2), reason: type);
    }
  }, skip: !keygen);

  test('garbage is unsupported, not a crash', () {
    expect(() => KeyCodec.inspect('not a key'), throwsA(isA<KeyCodecException>()));
  });

  test('the store keeps private keys in secrets and metadata on disk, and refuses duplicates', () async {
    final secrets = MemorySecrets();
    final c = ProviderContainer(overrides: [
      dataDirProvider.overrideWithValue(dir.path),
      secretStoreProvider.overrideWithValue(secrets),
    ]);
    addTearDown(c.dispose);
    final keys = c.read(keysProvider.notifier);

    final made = await keys.generate('laptop');
    expect(secrets.values[made.privateRef], contains('OPENSSH PRIVATE KEY'));
    final onDisk = File('${dir.path}/keys.json').readAsStringSync();
    expect(onDisk, contains(made.fingerprint));
    expect(onDisk, isNot(contains('PRIVATE KEY')));

    final again = await keys.import('copy', secrets.values[made.privateRef]!);
    expect((again as Err).error.code, 'keyDuplicate');

    final path = '${dir.path}/other';
    File(path).writeAsStringSync(KeyCodec.generateEd25519());
    final imported = await keys.import('', path);
    expect(imported, isA<Ok<SshKey>>());
    expect((imported as Ok<SshKey>).value.label, 'ssh-ed25519', reason: 'a blank label falls back to the algorithm');

    await keys.delete(made);
    expect(secrets.values.containsKey(made.privateRef), isFalse);
    expect(c.read(keysProvider).map((k) => k.id), [imported.value.id]);
  });

  test('an encrypted import stays encrypted; its passphrase is kept only when asked', () async {
    if (!keygen) return;
    final secrets = MemorySecrets();
    final c = ProviderContainer(overrides: [
      dataDirProvider.overrideWithValue(dir.path),
      secretStoreProvider.overrideWithValue(secrets),
    ]);
    addTearDown(c.dispose);
    final keys = c.read(keysProvider.notifier);
    final path = '${dir.path}/enc';
    sshKeygen(['-q', '-t', 'ed25519', '-N', 'pw', '-f', path]);

    expect(((await keys.import('k', path)) as Err).error.code, 'keyNeedsPassphrase');
    expect(((await keys.import('k', path, passphrase: const Secret('no'))) as Err).error.code, 'keyWrongPassphrase');
    final key = ((await keys.import('k', path, passphrase: const Secret('pw'))) as Ok<SshKey>).value;
    expect(key.encrypted, isTrue);
    expect(KeyCodec.isEncrypted(secrets.values[key.privateRef]!), isTrue);
    expect(secrets.values.containsKey(key.passphraseRef), isFalse);
  });
}

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/features/connections/api.dart';

class _Once implements ConnectPrompts {
  @override
  Future<TrustChoice> hostKey(HostKeyPrompt prompt) async => TrustChoice.once;
  @override
  Future<SecretAnswer?> secret(SecretRequest request) async => null;
}

class _Save implements ConnectPrompts {
  @override
  Future<TrustChoice> hostKey(HostKeyPrompt prompt) async => TrustChoice.save;
  @override
  Future<SecretAnswer?> secret(SecretRequest request) async => null;
}

void main() {
  test('changed RSA keys cannot be accepted once through a non-dialog caller', () async {
    final dir = await Directory.systemTemp.createTemp('sshairy-trust-');
    addTearDown(() => dir.delete(recursive: true));
    final trust = HostTrustService(dir.path);
    await trust.import({
      'h:22': {'rsa-sha2-512': 'old'},
    });
    expect(await trust.verify('h', 22, 'ssh-rsa', 'old', _Once()), isTrue);
    expect(await trust.verify('h', 22, 'rsa-sha2-256', 'changed', _Once()), isFalse);
    expect(trust.entries['h:22'], {'ssh-rsa': 'old'});
  });

  test('only taking trust away invalidates pooled connections; a first save during a dial does not', () async {
    final dir = await Directory.systemTemp.createTemp('sshairy-trust-');
    addTearDown(() => dir.delete(recursive: true));
    final trust = HostTrustService(dir.path);
    expect(trust.revision, 0);

    expect(await trust.verify('h', 22, 'ssh-ed25519', 'one', _Save()), isTrue);
    expect(trust.entries['h:22'], {'ssh-ed25519': 'one'});
    expect(trust.revision, 0, reason: 'the connection being dialled would otherwise never be reusable');

    await trust.import({
      'other:22': {'ssh-ed25519': 'x'},
    });
    expect(trust.revision, 0);

    expect(await trust.verify('h', 22, 'ssh-ed25519', 'two', _Save()), isTrue);
    expect(trust.entries['h:22'], {'ssh-ed25519': 'two'});
    expect(trust.revision, 1, reason: 'a replaced key is a change of what earlier connections were verified against');

    await trust.forget('other:22');
    expect(trust.revision, 2);
  });
}

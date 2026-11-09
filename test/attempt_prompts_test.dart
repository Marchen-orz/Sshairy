import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/features/connections/adapters/attempt_prompts.dart';
import 'package:sshairy/features/connections/api.dart';
import 'package:sshairy/features/connections/domain/known_keys.dart';
import 'package:sshairy/foundation/cancellation.dart';
import 'package:sshairy/foundation/secret.dart';

class _Prompts implements ConnectPrompts {
  var hostCalls = 0, secretCalls = 0;
  TrustChoice choice = TrustChoice.once;
  Completer<TrustChoice>? pendingHost;
  Completer<SecretAnswer?>? pendingSecret;

  @override
  Future<TrustChoice> hostKey(HostKeyPrompt prompt) async {
    hostCalls++;
    return pendingHost == null ? choice : pendingHost!.future;
  }

  @override
  Future<SecretAnswer?> secret(SecretRequest request) async {
    secretCalls++;
    return pendingSecret?.future;
  }
}

const _key = HostKeyPrompt('h:22', 'ssh-ed25519', 'fingerprint', KeyUnknown({}));

void main() {
  test('detached prompts never call the former UI for trust, password, or challenge', () async {
    final ui = _Prompts();
    final prompts = AttemptPrompts(ui, CancellationToken());
    prompts.detach();
    prompts.detach();
    expect(await prompts.hostKey(_key), TrustChoice.reject);
    for (final kind in SecretKind.values) {
      expect(await prompts.secret(SecretRequest(kind)), isNull);
    }
    expect(ui.hostCalls, 0);
    expect(ui.secretCalls, 0);
  });

  test('an approved once key survives detaching only for its exact endpoint, type, and fingerprint', () async {
    final ui = _Prompts();
    final prompts = AttemptPrompts(ui, CancellationToken());
    expect(await prompts.hostKey(_key), TrustChoice.once);
    prompts.detach();
    expect(await prompts.hostKey(_key), TrustChoice.once);
    for (final prompt in [
      const HostKeyPrompt('other:22', 'ssh-ed25519', 'fingerprint', KeyUnknown({})),
      const HostKeyPrompt('h:23', 'ssh-ed25519', 'fingerprint', KeyUnknown({})),
      const HostKeyPrompt('h:22', 'ssh-rsa', 'fingerprint', KeyUnknown({})),
      const HostKeyPrompt('h:22', 'ssh-ed25519', 'other', KeyUnknown({})),
      const HostKeyPrompt('h:22', 'ssh-ed25519', 'fingerprint', KeyChanged('old')),
    ]) {
      expect(await prompts.hostKey(prompt), TrustChoice.reject);
    }
    expect(ui.hostCalls, 1);
    expect(await prompts.secret(const SecretRequest(SecretKind.password)), isNull);
    expect(ui.secretCalls, 0);
  });

  test('a cancelled attempt rejects even its earlier exact once approval', () async {
    final ui = _Prompts();
    final cancel = CancellationToken();
    final prompts = AttemptPrompts(ui, cancel);
    expect(await prompts.hostKey(_key), TrustChoice.once);
    prompts.detach();
    cancel.cancel();
    expect(await prompts.hostKey(_key), TrustChoice.reject);
    expect(await prompts.secret(const SecretRequest(SecretKind.challenge)), isNull);
    expect(ui.hostCalls, 1);
    expect(ui.secretCalls, 0);
  });

  test('a late UI answer cannot grant trust or return a secret after detaching', () async {
    final ui = _Prompts()
      ..pendingHost = Completer<TrustChoice>()
      ..pendingSecret = Completer<SecretAnswer?>();
    final prompts = AttemptPrompts(ui, CancellationToken());
    final host = prompts.hostKey(_key);
    final secret = prompts.secret(const SecretRequest(SecretKind.password));
    prompts.detach();
    ui.pendingHost!.complete(TrustChoice.once);
    ui.pendingSecret!.complete(SecretAnswer(Secret('test-only')));
    expect(await host, TrustChoice.reject);
    expect(await secret, isNull);
    expect(await prompts.hostKey(_key), TrustChoice.reject);
    expect(ui.hostCalls, 1);
    expect(ui.secretCalls, 1);
  });

  test('host trust still checks saved and once keys after UI detaches and blocks a changed key', () async {
    final dir = await Directory.systemTemp.createTemp('sshairy-attempt-trust-');
    addTearDown(() => dir.delete(recursive: true));
    final trust = HostTrustService(dir.path);
    final ui = _Prompts();
    final prompts = AttemptPrompts(ui, CancellationToken());
    expect(await trust.verify('h', 22, 'ssh-ed25519', 'fingerprint', prompts), isTrue);
    prompts.detach();
    expect(await trust.verify('h', 22, 'ssh-ed25519', 'fingerprint', prompts), isTrue);
    expect(await trust.verify('h', 22, 'ssh-ed25519', 'changed', prompts), isFalse);
    await trust.import({
      'saved:22': {'ssh-ed25519': 'saved-key'},
      'h:22': {'ssh-ed25519': 'old-key'},
    });
    expect(await trust.verify('saved', 22, 'ssh-ed25519', 'saved-key', prompts), isTrue);
    expect(await trust.verify('h', 22, 'ssh-ed25519', 'fingerprint', prompts), isFalse);
    expect(ui.hostCalls, 1);
  });
}

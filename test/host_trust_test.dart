import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/features/connections/api.dart';

class _Once implements ConnectPrompts {
  @override
  Future<TrustChoice> hostKey(HostKeyPrompt prompt) async => TrustChoice.once;
  @override
  Future<SecretAnswer?> secret(SecretRequest request) async => null;
}

void main() {
  test(
    'changed RSA keys cannot be accepted once through a non-dialog caller',
    () async {
      final dir = await Directory.systemTemp.createTemp('sshairy-trust-');
      addTearDown(() => dir.delete(recursive: true));
      final trust = HostTrustService(dir.path);
      await trust.import({
        'h:22': {'rsa-sha2-512': 'old'},
      });
      expect(await trust.verify('h', 22, 'ssh-rsa', 'old', _Once()), isTrue);
      expect(
        await trust.verify('h', 22, 'rsa-sha2-256', 'changed', _Once()),
        isFalse,
      );
      expect(trust.entries['h:22'], {'ssh-rsa': 'old'});
    },
  );
}

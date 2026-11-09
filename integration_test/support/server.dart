// Shared by the real-server integration tests (docs/TESTING.md §2). Credentials come only from the environment
// (SSHAIRY_TEST_TARGET=user@host[:port], SSHAIRY_TEST_PASSWORD) and are never written anywhere.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sshairy/app/composition.dart';
import 'package:sshairy/features/connections/api.dart';
import 'package:sshairy/features/credentials/application/credential_access.dart' show secretStoreProvider;
import 'package:sshairy/features/hosts/api.dart';
import 'package:sshairy/foundation/data_dir.dart';
import 'package:sshairy/foundation/ids.dart';
import 'package:sshairy/foundation/secret.dart';

import 'credentials.dart';

class TestServer {
  TestServer._(this.user, this.address, this.port, this.password);

  factory TestServer.fromEnvironment() {
    final target = Platform.environment['SSHAIRY_TEST_TARGET'];
    final password = Platform.environment['SSHAIRY_TEST_PASSWORD'];
    if (target == null || password == null) {
      throw StateError('Set SSHAIRY_TEST_TARGET and SSHAIRY_TEST_PASSWORD');
    }
    final parsed = parseQuickConnect(target)!;
    return TestServer._(parsed.username, parsed.address, parsed.port, password);
  }

  final String user, address, password;
  final int port;

  /// A host record that logs in the way [policy] says.
  Host host(String id, AuthPolicy policy, {String? label}) => Host(
    id: HostId(id),
    label: label ?? id,
    address: address,
    port: port,
    username: '',
    overrides: ConnectionOverrides(authentication: OverrideValue.value(Authentication.inline(user, policy))),
  );
}

/// Answers what a user would: trusts the key once, gives the password, and hands out passphrases in order.
class ScriptedPrompts implements ConnectPrompts {
  ScriptedPrompts(this.server, {List<String> passphrases = const []}) : _passphrases = [...passphrases];

  final TestServer server;
  final List<String> _passphrases;
  var passwordAsked = 0, passphraseAsked = 0;

  @override
  Future<TrustChoice> hostKey(HostKeyPrompt p) async => TrustChoice.once;

  @override
  Future<SecretAnswer?> secret(SecretRequest request) async {
    switch (request.kind) {
      case SecretKind.password:
        passwordAsked++;
        return SecretAnswer(Secret(server.password));
      case SecretKind.passphrase:
        passphraseAsked++;
        return _passphrases.isEmpty ? null : SecretAnswer(Secret(_passphrases.removeAt(0)));
      case SecretKind.challenge || SecretKind.proxyPassword:
        return null;
    }
  }
}

/// The app's own providers over a throwaway data directory, so a host is saved, resolved and dialled the way
/// the application does it.
ProviderContainer appContainer(Directory dir) => ProviderContainer(
  overrides: [
    dataDirProvider.overrideWithValue(dir.path),
    ...appOverrides(),
    secretStoreProvider.overrideWithValue(EphemeralSecretStore()),
  ],
);

extension ServerCalls on ProviderContainer {
  /// Runs [command] on [host] and returns its output; fails the call on a non-zero exit.
  Future<String> exec(Host host, ConnectPrompts prompts, String command) async {
    final lease = await read(connectionManagerProvider).acquire(host, prompts);
    try {
      final result = await lease.exec(command);
      if (result.exitCode != 0) {
        throw StateError('exit ${result.exitCode}: ${utf8.decode(result.stderr, allowMalformed: true)}');
      }
      return utf8.decode(result.stdout, allowMalformed: true);
    } finally {
      lease.release();
    }
  }
}

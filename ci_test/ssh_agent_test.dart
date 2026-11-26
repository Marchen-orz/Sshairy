import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/features/connections/adapters/ssh_agent.dart';
import 'package:sshairy/features/hosts/api.dart';

Uint8List _string(List<int> bytes) =>
    Uint8List.fromList([...(Uint8List(4)..buffer.asByteData().setUint32(0, bytes.length)), ...bytes]);

Uint8List _blob(String type) => Uint8List.fromList([
  ..._string(utf8.encode(type)),
  ..._string([1, 2, 3]),
]);

Uint8List _answer(List<(Uint8List, String)> keys) => Uint8List.fromList([
  AgentMessage.identitiesAnswer,
  ...(Uint8List(4)..buffer.asByteData().setUint32(0, keys.length)),
  for (final (blob, comment) in keys) ...[..._string(blob), ..._string(utf8.encode(comment))],
]);

void main() {
  test('agent identities sign through the agent, RSA with SHA-256 and a probe first', () async {
    final requests = <Uint8List>[];
    final rsa = _blob('ssh-rsa'), ed = _blob('ssh-ed25519');
    final signature = _string(utf8.encode('sig'));
    final agent = SystemAgent(
      'fake',
      transport: (payload) async {
        requests.add(payload);
        return payload[0] == AgentMessage.requestIdentities
            ? _answer([(rsa, 'laptop'), (ed, 'yubikey')])
            : Uint8List.fromList([AgentMessage.signResponse, ..._string(signature)]);
      },
    );

    final keys = await agent.identities();
    expect([for (final k in keys) k.type], ['rsa-sha2-256', 'ssh-ed25519']);
    expect([for (final k in keys) k.comment], ['laptop', 'yubikey']);
    expect(keys.every((k) => k.shouldProbe), isTrue);
    expect(keys.first.toPublicKey().encode(), rsa);

    final signed = await keys.first.sign(Uint8List.fromList([9, 9]));
    expect(signed.encode(), signature);
    final sign = requests.last;
    expect(sign, signRequest(rsa, Uint8List.fromList([9, 9]), AgentMessage.rsaSha256));
    expect(sign.sublist(sign.length - 4), [0, 0, 0, 2]);

    await keys.last.sign(Uint8List.fromList([1]));
    expect(requests.last.sublist(requests.last.length - 4), [0, 0, 0, 0]);
  });

  test('a refused or truncated answer is an error, not an empty agent', () {
    expect(() => parseIdentities(Uint8List.fromList([AgentMessage.failure])), throwsFormatException);
    expect(() => parseIdentities(Uint8List.fromList([AgentMessage.identitiesAnswer, 0, 0])), throwsFormatException);
    expect(() => parseSignature(Uint8List.fromList([AgentMessage.failure])), throwsFormatException);
  });

  test('the forwarded agent passes listing and signing only', () async {
    final seen = <int>[];
    final forwarded = ForwardedAgent(
      SystemAgent(
        'fake',
        transport: (payload) async {
          seen.add(payload[0]);
          if (payload[0] == AgentMessage.signRequest) throw const SocketException('agent gone');
          return _answer([]);
        },
      ),
    );
    expect(await forwarded.handleRequest(identitiesRequest()), _answer([]));
    // Signing failures, adding a key (17), removing all keys (19) and locking (22) all answer failure.
    for (final type in [AgentMessage.signRequest, 17, 19, 22]) {
      expect(await forwarded.handleRequest(Uint8List.fromList([type, 0])), [AgentMessage.failure]);
    }
    expect(seen, [AgentMessage.requestIdentities, AgentMessage.signRequest]);
    expect(await ForwardedAgent(null).handleRequest(identitiesRequest()), [AgentMessage.failure]);
  });

  test('the agent is found where the platform keeps it', () {
    if (Platform.isWindows) {
      expect(SystemAgent.locate(const {})!.path, r'\\.\pipe\openssh-ssh-agent');
      expect(SystemAgent.locate(const {'SSH_AUTH_SOCK': '/tmp/ssh-x/agent.1'})!.path, r'\\.\pipe\openssh-ssh-agent');
      expect(SystemAgent.locate(const {'SSH_AUTH_SOCK': r'\\.\pipe\other'})!.path, r'\\.\pipe\other');
    } else {
      expect(SystemAgent.locate(const {}), isNull);
      expect(SystemAgent.locate(const {'SSH_AUTH_SOCK': '/tmp/ssh-x/agent.1'})!.path, '/tmp/ssh-x/agent.1');
    }
  });

  test('a missing agent fails the request', () async {
    final path = Platform.isWindows ? r'\\.\pipe\sshairy-test-missing-agent' : '/tmp/sshairy-test-missing-agent';
    await expectLater(SystemAgent(path).identities(), throwsA(anything));
  });

  test('agent login policies: one public key way, then optionally the password', () {
    for (final methods in [
      [AuthKind.agent],
      [AuthKind.agent, AuthKind.password],
    ]) {
      expect(() => AuthPolicy(methods: methods).validate(), returnsNormally);
    }
    for (final methods in [
      [AuthKind.password, AuthKind.agent],
      [AuthKind.key, AuthKind.agent],
    ]) {
      expect(() => AuthPolicy(methods: methods, keyPath: 'k').validate(), throwsArgumentError);
    }
    final forwarded = AuthPolicy.fromJson(
      const AuthPolicy(methods: [AuthKind.agent], forwardAgent: true).toJson().cast(),
    );
    expect(forwarded.usesAgent && forwarded.forwardAgent, isTrue);
    expect(const AuthPolicy().toJson().containsKey('forwardAgent'), isFalse);
  });
}

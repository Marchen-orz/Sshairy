import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/app/ai_backend.dart';
import 'package:sshairy/features/ai/api.dart';
import 'package:sshairy/features/connections/api.dart';
import 'package:sshairy/features/hosts/api.dart';
import 'package:sshairy/foundation/cancellation.dart';
import 'package:sshairy/foundation/ids.dart';

import 'connection_manager_test.dart' show FakeTransport, NoPrompts;

class _Transport extends FakeTransport implements StreamingTransport {
  final probes = <String>[];
  final executions = <String>[];
  var linux = true;
  Object? executeFailure;
  void Function()? onProbe;

  @override
  Future<ExecResult> exec(String command, {int limit = 0, Duration? timeout, CancellationToken? cancel}) async {
    probes.add(command);
    onProbe?.call();
    if (cancel?.isCancelled ?? false) throw const ExecError(ExecFailure.cancelled);
    return ExecResult(Uint8List.fromList(utf8.encode(linux ? 'sshairy-posix-v1' : '')), Uint8List(0), linux ? 0 : 1);
  }

  @override
  Future<int?> execStreaming(
    String command, {
    required void Function(ExecChunk) onOutput,
    Duration? timeout,
    CancellationToken? cancel,
  }) async {
    executions.add(command);
    if (executeFailure case final error?) throw error;
    onOutput(ExecChunk(ExecStream.stdout, Uint8List.fromList(utf8.encode('out'))));
    onOutput(ExecChunk(ExecStream.stderr, Uint8List.fromList(utf8.encode('err'))));
    return null;
  }
}

const _host = Host(id: HostId('host-1'), label: 'web', address: 'example.com', username: 'u');

void main() {
  test('backend projects only saved IDs and labels and refuses missing targets before dial', () async {
    var dials = 0;
    final manager = ConnectionManager((_, _, _) async {
      dials++;
      return _Transport();
    });
    addTearDown(manager.closeAll);
    final backend = SshAgentBackend(
      manager,
      () => [_host, const Host(id: HostId(''), label: 'temp', address: 'tmp', username: 'u')],
    );
    expect(backend.hosts.map((host) => host.id), [_host.id]);
    expect(backend.hosts.single.label, 'web');
    await expectLater(
      backend.prepare(const HostId('missing'), CancellationToken()),
      throwsA(isA<AgentFailure>().having((e) => e.code, 'code', 'hostUnavailable')),
    );
    final cancelled = CancellationToken()..cancel();
    await expectLater(
      backend.prepare(_host.id, cancelled),
      throwsA(isA<AgentFailure>().having((e) => e.code, 'code', 'cancelled')),
    );
    expect(dials, 0);
  });

  test('prepared target binds the real shared lease and streams both outputs without retry', () async {
    final transport = _Transport();
    var dials = 0;
    final manager = ConnectionManager((_, _, _) async {
      dials++;
      return transport;
    });
    addTearDown(manager.closeAll);
    final backend = SshAgentBackend(manager, () => [_host]);
    final shell = await manager.acquire(_host, NoPrompts());
    final first = await backend.prepare(_host.id, CancellationToken());
    final second = await backend.prepare(_host.id, CancellationToken());
    expect(first.identity, second.identity);
    expect(first.display, 'u@example.com:22');
    expect(first.current, isTrue);
    final output = <(bool, String)>[];
    expect(
      await first.execute(
        "sh -c 'printf out'",
        (err, bytes) => output.add((err, utf8.decode(bytes))),
        timeout: const Duration(seconds: 60),
        cancel: CancellationToken(),
      ),
      isNull,
    );
    expect(output, [(false, 'out'), (true, 'err')]);
    expect(transport.probes, hasLength(1));
    expect(await first.supportsPosix(CancellationToken()), isTrue);
    expect(transport.probes, hasLength(1), reason: 'the fixed adapter probe is cached on this prepared identity');
    transport.executeFailure = const ConnectError(ConnectFailure.network);
    await expectLater(
      first.execute('another', (_, _) {}, timeout: const Duration(seconds: 60), cancel: CancellationToken()),
      throwsA(isA<ConnectError>()),
    );
    expect(transport.executions, ["sh -c 'printf out'", 'another']);
    expect(dials, 1, reason: 'execute is never passed to ConnectionManager.open');
    first.release();
    first.release();
    expect(first.current, isFalse);
    expect(second.current, isTrue);
    expect(shell.lost, isFalse, reason: 'releasing agent work leaves other leases connected');
    second.release();
    shell.release();
  });

  test('changed config, deleted host and cancellation prevent execution on a stale target', () async {
    final transport = _Transport();
    var revision = 0;
    var hosts = [_host];
    final manager = ConnectionManager.routed(
      (_, _, _) async => transport,
      (id) => hosts.where((h) => h.id == id).firstOrNull,
      securityRevision: () => [revision],
    );
    addTearDown(manager.closeAll);
    final backend = SshAgentBackend(manager, () => hosts);
    final target = await backend.prepare(_host.id, CancellationToken());
    revision++;
    expect(target.current, isFalse);
    await expectLater(
      target.execute('must not run', (_, _) {}, timeout: const Duration(seconds: 1), cancel: CancellationToken()),
      throwsA(isA<AgentFailure>().having((e) => e.code, 'code', 'scopeChanged')),
    );
    revision--;
    hosts = [];
    expect(target.current, isFalse);
    hosts = [_host];
    final cancel = CancellationToken()..cancel();
    await expectLater(
      target.execute('must not run', (_, _) {}, timeout: const Duration(seconds: 1), cancel: cancel),
      throwsA(isA<AgentFailure>().having((e) => e.code, 'code', 'cancelled')),
    );
    expect(transport.executions, isEmpty);
    target.release();
  });

  test('unsupported system and change during adapter probe never start user command', () async {
    final transport = _Transport()..linux = false;
    var revision = 0;
    final manager = ConnectionManager((_, _, _) async => transport, securityRevision: () => [revision]);
    addTearDown(manager.closeAll);
    final backend = SshAgentBackend(manager, () => [_host]);
    final unsupported = await backend.prepare(_host.id, CancellationToken());
    await expectLater(
      unsupported.execute('must not run', (_, _) {}, timeout: const Duration(seconds: 1), cancel: CancellationToken()),
      throwsA(isA<AgentFailure>().having((e) => e.code, 'code', 'unsupported')),
    );
    unsupported.release();
    transport.linux = true;
    transport.onProbe = () => revision++;
    final stale = await backend.prepare(_host.id, CancellationToken());
    await expectLater(
      stale.execute('must not run', (_, _) {}, timeout: const Duration(seconds: 1), cancel: CancellationToken()),
      throwsA(isA<AgentFailure>().having((e) => e.code, 'code', 'scopeChanged')),
    );
    expect(transport.executions, isEmpty);
    stale.release();
  });

  test('unknown trust or secret challenges require the user connection flow', () async {
    var asksTrust = true;
    final manager = ConnectionManager((_, prompts, _) async {
      if (asksTrust) {
        // The prompt payload belongs to host-trust; this fake never accesses its fields.
        final choice = await prompts.hostKey(_Prompt());
        expect(choice, TrustChoice.reject);
        throw const ConnectError(ConnectFailure.hostKeyRejected);
      }
      final secret = await prompts.secret(const SecretRequest(SecretKind.password));
      expect(secret, isNull);
      throw const ConnectError(ConnectFailure.auth);
    });
    addTearDown(manager.closeAll);
    final backend = SshAgentBackend(manager, () => [_host]);
    await expectLater(
      backend.prepare(_host.id, CancellationToken()),
      throwsA(isA<AgentFailure>().having((e) => e.code, 'code', 'hostTrustRequired')),
    );
    asksTrust = false;
    await expectLater(
      backend.prepare(_host.id, CancellationToken()),
      throwsA(isA<AgentFailure>().having((e) => e.code, 'code', 'authenticationRequired')),
    );
  });
}

class _Prompt implements HostKeyPrompt {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

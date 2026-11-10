import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/features/connections/api.dart';
import 'package:sshairy/features/hosts/api.dart';
import 'package:sshairy/foundation/cancellation.dart';
import 'package:sshairy/foundation/ids.dart';

import 'connection_manager_test.dart' show FakeTransport, NoPrompts;

Host _host(String id, {String address = 'example.com', String username = 'u', String? jump}) => Host(
  id: HostId(id),
  label: id,
  address: address,
  username: username,
  jumpHostId: jump == null ? null : HostId(jump),
);

class _Streaming extends FakeTransport implements StreamingTransport {
  var starts = 0;
  Object? failure;

  @override
  Future<int?> execStreaming(
    String command, {
    required void Function(ExecChunk) onOutput,
    Duration? timeout,
    CancellationToken? cancel,
  }) async {
    starts++;
    if (failure case final error?) throw error;
    onOutput(ExecChunk(ExecStream.stdout, Uint8List.fromList(utf8.encode('live'))));
    return null;
  }
}

void main() {
  test('shared leases bind one actual transport and a redial gets a new identity', () async {
    final transports = <FakeTransport>[];
    final manager = ConnectionManager((_, _, _) async {
      final transport = FakeTransport();
      transports.add(transport);
      return transport;
    });
    addTearDown(manager.closeAll);
    final host = _host('target');
    final first = await manager.acquire(host, NoPrompts());
    final second = await manager.acquire(host, NoPrompts());
    expect(first.identity, same(second.identity));
    expect(first.identity.hostId, host.id);
    expect(first.identity.address, host.address);
    expect(first.identity.username, host.username);
    expect(first.identity.port, host.port);
    expect(first.isCurrent, isTrue);
    expect(second.isCurrent, isTrue);
    final identity = first.identity;
    first.release();
    expect(first.isCurrent, isFalse);
    expect(second.isCurrent, isTrue);
    transports.first.close();
    expect(second.isCurrent, isFalse);
    final fresh = await manager.acquire(host, NoPrompts());
    expect(fresh.identity.transportId, isNot(identity.transportId));
    expect(fresh.identity.configKey, identity.configKey);
    expect(fresh.identity, isNot(identity));
    expect(fresh.identity.toString(), isNot(contains(host.address)));
    second.release();
    fresh.release();
  });

  test('target, intermediate route, security revision and deletion invalidate the held lease', () async {
    var revision = 0;
    final hosts = <HostId, Host>{
      const HostId('target'): _host('target', jump: 'jump'),
      const HostId('jump'): _host('jump'),
    };
    final manager = ConnectionManager.routed(
      (_, _, _) async => FakeTransport(),
      (id) => hosts[id],
      securityRevision: () => [revision],
    );
    addTearDown(manager.closeAll);
    Future<TransportLease> acquire() => manager.acquire(hosts[const HostId('target')]!, NoPrompts());

    final original = await acquire();
    hosts[const HostId('target')] = _host('target', username: 'other', jump: 'jump');
    expect(original.isCurrent, isFalse);
    expect(original.lost, isFalse, reason: 'the original terminal is allowed to keep its channel');
    final targetEdit = await acquire();
    expect(targetEdit.isCurrent, isTrue);
    expect(targetEdit.identity.configKey, isNot(original.identity.configKey));
    hosts[const HostId('jump')] = _host('jump', address: 'new-jump.example');
    expect(targetEdit.isCurrent, isFalse);
    final routeEdit = await acquire();
    expect(routeEdit.isCurrent, isTrue);
    revision++;
    expect(routeEdit.isCurrent, isFalse);
    final securityEdit = await acquire();
    expect(securityEdit.isCurrent, isTrue);
    hosts.remove(const HostId('target'));
    expect(securityEdit.isCurrent, isFalse, reason: 'a deleted host cannot retain execution authority');
    for (final lease in [original, targetEdit, routeEdit, securityEdit]) {
      lease.release();
    }
  });

  test('an edit made while dialling is visible before the lease can be approved', () async {
    var host = _host('target');
    final opening = Completer<FakeTransport>();
    final manager = ConnectionManager.routed((_, _, _) => opening.future, (_) => host);
    addTearDown(manager.closeAll);
    final pending = manager.acquire(host, NoPrompts());
    host = _host('target', address: 'changed.example');
    opening.complete(FakeTransport());
    final lease = await pending;
    expect(lease.identity.address, 'example.com');
    expect(lease.isCurrent, isFalse);
    lease.release();
  });

  test('acquireRoute owns an immutable route snapshot and closed manager invalidates it', () async {
    final route = [_host('target')];
    final manager = ConnectionManager((_, _, _) async => FakeTransport());
    final lease = await manager.acquireRoute(route, NoPrompts());
    route[0] = _host('changed');
    expect(lease.host.id, const HostId('target'));
    expect(lease.isCurrent, isTrue);
    manager.closeAll();
    expect(lease.isCurrent, isFalse);
    lease.release();
  });

  test('streaming exec uses its acquired transport once and never redials a failed command', () async {
    var dials = 0;
    final transport = _Streaming();
    final manager = ConnectionManager((_, _, _) async {
      dials++;
      return transport;
    });
    addTearDown(manager.closeAll);
    final keep = await manager.acquire(_host('target'), NoPrompts());
    final lease = await manager.acquire(_host('target'), NoPrompts(), purpose: LeasePurpose.exec);
    expect(lease.reused, isTrue);
    final output = <ExecChunk>[];
    expect(await lease.execStreaming('example', onOutput: output.add), isNull);
    expect(utf8.decode(output.single.bytes), 'live');
    transport.failure = StateError('request outcome unknown');
    await expectLater(lease.execStreaming('another', onOutput: output.add), throwsStateError);
    expect(transport.starts, 2);
    expect(dials, 1);
    expect(keep.lost, isFalse);
    lease.release();
    keep.release();
  });

  test('a transport without streaming support rejects without running one-shot exec', () async {
    final manager = ConnectionManager((_, _, _) async => FakeTransport());
    addTearDown(manager.closeAll);
    final lease = await manager.acquire(_host('target'), NoPrompts());
    expect(() => lease.execStreaming('example', onOutput: (_) {}), throwsUnsupportedError);
    lease.release();
    expect(() => lease.execStreaming('example', onOutput: (_) {}), throwsStateError);
  });
}

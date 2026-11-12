import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/features/connections/api.dart';
import 'package:sshairy/features/files/application/file_systems.dart';
import 'package:sshairy/features/hosts/api.dart';
import 'package:sshairy/foundation/cancellation.dart';
import 'package:sshairy/foundation/file_system.dart';
import 'package:sshairy/foundation/ids.dart';

import 'connection_manager_test.dart' show FakeTransport;

class _Files implements FileSystem {
  var closed = false;
  @override
  Future<void> close() async => closed = true;
  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError('unexpected ${invocation.memberName}');
}

class _Transport extends FakeTransport {
  _Transport(this.address);
  final String address;
  final files = <_Files>[];
  Completer<void>? opening;
  @override
  Future<FileSystem> openFiles() async {
    await opening?.future;
    final fs = _Files();
    files.add(fs);
    return fs;
  }
}

void main() {
  const original = Host(id: HostId('pool'), label: 'fixture', address: 'first.invalid', username: 'fixture');
  const edited = Host(id: HostId('pool'), label: 'fixture', address: 'second.invalid', username: 'fixture');

  test('new file operations use the edited route while active old handles remain usable', () async {
    var current = original;
    final transports = <_Transport>[];
    final connections = ConnectionManager.routed((route, _, _) async {
      final transport = _Transport(route.single.address);
      transports.add(transport);
      return transport;
    }, (_) => current);
    final pool = FileSystems(connections, (_) => current);
    addTearDown(() {
      pool.closeAll();
      connections.closeAll();
    });
    final first = await pool.acquire(original.id, const NoPrompts());
    final shared = await pool.acquire(original.id, const NoPrompts());
    expect(shared.fs, same(first.fs));
    current = edited;
    final next = await pool.acquire(original.id, const NoPrompts());
    expect(transports.map((transport) => transport.address), ['first.invalid', 'second.invalid']);
    expect(next.fs, isNot(same(first.fs)));
    expect((first.fs as _Files).closed, isFalse);
    expect(transports.first.isClosed, isFalse);
    first.release();
    await pumpEventQueue();
    expect((shared.fs as _Files).closed, isFalse);
    shared.release();
    await pumpEventQueue();
    expect((shared.fs as _Files).closed, isTrue);
    expect((next.fs as _Files).closed, isFalse);
    next.release();
  });

  test('a security revision prevents reuse without closing an active old SFTP channel', () async {
    var revision = 0;
    final transports = <_Transport>[];
    final connections = ConnectionManager((host, _, _) async {
      final transport = _Transport(host.address);
      transports.add(transport);
      return transport;
    }, securityRevision: () => [revision]);
    final pool = FileSystems(connections, (_) => original);
    addTearDown(() {
      pool.closeAll();
      connections.closeAll();
    });
    final first = await pool.acquire(original.id, const NoPrompts());
    revision++;
    final next = await pool.acquire(original.id, const NoPrompts());
    expect(transports, hasLength(2));
    expect(next.fs, isNot(same(first.fs)));
    expect((first.fs as _Files).closed, isFalse);
    first.release();
    next.release();
  });

  test('a cancelled acquire releases only its waiter and late unowned channels close', () async {
    final opening = Completer<void>();
    final transport = _Transport(original.address)..opening = opening;
    final connections = ConnectionManager((_, _, _) async => transport);
    final pool = FileSystems(connections, (_) => original);
    addTearDown(() {
      pool.closeAll();
      connections.closeAll();
    });
    final cancel = CancellationToken();
    final acquiring = pool.acquire(original.id, const NoPrompts(), cancel: cancel);
    await pumpEventQueue();
    final stopped = expectLater(acquiring, throwsA(isA<FsError>().having((e) => e.detail, 'detail', 'cancelled')));
    cancel.cancel();
    await stopped;
    expect(transport.isClosed, isFalse);
    opening.complete();
    await pumpEventQueue();
    expect(transport.files.single.closed, isTrue);
  });

  test('a cancelled waiter does not close a channel another waiter still owns', () async {
    final opening = Completer<void>();
    final transport = _Transport(original.address)..opening = opening;
    final connections = ConnectionManager((_, _, _) async => transport);
    final pool = FileSystems(connections, (_) => original);
    addTearDown(() {
      pool.closeAll();
      connections.closeAll();
    });
    final cancel = CancellationToken();
    final first = pool.acquire(original.id, const NoPrompts(), cancel: cancel);
    final second = pool.acquire(original.id, const NoPrompts());
    await pumpEventQueue();
    final stopped = expectLater(first, throwsA(isA<FsError>()));
    cancel.cancel();
    await stopped;
    opening.complete();
    final handle = await second;
    expect(transport.files.single.closed, isFalse);
    handle.release();
    await pumpEventQueue();
    expect(transport.files.single.closed, isTrue);
  });

  test('a channel opened after a route edit is retired and the acquire returns the current host', () async {
    var current = original;
    final opening = Completer<void>();
    final transports = <_Transport>[];
    final connections = ConnectionManager.routed((route, _, _) async {
      final transport = _Transport(route.single.address);
      if (transports.isEmpty) transport.opening = opening;
      transports.add(transport);
      return transport;
    }, (_) => current);
    final pool = FileSystems(connections, (_) => current);
    addTearDown(() {
      pool.closeAll();
      connections.closeAll();
    });
    final acquiring = pool.acquire(original.id, const NoPrompts());
    await pumpEventQueue();
    current = edited;
    opening.complete();
    final handle = await acquiring;
    await pumpEventQueue();
    expect(transports.map((transport) => transport.address), ['first.invalid', 'second.invalid']);
    expect(transports.first.files.single.closed, isTrue);
    expect(handle.fs, same(transports.last.files.single));
    expect(transports.last.files.single.closed, isFalse);
    handle.release();
  });
}

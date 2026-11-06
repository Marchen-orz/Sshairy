import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/features/connections/api.dart';
import 'package:sshairy/features/hosts/api.dart';
import 'package:sshairy/features/terminal/api.dart';
import 'package:sshairy/foundation/ids.dart';

import 'connection_manager_test.dart' show FakeTransport, NoPrompts;

class _Shell implements ShellChannel {
  final ended = Completer<void>();
  final writes = <String>[];
  @override
  Stream<Uint8List> get stdout => const Stream.empty();
  @override
  Stream<Uint8List> get stderr => const Stream.empty();
  @override
  Future<void> get done => ended.future;
  @override
  void write(Uint8List data) => writes.add(utf8.decode(data));
  @override
  void resize(int cols, int rows) {}
  @override
  void close() {
    if (!ended.isCompleted) ended.complete();
  }
}

class _Transport extends FakeTransport {
  final opened = <_Shell>[];
  @override
  Future<ShellChannel> openShell({required int cols, required int rows}) async {
    final shell = _Shell();
    opened.add(shell);
    return shell;
  }
}

void main() {
  late _Transport transport;
  late ConnectionManager manager;
  late TerminalSession session;
  Future<void> connected() async {
    unawaited(session.connect(NoPrompts()));
    await pumpEventQueue();
    expect(session.canInsert, isTrue);
  }

  setUp(() {
    transport = _Transport();
    manager = ConnectionManager((_, _, _) async => transport);
    session = TerminalSession(
      const SessionId('s'),
      const Host(id: HostId('h'), label: 'host', address: 'h', username: 'u'),
      manager,
    );
  });
  tearDown(() async {
    session.close();
    manager.closeAll();
    await pumpEventQueue();
  });

  test('insert leaves Enter to user; run sends Enter only after approval', () async {
    await connected();
    final shell = transport.opened.single;
    expect(await session.insert('echo test'), InsertResult.sent);
    expect(shell.writes.join(), 'echo test');
    shell.writes.clear();
    expect(await session.insert('echo denied', run: true), InsertResult.rejected);
    expect(shell.writes, isEmpty);
    expect(await session.insert('echo run', run: true, confirm: (_) async => true), InsertResult.sent);
    expect(shell.writes.join(), 'echo run\r');
  });

  test('approval for old shell cannot send into reconnected shell', () async {
    await connected();
    final old = transport.opened.single;
    final gate = Completer<bool>();
    final pending = session.insert('echo stale', run: true, confirm: (_) => gate.future);
    old.close();
    await pumpEventQueue();
    await connected();
    gate.complete(true);
    expect(await pending, InsertResult.stale);
    expect(old.writes, isEmpty);
    expect(transport.opened.last.writes, isEmpty);
  });

  test('closed or ended shell rejects pending approval', () async {
    await connected();
    final shell = transport.opened.single;
    final gate = Completer<bool>();
    final pending = session.insert('echo stale', run: true, confirm: (_) => gate.future);
    shell.close();
    await Future<void>.delayed(Duration.zero);
    expect(session.canInsert, isFalse);
    gate.complete(true);
    expect(await pending, InsertResult.stale);
    expect(shell.writes, isEmpty);
  });
}

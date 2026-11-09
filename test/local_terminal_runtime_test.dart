import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/features/terminal/api.dart';
import 'package:sshairy/features/workspace/api.dart';
import 'package:sshairy/foundation/cancellation.dart';
import 'package:sshairy/foundation/data_dir.dart';
import 'package:sshairy/foundation/ids.dart';

const _local = LocalShell(kind: LocalShellKind.cmd, executable: r'C:\Windows\System32\cmd.exe');

class _Pty implements LocalPty {
  final bytes = StreamController<Uint8List>();
  final ended = Completer<int>();
  final writes = <String>[];
  @override
  Stream<Uint8List> get output => bytes.stream;
  @override
  Future<int> get exitCode => ended.future;
  @override
  void write(Uint8List data) => writes.add(utf8.decode(data));
  @override
  void resize(int cols, int rows) {}
  @override
  void close() {
    if (ended.isCompleted) return;
    bytes.close();
    ended.complete(0);
  }
}

class _Factory implements LocalPtyFactory {
  final opened = <_Pty>[];
  Completer<LocalPty>? gate;
  @override
  Future<LocalPty> start(LocalShell shell, {required int cols, required int rows, CancellationToken? cancel}) async {
    if (gate case final pending?) return pending.future;
    final pty = _Pty();
    opened.add(pty);
    return pty;
  }
}

void main() {
  test('local split, duplicate and layout restore keep typed targets without starting shells', () async {
    final dir = await Directory.systemTemp.createTemp('sshairy-local-layout-');
    final factory = _Factory();
    ProviderContainer container() => ProviderContainer(
      overrides: [dataDirProvider.overrideWithValue(dir.path), localPtyProvider.overrideWithValue(factory)],
    );
    final first = container();
    try {
      final ws = first.read(workspaceProvider.notifier);
      final id = ws.openLocal(_local);
      expect(ws.split(SplitAxis.horizontal), isTrue);
      expect(ws.duplicate(id), isNotNull);
      expect(
        first.read(terminalSessionsProvider).values.every((s) => s.target is LocalTerminalTarget && s.sshHost == null),
        isTrue,
      );
      await ws.saved;
      final json = jsonDecode(await File('${dir.path}/workspace.json').readAsString()) as Map;
      expect(json['schemaVersion'], 2);
      expect(json.toString(), isNot(contains('environment')));
      first.dispose();
      final second = container();
      try {
        final restored = second.read(workspaceProvider);
        await pumpEventQueue();
        expect(restored.tabs, hasLength(2));
        final sessions = second.read(terminalSessionsProvider).values;
        expect(sessions, hasLength(3));
        expect(
          sessions.every((s) => s.localShell == _local && !s.autoConnect && s.status == SessionStatus.idle),
          isTrue,
        );
        expect(factory.opened, isEmpty);
        await second.read(terminalSessionsProvider.notifier).shutdown();
      } finally {
        second.dispose();
      }
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('local exit changes generation and stale approvals cannot send into a restarted PTY', () async {
    final factory = _Factory();
    final session = TerminalSession.local(const SessionId('local'), _local, factory);
    unawaited(session.connect());
    await pumpEventQueue();
    expect(session.canInsert, isTrue);
    final first = factory.opened.single;
    final generation = session.shellGeneration;
    final approval = Completer<bool>();
    final pending = session.insert('echo old', run: true, confirm: (_) => approval.future);
    first.close();
    await pumpEventQueue();
    expect(session.canInsert, isFalse);
    expect(session.shellGeneration, greaterThan(generation));
    unawaited(session.connect());
    await pumpEventQueue();
    approval.complete(true);
    expect(await pending, InsertResult.stale);
    expect(factory.opened.last.writes, isEmpty);
    session.multilineDraft = 'private draft';
    session.close();
    await session.stopped;
    expect(session.multilineDraft, isEmpty);
    expect(factory.opened.every((p) => p.ended.isCompleted), isTrue);
  });

  test('repeated connect preserves the running lifetime until close has finished', () async {
    final factory = _Factory();
    final session = TerminalSession.local(const SessionId('local'), _local, factory);
    unawaited(session.connect());
    await pumpEventQueue();
    var finished = false;
    final repeated = session.connect().then((_) => finished = true);
    await pumpEventQueue();
    expect(factory.opened, hasLength(1));
    expect(finished, isFalse);
    session.close();
    await repeated;
    await session.stopped;
    expect(finished, isTrue);
    expect(factory.opened.single.ended.isCompleted, isTrue);
  });

  test('closing while local start is pending disposes its late PTY', () async {
    final factory = _Factory()..gate = Completer<LocalPty>();
    final session = TerminalSession.local(const SessionId('local'), _local, factory);
    final connecting = session.connect();
    session.close();
    final late = _Pty();
    factory.gate!.complete(late);
    await connecting;
    expect(late.ended.isCompleted, isTrue);
    expect(late.writes, isEmpty);
  });

  test('only conservative local default prompts expose command drafts', () {
    expect(visibleLocalShellCommand(r'C:\Users\me>echo hi', '', powershell: false, bash: false), 'echo hi');
    expect(visibleLocalShellCommand(r'PS C:\Users\me> Get-Item .', '', powershell: true, bash: false), 'Get-Item .');
    expect(visibleLocalShellCommand(r'$ echo hi', '', powershell: false, bash: true), 'echo hi');
    expect(visibleLocalShellCommand('Password: ', '', powershell: true, bash: false), isNull);
  });
}

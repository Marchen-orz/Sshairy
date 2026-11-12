import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/app/ai_terminal_history.dart';
import 'package:sshairy/features/connections/api.dart';
import 'package:sshairy/features/hosts/api.dart';
import 'package:sshairy/features/terminal/api.dart';
import 'package:sshairy/features/terminal/adapters/completion_specs.dart';
import 'package:sshairy/features/workspace/api.dart';
import 'package:sshairy/features/workspace/domain/layout.dart' show Layout;
import 'package:sshairy/foundation/cancellation.dart';
import 'package:sshairy/foundation/ids.dart';

import 'connection_manager_test.dart' show FakeTransport, NoPrompts;

class _Assets extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async => ByteData.sublistView(Uint8List.fromList(utf8.encode('{"commands":{}}')));
}

class _Shell implements ShellChannel {
  final output = StreamController<Uint8List>();
  final ended = Completer<void>();
  final writes = <String>[];
  void echo(String text) => output.add(Uint8List.fromList(utf8.encode(text)));
  @override
  Stream<Uint8List> get stdout => output.stream;
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
    if (ended.isCompleted) return;
    output.close();
    ended.complete();
  }
}

class _Transport extends FakeTransport {
  final channels = <_Shell>[];
  @override
  Future<ShellChannel> openShell({
    required int cols,
    required int rows,
    Map<String, String> environment = const {},
  }) async {
    final shell = _Shell();
    channels.add(shell);
    return shell;
  }
}

class _Pty implements LocalPty {
  final outputBytes = StreamController<Uint8List>();
  final ended = Completer<int>();
  final writes = <String>[];
  void echo(String text) => outputBytes.add(Uint8List.fromList(utf8.encode(text)));
  @override
  Stream<Uint8List> get output => outputBytes.stream;
  @override
  Future<int> get exitCode => ended.future;
  @override
  void write(Uint8List data) => writes.add(utf8.decode(data));
  @override
  void resize(int cols, int rows) {}
  @override
  void close() {
    if (ended.isCompleted) return;
    outputBytes.close();
    ended.complete(0);
  }
}

class _Factory implements LocalPtyFactory {
  final pty = _Pty();
  @override
  Future<LocalPty> start(LocalShell shell, {required int cols, required int rows, CancellationToken? cancel}) async =>
      pty;
}

Future<void> _feed(WidgetTester tester, void Function(String) echo, String text) async {
  echo(text);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
  await tester.pump();
  await tester.pump();
}

void main() {
  late _Transport transport;
  late ConnectionManager manager;
  late TerminalSession session;

  Future<_Shell> connect(WidgetTester tester) async {
    unawaited(session.connect(NoPrompts()));
    await tester.pump();
    return transport.channels.last;
  }

  setUp(() {
    transport = _Transport();
    manager = ConnectionManager((_, _, _) async => transport, park: const Duration(minutes: 1));
    session = TerminalSession(
      const SessionId('session'),
      const Host(id: HostId('host'), label: 'private alias', address: 'example.com', username: 'account'),
      manager,
      completionSpecs: CompletionSpecs(bundle: _Assets()),
    );
  });

  tearDown(() {
    session.close();
    manager.closeAll();
  });

  test('AI command validation rejects execution controls and enforces UTF-16 and UTF-8 limits', () {
    expect(validTerminalAiCommand('printf hello'), isTrue);
    expect(validTerminalAiCommand('echo 中文'), isTrue);
    for (final text in [
      '',
      ' ',
      'echo hi\nnext',
      'echo hi\r',
      '\x1b[31m',
      'echo \u2028next',
      'echo \u202eabc',
      '\ud800',
    ]) {
      expect(validTerminalAiCommand(text), isFalse, reason: text);
    }
    expect(validTerminalAiCommand('a' * 2048), isTrue);
    expect(validTerminalAiCommand('a' * 2049), isFalse);
    expect(validTerminalAiCommand('中' * 1365), isTrue);
    expect(validTerminalAiCommand('中' * 1366), isFalse);
  });

  testWidgets('context uses a target projection and excludes unknown or hidden input', (tester) async {
    expect(session.readAiContext().prompt, TerminalAiPrompt.unavailable);
    final shell = await connect(tester);
    await _feed(tester, shell.echo, 'Password: ');
    final hidden = session.readAiContext();
    expect(hidden.prompt, TerminalAiPrompt.unknown);
    expect(hidden.ready, isFalse);
    expect(hidden.draft, isNull);
    expect(session.readAiSnapshot(hidden), isNull);
    await _feed(tester, shell.echo, '\r\nu@box:~\$ git st');
    final context = session.readAiContext();
    expect(context.sessionId, const SessionId('session'));
    expect((context.target as SshTerminalAiTarget).hostId, const HostId('host'));
    expect(context.prompt, TerminalAiPrompt.recognized);
    expect(context.draft, 'git st');
    expect(context.directory, isNull);
    expect(context.ready, isTrue);
    session.close();
    manager.closeAll();
    await tester.pump();
  });

  testWidgets('a cursor inside a wide character cannot be treated as an editable line end', (tester) async {
    final shell = await connect(tester);
    await _feed(tester, shell.echo, 'u@box:~\$ 查看内存');
    final expected = session.readAiContext();
    expect(expected.ready, isTrue);
    await _feed(tester, shell.echo, '\x1b[D');
    expect(session.readAiContext().ready, isFalse);
    expect(await session.acceptAiDraft(expected, 'free -h'), InsertResult.stale);
    expect(shell.writes, isEmpty);
    await _feed(tester, shell.echo, '\x1b[C');
    expect(session.readAiContext().draft, '查看内存');
    expect(session.readAiContext().ready, isTrue);
  });

  testWidgets('complete generated draft inserts into an exact empty prompt and sends no Enter', (tester) async {
    final shell = await connect(tester);
    await _feed(tester, shell.echo, 'u@box:~\$ ');
    final empty = session.readAiContext();
    expect(await session.acceptAiDraft(empty, 'printf hello'), InsertResult.sent);
    expect(shell.writes, ['printf hello']);
    expect(await session.acceptAiDraft(empty, 'printf again'), InsertResult.stale);
    expect(shell.writes, ['printf hello']);
    session.close();
    manager.closeAll();
    await tester.pump();
  });

  for (final original in ['show disk usage', '请查看磁盘', 'echo café😀']) {
    testWidgets('full command replaces $original only after an empty echo and sends no Enter', (tester) async {
      final shell = await connect(tester);
      await _feed(tester, shell.echo, 'u@box:~\$ $original');
      final work = session.acceptAiDraft(session.readAiContext(), 'df -h');
      await tester.pump();
      expect(shell.writes, List.filled(original.runes.length, '\x7f'));
      await _feed(tester, shell.echo, '\r\x1b[2Ku@box:~\$ ');
      expect(await work, InsertResult.sent);
      expect(shell.writes.last, 'df -h');
      expect(shell.writes.join(), isNot(contains('\r')));
      expect(shell.writes.join(), isNot(contains('\n')));
    });
  }

  testWidgets('replacement preserves the terminal erase mode and bracketed paste', (tester) async {
    final shell = await connect(tester);
    await _feed(tester, shell.echo, '\x1b[?67h\x1b[?2004hu@box:~\$ old');
    final work = session.acceptAiDraft(session.readAiContext(), 'df -h');
    await tester.pump();
    expect(shell.writes, ['\b', '\b', '\b']);
    await _feed(tester, shell.echo, '\r\x1b[2Ku@box:~\$ ');
    expect(await work, InsertResult.sent);
    expect(shell.writes.last, '\x1b[200~df -h\x1b[201~');
  });

  testWidgets('new input during replacement cannot receive the generated command', (tester) async {
    final shell = await connect(tester);
    await _feed(tester, shell.echo, 'u@box:~\$ old');
    final work = session.acceptAiDraft(session.readAiContext(), 'df -h');
    await tester.pump();
    await session.insert('x');
    await _feed(tester, shell.echo, '\r\x1b[2Ku@box:~\$ ');
    expect(await work, InsertResult.stale);
    expect(shell.writes, ['\x7f', '\x7f', '\x7f', 'x']);
  });

  testWidgets('cancelled replacement never pastes after a late empty echo', (tester) async {
    final shell = await connect(tester);
    await _feed(tester, shell.echo, 'u@box:~\$ old');
    final cancel = CancellationToken();
    final work = session.acceptAiDraft(session.readAiContext(), 'df -h', cancel: cancel);
    cancel.cancel();
    await tester.pump();
    expect(await work, InsertResult.cancelled);
    await _feed(tester, shell.echo, '\r\x1b[2Ku@box:~\$ ');
    expect(shell.writes, ['\x7f', '\x7f', '\x7f']);
  });

  testWidgets('history changes during replacement prevent a late paste into the emptied line', (tester) async {
    final shell = await connect(tester);
    await _feed(tester, shell.echo, 'u@box:~\$ old');
    final expected = session.readAiContext();
    final work = session.acceptAiDraft(expected, 'df -h');
    await tester.pump();
    session.clearCommandHistory();
    await _feed(tester, shell.echo, '\r\x1b[2Ku@box:~\$ ');
    expect(await work, InsertResult.stale);
    expect(shell.writes, ['\x7f', '\x7f', '\x7f']);
    expect(await session.acceptAiDraft(expected, 'pwd'), InsertResult.stale);
  });

  testWidgets('replacement rechecks caller authorization before the final paste', (tester) async {
    final shell = await connect(tester);
    await _feed(tester, shell.echo, 'u@box:~\$ old');
    var current = true;
    final work = session.acceptAiDraft(session.readAiContext(), 'df -h', isCurrent: () => current);
    current = false;
    await _feed(tester, shell.echo, '\r\x1b[2Ku@box:~\$ ');
    expect(await work, InsertResult.cancelled);
    expect(shell.writes, ['\x7f', '\x7f', '\x7f']);
  });

  testWidgets('a new prompt during replacement cannot receive the generated command', (tester) async {
    final shell = await connect(tester);
    await _feed(tester, shell.echo, 'u@box:~\$ old');
    final work = session.acceptAiDraft(session.readAiContext(), 'df -h');
    await _feed(tester, shell.echo, '\r\nbackground output\r\nu@box:~\$ ');
    expect(await work, InsertResult.stale);
    expect(shell.writes, ['\x7f', '\x7f', '\x7f']);
  });

  testWidgets('replacement times out without a confirmed empty prompt', (tester) async {
    final shell = await connect(tester);
    await _feed(tester, shell.echo, 'u@box:~\$ old');
    final work = session.acceptAiDraft(session.readAiContext(), 'df -h');
    await tester.pump(const Duration(seconds: 3));
    expect(await work, InsertResult.rejected);
    expect(shell.writes, ['\x7f', '\x7f', '\x7f']);
  });

  testWidgets('closing the shell cancels a replacement waiting for echo', (tester) async {
    final shell = await connect(tester);
    await _feed(tester, shell.echo, 'u@box:~\$ old');
    final work = session.acceptAiDraft(session.readAiContext(), 'df -h');
    session.close();
    manager.closeAll();
    await tester.pump();
    expect(await work, InsertResult.cancelled);
    expect(shell.writes, ['\x7f', '\x7f', '\x7f']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('suffix accepts only the captured echoed prefix and rejects a changed draft', (tester) async {
    final shell = await connect(tester);
    await _feed(tester, shell.echo, 'u@box:~\$ git st');
    final original = session.readAiContext();
    expect(await session.acceptAiDraft(original, 'atus', suffix: true), InsertResult.sent);
    expect(shell.writes, ['atus']);
    await _feed(tester, shell.echo, 'atus');
    final edited = session.readAiContext();
    await _feed(tester, shell.echo, ' --short');
    expect(await session.acceptAiDraft(edited, ' --branch', suffix: true), InsertResult.stale);
    expect(await session.acceptAiDraft(original, '\nwhoami', suffix: true), InsertResult.rejected);
    expect(shell.writes, ['atus']);
    session.close();
    manager.closeAll();
    await tester.pump();
  });

  testWidgets('directory changes and other session contexts cannot authorize a draft', (tester) async {
    final shell = await connect(tester);
    await _feed(tester, shell.echo, '\x1b]7;file://box/first\x07u@box:~\$ ');
    final old = session.readAiContext();
    expect(old.directory, '/first');
    await _feed(tester, shell.echo, '\x1b]7;file://box/second\x07');
    expect(session.readAiContext().directory, '/second');
    expect(await session.acceptAiDraft(old, 'pwd'), InsertResult.stale);
    final current = session.readAiContext();
    final foreign = TerminalAiContext(
      sessionId: const SessionId('other'),
      target: current.target,
      generation: current.generation,
      revision: current.revision,
      prompt: current.prompt,
      draft: current.draft,
      directory: current.directory,
    );
    expect(await session.acceptAiDraft(foreign, 'pwd'), InsertResult.stale);
    expect(shell.writes, isEmpty);
    session.close();
    manager.closeAll();
    await tester.pump();
  });

  testWidgets('alternate screen and submitted commands disable the AI input port', (tester) async {
    final shell = await connect(tester);
    await _feed(tester, shell.echo, 'u@box:~\$ ');
    final initial = session.readAiContext();
    await _feed(tester, shell.echo, '\x1b[?1049hu@box:~\$ ');
    expect(session.readAiContext().ready, isFalse);
    expect(await session.acceptAiDraft(initial, 'pwd'), InsertResult.stale);
    await _feed(tester, shell.echo, '\x1b[?1049l\r\nu@box:~\$ ');
    final beforeEnter = session.readAiContext();
    expect(beforeEnter.ready, isTrue);
    session.commandSubmitted();
    expect(session.readAiContext().ready, isFalse);
    expect(await session.acceptAiDraft(beforeEnter, 'pwd'), InsertResult.stale);
    expect(shell.writes, isEmpty);
    session.close();
    manager.closeAll();
    await tester.pump();
  });

  testWidgets('history reads completed records while running and never include an unsubmitted draft', (tester) async {
    final shell = await connect(tester);
    await _feed(tester, shell.echo, '\x1b]7;file://box/work\x07u@box:~\$ printf value');
    session.commandSubmitted();
    final pending = session.historySession!;
    await _feed(tester, shell.echo, '\r\nfirst\r\nu@box:~\$ ');
    expect(session.readHistory(pending), isNull, reason: 'completing a result changes its history revision');
    final completed = session.historySession!;
    await _feed(tester, shell.echo, 'draft-only-text');
    final snapshot = session.readHistory(completed)!;
    expect(snapshot.directory, '/work');
    expect(snapshot.prompt, TerminalAiPrompt.recognized);
    expect(snapshot.history.single.text, 'printf value');
    expect(snapshot.history.single.output.trim(), 'first');
    expect(jsonEncode(snapshot.history.map(terminalAiHistoryData).toList()), isNot(contains('draft-only-text')));
    session.commandSubmitted();
    expect(session.readHistory(completed), isNull);
    final running = session.historySession!;
    await _feed(tester, shell.echo, '\r\nworking');
    expect(session.readAiContext().prompt, TerminalAiPrompt.unknown);
    final result = session.readHistory(running)!;
    expect(result.prompt, TerminalAiPrompt.unknown);
    expect(result.history.first.output.trim(), 'first');
    expect(result.history.last.resultStatus, TerminalAiHistoryResultStatus.unavailable);
    await _feed(tester, shell.echo, '\x1b]7;file://box/token/cache\x07');
    expect(session.readHistory(running)!.directory, isNull);
    expect(shell.writes, isEmpty);
  });

  testWidgets('history rejects a stale SSH lease even while its existing shell remains connected', (tester) async {
    final host = session.host;
    session.close();
    manager.closeAll();
    var revision = 0;
    manager = ConnectionManager((_, _, _) async => transport, securityRevision: () => [revision]);
    session = TerminalSession(
      const SessionId('session'),
      host,
      manager,
      completionSpecs: CompletionSpecs(bundle: _Assets()),
    );
    await connect(tester);
    final expected = session.historySession!;
    expect(session.readHistory(expected), isNotNull);
    revision++;
    expect(session.status, SessionStatus.connected);
    expect(session.canInsert, isTrue);
    expect(session.historySession, isNull);
    expect(session.historySessionCurrent(expected), isFalse);
    expect(session.readHistory(expected), isNull);
    session.close();
    manager.closeAll();
    await tester.pump();
  });

  testWidgets('workspace history includes background splits and intersects the session manager', (tester) async {
    await connect(tester);
    final others = [
      for (final id in ['split', 'background', 'orphan', 'idle'])
        TerminalSession(SessionId(id), session.host, manager, completionSpecs: CompletionSpecs(bundle: _Assets())),
    ];
    for (final other in others) {
      addTearDown(other.close);
      if (other.id != const SessionId('idle')) unawaited(other.connect(NoPrompts()));
    }
    final local = TerminalSession.local(
      const SessionId('local'),
      const LocalShell(kind: LocalShellKind.cmd, executable: r'C:\Windows\System32\cmd.exe'),
      _Factory(),
      completionSpecs: CompletionSpecs(bundle: _Assets()),
    );
    addTearDown(local.close);
    unawaited(local.connect());
    await tester.pump();
    final current = {session.id: session, for (final other in others) other.id: other, local.id: local};
    final split = Layout.single(
      const PaneId('first'),
      session.id,
    ).split(const PaneId('first'), SplitAxis.horizontal, const PaneId('second'), others.first.id)!;
    final initial = WorkspaceState(
      active: const TabId('active'),
      tabs: [
        WorkspaceTab(const TabId('active'), split),
        WorkspaceTab(const TabId('background'), Layout.single(const PaneId('third'), others[1].id)),
        WorkspaceTab(const TabId('local'), Layout.single(const PaneId('local'), local.id)),
        WorkspaceTab(const TabId('idle'), Layout.single(const PaneId('idle'), others.last.id)),
        WorkspaceTab(const TabId('missing'), Layout.single(const PaneId('missing'), const SessionId('missing'))),
      ],
    );
    var workspace = initial;
    final reader = WorkspaceTerminalHistoryReader(() => workspace, () => current);
    expect(reader.sessions.map((entry) => entry.sessionId), [session.id, others.first.id, others[1].id, local.id]);
    expect(reader.sessions.where((entry) => entry.target is SshTerminalAiTarget), hasLength(3));
    expect(reader.sessions.last.target, isA<LocalTerminalAiTarget>());
    expect(reader.focusedSession, split.focusedLeaf.session);
    final expected = reader.sessions.first;
    expect(reader.read(expected), isNotNull);
    workspace = WorkspaceState(tabs: initial.tabs.skip(1).toList());
    expect(reader.focusedSession, isNull);
    expect(reader.isCurrent(expected), isFalse);
    expect(reader.read(expected), isNull);
    workspace = initial;
    current.remove(expected.sessionId);
    expect(reader.isCurrent(expected), isFalse);
    expect(reader.sessions.map((entry) => entry.sessionId), isNot(contains(expected.sessionId)));
    current[expected.sessionId] = session;
    expect(reader.isCurrent(expected), isTrue);
    session.close();
    expect(reader.isCurrent(expected), isFalse);
    expect(reader.read(expected), isNull);
    for (final other in others) {
      other.close();
    }
    local.close();
    manager.closeAll();
    await tester.pump();
  });

  testWidgets('recent AI history is bounded, belongs to this shell generation and is revoked on clear', (tester) async {
    final shell = await connect(tester);
    for (var i = 0; i < 10; i++) {
      await _feed(tester, shell.echo, '${i == 0 ? '' : '\r\n'}u@box:~\$ echo $i');
      session.commandSubmitted();
    }
    await _feed(tester, shell.echo, '\r\nu@box:~\$ echo ');
    final current = session.readAiContext();
    final history = session.readAiHistory(current);
    expect(history.map((entry) => entry.text), [for (var i = 2; i < 10; i++) 'echo $i']);
    expect(history.every((entry) => entry.generation == current.generation), isTrue);
    expect(history.last.at.isBefore(history.first.at), isFalse);
    await _feed(tester, shell.echo, 'new');
    expect(session.readAiHistory(current), isEmpty);
    session.clearCommandHistory();
    expect(session.readAiHistory(session.readAiContext()), isEmpty);
    session.commandSubmitted();
    await _feed(tester, shell.echo, '\r\nu@box:~\$ ');
    expect(session.readAiHistory(session.readAiContext()), hasLength(1));
    shell.close();
    for (var i = 0; i < 10 && session.status != SessionStatus.disconnected; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(session.status, SessionStatus.disconnected);
    final count = transport.channels.length;
    unawaited(session.connect(NoPrompts()));
    for (var i = 0; i < 10 && transport.channels.length == count; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(transport.channels, hasLength(count + 1));
    await _feed(tester, transport.channels.last.echo, '\r\nu@box:~\$ ');
    expect(session.readAiContext().generation, isNot(current.generation));
    expect(session.readAiHistory(session.readAiContext()), isEmpty);
    session.close();
    manager.closeAll();
    await tester.pump();
  });

  testWidgets('recognized prompt results stay paired with each submission of the same command', (tester) async {
    final shell = await connect(tester);
    await _feed(tester, shell.echo, 'u@box:~\$ printf value');
    session.commandSubmitted();
    await _feed(tester, shell.echo, '\r\nfirst\r\nu@box:~\$ ');
    final first = session.readAiContext();
    final firstResult = session.readAiHistory(first).single;
    expect(firstResult.output.trim(), 'first');
    expect(firstResult.resultStatus, TerminalAiHistoryResultStatus.available);
    expect(firstResult.boundary, TerminalAiHistoryBoundary.prompt);
    expect(firstResult.exitCode, isNull);
    await _feed(tester, shell.echo, 'printf value');
    session.commandSubmitted();
    await _feed(tester, shell.echo, '\r\nsecond\r\nu@box:~\$ ');
    final current = session.readAiContext();
    final results = session.readAiHistory(current);
    expect(results.map((entry) => entry.text), ['printf value', 'printf value']);
    expect(results.map((entry) => entry.output.trim()), ['first', 'second']);
    expect(current.historyRevision, greaterThan(first.historyRevision));
    expect(session.readAiHistory(first), isEmpty);
  });

  for (final code in ['133', '633']) {
    testWidgets('OSC $code command boundaries preserve an explicit exit code and exclude the next prompt', (
      tester,
    ) async {
      final shell = await connect(tester);
      await _feed(tester, shell.echo, '\x1b]$code;A\x07u@box:~\$ \x1b]$code;B\x07false');
      session.commandSubmitted();
      await _feed(
        tester,
        shell.echo,
        '\r\n\x1b]$code;C\x07failed\r\n\x1b]$code;D;7\x07'
        '\x1b]$code;A\x07u@box:~\$ \x1b]$code;B\x07',
      );
      final result = session.readAiHistory(session.readAiContext()).single;
      expect(result.output.trim(), 'failed');
      expect(result.exitCode, 7);
      expect(result.resultStatus, TerminalAiHistoryResultStatus.available);
      expect(result.output, isNot(contains('u@box')));
    });
  }

  testWidgets('OSC completion without a C boundary never borrows a previous exit code', (tester) async {
    final shell = await connect(tester);
    await _feed(tester, shell.echo, '\x1b]133;A\x07u@box:~\$ \x1b]133;B\x07echo value');
    session.commandSubmitted();
    await _feed(
      tester,
      shell.echo,
      '\r\nvalue\r\n\x1b]133;D;0\x07'
      '\x1b]133;A\x07u@box:~\$ \x1b]133;B\x07',
    );
    final result = session.readAiHistory(session.readAiContext()).single;
    expect(result.resultStatus, TerminalAiHistoryResultStatus.unavailable);
    expect(result.output, isEmpty);
    expect(result.exitCode, isNull);
  });

  for (final change in ['\x1b[?1049hprivate TUI\x1b[?1049l', '\x1b[2J\x1b[H']) {
    testWidgets('destructive screen changes never become command result text: $change', (tester) async {
      final shell = await connect(tester);
      await _feed(tester, shell.echo, 'u@box:~\$ echo value');
      session.commandSubmitted();
      await _feed(tester, shell.echo, '\r\nvalue$change\r\nu@box:~\$ ');
      final result = session.readAiHistory(session.readAiContext()).single;
      expect(result.resultStatus, TerminalAiHistoryResultStatus.unavailable);
      expect(result.output, isEmpty);
    });
  }

  testWidgets('scroll-region screen changes invalidate a command output range', (tester) async {
    final shell = await connect(tester);
    await _feed(tester, shell.echo, 'u@box:~\$ echo value');
    session.commandSubmitted();
    await _feed(tester, shell.echo, '\r\nvalue\x1b[1;10r\r\nu@box:~\$ ');
    final result = session.readAiHistory(session.readAiContext()).single;
    expect(result.resultStatus, TerminalAiHistoryResultStatus.unavailable);
    expect(result.output, isEmpty);
  });

  testWidgets('a different recognized prompt cannot finish an earlier command result', (tester) async {
    final shell = await connect(tester);
    await _feed(tester, shell.echo, 'u@box:~\$ ssh other');
    session.commandSubmitted();
    await _feed(tester, shell.echo, '\r\nremote output\r\nu@other:~\$ ');
    final result = session.readAiHistory(session.readAiContext()).single;
    expect(result.resultStatus, TerminalAiHistoryResultStatus.unavailable);
    expect(result.output, isEmpty);
  });

  testWidgets('secret output split between chunks removes the whole command record', (tester) async {
    final shell = await connect(tester);
    await _feed(tester, shell.echo, 'u@box:~\$ cat response');
    session.commandSubmitted();
    await _feed(tester, shell.echo, '\r\napi_');
    await _feed(tester, shell.echo, 'key=synthetic-private\r\nu@box:~\$ ');
    expect(session.readAiHistory(session.readAiContext()), isEmpty);
  });

  testWidgets('a sensitive result is removed even when a later screen change invalidates its boundary', (tester) async {
    final shell = await connect(tester);
    await _feed(tester, shell.echo, 'u@box:~\$ cat response');
    session.commandSubmitted();
    await _feed(tester, shell.echo, '\r\npassword=synthetic-private');
    await _feed(tester, shell.echo, '\x1b[?1049hTUI\x1b[?1049l\r\nu@box:~\$ ');
    expect(session.readAiHistory(session.readAiContext()), isEmpty);
  });

  testWidgets('results are bounded by their encoded projection and clear cannot attach a late result', (tester) async {
    final shell = await connect(tester);
    await _feed(tester, shell.echo, 'u@box:~\$ printf large');
    session.commandSubmitted();
    await _feed(tester, shell.echo, '\r\n${'中' * 1800}\r\nu@box:~\$ ');
    final results = session.readAiHistory(session.readAiContext());
    expect(results.single.resultStatus, TerminalAiHistoryResultStatus.truncated);
    expect(utf8.encode(jsonEncode(results.map(terminalAiHistoryData).toList())).length, lessThanOrEqualTo(4096));
    expect(results.single.output, isNot(contains('�')));
    await _feed(tester, shell.echo, 'echo late');
    session.commandSubmitted();
    session.clearCommandHistory();
    await _feed(tester, shell.echo, '\r\nlate\r\nu@box:~\$ ');
    expect(session.readAiHistory(session.readAiContext()), isEmpty);
  });

  testWidgets('snapshot access is explicit and bounded by rows and whole UTF-8 characters', (tester) async {
    final shell = await connect(tester);
    await _feed(tester, shell.echo, 'first\r\nsecond\r\n中文中文\r\nu@box:~\$ ');
    final context = session.readAiContext();
    final snapshot = session.readAiSnapshot(context, maxLines: 2)!;
    expect(snapshot.text, '中文中文\nu@box:~\$');
    expect(snapshot.lastLine - snapshot.firstLine + 1, 2);
    expect(snapshot.truncated, isTrue);
    final bytes = session.readAiSnapshot(context, maxLines: 2, maxBytes: 7)!;
    expect(bytes.text, '中文');
    expect(utf8.encode(bytes.text).length, lessThanOrEqualTo(7));
    expect(bytes.text.contains('�'), isFalse);
    expect(bytes.truncated, isTrue);
    expect(() => session.readAiSnapshot(context, maxLines: 201), throwsArgumentError);
    expect(() => session.readAiSnapshot(context, maxBytes: 32769), throwsArgumentError);
    await _feed(tester, shell.echo, 'pwd');
    expect(session.readAiSnapshot(context), isNull);
    session.close();
    manager.closeAll();
    await tester.pump();
  });

  testWidgets('local context exposes shell kind without its executable and follows the same draft checks', (
    tester,
  ) async {
    session.close();
    final factory = _Factory();
    session = TerminalSession.local(
      const SessionId('local'),
      const LocalShell(kind: LocalShellKind.cmd, executable: r'C:\Windows\System32\cmd.exe'),
      factory,
      completionSpecs: CompletionSpecs(bundle: _Assets()),
    );
    unawaited(session.connect());
    await tester.pump();
    await _feed(tester, factory.pty.echo, 'C:\\work>');
    final context = session.readAiContext();
    expect((context.target as LocalTerminalAiTarget).kind, LocalShellKind.cmd);
    expect(context.ready, isTrue);
    expect(await session.acceptAiDraft(context, 'dir'), InsertResult.sent);
    expect(factory.pty.writes, ['dir']);
    session.close();
    manager.closeAll();
    await tester.pump();
  });
}

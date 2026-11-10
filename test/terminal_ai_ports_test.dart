import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/features/connections/api.dart';
import 'package:sshairy/features/hosts/api.dart';
import 'package:sshairy/features/terminal/api.dart';
import 'package:sshairy/features/terminal/adapters/completion_specs.dart';
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
    manager = ConnectionManager((_, _, _) async => transport, park: Duration.zero);
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
    await tester.pump();
  });

  testWidgets('complete generated draft needs the exact empty prompt and sends no Enter', (tester) async {
    final shell = await connect(tester);
    await _feed(tester, shell.echo, 'u@box:~\$ ');
    final empty = session.readAiContext();
    expect(await session.acceptAiDraft(empty, 'printf hello'), InsertResult.sent);
    expect(shell.writes, ['printf hello']);
    expect(await session.acceptAiDraft(empty, 'printf again'), InsertResult.stale);
    await _feed(tester, shell.echo, 'printf hello');
    expect(await session.acceptAiDraft(session.readAiContext(), 'echo replacement'), InsertResult.rejected);
    expect(shell.writes, ['printf hello']);
    session.close();
    await tester.pump();
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
    await tester.pump();
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
    await tester.pump();
  });
}

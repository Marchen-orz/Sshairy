import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/design/theme.dart';
import 'package:sshairy/features/connections/api.dart';
import 'package:sshairy/features/hosts/api.dart';
import 'package:sshairy/features/terminal/api.dart';
import 'package:sshairy/foundation/cancellation.dart';
import 'package:sshairy/foundation/data_dir.dart';
import 'package:sshairy/foundation/ids.dart';
import 'package:sshairy/l10n/app_localizations.dart';
import 'package:xterm2/xterm.dart' show TerminalView;

import 'connection_manager_test.dart' show FakeTransport, NoPrompts;

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
    if (!ended.isCompleted) {
      ended.complete();
      output.close();
    }
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

class _Provider implements CommandCompletionProvider {
  final pending = <Completer<List<CommandCandidate>>>[];
  @override
  Future<List<CommandCandidate>> complete(CommandCompletionRequest request, CancellationToken cancel) {
    final gate = Completer<List<CommandCandidate>>();
    pending.add(gate);
    return gate.future;
  }
}

/// Output reaches the terminal on a timer, so the clock must advance past it and the 180 ms completion debounce.
Future<void> _feed(WidgetTester tester, _Shell shell, String text) async {
  shell.echo(text);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
}

void main() {
  test('history deduplicates, rejects controls and leading spaces, and stays bounded', () {
    final history = CommandHistory();
    for (var i = 0; i < 120; i++) {
      history.remember('echo $i');
    }
    history.remember('echo 119');
    history.remember(' secret');
    history.remember('echo bad\nrun');
    history.remember('echo \x1b[31m');
    expect(history.commands, hasLength(100));
    expect(history.commands.first, 'echo 119');
    expect(history.commands.last, 'echo 20');
    expect(localCommandCandidates('git s', history).map((c) => c.text), ['git status']);
    history.clear();
    expect(history.commands, isEmpty);
  });

  test('only recognized echoed prompt at end of line yields a command', () {
    expect(visibleShellCommand('u@box:~\$ git st', ''), 'git st');
    expect(visibleShellCommand('[u@box ~]\$ ls', ''), 'ls');
    expect(visibleShellCommand('Password: ', ''), isNull);
    expect(visibleShellCommand('u@box:~\$ git', ' status'), isNull);
    expect(visibleShellCommand('anything > ls', ''), isNull);
  });

  testWidgets('echoed completion appends only suffix, never Enter, and stale requests cannot insert', (tester) async {
    final transport = _Transport();
    final manager = ConnectionManager((_, _, _) async => transport, park: Duration.zero);
    final session = TerminalSession(
      const SessionId('s'),
      const Host(id: HostId('h'), label: 'h', address: 'box', username: 'u'),
      manager,
    );
    unawaited(session.connect(NoPrompts()));
    await tester.pump();
    final shell = transport.channels.single;
    shell.echo('u@box:~\$ git st');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    final state = session.commandAssistance.value;
    expect(state.candidates.map((c) => c.text), contains('git status'));
    expect(await session.acceptCommand(state.request!, 'git status'), InsertResult.sent);
    expect(shell.writes.join(), 'atus');
    expect(await session.acceptCommand(state.request!, 'git status'), InsertResult.stale);
    await _feed(tester, shell, 'atus');
    session.commandSubmitted();
    expect(session.commandHistory.value, ['git status']);
    await _feed(tester, shell, '\r\nPassword: ');
    session.commandSubmitted();
    expect(session.commandHistory.value, ['git status']);
    session.close();
    manager.closeAll();
    await tester.pump();
  });

  testWidgets('alternate screen and unknown prompts never collect history', (tester) async {
    final transport = _Transport();
    final manager = ConnectionManager((_, _, _) async => transport, park: Duration.zero);
    final session = TerminalSession(
      const SessionId('s'),
      const Host(id: HostId('h'), label: 'h', address: 'box', username: 'u'),
      manager,
    );
    unawaited(session.connect(NoPrompts()));
    await tester.pump();
    final shell = transport.channels.single;
    await _feed(tester, shell, 'Password: ');
    session.commandSubmitted();
    await _feed(tester, shell, '\x1b[?1049hu@box:~\$ git status');
    session.commandSubmitted();
    expect(session.commandHistory.value, isEmpty);
    expect(session.commandAssistance.value.candidates, isEmpty);
    session.close();
    manager.closeAll();
    await tester.pump();
  });

  testWidgets('late provider results cannot replace a newer draft or insert into an older one', (tester) async {
    final transport = _Transport();
    final provider = _Provider();
    final manager = ConnectionManager((_, _, _) async => transport, park: Duration.zero);
    final session = TerminalSession(
      const SessionId('s'),
      const Host(id: HostId('h'), label: 'h', address: 'box', username: 'u'),
      manager,
      completionProvider: provider,
    );
    unawaited(session.connect(NoPrompts()));
    await tester.pump();
    final shell = transport.channels.single;
    shell.echo('u@box:~\$ git');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(provider.pending, hasLength(1));
    final old = session.commandAssistance.value.request!;
    await _feed(tester, shell, ' s');
    provider.pending.first.complete([const CommandCandidate('git malicious')]);
    await tester.pump();
    expect(session.commandAssistance.value.request!.text, 'git s');
    expect(await session.acceptCommand(old, 'git status'), InsertResult.stale);
    expect(provider.pending, hasLength(2));
    provider.pending.last.complete(const []);
    await tester.pump();
    session.close();
    manager.closeAll();
    await tester.pump();
  });

  testWidgets('full scrollback, split prompt output and clear redraw keep history available', (tester) async {
    final transport = _Transport();
    final manager = ConnectionManager((_, _, _) async => transport, park: Duration.zero);
    final session = TerminalSession(
      const SessionId('s'),
      const Host(id: HostId('h'), label: 'h', address: 'box', username: 'u'),
      manager,
      scrollback: 30,
    );
    unawaited(session.connect(NoPrompts()));
    await tester.pump();
    final shell = transport.channels.single;
    try {
      await _feed(tester, shell, '${List.filled(50, 'output\r\n').join()}u@box:~\$ git status');
      session.commandSubmitted();
      await _feed(tester, shell, '\r\n');
      await _feed(tester, shell, 'u@box:~\$ git diff');
      expect(session.commandAssistance.value.request?.text, 'git diff');
      session.commandSubmitted();
      expect(session.commandHistory.value, ['git diff', 'git status']);
      await _feed(tester, shell, '\x1b[2J\x1b[Hu@box:~\$ clear');
      session.commandSubmitted();
      await _feed(tester, shell, '\x1b[2J\x1b[Hu@box:~\$ pwd');
      expect(session.commandAssistance.value.request?.text, 'pwd');
      session.commandSubmitted();
      expect(session.commandHistory.value.first, 'pwd');
    } finally {
      session.close();
      manager.closeAll();
      await tester.pump();
    }
  });

  testWidgets('clearing history revokes old candidates and closing wipes notifier copies', (tester) async {
    final transport = _Transport();
    final manager = ConnectionManager((_, _, _) async => transport, park: Duration.zero);
    final session = TerminalSession(
      const SessionId('s'),
      const Host(id: HostId('h'), label: 'h', address: 'box', username: 'u'),
      manager,
    );
    unawaited(session.connect(NoPrompts()));
    await tester.pump();
    final shell = transport.channels.single;
    await _feed(tester, shell, 'u@box:~\$ echo café');
    session.commandSubmitted();
    expect(session.commandHistory.value, ['echo café']);
    await _feed(tester, shell, '\r\nu@box:~\$ echo');
    final old = session.commandAssistance.value.request!;
    expect(session.commandAssistance.value.candidates.map((c) => c.text), contains('echo café'));
    session.clearCommandHistory();
    expect(session.commandAssistance.value.candidates, isEmpty);
    expect(await session.acceptCommand(old, 'echo café'), InsertResult.stale);
    await tester.pump(const Duration(milliseconds: 200));
    expect(session.commandAssistance.value.candidates, isEmpty);
    final history = session.commandHistory;
    final assistance = session.commandAssistance;
    session.close();
    expect(history.value, isEmpty);
    expect(assistance.value.candidates, isEmpty);
    manager.closeAll();
    await tester.pump();
  });

  group('pane', () {
    late Directory dir;
    late ProviderContainer container;
    late _Transport transport;
    late ConnectionManager manager;
    late TerminalSession session;

    Future<_Shell> mount(WidgetTester tester) async {
      dir = Directory.systemTemp.createTempSync('sshairy-pane-');
      container = ProviderContainer(overrides: [dataDirProvider.overrideWithValue(dir.path)]);
      transport = _Transport();
      manager = ConnectionManager((_, _, _) async => transport, park: Duration.zero);
      session = TerminalSession(
        const SessionId('s'),
        const Host(id: HostId('h'), label: 'h', address: 'box', username: 'u'),
        manager,
        autoConnect: false,
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: buildTheme(Brightness.light),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(body: SizedBox.expand(child: TerminalPane(session, active: true))),
          ),
        ),
      );
      unawaited(session.connect(NoPrompts()));
      await tester.pump();
      await tester.pump();
      return transport.channels.single;
    }

    Future<void> unmount(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox.shrink());
      session.close();
      manager.closeAll();
      await tester.pump();
      container.dispose();
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        dir.deleteSync(recursive: true);
      });
    }

    Future<void> chord(WidgetTester tester, List<LogicalKeyboardKey> modifiers, LogicalKeyboardKey key) async {
      for (final modifier in modifiers) {
        await tester.sendKeyDownEvent(modifier);
      }
      await tester.sendKeyEvent(key);
      for (final modifier in modifiers.reversed) {
        await tester.sendKeyUpEvent(modifier);
      }
      await tester.pump();
    }

    testWidgets('candidate mode is explicit: Enter appends the suffix only, plain Enter still reaches the shell', (
      tester,
    ) async {
      final shell = await mount(tester);
      await _feed(tester, shell, 'u@box:~\$ git st');
      expect(find.text('git status'), findsOneWidget);

      // Without Ctrl+Space the arrow keys and Enter belong to the shell, so nothing is accepted.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(shell.writes.join(), isNot(contains('atus')));
      shell.writes.clear();
      await _feed(tester, shell, '\r\x1b[2Ku@box:~\$ git st');

      await chord(tester, [LogicalKeyboardKey.controlLeft], LogicalKeyboardKey.space);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(shell.writes.join(), 'atus');

      await _feed(tester, shell, 'atus');
      shell.writes.clear();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(shell.writes.join(), '\r');
      expect(session.commandHistory.value, ['git status']);
      await unmount(tester);
    });

    testWidgets('pending input revokes mouse candidates and a new draft exits keyboard selection', (tester) async {
      final shell = await mount(tester);
      await _feed(tester, shell, 'u@box:~\$ git st');
      final old = session.commandAssistance.value.request!;
      await chord(tester, [LogicalKeyboardKey.controlLeft], LogicalKeyboardKey.space);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA, character: 'a');
      await tester.pump();
      expect(session.commandAssistance.value.request, isNull);
      expect(await session.acceptCommand(old, 'git status'), InsertResult.stale);
      await _feed(tester, shell, 'a');
      shell.writes.clear();
      await tester.sendKeyEvent(LogicalKeyboardKey.numpadEnter);
      await tester.pump();
      expect(shell.writes.join(), '\r');
      expect(session.commandHistory.value, ['git sta']);
      await unmount(tester);
    });

    testWidgets('Ctrl+Shift+H and the context menu open the history; inserting only appends', (tester) async {
      final shell = await mount(tester);
      await _feed(tester, shell, 'u@box:~\$ git status');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      await _feed(tester, shell, '\r\nu@box:~\$ git');
      expect(session.commandHistory.value, ['git status']);

      await chord(tester, [LogicalKeyboardKey.controlLeft, LogicalKeyboardKey.shiftLeft], LogicalKeyboardKey.keyH);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Command history'), findsOneWidget);
      expect(find.text('git status'), findsWidgets);
      shell.writes.clear();
      await tester.tap(find.byTooltip('Insert command'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Command history'), findsNothing);
      expect(shell.writes.join(), ' status');

      final click = await tester.startGesture(
        tester.getCenter(find.byType(TerminalView)),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryButton,
      );
      await click.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Command history'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('No commands'), findsNothing);
      await tester.tap(find.text('Clear history'));
      await tester.pump();
      expect(session.commandHistory.value, isEmpty);
      expect(find.text('No commands'), findsOneWidget);
      await unmount(tester);
    });
  });
}

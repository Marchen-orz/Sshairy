import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/design/theme.dart';
import 'package:sshairy/design/interface_scale.dart';
import 'package:sshairy/design/scrolling.dart';
import 'package:sshairy/features/connections/api.dart';
import 'package:sshairy/features/hosts/api.dart';
import 'package:sshairy/features/terminal/api.dart';
import 'package:sshairy/foundation/cancellation.dart';
import 'package:sshairy/foundation/data_dir.dart';
import 'package:sshairy/foundation/ids.dart';
import 'package:sshairy/l10n/app_localizations.dart';
import 'package:xterm2/xterm.dart' show TerminalView, TerminalViewState;

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
    expect(localCommandCandidates('git s', history).map((c) => c.text), contains('git status'));
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
    await _feed(tester, shell, 'u@box:~\$ custom-echo café');
    session.commandSubmitted();
    expect(session.commandHistory.value, ['custom-echo café']);
    await _feed(tester, shell, '\r\nu@box:~\$ custom-echo');
    final old = session.commandAssistance.value.request!;
    expect(session.commandAssistance.value.candidates.map((c) => c.text), contains('custom-echo café'));
    session.clearCommandHistory();
    expect(session.commandAssistance.value.candidates, isEmpty);
    expect(await session.acceptCommand(old, 'custom-echo café'), InsertResult.stale);
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

    Future<_Shell> mount(WidgetTester tester, {double scale = 1, CommandCompletionProvider? provider}) async {
      dir = Directory.systemTemp.createTempSync('sshairy-pane-');
      container = ProviderContainer(overrides: [dataDirProvider.overrideWithValue(dir.path)]);
      transport = _Transport();
      manager = ConnectionManager((_, _, _) async => transport, park: Duration.zero);
      session = TerminalSession(
        const SessionId('s'),
        const Host(id: HostId('h'), label: 'h', address: 'box', username: 'u'),
        manager,
        autoConnect: false,
        completionProvider: provider,
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: buildTheme(Brightness.light).copyWith(platform: TargetPlatform.windows),
            scrollBehavior: const AppScrollBehavior(),
            builder: (_, child) => InterfaceScale(scale: scale, child: child!),
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
      expect(find.text('status'), findsOneWidget);

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

    testWidgets('late AI candidates appear first without changing the selected local command', (tester) async {
      final provider = _Provider();
      final shell = await mount(tester, provider: provider);
      try {
        await _feed(tester, shell, 'u@box:~\$ git st');
        await chord(tester, [LogicalKeyboardKey.controlLeft], LogicalKeyboardKey.space);
        provider.pending.single.complete([const CommandCandidate('git stash list', source: CommandCandidateSource.ai)]);
        await tester.pump();
        expect(session.commandAssistance.value.candidates.first.source, CommandCandidateSource.ai);
        expect(tester.getTopLeft(find.text('git stash list')).dy, lessThan(tester.getTopLeft(find.text('status')).dy));
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        expect(shell.writes.join(), 'atus');
      } finally {
        await unmount(tester);
      }
    });

    testWidgets('keyboard selection scrolls a constrained list and starts again at its first item', (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 320));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final shell = await mount(tester);
      try {
        final view = tester.state<TerminalViewState>(find.byType(TerminalView));
        await _feed(tester, shell, '\x1b[${view.widget.terminal.viewHeight ~/ 2};1Hu@box:~\$ tmux ');
        final candidates = session.commandAssistance.value.candidates;
        expect(candidates, hasLength(8));
        await chord(tester, [LogicalKeyboardKey.controlLeft], LogicalKeyboardKey.space);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await tester.pump();
        await tester.pump();
        final popup = find.byKey(const ValueKey('command-completion-popup'));
        final list = tester.widget<ListView>(find.descendant(of: popup, matching: find.byType(ListView)));
        expect(list.controller!.offset, greaterThan(0));
        expect(find.text(candidates.last.displayText!).hitTestable(), findsOneWidget);
        await chord(tester, [LogicalKeyboardKey.controlLeft], LogicalKeyboardKey.space);
        await tester.pump();
        expect(list.controller!.offset, 0);
        expect(find.text(candidates.first.displayText!).hitTestable(), findsOneWidget);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        expect(shell.writes.join(), candidates.first.text.substring('tmux '.length));
      } finally {
        await unmount(tester);
      }
    });

    testWidgets('tmux subcommands display short labels and only insert the missing suffix', (tester) async {
      final shell = await mount(tester);
      try {
        await _feed(tester, shell, 'u@box:~\$ tmux ');
        expect(find.byKey(const ValueKey('command-completion-popup')), findsOneWidget);
        final candidate = session.commandAssistance.value.candidates.first;
        expect(candidate.kind, CommandKind.subcommand);
        expect(find.text(candidate.displayText!), findsOneWidget);
        await tester.tap(find.text(candidate.displayText!));
        await tester.pump();
        expect(shell.writes.join(), candidate.text.substring('tmux '.length));
        expect(shell.writes.join(), isNot(contains('\r')));
      } finally {
        await unmount(tester);
      }
    });

    for (final scale in [1.0, 1.5]) {
      testWidgets('completion tracks the caret at $scale scale and stays inside the pane', (tester) async {
        await tester.binding.setSurfaceSize(const Size(1400, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final shell = await mount(tester, scale: scale);
        try {
          await _feed(tester, shell, 'u@box:~\$ git s');
          await tester.pump();
          final popup = find.byKey(const ValueKey('command-completion-popup'));
          expect(popup, findsOneWidget);
          final first = tester.getRect(popup);
          final view = tester.state<TerminalViewState>(find.byType(TerminalView));
          Rect caret() => MatrixUtils.transformRect(view.renderTerminal.getTransformTo(null), view.cursorRect);
          expect(first.left, closeTo(caret().right + Space.xs * scale, .1));
          expect(first.top, greaterThanOrEqualTo(caret().bottom));
          await _feed(tester, shell, 't');
          await tester.pump();
          final moved = tester.getRect(popup);
          expect(moved.left, greaterThan(first.left));
          expect(moved.left, closeTo(caret().right + Space.xs * scale, .1));
          // Place a new prompt at the bottom: the popup flips above the caret.
          final terminal = view.widget.terminal;
          await _feed(tester, shell, '\x1b[${terminal.viewHeight};1Hu@box:~\$ git st');
          await tester.pump();
          final bottom = tester.getRect(popup);
          expect(bottom.bottom, lessThanOrEqualTo(caret().top));
          final pane = tester.getRect(find.byType(TerminalPane));
          expect(pane.contains(bottom.topLeft), isTrue);
          expect(pane.contains(bottom.bottomRight), isTrue);
          await tester.binding.setSurfaceSize(const Size(800, 600));
          await tester.pump();
          await _feed(tester, shell, '\x1b[2J\x1b[Hu@${List.filled(14, 'b').join()}:~\$ git s');
          await tester.pump();
          expect(
            popup,
            findsOneWidget,
            reason:
                'draft=${session.commandAssistance.value.request?.text}, '
                'grid=${terminal.viewWidth}x${terminal.viewHeight}, caret=${caret()}, '
                'scroll=${view.widget.scrollController!.offset}',
          );
          final clamped = tester.getRect(popup);
          final narrowPane = tester.getRect(find.byType(TerminalPane));
          expect(clamped.right, closeTo(narrowPane.right - Space.sm * scale, .1));
          expect(clamped.left, lessThan(caret().right + Space.xs * scale));
          expect(tester.takeException(), isNull);
        } finally {
          await unmount(tester);
        }
      });
    }

    testWidgets('scrolling away hides the popup and scrolling back restores its cursor anchor', (tester) async {
      final shell = await mount(tester);
      try {
        await _feed(tester, shell, '${List.filled(70, 'output\r\n').join()}u@box:~\$ git st');
        final popup = find.byKey(const ValueKey('command-completion-popup'));
        expect(popup, findsOneWidget);
        final view = tester.state<TerminalViewState>(find.byType(TerminalView));
        final scroll = view.widget.scrollController!;
        scroll.jumpTo(0);
        await tester.pump();
        await tester.pump();
        expect(popup, findsNothing);
        scroll.jumpTo(scroll.position.maxScrollExtent);
        await tester.pump();
        await tester.pump();
        expect(popup, findsOneWidget);
        final caret = MatrixUtils.transformRect(view.renderTerminal.getTransformTo(null), view.cursorRect);
        expect(tester.getRect(popup).left, closeTo(caret.right + Space.xs, .1));
        expect(tester.takeException(), isNull);
      } finally {
        await unmount(tester);
      }
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

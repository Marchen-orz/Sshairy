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
import 'package:sshairy/features/settings/api.dart';
import 'package:sshairy/features/terminal/api.dart';
import 'package:sshairy/features/terminal/adapters/completion_specs.dart';
import 'package:sshairy/features/terminal/adapters/completion_translations.dart';
import 'package:sshairy/features/terminal/domain/completion_translation.dart';
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
  final queries = <String>[];
  Completer<ExecResult>? directoryQuery;

  @override
  Future<ExecResult> exec(String command, {int limit = 0}) {
    queries.add(command);
    return directoryQuery?.future ?? super.exec(command, limit: limit);
  }

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

class _TranslationCall {
  _TranslationCall(this.original, this.target, this.cancel);
  final String original, target;
  final CancellationToken cancel;
  final result = Completer<String?>();
}

class _TranslationEngine implements CompletionTranslationEngine {
  _TranslationEngine({this.hold = false});
  final bool hold;
  final calls = <_TranslationCall>[];
  var disposed = false;

  @override
  Future<String?> translate(String original, String target, CancellationToken cancel) {
    final call = _TranslationCall(original, target, cancel);
    calls.add(call);
    if (!hold) call.result.complete('译文 $original');
    return call.result.future;
  }

  @override
  void dispose() => disposed = true;
}

class _SpecBundle extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async {
    final value = switch (key) {
      'assets/completions/manifest.json' => {
        'commands': {
          'git': 'git.json',
          'tmux': 'tmux.json',
          'cat': 'cat.json',
          'cd': 'cd.json',
          'mk': 'mk.json',
          'dd': 'dd.json',
        },
      },
      'git.json' => {
        'name': 'git',
        'subcommands': [
          for (final name in ['status', 'stash', 'switch', 'show', 'commit'])
            {'name': name, if (name == 'status') 'description': 'Show the working tree status'},
        ],
      },
      'tmux.json' => {
        'name': 'tmux',
        'subcommands': [
          for (var i = 0; i < 32; i++) {'name': 'command-$i', 'description': 'tmux action $i'},
        ],
      },
      'cat.json' => {
        'name': 'cat',
        'args': {'template': 'filepaths', 'isVariadic': true},
      },
      'cd.json' => {
        'name': 'cd',
        'args': {'template': 'folders'},
      },
      'dd.json' => {'name': 'dd'},
      'mk.json' => {
        'name': 'mk',
        'options': [
          {
            'name': '--color',
            'requiresSeparator': true,
            'args': {
              'suggestions': ['always', 'auto'],
            },
          },
        ],
      },
      _ => throw StateError('Missing test asset'),
    };
    return ByteData.sublistView(Uint8List.fromList(utf8.encode(jsonEncode(value))));
  }
}

CompletionSpecs _specs() => CompletionSpecs(bundle: _SpecBundle());

class _Paths implements RemotePathSource {
  _Paths({this.entries});

  final List<RemotePathEntry>? entries;
  final queries = <RemotePathQuery>[];
  @override
  Future<RemotePathResult> browse(RemotePathQuery query, {CancellationToken? cancel}) async {
    queries.add(query);
    final entries =
        this.entries ??
        switch (query.directory) {
          '/work' => [
            const RemotePathEntry('My Notes', RemotePathKind.directory, '/work/My Notes'),
            const RemotePathEntry('read me.txt', RemotePathKind.file, '/work/read me.txt'),
          ],
          '/work/My Notes' => [const RemotePathEntry('中文.txt', RemotePathKind.file, '/work/My Notes/中文.txt')],
          _ => <RemotePathEntry>[],
        };
    return RemotePathResult(
      directory: query.directory,
      prefix: query.prefix,
      entries: entries,
      truncated: false,
      generation: 1,
      cached: false,
    );
  }

  @override
  void invalidate([String? directory]) {}
  @override
  void dispose() {}
}

/// Output reaches the terminal on a timer, so the clock must advance past it and the 180 ms completion debounce.
Future<void> _feed(WidgetTester tester, _Shell shell, String text) async {
  shell.echo(text);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
  await tester.pump();
  await tester.pump();
}

void main() {
  test('asset adapter resolves a command spec before completing its current token', () async {
    final value = await _specs().complete('git st');
    expect(value.available, isTrue);
    expect(value.result.suggestions.map((s) => s.applyTo('git st')), contains('git status'));
  });
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
      completionSpecs: _specs(),
    );
    unawaited(session.connect(NoPrompts()));
    await tester.pump();
    final shell = transport.channels.single;
    shell.echo('u@box:~\$ git st');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();
    await tester.pump();
    final state = session.commandAssistance.value;
    expect(state.candidates.map((c) => c.text), contains('git status '));
    expect(await session.acceptCommand(state.request!, 'git status '), InsertResult.sent);
    expect(shell.writes.join(), 'atus ');
    expect(await session.acceptCommand(state.request!, 'git status '), InsertResult.stale);
    await _feed(tester, shell, 'atus ');
    session.commandSubmitted();
    expect(session.commandHistory.value, ['git status ']);
    await _feed(tester, shell, '\r\nPassword: ');
    session.commandSubmitted();
    expect(session.commandHistory.value, ['git status ']);
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
      completionSpecs: _specs(),
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
      completionSpecs: _specs(),
      completionProvider: provider,
    );
    unawaited(session.connect(NoPrompts()));
    await tester.pump();
    final shell = transport.channels.single;
    shell.echo('u@box:~\$ git');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();
    await tester.pump();
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
      completionSpecs: _specs(),
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
      completionSpecs: _specs(),
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
    await tester.pump();
    await tester.pump();
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
    CompletionTranslations? paneTranslations;
    Directory? translationsDir;

    Future<CompletionTranslations> translations(
      WidgetTester tester,
      _TranslationEngine engine, {
      int maxConcurrent = 32,
    }) async {
      late CompletionTranslations value;
      await tester.runAsync(() async {
        translationsDir = Directory.systemTemp.createTempSync('sshairy-pane-translations-');
        value = CompletionTranslations(
          cacheDirectory: translationsDir!.path,
          engine: engine,
          maxConcurrent: maxConcurrent,
        );
        await value.ready;
      });
      return value;
    }

    Future<void> mountView(
      WidgetTester tester, {
      double scale = 1,
      Locale locale = const Locale('en'),
      bool active = true,
      bool visible = true,
    }) => tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          locale: locale,
          theme: buildTheme(Brightness.light).copyWith(platform: TargetPlatform.windows),
          scrollBehavior: const AppScrollBehavior(),
          builder: (_, child) => InterfaceScale(scale: scale, child: child!),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: SizedBox.expand(
              child: TerminalPane(session, active: active, visible: visible),
            ),
          ),
        ),
      ),
    );

    Future<_Shell> mount(
      WidgetTester tester, {
      double scale = 1,
      CommandCompletionProvider? provider,
      RemotePathSource? paths,
      CompletionTranslations? completionTranslations,
      bool viaProvider = false,
      List<CommandSnippet> Function()? snippets,
      Locale locale = const Locale('en'),
    }) async {
      dir = Directory.systemTemp.createTempSync('sshairy-pane-');
      paneTranslations = completionTranslations;
      if (paneTranslations == null) {
        await tester.runAsync(() async {
          paneTranslations = CompletionTranslations(
            cacheDirectory: dir.path,
            engine: _TranslationEngine(hold: true),
            interval: Duration.zero,
          );
          await paneTranslations!.ready;
        });
      }
      container = ProviderContainer(
        overrides: [
          dataDirProvider.overrideWithValue(dir.path),
          if (viaProvider) completionTranslationsProvider.overrideWithValue(paneTranslations!),
        ],
      );
      transport = _Transport();
      manager = ConnectionManager((_, _, _) async => transport, park: Duration.zero);
      session = TerminalSession(
        const SessionId('s'),
        const Host(id: HostId('h'), label: 'h', address: 'box', username: 'u'),
        manager,
        completionSpecs: _specs(),
        autoConnect: false,
        completionProvider: provider,
        remotePaths: paths,
        completionTranslations: viaProvider ? null : paneTranslations,
        snippets: snippets,
      );
      await mountView(tester, scale: scale, locale: locale);
      unawaited(session.connect(NoPrompts()));
      await tester.pump();
      await tester.pump();
      return transport.channels.single;
    }

    Future<void> saveTranslations(WidgetTester tester, CompletionTranslations service) async {
      var done = false;
      service.saved.then((_) => done = true);
      for (var i = 0; i < 200 && !done; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 1)));
        await tester.pump(const Duration(milliseconds: 1));
      }
      expect(done, isTrue, reason: 'Translation cache save did not settle within 200 async pumps');
    }

    Future<void> unmount(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox.shrink());
      session.close();
      manager.closeAll();
      await tester.pump();
      container.dispose();
      paneTranslations?.dispose();
      if (paneTranslations != null) await saveTranslations(tester, paneTranslations!);
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        dir.deleteSync(recursive: true);
        translationsDir?.deleteSync(recursive: true);
      });
      paneTranslations = null;
      translationsDir = null;
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

    ListView candidateList(WidgetTester tester) => tester.widget<ListView>(
      find.descendant(of: find.byKey(const ValueKey('command-completion-popup')), matching: find.byType(ListView)),
    );

    Set<String> visibleTmuxDescriptions(WidgetTester tester) {
      final list = candidateList(tester);
      final position = list.controller!.position;
      final first = (position.pixels / list.itemExtent!).floor();
      final end = ((position.pixels + position.viewportDimension) / list.itemExtent!).ceil().clamp(
        first,
        session.commandAssistance.value.candidates.length,
      );
      return {for (var i = first; i < end; i++) session.commandAssistance.value.candidates[i].detail!};
    }

    Future<void> drainTranslations(WidgetTester tester) async {
      for (var i = 0; i < 40; i++) {
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump(const Duration(milliseconds: 1));
      }
    }

    testWidgets('popup accepts Tab immediately while Enter submits the actual draft', (tester) async {
      final shell = await mount(tester);
      try {
        await _feed(tester, shell, 'u@box:~\$ git st');
        expect(find.text('status'), findsOneWidget);
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        expect(shell.writes.join(), 'atus ');
        await _feed(tester, shell, 'atus ');
        shell.writes.clear();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        expect(shell.writes.join(), '\r');
        expect(session.commandHistory.value, ['git status ']);
      } finally {
        await unmount(tester);
      }
    });

    testWidgets('shell history arrows keep completion closed until typing or explicitly reopening', (tester) async {
      final shell = await mount(tester);
      final popup = find.byKey(const ValueKey('command-completion-popup'));
      try {
        await _feed(tester, shell, 'u@box:~\$ ');
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        expect(shell.writes.join(), contains('\x1b[A'));
        await _feed(tester, shell, 'git st');
        expect(session.commandAssistance.value.request?.text, 'git st');
        expect(popup, findsNothing);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await _feed(tester, shell, '\r\x1b[2Ku@box:~\$ cat ');
        expect(popup, findsNothing);
        await _feed(tester, shell, '\r\x1b[2Ku@box:~\$ git st');
        await chord(tester, [LogicalKeyboardKey.controlLeft], LogicalKeyboardKey.space);
        await tester.pump();
        await tester.pump();
        expect(popup, findsOneWidget);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await _feed(tester, shell, '\r\x1b[2Ku@box:~\$ git s');
        expect(popup, findsNothing);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyT, character: 't');
        await _feed(tester, shell, 't');
        expect(popup, findsOneWidget);
      } finally {
        await unmount(tester);
      }
    });

    testWidgets('left at the first completion level reaches the shell cursor', (tester) async {
      final shell = await mount(tester);
      try {
        await _feed(tester, shell, 'u@box:~\$ git st');
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
        await tester.pump();
        expect(shell.writes.join(), '\x1b[D');
        expect(find.byKey(const ValueKey('command-completion-popup')), findsNothing);
      } finally {
        await unmount(tester);
      }
    });

    testWidgets('right on a leaf reaches the shell while command branches still browse', (tester) async {
      final shell = await mount(tester);
      try {
        await _feed(tester, shell, 'u@box:~\$ g');
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump();
        await tester.pump();
        expect(session.commandAssistance.value.browse?.depth, 1);
        expect(find.text('status'), findsOneWidget);
        expect(shell.writes, isEmpty);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump();
        expect(shell.writes.join(), '\x1b[C');
        expect(find.byKey(const ValueKey('command-completion-popup')), findsNothing);
      } finally {
        await unmount(tester);
      }
    });

    testWidgets('a root command without browseable children also releases Right to the shell', (tester) async {
      final shell = await mount(tester);
      try {
        await _feed(tester, shell, 'u@box:~\$ d');
        expect(session.commandAssistance.value.candidates.single.preview, isNull);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        expect(shell.writes.join(), '\x1b[C');
        await tester.pump();
        expect(find.byKey(const ValueKey('command-completion-popup')), findsNothing);
      } finally {
        await unmount(tester);
      }
    });

    testWidgets('history navigation cancels late sources and deleting resumes completion', (tester) async {
      final provider = _Provider();
      final shell = await mount(tester, provider: provider);
      final popup = find.byKey(const ValueKey('command-completion-popup'));
      try {
        await _feed(tester, shell, 'u@box:~\$ git st');
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await _feed(tester, shell, '\r\x1b[2Ku@box:~\$ git s');
        provider.pending.single.complete([const CommandCandidate('git status --short')]);
        await tester.pump();
        expect(popup, findsNothing);
        expect(provider.pending, hasLength(1));
        await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
        await _feed(tester, shell, '\b \b');
        expect(popup, findsOneWidget);
        expect(provider.pending, hasLength(2));
        provider.pending.last.complete(const []);
        await tester.pump();
      } finally {
        await unmount(tester);
      }
    });

    testWidgets('late AI candidates preserve the selected command', (tester) async {
      final provider = _Provider();
      final shell = await mount(tester, provider: provider);
      try {
        await _feed(tester, shell, 'u@box:~\$ git st');
        await chord(tester, [LogicalKeyboardKey.controlLeft], LogicalKeyboardKey.space);
        provider.pending.single.complete([const CommandCandidate('git stash list', source: CommandCandidateSource.ai)]);
        await tester.pump();
        await tester.pump();
        expect(session.commandAssistance.value.candidates.first.source, CommandCandidateSource.ai);
        expect(tester.getTopLeft(find.text('git stash list')).dy, lessThan(tester.getTopLeft(find.text('status')).dy));
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        expect(shell.writes.join(), 'atus ');
      } finally {
        await unmount(tester);
      }
    });

    testWidgets('history stays above specification candidates and Tab accepts it first', (tester) async {
      final shell = await mount(tester);
      try {
        await _feed(tester, shell, 'u@box:~\$ git stash list');
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await _feed(tester, shell, '\r\nu@box:~\$ git st');
        shell.writes.clear();
        expect(session.commandAssistance.value.candidates.first.source, CommandCandidateSource.history);
        expect(tester.getTopLeft(find.text('git stash list')).dy, lessThan(tester.getTopLeft(find.text('status')).dy));
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        expect(shell.writes.join(), 'ash list');
      } finally {
        await unmount(tester);
      }
    });

    testWidgets('IME composing owns arrows and Tab while modified arrows still reach the terminal', (tester) async {
      final shell = await mount(tester);
      try {
        await _feed(tester, shell, 'u@box:~\$ git st');
        await chord(tester, [LogicalKeyboardKey.controlLeft], LogicalKeyboardKey.arrowLeft);
        expect(shell.writes, isNotEmpty);
        await _feed(tester, shell, '\r\nu@box:~\$ git st');
        shell.writes.clear();
        final initial = TextEditingValue.fromJSON(tester.testTextInput.editingState!);
        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: 'ni',
            selection: TextSelection.collapsed(offset: 2),
            composing: TextRange(start: 0, end: 2),
          ),
        );
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        expect(shell.writes, isEmpty);
        tester.testTextInput.updateEditingValue(initial);
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        expect(shell.writes.join(), 'atus ');
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
        expect(candidates.length, greaterThan(8));
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
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        expect(shell.writes.join(), candidates.first.text.substring('tmux '.length));
      } finally {
        await unmount(tester);
      }
    });

    testWidgets('path completion waits for an already running working-directory lookup', (tester) async {
      final paths = _Paths();
      final shell = await mount(tester, paths: paths);
      final lookup = Completer<ExecResult>();
      transport.directoryQuery = lookup;
      void follow() {}
      session.directory.addListener(follow);
      try {
        await tester.pump(Duration.zero);
        expect(transport.queries, hasLength(1));
        await _feed(tester, shell, 'u@box:~\$ cat ');
        expect(paths.queries, isEmpty);
        lookup.complete(ExecResult(Uint8List.fromList(utf8.encode('/work\n')), Uint8List(0), 0));
        await tester.pump();
        await tester.pump();
        expect(paths.queries.single.directory, '/work');
        expect(find.text('My Notes/'), findsOneWidget);
        expect(transport.queries, hasLength(1));
      } finally {
        session.directory.removeListener(follow);
        await unmount(tester);
      }
    });

    testWidgets('arrows browse paths virtually and Tab appends a safely escaped selection', (tester) async {
      final paths = _Paths();
      final shell = await mount(tester, paths: paths);
      try {
        await _feed(tester, shell, '\x1b]7;file://box/work\x07u@box:~\$ cat ');
        expect(find.text('My Notes/'), findsOneWidget);
        expect(shell.writes, isEmpty);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump();
        await tester.pump();
        expect(paths.queries.last.directory, '/work/My Notes');
        expect(find.text('中文.txt'), findsOneWidget);
        expect(shell.writes, isEmpty);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
        await tester.pump();
        await tester.pump();
        expect(paths.queries.last.directory, '/work');
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        expect(
          shell.writes.join(),
          r'My\ Notes/中文.txt'
          ' ',
        );
        expect(shell.writes.join(), isNot(contains('\r')));
      } finally {
        await unmount(tester);
      }
    });

    testWidgets('Tab separates completed words but leaves directories and option separators open', (tester) async {
      final shell = await mount(tester, paths: _Paths());
      try {
        await _feed(tester, shell, '\x1b]7;file://box/work\x07u@box:~\$ cat ');
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        expect(shell.writes.join(), r'My\ Notes/');
        shell.writes.clear();
        await _feed(tester, shell, '\r\x1b[2Ku@box:~\$ mk --co');
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        expect(shell.writes.join(), 'lor=');
        shell.writes.clear();
        await _feed(tester, shell, 'lor=a');
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        expect(shell.writes.join(), 'lways ');
        shell.writes.clear();
        await _feed(tester, shell, '\r\x1b[2Ku@box:~\$ cat "read');
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        expect(shell.writes.join(), ' me.txt" ');
        expect(shell.writes.join(), isNot(contains('\r')));
      } finally {
        await unmount(tester);
      }
    });

    testWidgets('Escape dismisses the current draft and Ctrl+Space reopens it', (tester) async {
      final shell = await mount(tester);
      try {
        await _feed(tester, shell, 'u@box:~\$ git st');
        final popup = find.byKey(const ValueKey('command-completion-popup'));
        expect(popup, findsOneWidget);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump();
        expect(popup, findsNothing);
        await chord(tester, [LogicalKeyboardKey.controlLeft], LogicalKeyboardKey.space);
        expect(popup, findsOneWidget);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        expect(shell.writes.join(), 'ash ');
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

    testWidgets('compact descriptions show originals before online results and expose complete hover tips', (
      tester,
    ) async {
      final engine = _TranslationEngine(hold: true);
      final service = await translations(tester, engine);
      final shell = await mount(tester, locale: const Locale('zh'), completionTranslations: service);
      try {
        await _feed(tester, shell, 'u@box:~\$ git st');
        final popup = find.byKey(const ValueKey('command-completion-popup'));
        expect(find.text('Show the working tree status'), findsOneWidget);
        expect(find.text('显示工作区和暂存区状态'), findsNothing);
        await drainTranslations(tester);
        expect(engine.calls.single.original, 'Show the working tree status');
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
        engine.calls.single.result.complete('显示工作区和暂存区状态');
        await drainTranslations(tester);
        final translated = find.text('显示工作区和暂存区状态');
        expect(translated, findsOneWidget);
        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(tester.getSize(popup).width, lessThanOrEqualTo(CompletionSize.width));
        final title = find.text('status');
        final gap = tester.getTopLeft(translated).dx - tester.getTopRight(title).dx;
        expect(gap, closeTo(Space.sm, .1));
        expect(tester.widget<Text>(translated).textAlign, isNot(TextAlign.end));
        final tooltip = find.byTooltip('显示工作区和暂存区状态\nShow the working tree status');
        expect(tooltip, findsOneWidget);
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: Offset.zero);
        await mouse.moveTo(tester.getCenter(translated));
        await tester.pump(const Duration(milliseconds: 600));
        expect(find.text('显示工作区和暂存区状态\nShow the working tree status'), findsOneWidget);
        await mouse.removePointer();
        await tester.pump(const Duration(seconds: 1));
        final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: app.theme,
              locale: const Locale('en'),
              scrollBehavior: app.scrollBehavior,
              builder: app.builder,
              localizationsDelegates: app.localizationsDelegates,
              supportedLocales: app.supportedLocales,
              home: app.home,
            ),
          ),
        );
        await tester.pump();
        expect(find.text('Show the working tree status'), findsOneWidget);
        expect(translated, findsNothing);
        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(engine.calls, hasLength(1));
        expect(shell.writes, isEmpty);
        expect(tester.takeException(), isNull);
      } finally {
        await unmount(tester);
      }
    });

    testWidgets('long command labels keep their explanation close in a narrow pane', (tester) async {
      await tester.binding.setSurfaceSize(const Size(300, 400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final shell = await mount(tester);
      try {
        await _feed(tester, shell, 'u@b:~\$ tmux ');
        final title = find.text('command-0');
        final detail = find.text('tmux action 0');
        expect(title, findsOneWidget);
        expect(detail, findsOneWidget);
        expect(tester.getTopLeft(detail).dx - tester.getTopRight(title).dx, closeTo(Space.sm, .1));
        expect(find.byTooltip('tmux action 0'), findsOneWidget);
        final popup = tester.getRect(find.byKey(const ValueKey('command-completion-popup')));
        final pane = tester.getRect(find.byType(TerminalPane));
        expect(pane.contains(popup.topLeft), isTrue);
        expect(pane.contains(popup.bottomRight), isTrue);
        expect(tester.takeException(), isNull);
      } finally {
        await unmount(tester);
      }
    });

    testWidgets('online descriptions request only intersecting rows and preserve the selected candidate', (
      tester,
    ) async {
      final engine = _TranslationEngine();
      final service = await translations(tester, engine);
      final shell = await mount(tester, locale: const Locale('zh'), completionTranslations: service);
      try {
        await _feed(tester, shell, 'u@box:~\$ tmux ');
        final candidates = session.commandAssistance.value.candidates;
        expect(candidates, hasLength(32));
        final visible = visibleTmuxDescriptions(tester);
        expect(visible.length, allOf(greaterThan(0), lessThan(32)));
        await drainTranslations(tester);
        expect(engine.calls.map((call) => call.original).toSet(), visible);
        expect(engine.calls.every((call) => call.target == 'zh-CN'), isTrue);
        expect(find.byTooltip('译文 tmux action 0\ntmux action 0'), findsOneWidget);
        expect(session.commandAssistance.value.candidates, same(candidates));
        expect(shell.writes, isEmpty);

        final list = candidateList(tester);
        list.controller!.jumpTo(list.controller!.position.maxScrollExtent);
        await tester.pump();
        final next = visibleTmuxDescriptions(tester);
        await drainTranslations(tester);
        expect(engine.calls.map((call) => call.original).toSet(), visible.union(next));
        expect(engine.calls, hasLength(visible.union(next).length));
        expect(session.commandAssistance.value.candidates, same(candidates));
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        expect(shell.writes.join(), candidates.first.text.substring('tmux '.length));
        expect(engine.disposed, isFalse);
      } finally {
        await unmount(tester);
      }
      expect(engine.disposed, isTrue);
    });

    testWidgets('queued and active descriptions retain originals beside bounded loading indicators', (tester) async {
      final engine = _TranslationEngine(hold: true);
      final service = await translations(tester, engine, maxConcurrent: 1);
      final shell = await mount(tester, locale: const Locale('zh'), completionTranslations: service);
      try {
        await _feed(tester, shell, 'u@box:~\$ tmux ');
        await drainTranslations(tester);
        final visible = visibleTmuxDescriptions(tester);
        expect(visible.length, greaterThan(1));
        expect(engine.calls, hasLength(1));
        expect(visible.every((original) => service.isPending(original, 'zh')), isTrue);
        for (final original in visible) {
          final tooltip = find.byTooltip(original);
          expect(find.text(original), findsOneWidget);
          final indicator = find.descendant(of: tooltip, matching: find.byType(CircularProgressIndicator));
          expect(indicator, findsOneWidget);
          expect(tester.getSize(indicator), const Size.square(12));
          final row = find.ancestor(of: tooltip, matching: find.byType(InkWell)).first;
          expect(tester.getRect(indicator).right, lessThanOrEqualTo(tester.getRect(row).right));
          expect(tester.getTopLeft(indicator).dx - tester.getTopRight(find.text(original)).dx, closeTo(Space.xs, .1));
        }
        final first = engine.calls.single;
        first.result.complete('排队完成的说明');
        await drainTranslations(tester);
        expect(service.isPending(first.original, 'zh'), isFalse);
        expect(find.byTooltip('排队完成的说明\n${first.original}'), findsOneWidget);
        expect(
          find.descendant(
            of: find.byTooltip('排队完成的说明\n${first.original}'),
            matching: find.byType(CircularProgressIndicator),
          ),
          findsNothing,
        );
        expect(engine.calls, hasLength(2));
        expect(engine.calls.last.cancel.isCancelled, isFalse);
        expect(shell.writes, isEmpty);
        expect(tester.takeException(), isNull);
      } finally {
        await unmount(tester);
      }
    });

    testWidgets('a failed translation keeps its original and clears active and queued loading indicators', (
      tester,
    ) async {
      final engine = _TranslationEngine(hold: true);
      final service = await translations(tester, engine, maxConcurrent: 1);
      final shell = await mount(tester, locale: const Locale('zh'), completionTranslations: service);
      try {
        await _feed(tester, shell, 'u@box:~\$ tmux ');
        await drainTranslations(tester);
        expect(find.byType(CircularProgressIndicator), findsWidgets);
        engine.calls.single.result.complete(null);
        await drainTranslations(tester);
        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(find.text('tmux action 0'), findsOneWidget);
        expect(find.byTooltip('tmux action 0'), findsOneWidget);
        expect(find.text('子命令'), findsNothing);
        expect(engine.calls, hasLength(1));
        expect(visibleTmuxDescriptions(tester).every((original) => !service.isPending(original, 'zh')), isTrue);
        expect(shell.writes, isEmpty);
      } finally {
        await unmount(tester);
      }
    });

    testWidgets('online descriptions keep stable demand while individual translations finish', (tester) async {
      final engine = _TranslationEngine(hold: true);
      final service = await translations(tester, engine);
      final shell = await mount(tester, locale: const Locale('zh'), completionTranslations: service);
      try {
        await _feed(tester, shell, 'u@box:~\$ tmux ');
        await drainTranslations(tester);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump();
        final visible = visibleTmuxDescriptions(tester);
        expect(engine.calls.map((call) => call.original).toSet(), visible);
        expect(engine.calls.length, greaterThan(1));
        final first = engine.calls.first;
        expect(first.original, 'tmux action 0');
        first.result.complete('在线说明');
        await drainTranslations(tester);
        await tester.pump();
        await tester.pump();
        await tester.pump();
        expect(find.byTooltip('在线说明\ntmux action 0'), findsOneWidget);
        expect(engine.calls, hasLength(visible.length));
        expect(engine.calls.skip(1).every((call) => !call.cancel.isCancelled), isTrue);
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        expect(shell.writes.join(), 'command-1 ');
      } finally {
        await unmount(tester);
      }
    });

    for (final change in ['locale', 'setting', 'hidden', 'inactive', 'focus', 'search', 'dismiss', 'dispose']) {
      testWidgets('$change cancels obsolete visible translation demand without disposing the service', (tester) async {
        final engine = _TranslationEngine(hold: true);
        final service = await translations(tester, engine);
        final shell = await mount(tester, locale: const Locale('zh'), completionTranslations: service);
        try {
          await _feed(tester, shell, 'u@box:~\$ tmux ');
          await drainTranslations(tester);
          final calls = engine.calls.toList();
          expect(calls.length, greaterThan(1));
          expect(find.byType(CircularProgressIndicator), findsWidgets);
          switch (change) {
            case 'locale':
              await mountView(tester, locale: const Locale('en'));
            case 'setting':
              await tester.runAsync(
                () => container.read(settingsProvider.notifier).set(SettingKeys.completionTranslation, false),
              );
            case 'hidden':
              await mountView(tester, locale: const Locale('zh'), visible: false);
            case 'inactive':
              await mountView(tester, locale: const Locale('zh'), active: false);
            case 'focus':
              tester.widget<TerminalView>(find.byType(TerminalView)).focusNode!.unfocus();
            case 'search':
              await chord(tester, [
                LogicalKeyboardKey.controlLeft,
                LogicalKeyboardKey.shiftLeft,
              ], LogicalKeyboardKey.keyF);
            case 'dismiss':
              await tester.sendKeyEvent(LogicalKeyboardKey.escape);
            case 'dispose':
              await tester.pumpWidget(const SizedBox.shrink());
          }
          await tester.pump();
          await tester.pump();
          expect(calls.every((call) => call.cancel.isCancelled), isTrue);
          expect(engine.disposed, isFalse);
          expect(find.byType(CircularProgressIndicator), findsNothing);
          for (final call in calls) {
            call.result.complete('迟到的说明');
          }
          await drainTranslations(tester);
          expect(engine.calls, hasLength(calls.length));
          expect(find.text('迟到的说明'), findsNothing);
          expect(calls.every((call) => service.lookup(call.original, 'zh') == null), isTrue);
          expect(shell.writes.where((text) => text != '\x1b'), isEmpty);
          if (change == 'hidden' || change == 'inactive') {
            await _feed(tester, shell, '\r\nu@box:~\$ tmux command-');
            await drainTranslations(tester);
            expect(engine.calls, hasLength(calls.length));
          }
        } finally {
          await unmount(tester);
        }
      });
    }

    testWidgets('hiding one pane retains a shared translation requested by another owner', (tester) async {
      final engine = _TranslationEngine(hold: true);
      final service = await translations(tester, engine);
      final shell = await mount(tester, locale: const Locale('zh'), completionTranslations: service);
      final other = CancellationToken();
      try {
        await _feed(tester, shell, 'u@box:~\$ tmux ');
        await drainTranslations(tester);
        final first = engine.calls.first;
        final count = engine.calls.length;
        final shared = service.translate(first.original, 'zh', cancel: other);
        await drainTranslations(tester);
        expect(engine.calls, hasLength(count));
        expect(first.cancel.isCancelled, isFalse);
        await mountView(tester, locale: const Locale('zh'), visible: false);
        await drainTranslations(tester);
        expect(first.cancel.isCancelled, isFalse);
        expect(engine.calls.skip(1).every((call) => call.cancel.isCancelled), isTrue);
        expect(find.byType(CircularProgressIndicator), findsNothing);
        first.result.complete('另一窗口仍需要的说明');
        await drainTranslations(tester);
        expect(await shared, '另一窗口仍需要的说明');
        expect(service.lookup(first.original, 'zh'), '另一窗口仍需要的说明');
        expect(shell.writes, isEmpty);
      } finally {
        other.cancel();
        await unmount(tester);
      }
    });

    testWidgets('scrolling cancels obsolete rows and requests only the next visible demand', (tester) async {
      final engine = _TranslationEngine(hold: true);
      final service = await translations(tester, engine);
      final shell = await mount(tester, locale: const Locale('zh'), completionTranslations: service);
      try {
        await _feed(tester, shell, 'u@box:~\$ tmux ');
        await drainTranslations(tester);
        final previous = engine.calls.toList();
        final list = candidateList(tester);
        list.controller!.jumpTo(list.controller!.position.maxScrollExtent);
        await tester.pump();
        final visible = visibleTmuxDescriptions(tester);
        await drainTranslations(tester);
        expect(previous.every((call) => call.cancel.isCancelled), isTrue);
        final current = engine.calls.skip(previous.length).toList();
        expect(current.map((call) => call.original).toSet(), visible);
        expect(current.every((call) => !call.cancel.isCancelled), isTrue);
        for (final call in current) {
          call.result.complete('译文 ${call.original}');
        }
        await drainTranslations(tester);
        expect(engine.calls, hasLength(previous.length + visible.length));
        expect(engine.disposed, isFalse);
      } finally {
        await unmount(tester);
      }
    });

    testWidgets('switching the shared translation provider cancels its old pending demand', (tester) async {
      final engine = _TranslationEngine(hold: true);
      final original = await translations(tester, engine);
      final shell = await mount(
        tester,
        locale: const Locale('zh'),
        completionTranslations: original,
        viaProvider: true,
      );
      final replacementEngine = _TranslationEngine(hold: true);
      late CompletionTranslations replacement;
      await tester.runAsync(() async {
        replacement = CompletionTranslations(
          cacheDirectory: translationsDir!.path,
          engine: replacementEngine,
          interval: Duration.zero,
        );
        await replacement.ready;
      });
      try {
        await _feed(tester, shell, 'u@box:~\$ tmux ');
        await drainTranslations(tester);
        final oldCalls = engine.calls.toList();
        final candidates = session.commandAssistance.value.candidates;
        container.updateOverrides([
          dataDirProvider.overrideWithValue(dir.path),
          completionTranslationsProvider.overrideWithValue(replacement),
        ]);
        await drainTranslations(tester);
        expect(oldCalls.every((call) => call.cancel.isCancelled), isTrue);
        expect(engine.disposed, isFalse);
        expect(replacementEngine.calls.length, greaterThan(1));
        expect(replacementEngine.calls.every((call) => !call.cancel.isCancelled), isTrue);
        oldCalls.first.result.complete('旧服务说明');
        replacementEngine.calls.first.result.complete('新服务说明');
        await drainTranslations(tester);
        expect(find.byTooltip('新服务说明\ntmux action 0'), findsOneWidget);
        expect(find.text('旧服务说明'), findsNothing);
        expect(session.commandAssistance.value.candidates, same(candidates));
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        expect(shell.writes.join(), candidates.first.text.substring('tmux '.length));
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        replacement.dispose();
        await saveTranslations(tester, replacement);
        await unmount(tester);
      }
    });

    testWidgets('turning online translation off preserves cached explanations', (tester) async {
      final engine = _TranslationEngine();
      final service = await translations(tester, engine);
      final shell = await mount(tester, locale: const Locale('zh'), completionTranslations: service);
      try {
        await _feed(tester, shell, 'u@box:~\$ tmux ');
        await drainTranslations(tester);
        final count = engine.calls.length;
        await tester.runAsync(
          () => container.read(settingsProvider.notifier).set(SettingKeys.completionTranslation, false),
        );
        await tester.pump();
        await tester.pump();
        expect(find.byTooltip('译文 tmux action 0\ntmux action 0'), findsOneWidget);
        final list = candidateList(tester);
        list.controller!.jumpTo(list.controller!.position.maxScrollExtent);
        await drainTranslations(tester);
        expect(engine.calls, hasLength(count));
        final original = visibleTmuxDescriptions(tester).first;
        expect(find.text(original), findsOneWidget);
        expect(find.byTooltip(original), findsOneWidget);
        expect(find.text('子命令'), findsNothing);
        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(shell.writes, isEmpty);
      } finally {
        await unmount(tester);
      }
    });

    testWidgets('an asynchronously loaded cache updates explanations without requesting translation', (tester) async {
      final seedEngine = _TranslationEngine();
      final seed = await translations(tester, seedEngine);
      unawaited(seed.translate('tmux action 30', 'zh'));
      unawaited(seed.translate('tmux action 31', 'zh'));
      await drainTranslations(tester);
      await saveTranslations(tester, seed);
      seed.dispose();
      await saveTranslations(tester, seed);
      final engine = _TranslationEngine(hold: true);
      late CompletionTranslations service;
      await tester.runAsync(() async {
        service = CompletionTranslations(
          cacheDirectory: translationsDir!.path,
          engine: engine,
          interval: Duration.zero,
        );
        await service.ready;
      });
      final shell = await mount(tester, locale: const Locale('zh'), completionTranslations: service);
      try {
        await _feed(tester, shell, 'u@box:~\$ tmux command-3');
        await tester.runAsync(() => service.ready);
        await tester.pump();
        expect(find.byTooltip('译文 tmux action 30\ntmux action 30'), findsOneWidget);
        expect(engine.calls, isEmpty);
        expect(shell.writes, isEmpty);
      } finally {
        await unmount(tester);
      }
    });

    testWidgets('provider source flags and colliding identities cannot authorize private descriptions', (tester) async {
      final engine = _TranslationEngine();
      final service = await translations(tester, engine);
      final provider = _Provider();
      final shell = await mount(
        tester,
        locale: const Locale('zh'),
        completionTranslations: service,
        provider: provider,
      );
      try {
        await _feed(tester, shell, 'u@box:~\$ tmux ');
        final bundled = session.commandAssistance.value.candidates.first;
        final collision = CommandCandidate(
          bundled.text,
          source: CommandCandidateSource.builtin,
          kind: bundled.kind,
          detail: 'private collision text',
        );
        expect(collision.identity, bundled.identity);
        provider.pending.single.complete([
          collision,
          const CommandCandidate(
            'tmux private-forged',
            source: CommandCandidateSource.builtin,
            kind: CommandKind.subcommand,
            detail: 'private forged builtin text',
          ),
          const CommandCandidate('tmux private-provider', detail: 'private provider text'),
          const CommandCandidate('tmux private-ai', source: CommandCandidateSource.ai, detail: 'private AI text'),
        ]);
        await tester.pump();
        await tester.pump();
        expect(session.commandAssistance.value.candidates, contains(bundled));
        expect(session.commandAssistance.value.candidates, isNot(contains(collision)));
        await drainTranslations(tester);
        // The merged collision cannot exercise provenance; the distinct forged object must remain visible too.
        final list = candidateList(tester);
        list.controller!.jumpTo(list.controller!.position.maxScrollExtent);
        await tester.pump();
        await drainTranslations(tester);
        expect(find.text('tmux private-forged').hitTestable(), findsOneWidget);
        expect(find.text('tmux private-provider').hitTestable(), findsOneWidget);
        expect(
          session.commandAssistance.value.candidates.map((candidate) => candidate.text),
          contains('tmux private-ai'),
        );
        expect(engine.calls, isNotEmpty);
        expect(engine.calls.every((call) => call.original.startsWith('tmux action ')), isTrue);
        expect(engine.calls.any((call) => call.original.contains('private')), isFalse);
        expect(shell.writes, isEmpty);
      } finally {
        await unmount(tester);
      }
    });

    testWidgets('history snippets paths and external providers send no translation text', (tester) async {
      final engine = _TranslationEngine();
      final service = await translations(tester, engine);
      final provider = _Provider();
      final paths = _Paths();
      final shell = await mount(
        tester,
        locale: const Locale('zh'),
        completionTranslations: service,
        provider: provider,
        paths: paths,
        snippets: () => const [CommandSnippet('private snippet command', 'private snippet label')],
      );
      try {
        await _feed(tester, shell, 'u@box:~\$ private history command');
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await _feed(tester, shell, '\r\nu@box:~\$ private');
        provider.pending.last.complete(const [
          CommandCandidate('private provider', detail: 'provider secret'),
          CommandCandidate('private AI', source: CommandCandidateSource.ai, detail: 'AI secret'),
          CommandCandidate(
            'private forged builtin',
            source: CommandCandidateSource.builtin,
            detail: 'forged builtin secret',
          ),
        ]);
        await tester.pump();
        await tester.pump();
        final candidates = session.commandAssistance.value.candidates;
        expect(
          candidates.map((candidate) => candidate.source),
          containsAll([
            CommandCandidateSource.history,
            CommandCandidateSource.snippet,
            CommandCandidateSource.provider,
            CommandCandidateSource.ai,
            CommandCandidateSource.builtin,
          ]),
        );
        await drainTranslations(tester);
        expect(engine.calls, isEmpty);
        await _feed(tester, shell, '\r\nu@box:~\$ cat /work/');
        expect(paths.queries, isNotEmpty);
        expect(
          session.commandAssistance.value.candidates.map((candidate) => candidate.source),
          contains(CommandCandidateSource.path),
        );
        await drainTranslations(tester);
        expect(engine.calls, isEmpty);
        expect(shell.writes.join(), '\r');
      } finally {
        for (final pending in provider.pending) {
          if (!pending.isCompleted) pending.complete(const []);
        }
        await tester.pump();
        await unmount(tester);
      }
    });

    testWidgets('Chinese category labels appear only when a specification has no description', (tester) async {
      final engine = _TranslationEngine(hold: true);
      final service = await translations(tester, engine);
      final shell = await mount(tester, locale: const Locale('zh'), completionTranslations: service);
      try {
        await _feed(tester, shell, 'u@box:~\$ git st');
        expect(find.text('Show the working tree status'), findsOneWidget);
        expect(find.text('子命令'), findsOneWidget);
        await drainTranslations(tester);
        expect(engine.calls.single.original, 'Show the working tree status');
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
        expect(shell.writes, isEmpty);
      } finally {
        await unmount(tester);
      }
    });

    testWidgets('an available original takes precedence over a catalog explanation without authorizing translation', (
      tester,
    ) async {
      final engine = _TranslationEngine();
      final service = await translations(tester, engine);
      final provider = _Provider();
      final shell = await mount(
        tester,
        locale: const Locale('zh'),
        completionTranslations: service,
        provider: provider,
      );
      try {
        await _feed(tester, shell, 'u@box:~\$ private');
        provider.pending.single.complete(const [
          CommandCandidate(
            'private-original',
            source: CommandCandidateSource.builtin,
            description: CommandDescription.toolTmux,
            detail: 'Exact original English explanation',
          ),
        ]);
        await tester.pump();
        await tester.pump();
        expect(find.text('Exact original English explanation'), findsOneWidget);
        expect(find.byTooltip('Exact original English explanation'), findsOneWidget);
        await drainTranslations(tester);
        expect(engine.calls, isEmpty);
        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(shell.writes, isEmpty);
      } finally {
        await unmount(tester);
      }
    });

    testWidgets('packaged root descriptions use online history and never a bundled translation', (tester) async {
      final engine = _TranslationEngine(hold: true);
      final service = await translations(tester, engine);
      final shell = await mount(tester, locale: const Locale('zh'), completionTranslations: service);
      try {
        await _feed(tester, shell, 'u@box:~\$ gi');
        expect(find.text('Distributed version control system'), findsOneWidget);
        expect(find.text('分布式版本控制工具'), findsNothing);
        await drainTranslations(tester);
        expect(engine.calls.single.original, 'Distributed version control system');
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
        engine.calls.single.result.complete('在线版本控制说明');
        await drainTranslations(tester);
        expect(find.byTooltip('在线版本控制说明\nDistributed version control system'), findsOneWidget);
        expect(find.byType(CircularProgressIndicator), findsNothing);
      } finally {
        await unmount(tester);
      }
    });

    testWidgets('untranslated specification explanations display their original with a complete tooltip', (
      tester,
    ) async {
      final shell = await mount(tester, locale: const Locale('zh'));
      try {
        await _feed(tester, shell, 'u@box:~\$ tmux command-0');
        await _feed(tester, shell, '\b \b');
        expect(find.text('tmux action 0'), findsOneWidget);
        expect(find.text('子命令'), findsNothing);
        expect(find.byTooltip('tmux action 0'), findsOneWidget);
        expect(
          tester.getSize(find.byKey(const ValueKey('command-completion-popup'))).width,
          lessThan(CompletionSize.width),
        );
        expect(tester.takeException(), isNull);
      } finally {
        await unmount(tester);
      }
    });

    for (final scale in [1.0, 1.5]) {
      testWidgets('completion reserves one scrollbar gutter and no extra trailing row padding at $scale scale', (
        tester,
      ) async {
        await tester.binding.setSurfaceSize(const Size(1200, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final shell = await mount(tester, scale: scale);
        try {
          await _feed(tester, shell, 'u@box:~\$ tmux ');
          await tester.pump();
          await tester.pump();
          final popup = find.byKey(const ValueKey('command-completion-popup'));
          final scrollbar = find.descendant(of: popup, matching: find.byType(Scrollbar));
          final viewport = find.descendant(of: popup, matching: find.byType(ShrinkWrappingViewport));
          final row = find.ancestor(of: find.text('tmux action 0'), matching: find.byType(InkWell)).first;
          final detailRow = find.ancestor(of: find.text('tmux action 0'), matching: find.byType(Tooltip)).first;
          final list = candidateList(tester);
          expect(list.controller!.position.maxScrollExtent, greaterThan(0));
          expect(scrollbar, findsOneWidget);
          expect(viewport, findsOneWidget);
          expect(
            tester.getRect(scrollbar).right - tester.getRect(viewport).right,
            closeTo(ScrollSize.gutter * scale, .1),
          );
          expect(tester.getRect(row).right, closeTo(tester.getRect(viewport).right, .1));
          expect(tester.getRect(detailRow).right, closeTo(tester.getRect(row).right, .1));

          await _feed(tester, shell, '\r\x1b[2Ku@box:~\$ tmux command-3');
          await tester.pump();
          await tester.pump();
          final shortList = candidateList(tester);
          expect(session.commandAssistance.value.candidates, hasLength(2));
          expect(shortList.controller!.position.maxScrollExtent, 0);
          final shortScrollbar = find.descendant(of: popup, matching: find.byType(Scrollbar));
          final shortViewport = find.descendant(of: popup, matching: find.byType(ShrinkWrappingViewport));
          final shortRow = find.ancestor(of: find.text('tmux action 30'), matching: find.byType(InkWell)).first;
          final shortDetail = find.ancestor(of: find.text('tmux action 30'), matching: find.byType(Tooltip)).first;
          expect(tester.getRect(shortScrollbar).right, closeTo(tester.getRect(shortViewport).right, .1));
          expect(tester.getRect(shortRow).right - tester.getRect(shortDetail).right, closeTo(Space.sm * scale, .1));
          expect(tester.takeException(), isNull);
        } finally {
          await unmount(tester);
        }
      });

      testWidgets('directory completion keeps its arrow beside one compact scrollbar at $scale scale', (tester) async {
        await tester.binding.setSurfaceSize(const Size(1200, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final paths = _Paths(
          entries: [
            for (var i = 0; i < 24; i++) RemotePathEntry('folder-$i', RemotePathKind.directory, '/work/folder-$i'),
          ],
        );
        final shell = await mount(tester, scale: scale, paths: paths);
        try {
          await _feed(tester, shell, '\x1b]7;file://box/work\x07u@box:~\$ cat ');
          await tester.pump();
          await tester.pump();
          final popup = find.byKey(const ValueKey('command-completion-popup'));
          final scrollbar = find.descendant(of: popup, matching: find.byType(Scrollbar));
          final viewport = find.descendant(of: popup, matching: find.byType(ShrinkWrappingViewport));
          final row = find.ancestor(of: find.text('folder-0/'), matching: find.byType(InkWell)).first;
          final arrow = find.descendant(of: row, matching: find.byIcon(Icons.chevron_right));
          expect(candidateList(tester).controller!.position.maxScrollExtent, greaterThan(0));
          final barRight = tester.getRect(scrollbar).right;
          final rowRight = tester.getRect(row).right;
          expect(barRight - tester.getRect(viewport).right, closeTo(ScrollSize.gutter * scale, .1));
          expect(rowRight, closeTo(tester.getRect(viewport).right, .1));
          expect(tester.getRect(arrow).right, closeTo(rowRight, .1));
          expect(barRight - ScrollSize.thumb * scale - rowRight, closeTo(Space.xs * scale, .1));
          expect(shell.writes, isEmpty);
          expect(tester.takeException(), isNull);
        } finally {
          await unmount(tester);
        }
      });

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
          await _feed(tester, shell, '\x1b[2J\x1b[Hu@${List.filled(scale == 1 ? 25 : 14, 'b').join()}:~\$ git s');
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

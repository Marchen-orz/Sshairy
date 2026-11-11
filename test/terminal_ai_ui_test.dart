import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/design/theme.dart';
import 'package:sshairy/features/connections/api.dart';
import 'package:sshairy/features/hosts/api.dart';
import 'package:sshairy/features/terminal/api.dart';
import 'package:sshairy/features/terminal/adapters/completion_specs.dart';
import 'package:sshairy/features/terminal/domain/ai_intent.dart';
import 'package:sshairy/foundation/cancellation.dart';
import 'package:sshairy/foundation/data_dir.dart';
import 'package:sshairy/foundation/ids.dart';
import 'package:sshairy/l10n/app_localizations.dart';

import 'connection_manager_test.dart' show FakeTransport, NoPrompts;

class _Shell implements ShellChannel {
  final output = StreamController<Uint8List>();
  final ended = Completer<void>();
  final writes = <String>[];
  void echo(String value) => output.add(Uint8List.fromList(utf8.encode(value)));
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
    ended.complete();
    unawaited(output.close());
  }
}

class _Transport extends FakeTransport {
  final shell = _Shell();
  var queries = 0;
  @override
  Future<ExecResult> exec(String command, {int limit = 0, Duration? timeout, CancellationToken? cancel}) async {
    queries++;
    return ExecResult(Uint8List(0), Uint8List(0), 0);
  }

  @override
  Future<ShellChannel> openShell({
    required int cols,
    required int rows,
    Map<String, String> environment = const {},
  }) async => shell;
}

class _Assets extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async => ByteData.sublistView(
    Uint8List.fromList(
      utf8.encode(
        jsonEncode(
          key.endsWith('manifest.json')
              ? {
                  'commands': {'git': 'git.json'},
                }
              : {
                  'name': 'git',
                  'subcommands': [
                    {'name': 'status'},
                    {'name': 'stash'},
                  ],
                },
        ),
      ),
    ),
  );
}

class _Ai implements TerminalAiService {
  bool enabled = true;
  final changed = StreamController<void>.broadcast(sync: true);
  final completions = <Completer<String?>>[];
  final completionTokens = <CancellationToken>[];
  final generations = <Completer<TerminalAiGeneration>>[];
  final generationTokens = <CancellationToken>[];
  final history = <List<TerminalAiHistoryEntry>>[];
  @override
  bool canGenerate(TerminalAiContext context) => enabled && context.ready;
  @override
  bool canComplete(TerminalAiContext context) =>
      enabled && context.ready && context.draft?.startsWith('git st') == true;
  @override
  Stream<void> get changes => changed.stream;
  @override
  Future<String?> complete(TerminalAiContext context, List<TerminalAiHistoryEntry> history, CancellationToken cancel) {
    this.history.add(history);
    completionTokens.add(cancel);
    final result = Completer<String?>();
    completions.add(result);
    return result.future;
  }

  @override
  Future<TerminalAiGeneration> generate(
    TerminalAiContext context,
    String instruction,
    CancellationToken cancel, {
    List<TerminalAiHistoryEntry> history = const [],
  }) {
    this.history.add(history);
    generationTokens.add(cancel);
    final result = Completer<TerminalAiGeneration>();
    generations.add(result);
    return result.future;
  }
}

void main() {
  test('local intent detection leaves command arguments and unknown aliases alone', () {
    for (final value in ['echo 查看磁盘', 'git status', './查看磁盘', '中文/文件', 'myalias 中文']) {
      expect(terminalInputIntent(value), isNot(TerminalInputIntent.naturalLanguage), reason: value);
    }
    expect(terminalInputIntent('请帮我查看磁盘空间'), TerminalInputIntent.naturalLanguage);
    expect(terminalInputIntent('show me disk usage'), TerminalInputIntent.naturalLanguage);
    expect(terminalInputIntent('unfamiliar'), TerminalInputIntent.uncertain);
  });

  late Directory dir;
  late ProviderContainer container;
  late _Ai ai;
  late _Transport transport;
  late ConnectionManager manager;
  late TerminalSession session;
  String? handedOff;

  Future<void> view(WidgetTester tester, {bool active = true}) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildTheme(Brightness.light).copyWith(platform: TargetPlatform.windows),
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: TerminalPane(session, active: active, onAskAgent: (goal) => handedOff = goal),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> feed(WidgetTester tester, String value) async {
    transport.shell.echo(value);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 220));
    await tester.pump();
    await tester.pump();
  }

  Future<void> mount(WidgetTester tester, String draft) async {
    dir = Directory.systemTemp.createTempSync('sshairy-ai-ui-');
    ai = _Ai();
    handedOff = null;
    container = ProviderContainer(
      overrides: [dataDirProvider.overrideWithValue(dir.path), terminalAiServiceProvider.overrideWithValue(ai)],
    );
    transport = _Transport();
    manager = ConnectionManager((_, _, _) async => transport, park: Duration.zero);
    session = TerminalSession(
      const SessionId('s'),
      const Host(id: HostId('h'), label: 'host', address: 'box', username: 'u'),
      manager,
      autoConnect: false,
      completionSpecs: CompletionSpecs(bundle: _Assets()),
    );
    await view(tester);
    unawaited(session.connect(NoPrompts()));
    await tester.pump();
    await feed(tester, 'u@box:~\$ $draft');
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      session.close();
      manager.closeAll();
      for (final result in ai.completions) {
        if (!result.isCompleted) result.complete(null);
      }
      for (final result in ai.generations) {
        if (!result.isCompleted) {
          result.complete(const TerminalAiGeneration(TerminalAiGenerationKind.clarify, message: 'Cancelled'));
        }
      }
      await tester.pump();
      container.dispose();
      await ai.changed.close();
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        dir.deleteSync(recursive: true);
      });
    });
  }

  testWidgets('late AI goes first while Tab retains the previously selected local candidate', (tester) async {
    await mount(tester, 'git st');
    await tester.pump(const Duration(milliseconds: 850));
    expect(ai.completions, hasLength(1));
    ai.completions.single.complete('git stash');
    await tester.pump();
    await tester.pump();
    expect(find.text('git stash'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(transport.shell.writes.join(), 'atus ');
    expect(tester.takeException(), isNull);
  });

  testWidgets('explicit AI selection appends exact suffix without space or Enter', (tester) async {
    await mount(tester, 'git st');
    await tester.pump(const Duration(milliseconds: 850));
    ai.completions.single.complete('git stash');
    await tester.pump();
    await tester.pump();
    await tester.tap(find.text('git stash'));
    await tester.pump();
    expect(transport.shell.writes, ['ash']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('IME begins during a request cancels it and a late result cannot appear', (tester) async {
    await mount(tester, 'git st');
    await tester.pump(const Duration(milliseconds: 850));
    expect(ai.completions, hasLength(1));
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'ni',
        selection: TextSelection.collapsed(offset: 2),
        composing: TextRange(start: 0, end: 2),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(ai.completionTokens.single.isCancelled, isTrue);
    ai.completions.single.complete('git stash');
    await tester.pump();
    await tester.pump();
    expect(find.text('git stash'), findsNothing);
    expect(transport.shell.writes, isEmpty);
  });

  testWidgets('changing draft and hiding the pane invalidate suggestions', (tester) async {
    await mount(tester, 'git st');
    await tester.pump(const Duration(milliseconds: 850));
    await feed(tester, 'a');
    expect(ai.completionTokens.first.isCancelled, isTrue);
    ai.completions.first.complete('git status');
    await tester.pump();
    expect(find.text('git status'), findsNothing);
    await tester.pump(const Duration(milliseconds: 850));
    await view(tester, active: false);
    expect(ai.completionTokens.last.isCancelled, isTrue);
  });

  testWidgets('inline generation passes same-session history without directory probes', (tester) async {
    await mount(tester, 'git status');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await feed(tester, '\r\nOn branch main\r\nu@box:~\$ ');
    await tester.tap(find.byKey(const ValueKey('terminal-ai-toggle')));
    await tester.pump();
    await tester.enterText(find.byKey(const ValueKey('terminal-ai-instruction')), 'Show recent changes');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('terminal-ai-generate')));
    await tester.pump();
    expect(ai.generations, hasLength(1));
    expect(ai.history.last.map((entry) => entry.text), contains('git status'));
    expect(transport.queries, 0);
  });

  testWidgets('inline local editor previews and inserts only into an empty prompt without executing', (tester) async {
    await mount(tester, '');
    await tester.tap(find.byKey(const ValueKey('terminal-ai-toggle')));
    await tester.pump();
    await tester.enterText(find.byKey(const ValueKey('terminal-ai-instruction')), 'Show current directory');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('terminal-ai-generate')));
    await tester.pump();
    expect(ai.generations, hasLength(1));
    expect(transport.shell.writes, isEmpty);
    ai.generations.single.complete(const TerminalAiGeneration(TerminalAiGenerationKind.command, command: 'pwd'));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('terminal-ai-accept')));
    await tester.pump();
    expect(transport.shell.writes, ['pwd']);
    expect(find.byKey(const ValueKey('terminal-ai-composer')), findsNothing);
  });

  testWidgets('the inline generation shortcut opens the composer on a draft and starts generation', (tester) async {
    await mount(tester, 'show disk usage');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('terminal-ai-composer')), findsOneWidget);
    expect(ai.generations, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('opening inline AI from the button generates from the existing draft', (tester) async {
    await mount(tester, 'show disk usage');
    await tester.tap(find.byKey(const ValueKey('terminal-ai-toggle')));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('terminal-ai-composer')), findsOneWidget);
    expect(ai.generations, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('inline with remote text cannot replace it and retained preview can be accepted after clearing', (
    tester,
  ) async {
    await mount(tester, '请查看磁盘');
    await tester.tap(find.byKey(const ValueKey('terminal-ai-toggle')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('terminal-ai-generate')));
    await tester.pump();
    ai.generations.single.complete(const TerminalAiGeneration(TerminalAiGenerationKind.command, command: 'df -h'));
    await tester.pump();
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('terminal-ai-accept'))).onPressed, isNull);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await feed(tester, '\r\x1b[2Ku@box:~\$ ');
    await tester.tap(find.byKey(const ValueKey('terminal-ai-toggle')));
    await tester.pump();
    await tester.pump();
    expect(tester.widget<TextField>(find.byKey(const ValueKey('terminal-ai-command'))).controller!.text, 'df -h');
    await tester.tap(find.byKey(const ValueKey('terminal-ai-accept')));
    await tester.pump();
    expect(transport.shell.writes, ['df -h']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('AI context observes known directory changes without starting remote probes', (tester) async {
    await mount(tester, '');
    await tester.pump(const Duration(seconds: 2));
    expect(transport.queries, 0);
    await tester.tap(find.byKey(const ValueKey('terminal-ai-toggle')));
    await tester.pump();
    await tester.enterText(find.byKey(const ValueKey('terminal-ai-instruction')), 'Show directory');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('terminal-ai-generate')));
    await tester.pump();
    await feed(tester, '\x1b]7;file://box/srv/new\x07');
    expect(ai.generationTokens.single.isCancelled, isTrue);
    expect(transport.queries, 0);
    ai.generations.single.complete(const TerminalAiGeneration(TerminalAiGenerationKind.command, command: 'pwd'));
    await tester.pump();
    expect(find.byKey(const ValueKey('terminal-ai-accept')), findsNothing);
  });

  testWidgets('complex inline result transfers only the explicit instruction when clicked', (tester) async {
    await mount(tester, '');
    await tester.tap(find.byKey(const ValueKey('terminal-ai-toggle')));
    await tester.pump();
    await tester.enterText(find.byKey(const ValueKey('terminal-ai-instruction')), 'Investigate service health');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('terminal-ai-generate')));
    await tester.pump();
    ai.generations.single.complete(
      const TerminalAiGeneration(TerminalAiGenerationKind.useAgent, message: 'Needs several steps'),
    );
    await tester.pump();
    expect(handedOff, isNull);
    await tester.tap(find.byKey(const ValueKey('terminal-ai-agent')));
    await tester.pump();
    expect(handedOff, 'Investigate service health');
    expect(transport.shell.writes, isEmpty);
    expect(find.byKey(const ValueKey('terminal-ai-composer')), findsNothing);
  });

  testWidgets('revoking model policy closes local editor and cancels generation', (tester) async {
    await mount(tester, '');
    await tester.tap(find.byKey(const ValueKey('terminal-ai-toggle')));
    await tester.pump();
    await tester.enterText(find.byKey(const ValueKey('terminal-ai-instruction')), 'Show directory');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('terminal-ai-generate')));
    await tester.pump();
    ai.enabled = false;
    ai.changed.add(null);
    await tester.pump();
    expect(ai.generationTokens.single.isCancelled, isTrue);
    ai.generations.single.complete(const TerminalAiGeneration(TerminalAiGenerationKind.command, command: 'pwd'));
    await tester.pump();
    expect(find.byKey(const ValueKey('terminal-ai-composer')), findsNothing);
    expect(transport.shell.writes, isEmpty);
  });
}

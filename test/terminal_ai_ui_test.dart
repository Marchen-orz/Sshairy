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
  bool enabled = true, startCompletions = true;
  Duration? deferNextCompletion;
  final changed = StreamController<void>.broadcast(sync: true);
  final completions = <Completer<String?>>[];
  final completionTokens = <CancellationToken>[];
  final completionStarts = <void Function()?>[];
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
  Future<String?> complete(
    TerminalAiContext context,
    List<TerminalAiHistoryEntry> history,
    CancellationToken cancel, {
    void Function()? onStarted,
    void Function(Duration)? onDeferred,
  }) {
    this.history.add(history);
    completionTokens.add(cancel);
    completionStarts.add(onStarted);
    final result = Completer<String?>();
    completions.add(result);
    final delay = deferNextCompletion;
    deferNextCompletion = null;
    if (delay != null) {
      onDeferred?.call(delay);
      result.complete(null);
    } else if (startCompletions) {
      onStarted?.call();
    }
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

  Future<void> view(WidgetTester tester, {bool active = true, double textScale = 1}) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildTheme(Brightness.light).copyWith(platform: TargetPlatform.windows),
          locale: const Locale('en'),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
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

  Future<void> openWithShortcut(WidgetTester tester) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
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

  testWidgets('completion loading waits for an actual request and clears after abstaining', (tester) async {
    await mount(tester, 'git st');
    ai.startCompletions = false;
    final loading = find.byKey(const ValueKey('terminal-ai-completion-loading'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(ai.completions, isEmpty);
    expect(loading, findsNothing);
    await tester.pump(const Duration(milliseconds: 350));
    expect(ai.completions, hasLength(1));
    expect(loading, findsNothing);
    ai.completionStarts.single?.call();
    await tester.pump();
    expect(loading, findsOneWidget);
    ai.completions.single.complete(null);
    await tester.pump();
    expect(loading, findsNothing);
    expect(find.text('status'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    expect(ai.completions, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a rate-limited new prefix waits only its remaining interval before the first request', (tester) async {
    await mount(tester, 'git st');
    await tester.pump(const Duration(milliseconds: 850));
    expect(ai.completions, hasLength(1));
    ai.deferNextCompletion = const Duration(milliseconds: 350);
    transport.shell.echo('a');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 800));
    expect(ai.completions, hasLength(2));
    final loading = find.byKey(const ValueKey('terminal-ai-completion-loading'));
    expect(loading, findsNothing);
    ai.completions.first.complete(null);
    await tester.pump(const Duration(milliseconds: 349));
    expect(ai.completions, hasLength(2));
    await tester.pump(const Duration(milliseconds: 1));
    expect(ai.completions, hasLength(3));
    expect(loading, findsOneWidget);
    ai.completions.last.complete('git status');
    await tester.pump();
    expect(loading, findsNothing);
    expect(find.text('git status'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    expect(ai.completions, hasLength(3));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a deferred first request is cancelled when the pane becomes inactive', (tester) async {
    await mount(tester, 'git st');
    ai.deferNextCompletion = const Duration(milliseconds: 350);
    await tester.pump(const Duration(milliseconds: 850));
    expect(ai.completions, hasLength(1));
    await view(tester, active: false);
    await tester.pump(const Duration(seconds: 3));
    expect(ai.completions, hasLength(1));
    expect(ai.completionTokens.single.isCancelled, isTrue);
    expect(find.byKey(const ValueKey('terminal-ai-completion-loading')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Escape cancels a deferred request even without visible candidates', (tester) async {
    await mount(tester, 'git st-missing');
    ai.deferNextCompletion = const Duration(milliseconds: 350);
    await tester.pump(const Duration(milliseconds: 850));
    expect(ai.completions, hasLength(1));
    expect(find.byKey(const ValueKey('command-completion-popup')), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump(const Duration(seconds: 3));
    expect(ai.completionTokens.single.isCancelled, isTrue);
    expect(ai.completions, hasLength(1));
    expect(find.byKey(const ValueKey('terminal-ai-completion-loading')), findsNothing);
    expect(transport.shell.writes, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a skipped completion never shows loading', (tester) async {
    await mount(tester, 'git st');
    ai.startCompletions = false;
    await tester.pump(const Duration(milliseconds: 850));
    ai.completions.single.complete(null);
    await tester.pump();
    expect(find.byKey(const ValueKey('terminal-ai-completion-loading')), findsNothing);
    expect(find.text('status'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    expect(ai.completions, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a failed request clears loading and keeps local candidates', (tester) async {
    await mount(tester, 'git st');
    await tester.pump(const Duration(milliseconds: 850));
    final loading = find.byKey(const ValueKey('terminal-ai-completion-loading'));
    expect(loading, findsOneWidget);
    ai.completions.single.completeError(const TerminalAiFailure(TerminalAiFailureReason.network));
    await tester.pump();
    expect(loading, findsNothing);
    expect(find.text('status'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    expect(ai.completions, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('loading without candidates leaves Tab to the shell and Escape cancels the request', (tester) async {
    await mount(tester, 'git st-missing');
    await tester.pump(const Duration(milliseconds: 850));
    final loading = find.byKey(const ValueKey('terminal-ai-completion-loading'));
    final popup = find.byKey(const ValueKey('command-completion-popup'));
    expect(loading, findsOneWidget);
    expect(popup, findsOneWidget);
    expect(find.descendant(of: popup, matching: find.byType(InkWell)), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(transport.shell.writes, ['\t']);
    expect(ai.completionTokens.single.isCancelled, isTrue);
    expect(loading, findsNothing);
    await feed(tester, '\r\x1b[2Ku@box:~\$ git st-missing');
    await tester.pump(const Duration(milliseconds: 850));
    expect(loading, findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(ai.completionTokens.last.isCancelled, isTrue);
    expect(loading, findsNothing);
    ai.completions.last.complete('git st-missing --help');
    await tester.pump();
    expect(popup, findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('late AI goes first while loading preserves the selected local candidate', (tester) async {
    await mount(tester, 'git st');
    await tester.pump(const Duration(milliseconds: 850));
    expect(ai.completions, hasLength(1));
    final loading = find.byKey(const ValueKey('terminal-ai-completion-loading'));
    expect(loading, findsOneWidget);
    ai.completions.single.complete('git stash');
    await tester.pump();
    await tester.pump();
    expect(loading, findsNothing);
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
    expect(find.byKey(const ValueKey('terminal-ai-completion-loading')), findsNothing);
    ai.completions.single.complete('git stash');
    await tester.pump();
    await tester.pump();
    expect(find.text('git stash'), findsNothing);
    expect(find.byKey(const ValueKey('terminal-ai-completion-loading')), findsNothing);
    expect(transport.shell.writes, isEmpty);
  });

  testWidgets('an older completion cannot clear a newer request loading state', (tester) async {
    await mount(tester, 'git st');
    await tester.pump(const Duration(milliseconds: 850));
    await feed(tester, 'a');
    await tester.pump(const Duration(milliseconds: 850));
    expect(ai.completions, hasLength(2));
    final loading = find.byKey(const ValueKey('terminal-ai-completion-loading'));
    expect(loading, findsOneWidget);
    ai.completions.first.complete(null);
    await tester.pump();
    expect(loading, findsOneWidget);
    ai.completions.last.complete(null);
    await tester.pump();
    expect(loading, findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('changing draft and hiding the pane invalidate suggestions', (tester) async {
    await mount(tester, 'git st');
    await tester.pump(const Duration(milliseconds: 850));
    final loading = find.byKey(const ValueKey('terminal-ai-completion-loading'));
    expect(loading, findsOneWidget);
    await feed(tester, 'a');
    expect(ai.completionTokens.first.isCancelled, isTrue);
    expect(loading, findsNothing);
    ai.completions.first.complete('git status');
    await tester.pump();
    expect(find.text('git status'), findsNothing);
    await tester.pump(const Duration(milliseconds: 850));
    expect(loading, findsOneWidget);
    await view(tester, active: false);
    expect(ai.completionTokens.last.isCancelled, isTrue);
    expect(loading, findsNothing);
  });

  testWidgets('inline generation passes same-session history without directory probes', (tester) async {
    await mount(tester, 'git status');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await feed(tester, '\r\nOn branch main\r\nu@box:~\$ ');
    await openWithShortcut(tester);
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
    await openWithShortcut(tester);
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
    await mount(tester, 'show me disk usage');
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
    await mount(tester, 'show me disk usage');
    await tester.tap(find.byKey(const ValueKey('terminal-ai-toggle')));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('terminal-ai-composer')), findsOneWidget);
    expect(ai.generations, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  for (final draft in ['', 'git status', 'unfamiliar', '中文/文件']) {
    testWidgets('ordinary input "$draft" keeps a subdued AI badge and opens only on explicit click', (tester) async {
      await mount(tester, draft);
      final badge = find.byKey(const ValueKey('terminal-ai-toggle'));
      expect(badge, findsOneWidget);
      final color = Theme.of(tester.element(badge)).colorScheme.onSurfaceVariant;
      expect(tester.widget<IconButton>(badge).style!.foregroundColor!.resolve({}), color);
      expect(ai.generations, isEmpty);
      await tester.tap(badge);
      await tester.pump();
      expect(find.byKey(const ValueKey('terminal-ai-composer')), findsOneWidget);
      expect(ai.generations, hasLength(draft.isEmpty ? 0 : 1));
    });
  }

  testWidgets('a short natural-language request shows the badge without a global length threshold', (tester) async {
    await mount(tester, '查看内存');
    final badge = find.byKey(const ValueKey('terminal-ai-toggle'));
    expect(badge, findsOneWidget);
    final color = Theme.of(tester.element(badge)).colorScheme.primary;
    expect(tester.widget<IconButton>(badge).style!.foregroundColor!.resolve({}), color);
    expect(ai.generations, isEmpty);
  });

  testWidgets('an unknown prompt and alternate screen never expose or request inline generation', (tester) async {
    await mount(tester, '查看内存');
    await feed(tester, '\r\x1b[2KPassword: 查看内存');
    expect(session.readAiContext().ready, isFalse);
    expect(find.byKey(const ValueKey('terminal-ai-toggle')), findsNothing);
    await openWithShortcut(tester);
    expect(ai.generations, isEmpty);
    expect(find.byKey(const ValueKey('terminal-ai-composer')), findsNothing);
    await feed(tester, '\x1b[?1049hu@box:~\$ 查看内存');
    expect(session.readAiContext().ready, isFalse);
    expect(find.byKey(const ValueKey('terminal-ai-toggle')), findsNothing);
    await openWithShortcut(tester);
    expect(ai.generations, isEmpty);
  });

  testWidgets('leaving terminal focus hides its inline entry without starting generation', (tester) async {
    await mount(tester, '查看内存');
    FocusManager.instance.primaryFocus!.unfocus();
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('terminal-ai-toggle')), findsNothing);
    expect(ai.generations, isEmpty);
  });

  testWidgets('pending echo and a cursor away from the line end hide the AI badge', (tester) async {
    await mount(tester, '查看内存');
    tester.testTextInput.enterText('呀');
    await tester.pump();
    await tester.pump();
    expect(session.readAiContext().ready, isFalse);
    expect(find.byKey(const ValueKey('terminal-ai-toggle')), findsNothing);
    expect(ai.generations, isEmpty);
    await feed(tester, '呀');
    expect(find.byKey(const ValueKey('terminal-ai-toggle')), findsOneWidget);
    await feed(tester, '\x1b[D');
    expect(session.readAiContext().ready, isFalse);
    expect(find.byKey(const ValueKey('terminal-ai-toggle')), findsNothing);
    expect(ai.generations, isEmpty);
  });

  testWidgets('manual generation for uncertain input can still replace the original safely', (tester) async {
    await mount(tester, 'unfamiliar');
    await openWithShortcut(tester);
    ai.generations.single.complete(const TerminalAiGeneration(TerminalAiGenerationKind.command, command: 'pwd'));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('terminal-ai-accept')));
    await tester.pump();
    expect(transport.shell.writes.last, '\x7f');
    expect(transport.shell.writes, isNot(contains('pwd')));
    await feed(tester, '\r\x1b[2Ku@box:~\$ ');
    expect(transport.shell.writes.last, 'pwd');
    expect(transport.shell.writes.join(), isNot(contains('\r')));
    expect(transport.shell.writes.join(), isNot(contains('\n')));
  });

  testWidgets('the AI badge sits at the cursor and moves with the typed line', (tester) async {
    await mount(tester, '查看内存');
    final badge = find.byKey(const ValueKey('terminal-ai-toggle'));
    expect(badge, findsOneWidget);
    final pane = tester.getRect(find.byType(TerminalPane));
    final before = tester.getRect(badge);
    expect(before.left, lessThan(pane.width / 2));
    await feed(tester, ' now');
    final after = tester.getRect(badge);
    expect(after.left, greaterThan(before.left));
    expect(after.top, closeTo(before.top, 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('stopping inline generation clears the wait and ignores the late result', (tester) async {
    await mount(tester, 'show me disk usage');
    await tester.tap(find.byKey(const ValueKey('terminal-ai-toggle')));
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('terminal-ai-stop')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('terminal-ai-stop')));
    await tester.pump();
    expect(ai.generationTokens.single.isCancelled, isTrue);
    expect(find.byKey(const ValueKey('terminal-ai-generate')), findsOneWidget);
    ai.generations.single.complete(const TerminalAiGeneration(TerminalAiGenerationKind.command, command: 'df -h'));
    await tester.pump();
    expect(find.byKey(const ValueKey('terminal-ai-accept')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('inline failure names the reason instead of hiding it', (tester) async {
    await mount(tester, 'show me disk usage');
    await tester.tap(find.byKey(const ValueKey('terminal-ai-toggle')));
    await tester.pump();
    await tester.pump();
    await tester.pump();
    ai.generations.single.completeError(const TerminalAiFailure(TerminalAiFailureReason.http, statusCode: 429));
    await tester.pump();
    expect(find.text('The model service returned HTTP 429.'), findsOneWidget);
    expect(find.byKey(const ValueKey('terminal-ai-generate')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('outside dismissal keeps the request and reopening reuses it and its result', (tester) async {
    await mount(tester, 'show me disk usage');
    final toggle = find.byKey(const ValueKey('terminal-ai-toggle'));
    final composer = find.byKey(const ValueKey('terminal-ai-composer'));
    await tester.tap(toggle);
    await tester.pump();
    final pane = tester.getRect(find.byType(TerminalPane));
    await tester.tapAt(pane.bottomRight - const Offset(20, 20));
    await tester.pump();
    expect(composer, findsNothing);
    expect(ai.generationTokens.single.isCancelled, isFalse);
    await tester.tap(toggle);
    await tester.pump();
    expect(ai.generations, hasLength(1));
    expect(find.byKey(const ValueKey('terminal-ai-stop')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    ai.generations.single.complete(const TerminalAiGeneration(TerminalAiGenerationKind.command, command: 'df -h'));
    await tester.pump();
    await tester.tap(toggle);
    await tester.pump();
    expect(ai.generations, hasLength(1));
    final command = find.byKey(const ValueKey('terminal-ai-command'));
    expect(tester.widget<TextField>(command).controller!.text, 'df -h');
    await tester.enterText(command, 'df -h /');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.tap(toggle);
    await tester.pump();
    expect(tester.widget<TextField>(command).controller!.text, 'df -h /');
    expect(ai.generations, hasLength(1));
    expect(transport.shell.writes, isEmpty);
  });

  testWidgets('hidden inline input changes cancel immediately and wait for a manual request', (tester) async {
    await mount(tester, 'show me disk usage');
    final toggle = find.byKey(const ValueKey('terminal-ai-toggle'));
    await tester.tap(toggle);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    tester.testTextInput.enterText(' now');
    await tester.pump();
    expect(ai.generationTokens.single.isCancelled, isTrue);
    await feed(tester, ' now');
    ai.generations.single.complete(const TerminalAiGeneration(TerminalAiGenerationKind.command, command: 'old'));
    await tester.pump(const Duration(seconds: 1));
    expect(ai.generations, hasLength(1));
    expect(find.byKey(const ValueKey('terminal-ai-composer')), findsNothing);
    await tester.tap(toggle);
    await tester.pump();
    expect(ai.generations, hasLength(2));
    expect(find.byKey(const ValueKey('terminal-ai-command')), findsNothing);
    expect(
      tester.widget<TextField>(find.byKey(const ValueKey('terminal-ai-instruction'))).controller!.text,
      'show me disk usage now',
    );
  });

  testWidgets('manual stop discards late results before reopening starts a fresh request', (tester) async {
    await mount(tester, 'show me disk usage');
    final toggle = find.byKey(const ValueKey('terminal-ai-toggle'));
    await tester.tap(toggle);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('terminal-ai-stop')));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.tap(toggle);
    await tester.pump();
    expect(ai.generations, hasLength(2));
    ai.generations.first.complete(const TerminalAiGeneration(TerminalAiGenerationKind.command, command: 'old'));
    await tester.pump();
    expect(find.byKey(const ValueKey('terminal-ai-command')), findsNothing);
    ai.generations.last.complete(const TerminalAiGeneration(TerminalAiGenerationKind.command, command: 'new'));
    await tester.pump();
    expect(tester.widget<TextField>(find.byKey(const ValueKey('terminal-ai-command'))).controller!.text, 'new');
  });

  testWidgets('inline generation survives a pane unmount but session close cancels it', (tester) async {
    await mount(tester, 'show me disk usage');
    await tester.tap(find.byKey(const ValueKey('terminal-ai-toggle')));
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    expect(ai.generationTokens.single.isCancelled, isFalse);
    ai.generations.single.complete(const TerminalAiGeneration(TerminalAiGenerationKind.command, command: 'df -h'));
    await tester.pump();
    await view(tester);
    await tester.tapAt(tester.getCenter(find.byType(TerminalPane)));
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('terminal-ai-toggle')));
    await tester.pump();
    expect(ai.generations, hasLength(1));
    expect(tester.widget<TextField>(find.byKey(const ValueKey('terminal-ai-command'))).controller!.text, 'df -h');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await feed(tester, ' now');
    await tester.tap(find.byKey(const ValueKey('terminal-ai-toggle')));
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    session.close();
    expect(ai.generationTokens.last.isCancelled, isTrue);
  });

  testWidgets('editing the local request cancels generation without automatically restarting it', (tester) async {
    await mount(tester, 'show me disk usage');
    await tester.tap(find.byKey(const ValueKey('terminal-ai-toggle')));
    await tester.pump();
    await tester.enterText(find.byKey(const ValueKey('terminal-ai-instruction')), 'show memory');
    await tester.pump();
    expect(ai.generationTokens.single.isCancelled, isTrue);
    expect(ai.generations, hasLength(1));
    await tester.tap(find.byKey(const ValueKey('terminal-ai-generate')));
    await tester.pump();
    expect(ai.generations, hasLength(2));
  });

  testWidgets('inline editor is compact, draggable and stays within a narrow scaled pane', (tester) async {
    await mount(tester, 'show me disk usage');
    await tester.tap(find.byKey(const ValueKey('terminal-ai-toggle')));
    await tester.pump();
    final composer = find.byKey(const ValueKey('terminal-ai-composer'));
    final drag = find.byKey(const ValueKey('terminal-ai-drag'));
    final before = tester.getRect(composer);
    expect(before.width, 360);
    expect(before.height, lessThan(240));
    await tester.drag(drag, const Offset(100, 80));
    await tester.pump();
    final after = tester.getRect(composer);
    expect(after.left, greaterThan(before.left));
    expect(after.top, greaterThan(before.top));
    expect(ai.generationTokens.single.isCancelled, isFalse);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(300, 300);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await view(tester, textScale: 1.5);
    await tester.pump();
    await tester.drag(drag, const Offset(1000, 1000));
    await tester.pump();
    final pane = tester.getRect(find.byType(TerminalPane));
    final bounds = tester.getRect(composer);
    expect(bounds.left, greaterThanOrEqualTo(pane.left));
    expect(bounds.right, lessThanOrEqualTo(pane.right));
    expect(bounds.top, greaterThanOrEqualTo(pane.top));
    expect(bounds.bottom, lessThanOrEqualTo(pane.bottom));
    expect(tester.takeException(), isNull);
  });

  testWidgets('retained inline preview can still be accepted after the user clears the original', (tester) async {
    await mount(tester, '请查看磁盘');
    await tester.tap(find.byKey(const ValueKey('terminal-ai-toggle')));
    await tester.pump();
    expect(ai.generations, hasLength(1));
    ai.generations.single.complete(const TerminalAiGeneration(TerminalAiGenerationKind.command, command: 'df -h'));
    await tester.pump();
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('terminal-ai-accept'))).onPressed, isNotNull);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await feed(tester, '\r\x1b[2Ku@box:~\$ ');
    await openWithShortcut(tester);
    await tester.pump();
    await tester.pump();
    expect(tester.widget<TextField>(find.byKey(const ValueKey('terminal-ai-command'))).controller!.text, 'df -h');
    await tester.tap(find.byKey(const ValueKey('terminal-ai-accept')));
    await tester.pump();
    expect(transport.shell.writes, ['df -h']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('accepting inline generation replaces the original input without manual clearing or Enter', (
    tester,
  ) async {
    await mount(tester, '请查看磁盘');
    await tester.tap(find.byKey(const ValueKey('terminal-ai-toggle')));
    await tester.pump();
    ai.generations.single.complete(const TerminalAiGeneration(TerminalAiGenerationKind.command, command: 'df -h'));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('terminal-ai-accept')));
    await tester.pump();
    expect(transport.shell.writes, List.filled('请查看磁盘'.runes.length, '\x7f'));
    expect(find.byKey(const ValueKey('terminal-ai-composer')), findsOneWidget);
    await feed(tester, '\r\x1b[2Ku@box:~\$ 请查');
    expect(tester.widget<TextField>(find.byKey(const ValueKey('terminal-ai-command'))).controller!.text, 'df -h');
    expect(transport.shell.writes.last, '\x7f');
    await feed(tester, '\r\x1b[2Ku@box:~\$ ');
    expect(transport.shell.writes.last, 'df -h');
    expect(transport.shell.writes.join(), isNot(contains('\r')));
    expect(transport.shell.writes.join(), isNot(contains('\n')));
    expect(find.byKey(const ValueKey('terminal-ai-composer')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('closing the inline editor during replacement prevents the later paste', (tester) async {
    await mount(tester, 'show me disk');
    await tester.tap(find.byKey(const ValueKey('terminal-ai-toggle')));
    await tester.pump();
    ai.generations.single.complete(const TerminalAiGeneration(TerminalAiGenerationKind.command, command: 'df -h'));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('terminal-ai-accept')));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await feed(tester, '\r\x1b[2Ku@box:~\$ ');
    expect(transport.shell.writes, List.filled('show me disk'.length, '\x7f'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('an inactive window cannot finish a pending inline replacement', (tester) async {
    await mount(tester, 'show me disk');
    await tester.tap(find.byKey(const ValueKey('terminal-ai-toggle')));
    await tester.pump();
    ai.generations.single.complete(const TerminalAiGeneration(TerminalAiGenerationKind.command, command: 'df -h'));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('terminal-ai-accept')));
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    addTearDown(() => tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed));
    await feed(tester, '\r\x1b[2Ku@box:~\$ ');
    expect(transport.shell.writes, List.filled('show me disk'.length, '\x7f'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('replacement timeout shows an actionable inline failure', (tester) async {
    await mount(tester, 'show me disk');
    await tester.tap(find.byKey(const ValueKey('terminal-ai-toggle')));
    await tester.pump();
    ai.generations.single.complete(const TerminalAiGeneration(TerminalAiGenerationKind.command, command: 'df -h'));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('terminal-ai-accept')));
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('Could not replace the terminal input. Reopen the editor to try again.'), findsOneWidget);
    expect(transport.shell.writes, List.filled('show me disk'.length, '\x7f'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('AI context observes known directory changes without starting remote probes', (tester) async {
    await mount(tester, '');
    await tester.pump(const Duration(seconds: 2));
    expect(transport.queries, 0);
    await openWithShortcut(tester);
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
    await openWithShortcut(tester);
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

  testWidgets('policy changes cancel an inline request even with no mounted pane', (tester) async {
    await mount(tester, 'show me disk usage');
    await tester.tap(find.byKey(const ValueKey('terminal-ai-toggle')));
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    ai.enabled = false;
    ai.changed.add(null);
    expect(ai.generationTokens.single.isCancelled, isTrue);
    ai.generations.single.complete(const TerminalAiGeneration(TerminalAiGenerationKind.command, command: 'old'));
    await tester.pump();
    ai.enabled = true;
    ai.changed.add(null);
    await view(tester);
    await tester.tapAt(tester.getCenter(find.byType(TerminalPane)));
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('terminal-ai-toggle')));
    await tester.pump();
    expect(ai.generations, hasLength(2));
    expect(find.byKey(const ValueKey('terminal-ai-command')), findsNothing);
  });

  testWidgets('revoking model policy closes local editor and cancels generation', (tester) async {
    await mount(tester, '');
    await openWithShortcut(tester);
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

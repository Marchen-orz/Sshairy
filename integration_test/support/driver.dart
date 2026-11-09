// What the integration tests that drive the whole app against a real server share (docs/TESTING.md §2).
// Credentials come only from the environment; SSHAIRY_TEST_SHOTS=<dir> saves screenshots there.
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/app/composition.dart';
import 'package:sshairy/design/controls.dart';
import 'package:sshairy/design/dialog.dart';
import 'package:sshairy/features/credentials/application/credential_access.dart' show secretStoreProvider;
import 'package:sshairy/features/files/api.dart';
import 'package:sshairy/features/files/presentation/file_pane.dart';
import 'package:sshairy/features/settings/api.dart';
import 'package:sshairy/features/workspace/api.dart';
import 'package:sshairy/features/terminal/adapters/ime_caret.dart';
import 'package:sshairy/foundation/data_dir.dart';
import 'package:sshairy/foundation/file_system.dart';
import 'package:sshairy/foundation/ids.dart';
import 'package:sshairy/main.dart';
import 'package:xterm2/xterm.dart';

import 'credentials.dart';

final target = Platform.environment['SSHAIRY_TEST_TARGET']!;
final password = Platform.environment['SSHAIRY_TEST_PASSWORD']!;
final shots = Platform.environment['SSHAIRY_TEST_SHOTS'];
final boundary = GlobalKey();

// ignore: avoid_print
void report(String line) => print('REPORT $line');

Finder inDialog(Finder f) => find.descendant(of: find.byType(AppDialog), matching: f);

extension AppDriver on WidgetTester {
  Future<void> until(String what, bool Function() done, {int seconds = 30}) async {
    final end = DateTime.now().add(Duration(seconds: seconds));
    // A view that is briefly not there (a rebuild, an overlay) means "not yet", not an error.
    bool ready() {
      try {
        return done();
      } on StateError {
        return false;
      }
    }

    while (!ready()) {
      if (DateTime.now().isAfter(end)) {
        final texts = widgetList<Text>(find.byType(Text)).map((t) => t.data).whereType<String>().take(40).toList();
        final slug = what.replaceAll(RegExp(r'\W+'), '-');
        await shot('timeout-${slug.substring(0, min(40, slug.length))}');
        fail('timed out waiting for $what; on screen: $texts');
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await pump();
    }
    await pump();
  }

  Future<void> untilFound(Finder f, {int seconds = 30}) => until('$f', () => f.evaluate().isNotEmpty, seconds: seconds);

  Future<void> tapAndPump(Finder f) async {
    await tap(f);
    await pump(const Duration(milliseconds: 300));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await pump();
  }

  Future<void> startApp(Directory dir) async {
    // The first-run import offer would cover the vault; tests that want it seed `importOffered: false` themselves.
    final settings = File('${dir.path}/settings.json');
    Object? seeded;
    try {
      seeded = settings.existsSync() ? jsonDecode(settings.readAsStringSync()) : <String, dynamic>{};
    } on FormatException {
      seeded = null;
    }
    if (seeded is Map<String, dynamic> && !seeded.containsKey('importOffered')) {
      await settings.writeAsString(jsonEncode({...seeded, 'importOffered': true}));
    }
    await pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: ProviderScope(
          key: UniqueKey(),
          overrides: [
            dataDirProvider.overrideWithValue(dir.path),
            runningRendererProvider.overrideWithValue(Renderer.skia),
            ...appOverrides(),
            secretStoreProvider.overrideWithValue(EphemeralSecretStore()),
          ],
          child: const SshairyApp(),
        ),
      ),
    );
    await pump();
  }

  Future<void> quickConnect() async {
    await enterText(find.byType(TextField).hitTestable().first, target);
    await pump();
    await tapAndPump(find.widgetWithIcon(OutlinedButton, Icons.bolt).hitTestable());
  }

  Future<void> answerPassword(String value, {bool remember = false}) async {
    await untilFound(inDialog(find.byType(TextField)));
    await enterText(inDialog(find.byType(TextField)), value);
    if (remember) await tapAndPump(inDialog(find.byType(AppCheckbox)));
    await tapAndPump(inDialog(find.widgetWithText(FilledButton, 'Connect')));
  }

  /// The terminal in the visible tab.
  Terminal get terminal => widget<TerminalView>(find.byType(TerminalView).hitTestable().first).terminal;

  Future<void> untilPrompt() async {
    await until('terminal', () => find.byType(TerminalView).hitTestable().evaluate().isNotEmpty);
    await until('prompt', () => terminal.buffer.getText().trim().endsWith(r'$'));
  }

  /// Types through the terminal's input path; `$((…))` proves the shell ran it rather than echoed it.
  Future<void> run(String command) async {
    terminal.textInput(command);
    await sendKeyEvent(LogicalKeyboardKey.enter);
    await pump();
  }

  Future<void> expectShellAlive(int n) async {
    await run('echo sshairy-\$(($n*7))');
    await until('command output', () => terminal.buffer.getText().contains('sshairy-${n * 7}'));
  }

  Future<void> expectImeAtCursor() async {
    final view = state<TerminalViewState>(find.byType(TerminalView).hitTestable().first);
    final scale = this.view.devicePixelRatio;
    late Rect cursor;
    late ({Offset caret, Offset composition, Offset candidate})? ime;
    bool near(Offset a, double x, double y) => (a.dx - x).abs() <= 1 && (a.dy - y).abs() <= 1;
    await until('IME position at the cursor', () {
      final r = view.globalCursorRect;
      cursor = Rect.fromLTRB(r.left * scale, r.top * scale, r.right * scale, r.bottom * scale);
      ime = ImeCaret.current();
      final i = ime;
      return i != null &&
          near(i.composition, cursor.left, cursor.top) &&
          near(i.candidate, cursor.left, cursor.bottom) &&
          near(i.caret, cursor.left, cursor.bottom);
    }, seconds: 5).catchError((Object e) => fail('$e: cursor $cursor, IME $ime (null means the window has no focus)'));
  }

  Future<void> ctrlShift(LogicalKeyboardKey key) async {
    await sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await sendKeyEvent(key);
    await sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await pump();
  }

  Future<void> closeTabByKeyboard() => ctrlShift(LogicalKeyboardKey.keyW);

  /// What Ctrl+Shift+W does, without simulated key events, which only work in debug builds.
  void closeActiveTab() => container.read(workspaceProvider.notifier).closeTab(workspace.active!);

  Future<void> palette(String query) async {
    await sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await sendKeyEvent(LogicalKeyboardKey.keyP);
    await sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await untilFound(find.byType(Dialog));
    await enterText(find.descendant(of: find.byType(Dialog), matching: find.byType(TextField)), query);
    await pump();
    await testTextInput.receiveAction(TextInputAction.done);
    await pump(const Duration(milliseconds: 300));
  }

  WorkspaceState get workspace =>
      ProviderScope.containerOf(element(find.byType(WorkspacePage))).read(workspaceProvider);

  ProviderContainer get container => ProviderScope.containerOf(element(find.byType(WorkspacePage)));

  List<Transfer> get transfers => container.read(transfersProvider);

  Future<void> untilTransfers(int completed) => until('$completed transfers done', () {
    final failed = transfers.where((x) => x.state == TransferState.failed);
    if (failed.isNotEmpty) fail('transfer failed: ${failed.first.error} ${failed.first.detail}');
    return transfers.where((x) => x.state == TransferState.completed).length == completed;
  }, seconds: 120);

  Future<void> atTerminal(TabId tab) async {
    container.read(workspaceProvider.notifier).activate(tab);
    await untilPrompt();
    await tapAndPump(find.byType(TerminalView).hitTestable().first);
  }

  /// The visible file panes, left to right.
  Finder pane(int i) => find.byType(FilePane).hitTestable().at(i);

  Finder rowFinder(int i, String name) => find.descendant(of: pane(i), matching: find.text(name));

  FileEntry entry(int i, String name) => widget<FilePane>(pane(i)).browser.entries.firstWhere((e) => e.name == name);

  Future<void> untilRow(int i, String name) => untilFound(rowFinder(i, name));

  /// Ready, after a password prompt when the files channel needed a connection of its own.
  Future<void> untilReady(int i) async {
    bool ready() => find.byType(FilePane).hitTestable().evaluate().length > i && widget<FilePane>(pane(i)).browser.ready;
    await until('pane $i ready or asking', () => ready() || find.byType(AppDialog).evaluate().isNotEmpty);
    if (!ready()) await answerPassword(password);
    await until('pane $i ready', ready);
  }

  Future<void> openRow(int i, String name) async {
    await untilRow(i, name);
    await tapAndPump(rowFinder(i, name));
    await sendKeyEvent(LogicalKeyboardKey.enter);
    await pump();
  }

  Future<void> typePath(int i, String path) async {
    // The end of the path bar: empty space or the current folder, both edit the path.
    final bar = getRect(find.descendant(of: pane(i), matching: find.byTooltip('Edit path')));
    await tapAt(Offset(bar.right - 8, bar.center.dy));
    await pump(const Duration(milliseconds: 300));
    await enterText(find.descendant(of: pane(i), matching: find.byType(TextField)).first, path);
    await testTextInput.receiveAction(TextInputAction.done);
    await pump(const Duration(milliseconds: 300));
  }

  Future<void> menu(Finder on, String item) async {
    await tap(on, buttons: kSecondaryMouseButton, kind: PointerDeviceKind.mouse);
    await pump(const Duration(milliseconds: 300));
    await tapAndPump(find.text(item).last);
  }

  List<Terminal> get visibleTerminals => [
    for (final v in widgetList<TerminalView>(find.byType(TerminalView).hitTestable())) v.terminal,
  ];

  Future<void> shot(String name) async {
    if (shots == null) return;
    await pump(const Duration(milliseconds: 300));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await pump();
    final render = boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await render.toImage();
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    await File('$shots/$name.png').writeAsBytes(png!.buffer.asUint8List());
  }
}

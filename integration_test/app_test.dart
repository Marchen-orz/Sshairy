// Drives the real app against a real server (docs/TESTING.md §2); credentials come only from the environment.
// Usage: SSHAIRY_TEST_TARGET=user@host SSHAIRY_TEST_PASSWORD=... flutter test integration_test/app_test.dart -d windows
// Optional: SSHAIRY_TEST_SHOTS=<dir> saves screenshots there.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sshairy/app/composition.dart';
import 'package:sshairy/design/theme.dart';
import 'package:sshairy/features/credentials/api.dart';
import 'package:sshairy/features/settings/api.dart';
import 'package:sshairy/features/workspace/api.dart';
import 'package:sshairy/features/terminal/adapters/ime_caret.dart';
import 'package:sshairy/foundation/data_dir.dart';
import 'package:sshairy/main.dart';
import 'package:xterm2/xterm.dart';

final target = Platform.environment['SSHAIRY_TEST_TARGET']!;
final password = Platform.environment['SSHAIRY_TEST_PASSWORD']!;
final shots = Platform.environment['SSHAIRY_TEST_SHOTS'];
final boundary = GlobalKey();

Finder inDialog(Finder f) => find.descendant(of: find.byType(AlertDialog), matching: f);

extension on WidgetTester {
  Future<void> until(String what, bool Function() done, {int seconds = 30}) async {
    final end = DateTime.now().add(Duration(seconds: seconds));
    while (!done()) {
      if (DateTime.now().isAfter(end)) fail('timed out waiting for $what');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await pump();
    }
    await pump();
  }

  Future<void> untilFound(Finder f, {int seconds = 30}) =>
      until('$f', () => f.evaluate().isNotEmpty, seconds: seconds);

  Future<void> tapAndPump(Finder f) async {
    await tap(f);
    await pump(const Duration(milliseconds: 300));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await pump();
  }

  Future<void> startApp(Directory dir) async {
    await pumpWidget(RepaintBoundary(
      key: boundary,
      child: ProviderScope(
        key: UniqueKey(),
        overrides: [
          dataDirProvider.overrideWithValue(dir.path),
          runningRendererProvider.overrideWithValue(Renderer.skia),
          ...appOverrides(),
        ],
        child: const SshairyApp(),
      ),
    ));
    await pump();
  }

  Future<void> quickConnect() async {
    await enterText(find.byType(TextField).first, target);
    await pump();
    await tapAndPump(find.widgetWithIcon(OutlinedButton, Icons.bolt));
  }

  Future<void> answerPassword(String value, {bool remember = false}) async {
    await untilFound(inDialog(find.byType(TextField)));
    await enterText(inDialog(find.byType(TextField)), value);
    if (remember) await tapAndPump(inDialog(find.byType(Checkbox)));
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

  Future<void> closeTabByKeyboard() async {
    await sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await sendKeyEvent(LogicalKeyboardKey.keyW);
    await sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await pump();
  }

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

  List<Terminal> get visibleTerminals =>
      [for (final v in widgetList<TerminalView>(find.byType(TerminalView).hitTestable())) v.terminal];

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

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  final address = target.split('@').last;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('sshairy-it');
    await File('${dir.path}/settings.json').writeAsString('{"locale":"en"}');
  });
  tearDown(() => dir.delete(recursive: true));

  testWidgets('host key: rejecting stops the attempt, a changed key is flagged', (t) async {
    t.testTextInput.register();
    await t.startApp(dir);

    await t.quickConnect();
    await t.untilFound(find.text('Unknown host'));
    await t.shot('hostkey-unknown');
    await t.tapAndPump(inDialog(find.text('Cancel')));
    await t.untilFound(find.text('Host key rejected'));
    expect(find.byType(AlertDialog), findsNothing, reason: 'no password prompt after rejecting the key');
    expect(File('${dir.path}/trust.json').existsSync(), isFalse);
    await t.closeTabByKeyboard();
    expect(find.text(address), findsNothing);

    await t.quickConnect();
    await t.untilFound(find.text('Unknown host'));
    await t.tapAndPump(inDialog(find.text('Trust')));
    await t.answerPassword(password);
    await t.untilPrompt();
    await t.closeTabByKeyboard();

    final trust = File('${dir.path}/trust.json');
    final saved = jsonDecode(await trust.readAsString()) as Map<String, dynamic>;
    final keys = (saved['keys'] as Map<String, dynamic>).values.single as Map<String, dynamic>;
    keys[keys.keys.single] = 'SHA256:tampered';
    await trust.writeAsString(jsonEncode(saved));

    await t.startApp(dir);
    await t.quickConnect();
    await t.untilFound(find.text('Host key changed'));
    expect(find.text('Trust once'), findsNothing);
    await t.shot('hostkey-changed');
    await t.tapAndPump(inDialog(find.text('Cancel')));
    await t.untilFound(find.text('Host key rejected'));
    await t.closeTabByKeyboard();
  });

  testWidgets('terminal: runs commands, reports size, reconnects, survives tab changes', (t) async {
    t.testTextInput.register();
    await t.startApp(dir);

    await t.quickConnect();
    await t.untilFound(find.text('Unknown host'));
    await t.tapAndPump(inDialog(find.text('Trust')));
    await t.answerPassword(password);
    await t.untilPrompt();
    await t.expectShellAlive(6);
    await t.shot('terminal');

    // IMEs read their position before a composition starts, so it must follow the cursor between compositions.
    final start = t.terminal.buffer.cursorX;
    t.terminal.textInput('x' * 60);
    await t.until('long input echoed', () => t.terminal.buffer.cursorX == start + 60);
    await t.expectImeAtCursor();
    for (var i = 0; i < 60; i++) {
      await t.sendKeyEvent(LogicalKeyboardKey.backspace);
    }
    await t.until('input deleted', () => t.terminal.buffer.cursorX == start);
    await t.expectImeAtCursor();

    final term = t.terminal;
    await t.run('stty size');
    final size = '${term.viewHeight} ${term.viewWidth}';
    await t.until('stty size $size', () => term.buffer.getText().contains(size));

    await t.run('sleep 60');
    await t.pump(const Duration(milliseconds: 500));
    final drag = await t.startGesture(
      t.getTopLeft(find.byType(TerminalView).hitTestable().first) + const Offset(40, 60),
      kind: PointerDeviceKind.mouse,
    );
    await t.pump(const Duration(milliseconds: 100));
    await drag.moveBy(const Offset(200, 0));
    await t.pump(const Duration(milliseconds: 100));
    await drag.up();
    await t.pump(const Duration(milliseconds: 100));
    await t.shot('selection');
    await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await t.sendKeyEvent(LogicalKeyboardKey.keyC);
    await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await t.until('Ctrl+C interrupts even with a selection', () => term.buffer.getText().contains('^C'), seconds: 10);
    await t.untilPrompt();

    final clipboard = await Clipboard.getData(Clipboard.kTextPlain);
    addTearDown(() async {
      if (clipboard?.text case final text?) await Clipboard.setData(ClipboardData(text: text));
    });
    await Clipboard.setData(const ClipboardData(text: 'echo pasted-\$((1+1))\necho pasted-\$((2+2))\n'));
    await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await t.sendKeyEvent(LogicalKeyboardKey.keyV);
    await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await t.untilFound(find.byType(AlertDialog));
    expect(term.buffer.getText(), isNot(contains('pasted-2')), reason: 'nothing is sent before confirming');
    await t.shot('paste-confirm');
    await t.tapAndPump(inDialog(find.text('Paste')));
    // bash has bracketed paste on: the text waits on the command line until Enter.
    await t.until('pasted text shown', () => term.buffer.getText().contains(r'echo pasted-$((2+2))'));
    expect(term.buffer.getText(), isNot(contains('pasted-4')), reason: 'a paste must not run by itself');
    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    await t.until('pasted lines ran', () => term.buffer.getText().contains('pasted-4'));
    await t.untilPrompt();

    await t.run('exit');
    await t.untilFound(find.text('Disconnected'));
    await t.shot('disconnected');
    await t.tapAndPump(find.text('Reconnect'));
    await t.answerPassword(password);
    await t.untilPrompt();
    expect(find.text('Disconnected'), findsNothing);
    expect(t.terminal, same(term));

    await t.tapAndPump(find.text('Hosts'));
    await t.quickConnect();
    await t.answerPassword(password);
    await t.until('second tab', () => !identical(t.terminal, term));
    final second = t.terminal;
    await t.untilPrompt();
    await t.run('echo second-tab');
    await t.until('second tab output', () => second.buffer.getText().contains('second-tab'));

    await t.tapAndPump(find.text(address).first);
    expect(t.terminal, same(term));
    await t.expectShellAlive(8);

    await t.closeTabByKeyboard();
    await t.until('second tab active', () => identical(t.terminal, second));
    await t.pump(const Duration(milliseconds: 300));
    await t.run('echo after-close');
    await t.until('tab after the closed one is still alive', () => second.buffer.getText().contains('after-close'));
    await t.closeTabByKeyboard();
    expect(find.byType(TerminalView), findsNothing);
  });

  testWidgets('saved host: remembered password, wrong password, delete clears the secret', (t) async {
    t.testTextInput.register();
    await t.startApp(dir);
    final [user, host] = target.split('@');

    await t.tapAndPump(find.text('New host'));
    await t.enterText(find.widgetWithText(TextFormField, 'Name'), 'sshairy-it');
    await t.tapAndPump(find.text('Save'));
    expect(find.text('Required'), findsNWidgets(2));
    await t.shot('host-form');
    await t.enterText(find.widgetWithText(TextFormField, 'Address'), host);
    await t.enterText(find.widgetWithText(TextFormField, 'Username'), user);
    await t.tapAndPump(find.text('Save'));
    await t.untilFound(find.text('sshairy-it'));
    await t.until('form closed', () => find.byType(TextFormField).evaluate().isEmpty);
    await t.shot('vault');

    final hosts = jsonDecode(await File('${dir.path}/hosts.json').readAsString()) as Map<String, dynamic>;
    final ref = 'host/${(hosts['hosts'] as List<dynamic>).single['id']}/password';
    const secrets = SecretStore();
    addTearDown(() => secrets.delete(ref));
    expect(await secrets.read(ref), isNull);

    await t.tapAndPump(find.byTooltip('Connect'));
    await t.untilFound(find.text('Unknown host'));
    await t.tapAndPump(inDialog(find.text('Trust')));
    await t.answerPassword('sshairy-wrong-password');
    await t.until('auth result', () =>
        find.text('Authentication failed').evaluate().isNotEmpty || find.byType(AlertDialog).evaluate().isNotEmpty);
    // Servers that fall back to keyboard-interactive ask again; never send a second wrong password.
    if (find.byType(AlertDialog).evaluate().isNotEmpty) await t.tapAndPump(inDialog(find.text('Cancel')));
    await t.shot('auth-failed');
    await t.tapAndPump(find.text('Reconnect'));

    await t.answerPassword(password, remember: true);
    await t.untilPrompt();
    // Compared outside expect() so a failure cannot print the password.
    expect((await secrets.read(ref))?.reveal() == password, isTrue);
    final onDisk = [for (final f in dir.listSync().whereType<File>()) f.readAsStringSync().contains(password)];
    expect(onDisk.contains(true), isFalse, reason: 'the password must stay out of the data directory');
    await t.closeTabByKeyboard();

    await t.tapAndPump(find.byTooltip('Connect'));
    await t.untilPrompt();
    expect(find.byType(AlertDialog), findsNothing, reason: 'saved password and trusted key need no prompts');
    await t.expectShellAlive(9);
    await t.closeTabByKeyboard();

    await t.tapAndPump(find.byTooltip('More'));
    await t.tapAndPump(find.text('Delete'));
    await t.tapAndPump(inDialog(find.text('Delete')));
    await t.until('host removed', () => find.text('sshairy-it').evaluate().isEmpty);
    for (var i = 0; i < 50 && await secrets.read(ref) != null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(await secrets.read(ref), isNull);
  });

  testWidgets('workspace: palette, split panes, restore after restart', (t) async {
    t.testTextInput.register();
    final [user, host] = target.split('@');
    await File('${dir.path}/hosts.json').writeAsString(jsonEncode({
      'schemaVersion': 1,
      'hosts': [
        {'id': 'wshost', 'label': 'sshairy-ws', 'address': host, 'port': 22, 'username': user, 'auth': 'password'},
      ],
    }));
    await t.startApp(dir);

    await t.palette('sshairy-ws');
    await t.untilFound(find.text('Unknown host'));
    await t.tapAndPump(inDialog(find.text('Trust')));
    await t.answerPassword(password);
    await t.untilPrompt();

    await t.palette('Split right');
    await t.answerPassword(password);
    await t.until('two panes', () => t.visibleTerminals.length == 2);
    final [left, right] = t.visibleTerminals;
    await t.until('right prompt', () => right.buffer.getText().trim().endsWith(r'$'));
    expect(t.workspace.activeTab!.layout.focused, t.workspace.activeTab!.layout.leaves.last.pane);
    right.textInput('echo right-\$((3*5))');
    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    await t.until('right pane ran it', () => right.buffer.getText().contains('right-15'));
    expect(left.buffer.getText(), isNot(contains('right-15')));
    await t.shot('split');

    await t.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await t.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await t.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await t.pump();
    expect(t.workspace.activeTab!.layout.focused, t.workspace.activeTab!.layout.leaves.first.pane);
    await t.closeTabByKeyboard();
    await t.until('one pane left', () => t.visibleTerminals.length == 1);
    expect(t.visibleTerminals.single, same(right));

    // Saved hosts come back as tabs that wait for the user.
    await t.until('workspace saved', () => File('${dir.path}/workspace.json').readAsStringSync().contains('wshost'));
    await t.startApp(dir);
    await t.untilFound(find.widgetWithText(FilledButton, 'Connect'));
    expect(find.byType(AlertDialog), findsNothing, reason: 'a restored tab must not dial by itself');
    await t.shot('restored');
    await t.tapAndPump(find.widgetWithText(FilledButton, 'Connect'));
    await t.answerPassword(password);
    await t.untilPrompt();
    await t.expectShellAlive(5);

    await t.palette('Theme: Dark');
    await t.until('dark theme', () => Theme.of(t.element(find.byType(WorkspacePage))).brightness == Brightness.dark);
    await t.closeTabByKeyboard();
  });

  testWidgets('settings: theme, font size and language apply and persist', (t) async {
    t.testTextInput.register();
    await t.startApp(dir);

    await t.tapAndPump(find.byTooltip('Settings'));
    await t.tapAndPump(find.text('Dark'));
    expect(Theme.of(t.element(find.text('Theme'))).brightness, Brightness.dark);
    await t.shot('settings-dark');
    await t.tapAndPump(find.byTooltip('Green'));
    expect(Theme.of(t.element(find.text('Theme'))).colorScheme.primary, Accent.green.dark);
    await t.tapAndPump(find.byTooltip('Blue'));
    await t.tapAndPump(find.text('Impeller'));
    expect(find.text('Takes effect after restart'), findsOneWidget);
    await t.shot('settings-renderer');
    await t.tapAndPump(find.text('Skia'));
    expect(find.text('Takes effect after restart'), findsNothing);
    await t.tapAndPump(find.text('Impeller'));
    await t.tapAndPump(find.text('中文'));
    expect(find.text('主题'), findsOneWidget);
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.until('drawer closed', () => find.text('主题').evaluate().isEmpty);
    await t.shot('vault-empty-zh');

    final file = File('${dir.path}/settings.json');
    await t.until('settings saved', () => file.readAsStringSync().contains('"zh"'));
    final saved = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    expect(saved['themeMode'], 'dark');
    expect(saved['renderer'], 'impeller');
    expect(saved['accent'], 'blue');
  });
}

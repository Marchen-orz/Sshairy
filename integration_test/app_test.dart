// Drives the real app against a real server (docs/TESTING.md §2); credentials come only from the environment.
// Usage: SSHAIRY_TEST_TARGET=user@host SSHAIRY_TEST_PASSWORD=... flutter test integration_test/app_test.dart -d windows
// Optional: SSHAIRY_TEST_SHOTS=<dir> saves screenshots there.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sshairy/design/controls.dart';
import 'package:sshairy/design/dialog.dart';
import 'package:sshairy/design/popup.dart';
import 'package:sshairy/design/select.dart';
import 'package:sshairy/design/theme.dart';
import 'package:sshairy/features/credentials/api.dart';
import 'package:sshairy/features/credentials/adapters/secure_store.dart';
import 'package:sshairy/features/files/api.dart';
import 'package:sshairy/features/hosts/api.dart';
import 'package:sshairy/features/settings/api.dart';
import 'package:sshairy/features/terminal/api.dart';
import 'package:sshairy/features/workspace/api.dart';
import 'package:sshairy/foundation/ids.dart';
import 'package:xterm2/xterm.dart';

import 'support/driver.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  final address = target.split('@').last;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('sshairy-it');
    await File('${dir.path}/settings.json').writeAsString('{"locale":"en"}');
  });
  tearDown(() async {
    // The app can still hold its log file for a moment; the directory is a throwaway copy either way.
    for (var i = 0; i < 20; i++) {
      try {
        await dir.delete(recursive: true);
        return;
      } on FileSystemException {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
  });

  testWidgets('host key: rejecting stops the attempt, a changed key is flagged', (t) async {
    t.testTextInput.register();
    await t.startApp(dir);

    await t.quickConnect();
    await t.untilFound(find.text('Unknown host'));
    await t.shot('hostkey-unknown');
    await t.tapAndPump(inDialog(find.text('Cancel')));
    await t.untilFound(find.text('Host key rejected'));
    expect(find.byType(AppDialog), findsNothing, reason: 'no password prompt after rejecting the key');
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

    // Removing the record from settings means the next connection asks again.
    await t.tapAndPump(find.byTooltip('Settings'));
    await t.scrollUntilVisible(
      find.byTooltip('Remove'),
      300,
      scrollable: find.descendant(of: find.byType(SettingsPanel), matching: find.byType(Scrollable)).first,
    );
    final record = find.descendant(of: find.byType(SettingsPanel), matching: find.textContaining(address));
    expect(record, findsOneWidget);
    await t.shot('settings-trust');
    await t.tapAndPump(find.byTooltip('Remove'));
    expect(record, findsNothing);
    expect(find.text('None'), findsOneWidget);
    final left = jsonDecode(await trust.readAsString()) as Map<String, dynamic>;
    expect((left['keys'] as Map<String, dynamic>), isEmpty);
  });

  testWidgets('terminal: runs commands, searches, reconnects, survives tab changes', (t) async {
    t.testTextInput.register();
    await File('${dir.path}/settings.json').writeAsString('{"locale":"en","autoReconnect":true}');
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
    await t.untilFound(find.byType(AppDialog));
    expect(term.buffer.getText(), isNot(contains('pasted-2')), reason: 'nothing is sent before confirming');
    await t.shot('paste-confirm');
    await t.tapAndPump(inDialog(find.text('Paste')));
    // bash has bracketed paste on: the text waits on the command line until Enter.
    await t.until('pasted text shown', () => term.buffer.getText().contains(r'echo pasted-$((2+2))'));
    expect(term.buffer.getText(), isNot(contains('pasted-4')), reason: 'a paste must not run by itself');
    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    await t.until('pasted lines ran', () => term.buffer.getText().contains('pasted-4'));
    await t.untilPrompt();

    await t.ctrlShift(LogicalKeyboardKey.keyF);
    await t.untilFound(find.widgetWithText(TextField, 'Find'));
    await t.enterText(find.widgetWithText(TextField, 'Find'), 'pasted-');
    await t.pump();
    // Both echoed command lines and both results: the newest is current.
    final count = find.textContaining(RegExp(r'^\d+/\d+$'));
    await t.untilFound(count);
    final total = int.parse(t.widget<Text>(count).data!.split('/').last);
    expect(total, greaterThanOrEqualTo(4));
    expect(t.widget<Text>(count).data, '$total/$total');
    await t.testTextInput.receiveAction(TextInputAction.done);
    await t.pump();
    expect(t.widget<Text>(count).data, '${total - 1}/$total', reason: 'Enter goes to the match above');
    await t.enterText(find.widgetWithText(TextField, 'Find'), 'no-such-text-sshairy');
    await t.pump();
    expect(find.text('No results'), findsOneWidget);
    await t.shot('search');
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pump();
    expect(find.text('No results'), findsNothing);
    await t.expectShellAlive(3);

    await t.run('exit');
    await t.untilFound(find.text('Disconnected'));
    await t.shot('disconnected');
    // Leaving the shell only closes the channel; the connection is parked, so reconnecting needs no password.
    await t.tapAndPump(find.text('Reconnect'));
    await t.untilPrompt();
    expect(find.byType(AppDialog), findsNothing);
    expect(find.text('Disconnected'), findsNothing);
    expect(t.terminal, same(term));

    // Ending our own sshd session drops the transport; with auto-reconnect on, the pane dials again by itself.
    await t.run(r'kill $PPID');
    await t.untilFound(find.textContaining('Reconnecting in'));
    await t.shot('reconnecting');
    await t.answerPassword(password);
    await t.untilPrompt();
    expect(t.terminal, same(term));
    await t.expectShellAlive(4);

    await t.tapAndPump(find.text('Hosts'));
    await t.quickConnect();
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

  testWidgets('terminal flow: a flood stays bounded, keeps flowing in a hidden tab, and Ctrl+C ends it', (t) async {
    t.testTextInput.register();
    await t.startApp(dir);
    await t.quickConnect();
    await t.untilFound(find.text('Unknown host'));
    await t.tapAndPump(inDialog(find.text('Trust')));
    await t.answerPassword(password);
    await t.untilPrompt();
    final term = t.terminal;
    final session = ProviderScope.containerOf(t.element(find.byType(WorkspacePage)))
        .read(terminalSessionsProvider)
        .values
        .single;

    // The line number says how far the output got, whatever the screen shows.
    int latest() {
      final last = RegExp(r'flood-(\d+)-').allMatches(term.buffer.getText()).lastOrNull;
      return last == null ? 0 : int.parse(last.group(1)!);
    }

    Future<void> wait(Duration d) async {
      final end = DateTime.now().add(d);
      while (DateTime.now().isBefore(end)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await t.pump();
      }
    }

    final clock = Stopwatch()..start();
    final baselineRss = ProcessInfo.currentRss;
    var peakRss = baselineRss, peakPending = 0, maxLag = 0, last = clock.elapsedMilliseconds, ticks = 0;
    final sampler = Timer.periodic(const Duration(milliseconds: 50), (_) {
      final now = clock.elapsedMilliseconds;
      maxLag = max(maxLag, now - last - 50);
      last = now;
      peakPending = max(peakPending, session.pendingOutputBytes);
      if (++ticks % 10 == 0) peakRss = max(peakRss, ProcessInfo.currentRss);
    });
    addTearDown(sampler.cancel);

    await t.run("seq -f 'flood-%.0f-0123456789abcdefghijklmnopqrstuvwxyz' 1 100000000");
    await t.until('the flood has started', () => latest() > 2000, seconds: 60);
    final started = latest();
    final startedAt = clock.elapsedMilliseconds;
    await wait(const Duration(seconds: 8));
    final rate = (latest() - started) * 55 * 1000 ~/ (clock.elapsedMilliseconds - startedAt);
    report('flood: about ${rate ~/ 1024} KiB/s reached the screen');

    // A tab nobody looks at keeps consuming: the model is the session's, the view only displays it.
    await t.tapAndPump(find.text('Hosts'));
    expect(find.byType(TerminalView).hitTestable(), findsNothing);
    final hiddenFrom = latest();
    await wait(const Duration(seconds: 5));
    final hiddenTo = latest();
    report('hidden for 5 s: line $hiddenFrom -> $hiddenTo, unread=${session.unread}');
    expect(hiddenTo - hiddenFrom, greaterThan(1000), reason: 'output kept being parsed while no view was shown');
    expect(session.unread, isTrue);

    await t.tapAndPump(find.text(address).first);
    expect(t.terminal, same(term));
    expect(session.unread, isFalse);
    await t.tapAndPump(find.byType(TerminalView).hitTestable().first);
    final interrupt = Stopwatch()..start();
    await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await t.sendKeyEvent(LogicalKeyboardKey.keyC);
    await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await t.until('Ctrl+C ends the flood', () => term.buffer.getText().trim().endsWith(r'$'), seconds: 60);
    interrupt.stop();
    final endedAt = latest();
    await wait(const Duration(seconds: 2));
    expect(latest(), endedAt, reason: 'nothing more arrives once the prompt is back');
    await t.expectShellAlive(5);

    sampler.cancel();
    peakRss = max(peakRss, ProcessInfo.currentRss);
    report('Ctrl+C to prompt: ${interrupt.elapsedMilliseconds} ms (the output already on the way arrives first)');
    report(
      'peak queued ${peakPending ~/ 1024} KiB, memory +${(peakRss - baselineRss) ~/ (1 << 20)} MiB, '
      'longest event-loop stall $maxLag ms, lines ${latest()}',
    );
    expect(peakPending, lessThanOrEqualTo(2 << 20), reason: 'the queue stays near its high water mark');
    expect(peakRss - baselineRss, lessThan(200 << 20));
    expect(interrupt.elapsedMilliseconds, lessThan(20000));
    await t.closeTabByKeyboard();
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
    final ref = SecretRef.hostPassword(HostId((hosts['hosts'] as List<dynamic>).single['id'] as String));
    const secrets = SecretStore();
    addTearDown(() => secrets.delete(ref));
    expect(await secrets.read(ref), isNull);

    await t.tapAndPump(find.byTooltip('Connect'));
    await t.untilFound(find.text('Unknown host'));
    await t.tapAndPump(inDialog(find.text('Trust')));
    await t.answerPassword('sshairy-wrong-password');
    await t.until(
      'auth result',
      () => find.text('Authentication failed').evaluate().isNotEmpty || find.byType(AppDialog).evaluate().isNotEmpty,
    );
    // Servers that fall back to keyboard-interactive ask again; never send a second wrong password.
    if (find.byType(AppDialog).evaluate().isNotEmpty) await t.tapAndPump(inDialog(find.text('Cancel')));
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
    expect(find.byType(AppDialog), findsNothing, reason: 'saved password and trusted key need no prompts');
    await t.expectShellAlive(9);
    await t.closeTabByKeyboard();

    await t.tapAndPump(find.descendant(of: find.byType(Card), matching: find.byTooltip('More')));
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
    await File('${dir.path}/hosts.json').writeAsString(
      jsonEncode({
        'schemaVersion': 1,
        'hosts': [
          {'id': 'wshost', 'label': 'sshairy-ws', 'address': host, 'port': 22, 'username': user, 'auth': 'password'},
        ],
      }),
    );
    await t.startApp(dir);

    await t.palette('sshairy-ws');
    await t.untilFound(find.text('Unknown host'));
    await t.tapAndPump(inDialog(find.text('Trust')));
    await t.answerPassword(password);
    await t.untilPrompt();

    await t.palette('Split right');
    await t.until('two panes', () => t.visibleTerminals.length == 2);
    expect(find.byType(AppDialog), findsNothing, reason: 'the split shares the first connection');
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
    expect(find.byType(AppDialog), findsNothing, reason: 'a restored tab must not dial by itself');
    await t.shot('restored');
    await t.tapAndPump(find.widgetWithText(FilledButton, 'Connect'));
    await t.answerPassword(password);
    await t.untilPrompt();
    await t.expectShellAlive(5);

    // The tab bar comes before the host tree, which lists the host under the same name.
    await t.tap(find.text('sshairy-ws').hitTestable().first, buttons: kSecondaryButton);
    await t.pump(const Duration(milliseconds: 300));
    await t.tapAndPump(find.text('Rename'));
    await t.enterText(inDialog(find.byType(TextField)), 'prod');
    await t.tapAndPump(inDialog(find.text('Save')));
    expect(find.text('prod'), findsOneWidget);
    await t.palette('Duplicate');
    await t.until('two tabs', () => t.workspace.tabs.length == 2);
    await t.untilPrompt();
    expect(find.byType(AppDialog), findsNothing, reason: 'the copy shares the connection');
    await t.shot('tabs');
    await t.closeTabByKeyboard();

    await t.palette('Theme: Dark');
    await t.until('dark theme', () => Theme.of(t.element(find.byType(WorkspacePage))).brightness == Brightness.dark);
    await t.closeTabByKeyboard();
  });

  testWidgets('vault: groups, search by tag, pin, list view, a generated key on a host', (t) async {
    t.testTextInput.register();
    Map<String, Object?> host(String id, String group, [List<String> tags = const []]) => {
      'id': id,
      'label': id,
      'address': '$id.invalid',
      'username': 'u',
      'auth': 'password',
      'group': group,
      'tags': tags,
    };
    await File('${dir.path}/hosts.json').writeAsString(
      jsonEncode({
        'schemaVersion': 1,
        'hosts': [
          host('alpha', 'prod/web', ['nginx']),
          host('bravo', 'prod'),
          host('charlie', ''),
        ],
      }),
    );
    await t.startApp(dir);
    double top(String label) => t.getTopLeft(find.text(label)).dy;
    double left(String label) => t.getTopLeft(find.text(label)).dx;
    bool shown(String label) => find.text(label).evaluate().isNotEmpty;

    Finder chip(String label) => find.widgetWithText(ChoiceChip, label);
    await t.tapAndPump(chip('prod/web'));
    expect([shown('alpha'), shown('bravo'), shown('charlie')], [true, false, false]);
    await t.tapAndPump(chip('prod'));
    expect([shown('alpha'), shown('bravo'), shown('charlie')], [true, true, false]);
    await t.tapAndPump(chip('All'));
    await t.enterText(find.byType(TextField).first, 'nginx');
    await t.pump();
    expect([shown('alpha'), shown('bravo'), shown('charlie')], [true, false, false]);
    await t.enterText(find.byType(TextField).first, '');
    await t.pump();

    await t.tapAndPump(find.descendant(of: find.byType(Card).at(2), matching: find.byTooltip('More')));
    await t.tapAndPump(find.text('Pin'));
    await t.until('charlie first', () => left('charlie') < left('alpha') || top('charlie') < top('alpha'));
    await t.tapAndPump(find.byTooltip('List'));
    expect(top('charlie') < top('alpha') && top('alpha') < top('bravo'), isTrue);
    expect(find.textContaining('#nginx'), findsOneWidget);
    await t.shot('vault-list');

    // A generated key, given to a host; while a host uses it, it cannot be deleted.
    await t.tapAndPump(find.byTooltip('Keys'));
    await t.tapAndPump(find.text('Generate key'));
    await t.enterText(inDialog(find.byType(TextField)), 'sshairy-it-key');
    await t.tapAndPump(inDialog(find.text('Save')));
    await t.untilFound(find.text('sshairy-it-key'));
    final keys = jsonDecode(await File('${dir.path}/keys.json').readAsString()) as Map<String, dynamic>;
    final key = (keys['keys'] as List<dynamic>).single as Map<String, dynamic>;
    final privateRef = SecretRef.privateKey(key['id'] as String);
    const secrets = SecretStore();
    addTearDown(() => secrets.delete(privateRef));
    expect((await secrets.read(privateRef))?.reveal(), contains('OPENSSH PRIVATE KEY'));
    expect(jsonEncode(keys), isNot(contains('PRIVATE KEY')));
    await t.tapAndPump(find.byTooltip('Copy public key'));
    expect((await Clipboard.getData(Clipboard.kTextPlain))?.text, key['publicKey']);
    await t.shot('keys');
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.until('drawer closed', () => find.text('sshairy-it-key').evaluate().isEmpty);

    await t.tapAndPump(find.descendant(of: find.byType(Card).at(1), matching: find.byTooltip('More')));
    await t.tapAndPump(find.text('Edit'));
    await t.tapAndPump(find.text('Password'));
    await t.tapAndPump(find.text('Private key').last);
    await t.tapAndPump(find.widgetWithText(AppSelect<String?>, 'Private key'));
    await t.tapAndPump(find.text('sshairy-it-key · ssh-ed25519').last);
    await t.shot('host-form-key');
    await t.tapAndPump(find.text('Save'));
    await t.until('saved', () => File('${dir.path}/hosts.json').readAsStringSync().contains('"keyId"'));

    await t.tapAndPump(find.byTooltip('Keys'));
    expect(find.text('Used by alpha'), findsOneWidget);
    await t.tapAndPump(find.descendant(of: find.byType(KeysPanel), matching: find.byTooltip('More')));
    final delete = t.widget<PopupRow>(find.ancestor(of: find.text('Delete'), matching: find.byType(PopupRow)));
    expect(delete.onTap, isNull);
  });

  testWidgets('settings: theme, font size and language apply and persist', (t) async {
    t.testTextInput.register();
    await t.startApp(dir);

    await t.tapAndPump(find.byTooltip('Settings'));
    await t.tapAndPump(find.text('Dark'));
    expect(Theme.of(t.element(find.text('Theme'))).brightness, Brightness.dark);
    await t.shot('settings-dark');
    await t.tapAndPump(find.text('Mint Green'));
    expect(
      Theme.of(t.element(find.text('Theme'))).colorScheme.primary,
      Accent.green.palette(Brightness.dark).controlPrimary,
    );
    await t.tapAndPump(find.text('Ice Blue · Mint'));
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

  testWidgets('files: side panel, SFTP page, folder ops, transfers both ways, conflict, cancel', (t) async {
    t.testTextInput.register();
    final [user, host] = target.split('@');
    await File('${dir.path}/hosts.json').writeAsString(
      jsonEncode({
        'schemaVersion': 1,
        'hosts': [
          {'id': 'fhost', 'label': 'sshairy-files', 'address': host, 'port': 22, 'username': user, 'auth': 'password'},
        ],
      }),
    );
    final local = await Directory('${dir.path}/local 本地').create();
    final rnd = Random(7);
    Uint8List bytes(int n) => Uint8List.fromList(List.generate(n, (_) => rnd.nextInt(256)));
    await File('${local.path}/up 上传.bin').writeAsBytes(bytes(3 << 20));
    await File('${local.path}/huge.bin').writeAsBytes(bytes(64 << 20));
    await t.startApp(dir);

    await t.palette('sshairy-files');
    await t.untilFound(find.text('Unknown host'));
    await t.tapAndPump(inDialog(find.text('Trust')));
    await t.answerPassword(password);
    await t.untilPrompt();
    final term = t.terminal;
    final tab = t.workspace.active!;
    // Everything happens in ~/sshairy-test (TESTING §2), which the end of the test removes.
    await t.run(
      "rm -rf ~/sshairy-test && mkdir -p ~/sshairy-test/'中文 目录' && cd ~/sshairy-test && "
      "head -c 2000000 /dev/urandom > 'big file.bin' && echo hello > '中文 目录/note.txt' && ln -s '中文 目录' 'dir link' && echo ready-\$((2*3))",
    );
    await t.until('remote fixtures', () => term.buffer.getText().contains('ready-6'));

    // The side panel shares the terminal's connection.
    await t.tapAndPump(find.byTooltip('Files'));
    await t.untilReady(0);
    await t.openRow(0, 'sshairy-test');
    await t.untilRow(0, 'big file.bin');
    expect(t.rowFinder(0, '中文 目录'), findsOneWidget);
    await t.shot('files-side');
    await t.tapAndPump(find.byType(TerminalView).hitTestable().first);
    await t.expectShellAlive(2);

    await t.tapAndPump(find.text('SFTP'));
    await t.untilReady(0);
    await t.typePath(0, local.path);
    await t.untilRow(0, 'up 上传.bin');
    await t.tapAndPump(find.descendant(of: find.byType(FilesPage), matching: find.text('sshairy-files')));
    await t.untilReady(1);
    await t.openRow(1, 'sshairy-test');
    await t.untilRow(1, 'big file.bin');
    await t.shot('files-page');

    // Folder operations through the dialogs, checked from the shell.
    await t.tapAndPump(find.descendant(of: t.pane(1), matching: find.byTooltip('More')));
    await t.tapAndPump(find.text('New folder'));
    await t.enterText(inDialog(find.byType(TextField)), 'new 新建');
    await t.tapAndPump(inDialog(find.text('Save')));
    await t.untilRow(1, 'new 新建');
    await t.tapAndPump(t.rowFinder(1, 'new 新建'));
    await t.sendKeyEvent(LogicalKeyboardKey.f2);
    await t.untilFound(inDialog(find.byType(TextField)));
    await t.enterText(inDialog(find.byType(TextField)), 'renamed 改名');
    await t.tapAndPump(inDialog(find.text('Save')));
    await t.untilRow(1, 'renamed 改名');
    final before = t.entry(1, 'renamed 改名').mode! & 0x1FF;
    await t.menu(t.rowFinder(1, 'renamed 改名'), 'Permissions');
    await t.tapAndPump(inDialog(find.byType(AppCheckbox)).last);
    await t.tapAndPump(inDialog(find.text('Save')));
    final after = before ^ 1;
    await t.until('mode changed', () => (t.entry(1, 'renamed 改名').mode! & 0x1FF) == after);
    await t.atTerminal(tab);
    await t.run("stat -c mode-%a 'renamed 改名'");
    await t.until('mode on the server', () => term.buffer.getText().contains('mode-${after.toRadixString(8)}'));
    await t.tapAndPump(find.text('SFTP'));
    await t.tapAndPump(t.rowFinder(1, 'renamed 改名'));
    await t.sendKeyEvent(LogicalKeyboardKey.delete);
    await t.untilFound(inDialog(find.text('Delete')));
    await t.tapAndPump(inDialog(find.text('Delete')));
    await t.until('deleted', () => t.rowFinder(1, 'renamed 改名').evaluate().isEmpty);
    // Deleting a link to a folder removes the link only.
    await t.tapAndPump(t.rowFinder(1, 'dir link'));
    await t.sendKeyEvent(LogicalKeyboardKey.delete);
    await t.untilFound(inDialog(find.text('Delete')));
    await t.tapAndPump(inDialog(find.text('Delete')));
    await t.until('link deleted', () => t.rowFinder(1, 'dir link').evaluate().isEmpty);
    await t.atTerminal(tab);
    await t.run("echo kept-\$(cat '中文 目录/note.txt')");
    await t.until('target kept', () => term.buffer.getText().contains('kept-hello'));
    await t.tapAndPump(find.text('SFTP'));

    // Upload, download a file and a folder; compare contents on both sides.
    await t.menu(t.rowFinder(0, 'up 上传.bin'), 'Send to the other side');
    await t.untilTransfers(1);
    await t.untilRow(1, 'up 上传.bin');
    await t.menu(t.rowFinder(1, 'big file.bin'), 'Send to the other side');
    await t.untilTransfers(2);
    await t.menu(t.rowFinder(1, '中文 目录'), 'Send to the other side');
    await t.untilTransfers(3);
    expect(File('${local.path}/中文 目录/note.txt').readAsStringSync(), 'hello\n');
    final upHash = sha256.convert(File('${local.path}/up 上传.bin').readAsBytesSync()).toString();
    final downHash = sha256.convert(File('${local.path}/big file.bin').readAsBytesSync()).toString();
    await t.atTerminal(tab);
    await t.run("sha256sum 'up 上传.bin' 'big file.bin'; echo parts-\$(ls -A | grep -c part)");
    await t.until('hashes', () {
      final text = term.buffer.getText().replaceAll('\n', '');
      return text.contains(upHash) && text.contains(downHash) && text.contains('parts-0');
    });

    // The same name again asks; keeping both writes a second copy.
    await t.tapAndPump(find.text('SFTP'));
    await t.menu(t.rowFinder(1, 'big file.bin'), 'Send to the other side');
    await t.untilFound(find.text('"big file.bin" already exists'));
    await t.shot('files-conflict');
    await t.tapAndPump(inDialog(find.text('Keep both')));
    await t.untilTransfers(4);
    expect(File('${local.path}/big file (1).bin').lengthSync(), 2000000);

    // Cancelling an upload leaves no partial file and the terminal untouched.
    await t.menu(t.rowFinder(0, 'huge.bin'), 'Send to the other side');
    await t.until('upload running', () => t.transfers.any((x) => x.state == TransferState.running && x.bytes > 0));
    // Closing the window now asks first; staying keeps the upload going.
    final exit = t.binding.handleRequestAppExit();
    await t.untilFound(find.text('1 transfer in progress'));
    await t.shot('quit-confirm');
    await t.tapAndPump(inDialog(find.text('Cancel')));
    expect(await exit, ui.AppExitResponse.cancel);
    expect(t.transfers.any((x) => x.state == TransferState.running), isTrue);
    await t.tapAndPump(find.byTooltip('Transfers'));
    await t.shot('files-transfers');
    await t.tapAndPump(find.descendant(of: find.byType(TransfersPanel), matching: find.byTooltip('Cancel')));
    await t.until('cancelled', () => t.transfers.any((x) => x.state == TransferState.cancelled));
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pump(const Duration(milliseconds: 300));
    await t.atTerminal(tab);
    await t.run("echo left-\$(ls -A | grep -c -e part -e huge)");
    await t.until('nothing left of the upload', () => term.buffer.getText().contains('left-0'));
    await t.expectShellAlive(5);

    await t.run(r'cd ~ && rm -rf ~/sshairy-test && echo cleaned-$((5*5))');
    await t.until('cleaned up', () => term.buffer.getText().contains('cleaned-25'));
  });
}

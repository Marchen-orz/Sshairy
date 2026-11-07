// Real server only (docs/TESTING.md §2, P-01). Five sessions with full scrollback and a files panel, then the same
// sessions closed and opened again; the process's resident memory is printed after each step (REPORT lines).
// The numbers that matter come from a profile build (flutter drive does not run release on desktop):
//   flutter drive --driver=test_driver/integration_test.dart --target=integration_test/memory_test.dart -d windows --profile
// A debug build also keeps every provider state in Riverpod's devtool, so closed terminals stay reachable there.
// Usage: SSHAIRY_TEST_TARGET=user@host SSHAIRY_TEST_PASSWORD=... as for the other integration tests.
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:vm_service/vm_service_io.dart';
import 'package:xterm2/xterm.dart';

import 'support/driver.dart';

int _mib() => ProcessInfo.currentRss >> 20;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('sshairy-mem');
    await File('${dir.path}/settings.json').writeAsString('{"locale":"en"}');
  });
  tearDown(() async {
    for (var i = 0; i < 20; i++) {
      try {
        await dir.delete(recursive: true);
        return;
      } on FileSystemException {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
  });

  testWidgets('memory: five sessions and a files panel, then closed and opened again', (t) async {
    t.testTextInput.register();
    final mode = kReleaseMode
        ? 'release'
        : kProfileMode
        ? 'profile'
        : 'debug';

    Future<void> settle(String what) async {
      // Freed memory goes back to the system a little after the last frame.
      for (var i = 0; i < 40; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await t.pump();
      }
      report('memory[$mode] $what: ${_mib()} MiB');
    }

    // Closed sessions should leave nothing behind: their terminals must become collectable.
    final terminals = <WeakReference<Terminal>>[];

    /// A full collection on request, then how many of the terminals seen so far are still alive.
    Future<int> retained() async {
      final info = await developer.Service.getInfo();
      final uri = info.serverWebSocketUri;
      if (uri == null) fail('the VM service is not running, so a collection cannot be requested');
      final service = await vmServiceConnectUri(uri.toString());
      try {
        await service.getAllocationProfile(developer.Service.getIsolateId(Isolate.current)!, gc: true);
      } finally {
        await service.dispose();
      }
      await t.pump();
      final left = terminals.where((r) => r.target != null).length;
      terminals.clear();
      return left;
    }

    // A finite flood whose last line says the scrollback (2000 lines by default) is full.
    Future<void> fill(int n) async {
      // Typed straight into the terminal: simulated key events do not exist outside debug builds.
      t.terminal.textInput("seq -f 'fill$n-%.0f-0123456789abcdefghijklmnopqrstuvwxyz' 1 4000\r");
      await t.until('session $n filled', () => t.terminal.buffer.getText().contains('fill$n-4000-'), seconds: 120);
      await t.untilPrompt();
      terminals.add(WeakReference(t.terminal));
    }

    Future<void> openFive({required bool first}) async {
      for (var n = 1; n <= 5; n++) {
        if (n > 1) await t.tapAndPump(find.text('Hosts'));
        await t.quickConnect();
        if (first && n == 1) {
          await t.untilFound(find.text('Unknown host'));
          await t.tapAndPump(inDialog(find.text('Trust')));
          await t.answerPassword(password);
        } else {
          await t.until('prompt or password dialog', () {
            return find.byType(AlertDialog).evaluate().isNotEmpty ||
                find.byType(TerminalView).hitTestable().evaluate().isNotEmpty;
          });
          if (find.byType(AlertDialog).evaluate().isNotEmpty) await t.answerPassword(password);
        }
        await t.untilPrompt();
        await fill(n);
      }
    }

    Future<void> closeAll() async {
      for (var i = 0; i < 8 && find.byType(TerminalView).hitTestable().evaluate().isNotEmpty; i++) {
        t.closeActiveTab();
        await t.pump(const Duration(milliseconds: 300));
      }
      expect(find.byType(TerminalView).hitTestable(), findsNothing);
    }

    await t.startApp(dir);
    await settle('idle at start');

    await openFive(first: true);
    await settle('five sessions, scrollback full');

    await t.tapAndPump(find.byTooltip('Files'));
    await t.untilReady(0);
    await t.typePath(0, '/usr/bin');
    await t.until('/usr/bin listed', () => t.entry(0, 'ls').name == 'ls');
    await settle('five sessions and a files panel in /usr/bin');

    final cycles = <int>[];
    for (var cycle = 1; cycle <= 4; cycle++) {
      await closeAll();
      final left = await retained();
      report('memory[$mode] cycle $cycle: $left of 5 closed terminals still in memory after a collection');
      if (!kDebugMode) expect(left, 0, reason: 'a closed session must not be kept alive by the connection');
      await settle('cycle $cycle: all closed');
      await openFive(first: false);
      await settle('cycle $cycle: five sessions again');
      cycles.add(_mib());
    }
    report('memory[$mode] after each reopening: ${cycles.join(', ')} MiB');
    expect(cycles.last, lessThan(cycles.first + 100), reason: 'memory should not keep growing with every reopening');
    await closeAll();
  });
}

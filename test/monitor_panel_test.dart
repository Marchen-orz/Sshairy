import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/design/theme.dart';
import 'package:sshairy/features/connections/api.dart';
import 'package:sshairy/features/hosts/api.dart';
import 'package:sshairy/features/monitor/api.dart';
import 'package:sshairy/features/monitor/presentation/monitor_widgets.dart';
import 'package:sshairy/features/monitor/presentation/process_dialog.dart';
import 'package:sshairy/foundation/data_dir.dart';
import 'package:sshairy/foundation/ids.dart';
import 'package:sshairy/l10n/app_localizations.dart';

import 'connection_manager_test.dart' show FakeTransport, NoPrompts;

/// Answers the monitor's probe with a small Linux server whose `worker` process keeps one core busy.
class _Server extends FakeTransport {
  final commands = <String>[];
  var gpu = false;
  var _ticks = 0;

  @override
  Future<ExecResult> exec(String command, {int limit = 0}) async {
    commands.add(command);
    if (command.startsWith('kill ')) return ExecResult(Uint8List(0), Uint8List(0), 0);
    // Each sample: 200 ticks over two cores, all of one core's going to the worker.
    _ticks += 100;
    final out = StringBuffer('''
@@stat
cpu  ${100 + _ticks} 0 0 ${900 + _ticks} 0 0 0 0
cpu0 ${50 + _ticks} 0 0 450 0 0 0 0
cpu1 50 0 0 ${450 + _ticks} 0 0 0 0
@@mem
MemTotal: 2000000 kB
MemAvailable: 500000 kB
SwapTotal: 1000000 kB
SwapFree: 750000 kB
@@load
0.52 0.40 0.31 1/123 4567
@@up
93784.12 1.0
@@net
  eth0: ${1000 * _ticks} 1 0 0 0 0 0 0 500 1 0 0 0 0 0 0
@@conf
4096
100
@@df
Filesystem 1024-blocks Used Available Capacity Mounted on
/dev/vda2 41152812 20576406 18663036 53% /
@@proc
1 S 0 500 1 1 3000 systemd
400 R 1 ${1000 + _ticks} 4 9000 25600 worker
@@gpus
${gpu ? 'nvidia' : ''}
''');
    if (command.contains('@@ps')) out.write('@@ps\n  PID USER COMMAND\n  400 alice /usr/bin/worker --jobs 4\n');
    if (command.contains('@@nvgpu')) {
      out.write(
        '@@nvgpu\n0, GPU-a, NVIDIA A10, 37, 2048, 24576, 61, 85, 150, 30, 1695, 6251\n'
        '@@nvproc\n400, 1800, GPU-a, /usr/bin/worker\n',
      );
    }
    return ExecResult(Uint8List.fromList(utf8.encode(out.toString())), Uint8List(0), 0);
  }
}

void main() {
  const host = Host(id: HostId('h'), label: 'web', address: '10.0.0.5', username: 'u');

  Future<_Server> pump(WidgetTester tester, {bool gpu = false}) async {
    final server = _Server()..gpu = gpu;
    final manager = ConnectionManager((_, _, _) async => server);
    // The panel never dials: the terminal's lease is what makes the host connected.
    await manager.acquire(host, NoPrompts());
    final dir = Directory.systemTemp.createTempSync('sshairy-monitor-');
    addTearDown(() => dir.deleteSync(recursive: true));
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [dataDirProvider.overrideWithValue(dir.path), connectionManagerProvider.overrideWithValue(manager)],
        child: MaterialApp(
          theme: buildTheme(Brightness.light),
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(
            body: Align(
              alignment: Alignment.centerLeft,
              child: MonitorPanel(host: host, active: true),
            ),
          ),
        ),
      ),
    );
    // Two samples give rates.
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(Motion.normal);
    return server;
  }

  testWidgets('the panel shows rings, top processes, network and disks without a GPU page', (tester) async {
    await pump(tester);
    expect(find.text('10.0.0.5'), findsOneWidget);
    expect(find.byType(MonitorRing), findsNWidgets(3));
    expect(find.text('CPU'), findsWidgets);
    expect(find.text('50%'), findsOneWidget, reason: 'one of two cores busy');
    expect(find.text('worker'), findsOneWidget);
    expect(find.text('100'), findsOneWidget, reason: 'one busy core is 100% in top');
    expect(find.text('/'), findsOneWidget);
    expect(find.text('GPU'), findsNothing);
    expect(find.text('3s'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the process window lists owners, sorts and ends a process after confirming', (tester) async {
    final server = await pump(tester);
    expect(server.commands.last, isNot(contains('@@ps')));
    await tester.tap(find.text('worker'));
    await tester.pump();
    await tester.pump(Motion.normal);
    expect(find.byType(ProcessDialog), findsOneWidget);
    expect(server.commands.last, contains('@@ps'), reason: 'opening the window samples at once with owners');
    await tester.pump(Motion.normal);
    expect(find.text('alice'), findsOneWidget);
    expect(find.text('/usr/bin/worker --jobs 4'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'systemd');
    await tester.pump();
    expect(find.text('/usr/bin/worker --jobs 4'), findsNothing);
    await tester.enterText(find.byType(TextField), '');
    await tester.pump();

    final row = find.text('/usr/bin/worker --jobs 4');
    await tester.tap(row, buttons: kSecondaryButton);
    await tester.pump(Motion.normal);
    await tester.tap(find.text('End process'));
    await tester.pump(Motion.normal);
    expect(find.text('End worker (PID 400)?'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'End process'));
    await tester.pump(Motion.normal);
    expect(server.commands, contains('kill -s TERM 400'));

    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(find.byType(ProcessDialog), findsNothing);
    final closed = server.commands.length;
    await tester.pump(const Duration(seconds: 3));
    expect(server.commands.skip(closed), [
      isNot(contains('@@ps')),
    ], reason: 'owners are only fetched while the window is open');
    expect(tester.takeException(), isNull);
  });

  testWidgets('a detected GPU adds a page that queries the card only while shown', (tester) async {
    final server = await pump(tester, gpu: true);
    expect(server.commands.last, isNot(contains('@@nvgpu')));
    await tester.tap(find.text('GPU'));
    await tester.pump();
    await tester.pump(Motion.normal);
    expect(server.commands.last, contains('@@nvgpu'));
    expect(find.text('#0 NVIDIA A10'), findsOneWidget);
    expect(find.text('61°C'), findsOneWidget);
    expect(find.text('85/150 W'), findsOneWidget);
    expect(find.text('worker'), findsOneWidget);
    await tester.tap(find.text('System'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    expect(server.commands.last, isNot(contains('@@nvgpu')));
    expect(tester.takeException(), isNull);
  });
}

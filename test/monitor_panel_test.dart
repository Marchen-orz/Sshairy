import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/design/theme.dart';
import 'package:sshairy/design/scrolling.dart';
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
  var sortable = false;
  var spikeMemory = false;
  var _ticks = 0;

  static const processes = [
    (800, 'zulu', 7, 4),
    (700, 'alpha', 6, 2),
    (600, 'beta', 5, 8),
    (500, 'delta', 4, 1),
    (400, 'gamma', 3, 6),
    (300, 'aardvark', 2, 9),
    (200, 'Beta', 1, 8),
    (100, 'epsilon', 0, 3),
  ];

  String get processData => sortable
      ? [
          for (final (pid, name, cpu, pages) in processes)
            '$pid R 1 ${1000 + _ticks * cpu} 1 100 ${spikeMemory && name == 'alpha' ? 20 : pages} $name',
        ].join('\n')
      : '1 S 0 500 1 1 3000 systemd\n400 R 1 ${1000 + _ticks} 4 9000 25600 worker';

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
/dev/vda2 ext4 41152812 20576406 18663036 53% /
/dev/vdb1 xfs 104857600 10485760 94371840 10% /data
@@proc
$processData
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

  Future<_Server> pump(WidgetTester tester, {bool gpu = false, bool sortable = false}) async {
    final server = _Server()
      ..gpu = gpu
      ..sortable = sortable;
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
          scrollBehavior: const AppScrollBehavior(),
          theme: buildTheme(Brightness.light).copyWith(platform: TargetPlatform.windows),
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(
            body: Align(
              alignment: Alignment.centerLeft,
              child: SizedBox(
                width: WorkspaceSize.monitor,
                child: MonitorPanel(host: host, active: true),
              ),
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
    expect(find.text('/dev/vda2'), findsOneWidget);
    expect(find.text('/data'), findsOneWidget);
    expect(find.text('/dev/vdb1'), findsOneWidget);
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

  testWidgets('process column boundaries resize headers and rows without sorting and support keyboard and reset', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.text('worker'));
    await tester.pump();
    await tester.pump(Motion.normal);
    final dialog = find.byType(ProcessDialog);
    Finder header(String column) => find.byKey(ValueKey('process-header-$column'));
    Finder cell(String column) => find.byKey(ValueKey('process-cell-400-$column'));
    Finder divider(String column) => find.byKey(ValueKey('process-resize-$column'));
    double width(String column) => tester.getSize(header(column)).width;
    String direction() {
      final arrow = find.descendant(of: header('cpu'), matching: find.byIcon(Icons.arrow_downward));
      expect(arrow, findsOneWidget);
      return 'cpu descending';
    }

    void aligned() {
      for (final column in ['pid', 'user', 'cpu', 'memory', 'resident', 'state', 'threads', 'elapsed', 'command']) {
        final heading = tester.getRect(header(column));
        final value = tester.getRect(cell(column));
        expect(value.left, closeTo(heading.left, .01), reason: '$column left');
        expect(value.width, closeTo(heading.width, .01), reason: '$column width');
      }
    }

    Future<void> drag(String column, double delta) async {
      final gesture = await tester.startGesture(tester.getCenter(divider(column)));
      await gesture.moveBy(Offset(delta.sign * 20, 0));
      await tester.pump();
      await gesture.moveBy(Offset(delta, 0));
      await tester.pump();
      await gesture.up();
      await tester.pump();
    }

    aligned();
    final original = width('pid');
    expect(direction(), 'cpu descending');
    await drag('pid', 80);
    expect(width('pid'), greaterThan(original + 50));
    expect(direction(), 'cpu descending', reason: 'dragging a boundary cannot sort');
    aligned();
    final expanded = width('pid');
    final handle = tester.element(divider('pid'));
    Focus.of(handle).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(width('pid'), expanded + Space.sm);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(width('pid'), expanded);
    await tester.tap(divider('pid'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(divider('pid'));
    await tester.pumpAndSettle();
    expect(width('pid'), original);
    aligned();
    await tester.tap(find.descendant(of: dialog, matching: find.text('PID')));
    await tester.pump();
    expect(find.descendant(of: header('pid'), matching: find.byIcon(Icons.arrow_upward)), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('resized process columns clamp and remain aligned in a narrow horizontally scrolling table', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.text('worker'));
    await tester.pump();
    await tester.pump(Motion.normal);
    await tester.binding.setSurfaceSize(const Size(560, 700));
    await tester.pumpAndSettle();
    final dialog = find.byType(ProcessDialog);
    final horizontal = find.descendant(of: dialog, matching: find.byType(SingleChildScrollView));
    expect(horizontal, findsOneWidget);
    final controller = tester.widget<SingleChildScrollView>(horizontal).controller!;
    expect(controller.position.maxScrollExtent, greaterThan(0));
    Finder header(String column) => find.byKey(ValueKey('process-header-$column'));
    Finder cell(String column) => find.byKey(ValueKey('process-cell-400-$column'));
    final divider = find.byKey(const ValueKey('process-resize-pid'));
    var gesture = await tester.startGesture(tester.getCenter(divider));
    await gesture.moveBy(const Offset(-20, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(-2000, 0));
    await tester.pump();
    await gesture.up();
    await tester.pump();
    expect(tester.getSize(header('pid')).width, 56);
    gesture = await tester.startGesture(tester.getCenter(divider));
    await gesture.moveBy(const Offset(20, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(2000, 0));
    await tester.pump();
    await gesture.up();
    await tester.pump();
    final maxWidth = tester.getSize(horizontal).width;
    expect(tester.getSize(header('pid')).width, lessThanOrEqualTo(maxWidth));
    controller.jumpTo(controller.position.maxScrollExtent);
    await tester.pump();
    for (final column in ['pid', 'user', 'command']) {
      expect(tester.getRect(cell(column)).left, closeTo(tester.getRect(header(column)).left, .01));
      expect(tester.getSize(cell(column)).width, tester.getSize(header(column)).width);
    }
    await tester.pump(kDoubleTapMinTime);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the process preview sorts the full sample by CPU, memory and name in both directions', (tester) async {
    final server = await pump(tester, sortable: true);
    final preview = find.ancestor(of: find.byTooltip('Show all processes'), matching: find.byType(MonitorCard));
    List<String> names() => [
      for (final text in tester.widgetList<Text>(find.descendant(of: preview, matching: find.byType(Text))))
        if (_Server.processes.any((p) => p.$2 == text.data)) text.data!,
    ];
    Future<void> sort(String label, List<String> expected, IconData direction) async {
      await tester.tap(find.descendant(of: preview, matching: find.text(label)));
      await tester.pump();
      expect(names(), expected);
      expect(find.descendant(of: preview, matching: find.byIcon(direction)), findsOneWidget);
      expect(find.byType(ProcessDialog), findsNothing, reason: 'a header sorts without expanding the card');
    }

    expect(names(), ['zulu', 'alpha', 'beta', 'delta', 'gamma']);
    await sort('Memory', ['aardvark', 'Beta', 'beta', 'gamma', 'zulu'], Icons.arrow_downward);
    await tester.pump(const Duration(seconds: 3));
    expect(names(), ['aardvark', 'Beta', 'beta', 'gamma', 'zulu'], reason: 'refresh retains the selected sort');
    server.spikeMemory = true;
    await tester.pump(const Duration(seconds: 3));
    expect(names(), ['alpha', 'aardvark', 'Beta', 'beta', 'gamma'], reason: 'new samples use the active sort');
    server.spikeMemory = false;
    await tester.pump(const Duration(seconds: 3));
    await sort('Memory', ['delta', 'alpha', 'epsilon', 'zulu', 'gamma'], Icons.arrow_upward);
    await sort('Processes', ['aardvark', 'alpha', 'Beta', 'beta', 'delta'], Icons.arrow_upward);
    await sort('Processes', ['zulu', 'gamma', 'epsilon', 'delta', 'Beta'], Icons.arrow_downward);
    await sort('CPU', ['zulu', 'alpha', 'beta', 'delta', 'gamma'], Icons.arrow_downward);
    await sort('CPU', ['epsilon', 'Beta', 'aardvark', 'gamma', 'delta'], Icons.arrow_upward);
    expect(tester.takeException(), isNull);
  });

  testWidgets('process preview headers and values stay centered while sorting and hovering', (tester) async {
    await pump(tester, sortable: true);
    final preview = find.ancestor(of: find.byTooltip('Show all processes'), matching: find.byType(MonitorCard));
    final allRows = find.descendant(of: preview, matching: find.byType(Row));
    final headerElements = [
      for (final label in ['Memory', 'CPU', 'Processes']) find.descendant(of: preview, matching: find.text(label)),
    ];
    void aligned() {
      final header = tester.widgetList<Row>(allRows).firstWhere((row) => row.children.last is IconButton);
      final centers = [
        for (final index in [0, 1, 3]) tester.getCenter(find.byWidget(header.children[index])).dx,
      ];
      for (var index = 0; index < headerElements.length; index++) {
        final label = headerElements[index];
        final group = tester.widget<Row>(find.ancestor(of: label, matching: find.byType(Row)).first);
        final arrowSpace = tester.getRect(find.byWidget(group.children.last));
        final groupCenter = (tester.getTopLeft(label).dx + arrowSpace.right) / 2;
        expect(groupCenter, closeTo(centers[index], .1));
        expect(tester.widget<Text>(label).textAlign, TextAlign.center);
      }
      final rows = tester
          .widgetList<Row>(allRows)
          .where((row) => row.children.length == 5 && row.children.last is SizedBox);
      expect(rows, hasLength(5));
      for (final row in rows) {
        final values = find.descendant(of: find.byWidget(row), matching: find.byType(Text));
        final texts = tester.widgetList<Text>(values).toList();
        expect(texts, hasLength(3));
        for (var index = 0; index < texts.length; index++) {
          expect(tester.getCenter(values.at(index)).dx, closeTo(centers[index], .1));
          expect(texts[index].textAlign, TextAlign.center);
        }
      }
    }

    aligned();
    final origins = headerElements.map((finder) => tester.getTopLeft(finder).dx).toList();
    final pointer = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await pointer.addPointer(location: tester.getCenter(headerElements.first));
    for (final finder in headerElements) {
      await pointer.moveTo(tester.getCenter(finder));
      await tester.tap(finder);
      await tester.pump();
      aligned();
      expect(headerElements.map((element) => tester.getTopLeft(element).dx).toList(), origins);
    }
    await pointer.removePointer();
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

import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/design/sidebar_frame.dart';
import 'package:sshairy/design/theme.dart';
import 'package:sshairy/design/scrolling.dart';
import 'package:sshairy/features/settings/settings.dart';
import 'package:sshairy/foundation/data_dir.dart';
import 'package:sshairy/foundation/result.dart';

const _sidebar = ValueKey('sidebar'), _page = ValueKey('page'), _draft = ValueKey('draft');

/// Records when its state is created and dropped.
class _Probe extends StatefulWidget {
  const _Probe(this.name, this.log, {required this.child});

  final String name;
  final List<String> log;
  final Widget child;

  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  @override
  void initState() {
    super.initState();
    widget.log.add('+${widget.name}');
  }

  @override
  void dispose() {
    widget.log.add('-${widget.name}');
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _Rig {
  var stored = WorkspaceSize.monitor;
  var available = 1400.0;
  var shown = true;
  final resized = <double>[];
  final log = <String>[];
  late StateSetter rebuild;

  int count(String event) => log.where((e) => e == event).length;
}

Future<ThemeData> _mount(WidgetTester tester, _Rig rig) async {
  await tester.binding.setSurfaceSize(const Size(1600, 700));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final theme = buildTheme(Brightness.light).copyWith(platform: TargetPlatform.windows);
  await tester.pumpWidget(
    MaterialApp(
      scrollBehavior: const AppScrollBehavior(),
      theme: theme,
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: StatefulBuilder(
            builder: (context, setState) {
              rig.rebuild = setState;
              return SizedBox(
                width: rig.available,
                height: 600,
                child: SidebarFrame(
                  width: rig.stored,
                  resizeLabel: 'Resize monitor',
                  onResize: (width) => setState(() {
                    rig.resized.add(width);
                    rig.stored = width;
                  }),
                  sidebar: rig.shown ? _Probe('panel', rig.log, child: const SizedBox.expand(key: _sidebar)) : null,
                  child: _Probe(
                    'page',
                    rig.log,
                    child: const Column(
                      children: [
                        TextField(key: _draft),
                        Expanded(child: SizedBox.expand(key: _page)),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    ),
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });
  return theme;
}

double _width(WidgetTester tester, Key key) => tester.getSize(find.byKey(key)).width;

Future<void> _drag(WidgetTester tester, Finder handle, double dx) async {
  final gesture = await tester.startGesture(tester.getCenter(handle), kind: PointerDeviceKind.mouse);
  await gesture.moveBy(Offset(dx.sign * 60, 0));
  await gesture.moveBy(Offset(dx, 0));
  await gesture.up();
  await tester.pump(const Duration(milliseconds: 100));
}

/// The divider's grab area; semantics are only on while a test runs.
Finder _handle() => find.bySemanticsLabel('Resize monitor');

void main() {
  test('the largest width leaves the page its 480 px and never drops below the minimum', () {
    expect(SidebarFrame.maxWidth(1400), WorkspaceSize.monitorMax);
    expect(SidebarFrame.maxWidth(800), 800 - WorkspaceSize.divider - WorkspaceSize.terminalMin);
    expect(SidebarFrame.maxWidth(700), WorkspaceSize.monitorMin);
    expect(SidebarFrame.clampWidth(100, 1400), WorkspaceSize.monitorMin);
    expect(SidebarFrame.clampWidth(999, 1400), WorkspaceSize.monitorMax);
    expect(SidebarFrame.clampWidth(999, 800), SidebarFrame.maxWidth(800));
    for (var available = 721.0; available <= 1600; available += 7) {
      final page = available - WorkspaceSize.divider - SidebarFrame.maxWidth(available);
      expect(page, greaterThanOrEqualTo(WorkspaceSize.terminalMin), reason: '$available');
    }
    expect(WorkspaceSize.monitor, WorkspaceSize.monitorMin, reason: 'the default is the narrowest width');
  });

  testWidgets('dragging paints only a guide; release commits a width within 240-400', (tester) async {
    final rig = _Rig();
    final theme = await _mount(tester, rig);
    final handle = _handle();
    final guide = find.byWidgetPredicate((w) => w is ColoredBox && w.color == theme.colorScheme.primary);
    expect(_width(tester, _sidebar), WorkspaceSize.monitor);
    expect(_width(tester, _page), 1400 - WorkspaceSize.monitor - WorkspaceSize.divider);
    expect(guide, findsNothing);

    final drag = await tester.startGesture(tester.getCenter(handle), kind: PointerDeviceKind.mouse);
    await drag.moveBy(const Offset(60, 0));
    await drag.moveBy(const Offset(500, 0));
    await tester.pump();
    expect(_width(tester, _sidebar), WorkspaceSize.monitor, reason: 'the page does not reflow while dragging');
    expect(rig.resized, isEmpty);
    expect(guide, findsOneWidget);
    expect(tester.getSize(guide).width, 2);
    expect(tester.getTopLeft(guide).dx, WorkspaceSize.monitorMax);
    await drag.up();
    await tester.pump(const Duration(milliseconds: 100));
    expect(rig.resized, [WorkspaceSize.monitorMax]);
    expect(_width(tester, _sidebar), WorkspaceSize.monitorMax);
    expect(_width(tester, _page), 1400 - WorkspaceSize.monitorMax - WorkspaceSize.divider);
    expect(guide, findsNothing);

    await _drag(tester, handle, -500);
    expect(rig.resized, [WorkspaceSize.monitorMax, WorkspaceSize.monitorMin]);
    expect(_width(tester, _sidebar), WorkspaceSize.monitorMin);
    expect(tester.takeException(), isNull);
  });

  testWidgets('double-click restores the default and a second one writes nothing', (tester) async {
    final rig = _Rig()..stored = 360;
    await _mount(tester, rig);
    final handle = _handle();
    Future<void> doubleClick() async {
      final at = tester.getCenter(handle);
      await tester.tapAt(at, kind: PointerDeviceKind.mouse);
      await tester.pump(kDoubleTapMinTime);
      await tester.tapAt(at, kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle(const Duration(seconds: 1));
    }

    await doubleClick();
    expect(rig.resized, [WorkspaceSize.monitor]);
    expect(_width(tester, _sidebar), WorkspaceSize.monitor);
    await doubleClick();
    expect(rig.resized, [WorkspaceSize.monitor], reason: 'unchanged width is not committed again');
  });

  testWidgets('semantic actions and arrow keys step by 24 and stop at the limits', (tester) async {
    final rig = _Rig()..stored = 300;
    await _mount(tester, rig);
    final handle = _handle();
    final data = tester.getSemantics(handle).getSemanticsData();
    expect((data.label, data.value, data.increasedValue, data.decreasedValue), ('Resize monitor', '300', '324', '276'));
    expect(data.hasAction(SemanticsAction.increase), isTrue);
    expect(data.hasAction(SemanticsAction.decrease), isTrue);

    final node = find.semantics.byLabel('Resize monitor');
    tester.semantics.performAction(node, SemanticsAction.increase);
    await tester.pump();
    tester.semantics.performAction(node, SemanticsAction.decrease);
    await tester.pump();
    tester.semantics.performAction(node, SemanticsAction.decrease);
    await tester.pump();
    expect(rig.resized, [324, 300, 276]);
    expect(_width(tester, _sidebar), 276);

    // A drag focuses the divider; the arrow keys then move it, growing toward the page.
    await _drag(tester, handle, 500);
    expect(_width(tester, _sidebar), WorkspaceSize.monitorMax);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(_width(tester, _sidebar), WorkspaceSize.monitorMax - Space.xl);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(_width(tester, _sidebar), WorkspaceSize.monitorMax);
    final commits = rig.resized.length;
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(rig.resized, hasLength(commits), reason: 'already at the maximum');
    expect(tester.takeException(), isNull);
  });

  testWidgets('a width the window cannot hold is shown smaller and returns with the window', (tester) async {
    final rig = _Rig()
      ..stored = WorkspaceSize.monitorMax
      ..available = 800;
    await _mount(tester, rig);
    final handle = _handle();
    const fits = 800 - WorkspaceSize.divider - WorkspaceSize.terminalMin;
    expect(_width(tester, _sidebar), fits);
    expect(_width(tester, _page), WorkspaceSize.terminalMin);
    expect(rig.resized, isEmpty, reason: 'only the display is limited');

    rig.rebuild(() => rig.available = 1400);
    await tester.pump();
    expect(_width(tester, _sidebar), WorkspaceSize.monitorMax);
    rig.rebuild(() => rig.available = 800);
    await tester.pump();

    await _drag(tester, handle, 300);
    expect(_width(tester, _sidebar), fits);
    expect(rig.resized, isEmpty, reason: 'already the widest that fits, so nothing to commit');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(rig.resized, [fits - Space.xl]);

    rig.rebuild(() => rig.available = 700);
    await tester.pump();
    expect(_width(tester, _sidebar), WorkspaceSize.monitorMin, reason: 'never below the minimum');
    rig.rebuild(() => rig.available = 1400);
    await tester.pump();
    expect(_width(tester, _sidebar), fits - Space.xl);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the page keeps its state while the panel resizes, hides and shows', (tester) async {
    final rig = _Rig();
    await _mount(tester, rig);
    final handle = _handle();
    await tester.enterText(find.byKey(_draft), 'unsent draft');
    expect((rig.count('+panel'), rig.count('+page')), (1, 1));

    await _drag(tester, handle, 500);
    expect(_width(tester, _sidebar), WorkspaceSize.monitorMax);
    expect(
      (rig.count('+panel'), rig.count('-panel'), rig.count('+page'), rig.count('-page')),
      (1, 0, 1, 0),
      reason: 'resizing rebuilds neither the panel nor the page',
    );

    rig.rebuild(() => rig.shown = false);
    await tester.pump();
    expect(find.byKey(_sidebar), findsNothing);
    expect(handle, findsNothing);
    expect(_width(tester, _page), 1400);
    expect((rig.count('-panel'), rig.count('+page'), rig.count('-page')), (1, 1, 0));

    rig.rebuild(() => rig.shown = true);
    await tester.pump();
    expect(_width(tester, _sidebar), WorkspaceSize.monitorMax, reason: 'the width outlives the panel');
    expect((rig.count('+panel'), rig.count('+page'), rig.count('-page')), (2, 1, 0));
    expect(find.text('unsent draft'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('monitorWidth is a persisted setting limited to 240-400 that settings.patch can change', () async {
    final setting = SettingKeys.monitorWidth;
    expect(SettingKeys.all, contains(setting));
    expect(setting.defaultValue, WorkspaceSize.monitor);
    expect(setting.agentExposed, isTrue);
    for (final value in [240, 240.0, 320.5, 400]) {
      expect(setting.accepts(value), isTrue, reason: '$value');
    }
    for (final value in [239.9, 400.1, 0, -1, double.nan, 'wide', true, null]) {
      expect(setting.accepts(value), isFalse, reason: '$value');
    }
    expect(Settings.fromJson({'monitorWidth': 999}).get(setting), WorkspaceSize.monitor);
    expect(Settings.fromJson({'monitorWidth': 333}).get(setting), 333);

    final dir = Directory.systemTemp.createTempSync('sshairy-monitor-width');
    addTearDown(() => dir.deleteSync(recursive: true));
    final c = ProviderContainer(overrides: [dataDirProvider.overrideWithValue(dir.path)]);
    addTearDown(c.dispose);
    final n = c.read(settingsProvider.notifier);
    expect(await n.patch({'monitorWidth': 401}, exposedOnly: true), isA<Err<void>>());
    expect(c.read(settingsProvider).get(setting), WorkspaceSize.monitor);
    expect(await n.patch({'monitorWidth': 320}, exposedOnly: true), isA<Ok<void>>());
    expect(c.read(settingsProvider).get(setting), 320);
    expect(() => n.set(setting, 500.0), throwsArgumentError);
  });
}

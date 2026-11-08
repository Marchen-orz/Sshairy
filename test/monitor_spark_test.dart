import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/design/theme.dart';
import 'package:sshairy/features/monitor/domain/chart_range.dart';
import 'package:sshairy/features/monitor/presentation/monitor_widgets.dart';

void main() {
  test('small percentage changes occupy most of their own padded range', () {
    final cpu = MonitorRange.percentage([.10, .105, .11]);
    final memory = MonitorRange.percentage([.80, .805, .81]);
    expect(cpu.min, lessThan(.10));
    expect(cpu.max, greaterThan(.11));
    expect(cpu.fraction(.11) - cpu.fraction(.10), greaterThan(.75));
    expect(memory.fraction(.81) - memory.fraction(.80), closeTo(cpu.fraction(.11) - cpu.fraction(.10), 1e-9));
  });

  test('flat values, empty histories and boundaries retain a one-point minimum span', () {
    for (final value in [0.0, .18, 1.0]) {
      final range = MonitorRange.percentage([value, value]);
      expect(range.min, greaterThanOrEqualTo(0));
      expect(range.max, lessThanOrEqualTo(1));
      expect(range.max - range.min, closeTo(.01, 1e-9));
      expect(range.fraction(value), inInclusiveRange(0, 1));
    }
    final empty = MonitorRange.percentage([]);
    expect((empty.min, empty.max), (0, .01));
    final quiet = MonitorRange.percentage([.18, .18001]);
    expect(quiet.max - quiet.min, closeTo(.01, 1e-9));
    expect(quiet.fraction(.18001) - quiet.fraction(.18), lessThan(.002));
  });

  test('spikes stay visible and invalid samples cannot corrupt the range', () {
    final spike = MonitorRange.percentage([.10, 1, .11, double.nan, double.infinity]);
    expect(spike.min, greaterThanOrEqualTo(0));
    expect(spike.max, 1);
    expect(spike.fraction(1), 1);
    final invalid = MonitorRange.percentage([double.nan, double.infinity, double.negativeInfinity]);
    expect((invalid.min, invalid.max), (0, .01));
    final outliers = MonitorRange.percentage([-1, 2]);
    expect((outliers.min, outliers.max), (0, 1));
  });

  test('network series share their largest finite value and a zero baseline', () {
    final range = MonitorRange.network([12, 24, double.nan, double.infinity, -30]);
    expect((range.min, range.max), (0, 24));
    expect(range.fraction(12), .5);
    expect(range.fraction(0), 0);
    expect((MonitorRange.network([0, 0]).min, MonitorRange.network([]).max), (0, 1));
  });

  Future<List<CustomPainter>> pump(
    WidgetTester tester,
    List<(List<double>, Color)> series, {
    List<String> labels = const ['CPU'],
    bool percentage = true,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 240,
              child: MonitorSpark(percentage: percentage, series: series, labels: labels, height: 28),
            ),
          ),
        ),
      ),
    );
    return tester
        .widgetList<CustomPaint>(find.descendant(of: find.byType(MonitorSpark), matching: find.byType(CustomPaint)))
        .map((w) => w.painter!)
        .toList();
  }

  Future<int> paintedSpan(WidgetTester tester, CustomPainter painter) async {
    final bytes = await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      painter.paint(Canvas(recorder), const Size(240, 28));
      final picture = recorder.endRecording();
      final image = await picture.toImage(240, 28);
      final rgba = await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
      image.dispose();
      picture.dispose();
      return rgba!;
    });
    final rows = <int>{};
    for (var y = 0; y < 28; y++) {
      for (var x = 0; x < 240; x++) {
        final at = (y * 240 + x) * 4;
        if (bytes!.getUint8(at) < 30 &&
            bytes.getUint8(at + 1) > 200 &&
            bytes.getUint8(at + 2) < 30 &&
            bytes.getUint8(at + 3) > 160) {
          rows.add(y);
        }
      }
    }
    expect(rows, isNotEmpty);
    return rows.reduce((a, b) => a > b ? a : b) - rows.reduce((a, b) => a < b ? a : b);
  }

  testWidgets('a one-point fluctuation is visibly expanded while flat memory stays flat', (tester) async {
    const green = Color(0xff00ff00);
    final changed = await pump(tester, [(List.generate(60, (i) => .10 + .01 * i / 59), green)]);
    expect(await paintedSpan(tester, changed.single), greaterThanOrEqualTo(18));
    final flat = await pump(tester, [(List.filled(60, .18), green)]);
    expect(await paintedSpan(tester, flat.single), lessThanOrEqualTo(2));
  });

  testWidgets('percentage traces are separately named and old spikes leave the visible range', (tester) async {
    final plots = await pump(
      tester,
      [
        ([1, ...List.filled(60, .10)], Colors.blue),
        ([.80, .81], Colors.green),
      ],
      labels: ['CPU', 'Memory'],
    );
    expect(plots, hasLength(2));
    expect(find.text('CPU'), findsOneWidget);
    expect(find.text('Memory'), findsOneWidget);
    final tips = tester
        .widgetList<Tooltip>(find.descendant(of: find.byType(MonitorSpark), matching: find.byType(Tooltip)))
        .map((t) => t.message)
        .toList();
    expect(tips, contains('CPU · 9.5–10.5%'));
    expect(tips.any((t) => t!.startsWith('Memory · 79.9–81.1%')), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty, single and nonfinite histories render without connecting gaps', (tester) async {
    await pump(
      tester,
      [
        ([], Colors.blue),
        ([.1], Colors.green),
        ([.1, double.nan, .2, double.infinity], Colors.purple),
      ],
      labels: ['CPU', 'Memory', 'GPU'],
    );
    expect(tester.takeException(), isNull);
    final network = await pump(tester, [
      ([0, 12], Colors.blue),
      ([0, 24], Colors.purple),
    ], percentage: false);
    expect(network, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('painter snapshots mutable history and repaints only when plot data changes', (tester) async {
    final values = [.10, .105, .11];
    final first = (await pump(tester, [(values, Colors.blue)])).single;
    final same = (await pump(tester, [(values, Colors.blue)])).single;
    expect(same.shouldRepaint(first), isFalse);
    values[1] = .103;
    final changed = (await pump(tester, [(values, Colors.blue)])).single;
    expect(changed.shouldRepaint(first), isTrue);
    final recolored = (await pump(tester, [(values, Colors.green)])).single;
    expect(recolored.shouldRepaint(changed), isTrue);
  });
}

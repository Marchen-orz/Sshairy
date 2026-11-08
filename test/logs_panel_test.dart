import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/design/select.dart';
import 'package:sshairy/design/theme.dart';
import 'package:sshairy/features/logs/api.dart';
import 'package:sshairy/foundation/diagnostics.dart';
import 'package:sshairy/l10n/app_localizations.dart';

class _Log extends DiagnosticLog {
  _Log() : super.disabled();

  final events = StreamController<void>.broadcast();
  var records = <DiagnosticRecord>[];
  var reads = 0;
  var fail = false;
  Completer<DiagnosticSnapshot>? gate;

  @override
  bool get enabled => true;
  @override
  Stream<void> get changes => events.stream;
  @override
  Future<DiagnosticSnapshot> readRecent({int limit = 500}) {
    reads++;
    if (fail) return Future.error(const DiagnosticReadFailure());
    return gate?.future ?? Future.value(DiagnosticSnapshot(List.of(records)));
  }
}

DiagnosticRecord _record(DiagnosticArea area, int elapsed) => DiagnosticRecord(
  time: DateTime.utc(2026, 11, 8, 12),
  area: area,
  action: DiagnosticAction.dial,
  outcome: DiagnosticOutcome.succeeded,
  elapsedMilliseconds: elapsed,
);

void main() {
  Future<void> mount(WidgetTester tester, _Log log) async {
    addTearDown(() => log.events.close());
    await tester.pumpWidget(
      ProviderScope(
        overrides: [diagnosticLogProvider.overrideWithValue(log)],
        child: MaterialApp(
          theme: buildTheme(Brightness.light),
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(body: SizedBox(width: 440, child: LogsPanel())),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('live records can be paused, resumed, filtered and safely copied', (tester) async {
    final log = _Log()..records = [_record(DiagnosticArea.connection, 42)];
    await mount(tester, log);
    expect(find.text('42 ms'), findsOneWidget);
    await tester.tap(find.byTooltip('Pause'));
    await tester.pump();
    log.records = [_record(DiagnosticArea.transfer, 84), ...log.records];
    log.events.add(null);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('84 ms'), findsNothing);
    await tester.tap(find.byTooltip('Resume'));
    await tester.pumpAndSettle();
    expect(find.text('84 ms'), findsOneWidget);
    tester.widget<AppSelect<DiagnosticArea?>>(find.byType(AppSelect<DiagnosticArea?>)).onChanged!(
      DiagnosticArea.connection,
    );
    await tester.pumpAndSettle();
    expect(find.text('42 ms'), findsOneWidget);
    expect(find.text('84 ms'), findsNothing);

    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await tester.tap(find.text('42 ms'));
    await tester.pump();
    await tester.tap(find.byTooltip('Copy selected record'));
    await tester.pump();
    expect(copied, log.records.last.text);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(log.events.hasListener, isFalse);
  });

  testWidgets('reader failures retain a retry action and later recover', (tester) async {
    final log = _Log()..fail = true;
    await mount(tester, log);
    expect(find.text('Could not read diagnostic records. Refresh to retry.'), findsOneWidget);
    log.fail = false;
    log.records = [_record(DiagnosticArea.connection, 42)];
    await tester.tap(find.byTooltip('Refresh'));
    await tester.pumpAndSettle();
    expect(find.text('42 ms'), findsOneWidget);
    expect(find.text('Could not read diagnostic records. Refresh to retry.'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('pause discards an in-flight snapshot and resume reads fresh data', (tester) async {
    final log = _Log();
    await mount(tester, log);
    log.gate = Completer<DiagnosticSnapshot>();
    await tester.tap(find.byTooltip('Refresh'));
    await tester.pump();
    await tester.tap(find.byTooltip('Pause'));
    await tester.pump();
    log.gate!.complete(DiagnosticSnapshot([_record(DiagnosticArea.connection, 42)]));
    await tester.pumpAndSettle();
    expect(find.text('42 ms'), findsNothing);
    log.gate = null;
    log.records = [_record(DiagnosticArea.connection, 84)];
    await tester.tap(find.byTooltip('Resume'));
    await tester.pumpAndSettle();
    expect(find.text('84 ms'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

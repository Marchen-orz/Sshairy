import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/design/popup.dart';
import 'package:sshairy/design/theme.dart';
import 'package:sshairy/features/files/api.dart';
import 'package:sshairy/features/files/application/edits.dart' show ExternalEdit;
import 'package:sshairy/features/files/domain/transfer.dart' show FileEnd, TransferPhase;
import 'package:sshairy/foundation/ids.dart';
import 'package:sshairy/l10n/app_localizations.dart';

/// Holds seeded transfers and records the actions asked of it; nothing runs or touches a disk.
class _FakeTransfers extends TransferManager {
  _FakeTransfers(this.seed);
  final List<Transfer> seed;
  final calls = <String>[];

  @override
  List<Transfer> build() => seed;

  @override
  void pause(TransferId id) => calls.add('pause ${id.value}');

  @override
  void resume(TransferId id) => calls.add('resume ${id.value}');

  @override
  Future<void> cancel(TransferId id) async => calls.add('cancel ${id.value}');

  @override
  Future<void> retry(TransferId id) async => calls.add('retry ${id.value}');

  @override
  Future<void> remove(TransferId id) async => calls.add('remove ${id.value}');

  @override
  void clearFinished() => calls.add('clearFinished');
}

class _NoEdits extends ExternalEdits {
  @override
  List<ExternalEdit> build() => const [];
}

Transfer _transfer(String id, TransferState state, {TransferPhase? phase, int bytes = 0, int? total, String? error}) =>
    Transfer(
      id: TransferId(id),
      batch: 'batch',
      source: FileEnd(const HostId('host'), '/srv/$id.bin', label: 'box'),
      target: FileEnd(null, '/tmp/$id.bin'),
      created: DateTime(2026, 11, 7),
      state: state,
      phase: phase,
      bytes: bytes,
      total: total,
      error: error,
    );

final _mixed = [
  _transfer('run', TransferState.running, phase: TransferPhase.copying, bytes: 10, total: 100),
  _transfer('pau', TransferState.paused, bytes: 50, total: 100),
  _transfer('fai', TransferState.failed, error: 'permission'),
];

Future<void> _pump(WidgetTester tester, _FakeTransfers fake, Widget body, {Size size = const Size(1000, 900)}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [transfersProvider.overrideWith(() => fake), editsProvider.overrideWith(_NoEdits.new)],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(body: body),
      ),
    ),
  );
}

Future<void> _openFromButton(WidgetTester tester, _FakeTransfers fake, {Size size = const Size(1000, 900)}) async {
  await _pump(
    tester,
    fake,
    const Align(alignment: Alignment.topRight, child: TransfersButton()),
    size: size,
  );
  await tester.tap(find.byType(TransfersButton));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('opens as a popover under the button, inside the window', (tester) async {
    final fake = _FakeTransfers(_mixed);
    await _pump(tester, fake, const Align(alignment: Alignment.topRight, child: TransfersButton()));
    final button = tester.getRect(find.byType(IconButton));
    await tester.tap(find.byType(TransfersButton));
    await tester.pumpAndSettle();

    expect(find.byType(TransfersPanel), findsOneWidget);
    final popup = tester.getRect(find.byType(PopupSurface));
    expect(popup.width, closeTo(440, .01));
    expect(popup.top, closeTo(button.bottom + 4, .01));
    expect(popup.right, closeTo(1000 - 8, .01));
    expect(popup.height, lessThan(520));
  });

  testWidgets('stops at 520 high and scrolls when the list is longer', (tester) async {
    final fake = _FakeTransfers([for (var i = 0; i < 12; i++) _transfer('t$i', TransferState.completed)]);
    await _openFromButton(tester, fake);

    expect(tester.getSize(find.byType(PopupSurface)).height, closeTo(520, .01));
    final scrollable = find.descendant(of: find.byType(PopupSurface), matching: find.byType(Scrollable));
    expect(tester.state<ScrollableState>(scrollable).position.maxScrollExtent, greaterThan(0));
    await tester.drag(find.byType(ListView), const Offset(0, -300));
    await tester.pump();
    expect(tester.state<ScrollableState>(scrollable).position.pixels, greaterThan(0));
  });

  testWidgets('shrinks to a small window', (tester) async {
    final fake = _FakeTransfers([for (var i = 0; i < 12; i++) _transfer('t$i', TransferState.completed)]);
    await _openFromButton(tester, fake, size: const Size(320, 400));

    final popup = tester.getRect(find.byType(PopupSurface));
    expect(popup.width, closeTo(320 - 16, .01));
    expect(popup.height, closeTo(400 - 16, .01));
    expect(popup.left, greaterThanOrEqualTo(8 - .01));
    expect(popup.right, lessThanOrEqualTo(320 - 8 + .01));
    expect(tester.takeException(), isNull);
  });

  testWidgets('without an anchor it opens at the title bar right edge', (tester) async {
    final fake = _FakeTransfers(_mixed);
    await _pump(
      tester,
      fake,
      Builder(
        builder: (context) => TextButton(onPressed: () => showTransfers(context), child: const Text('open')),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final popup = tester.getRect(find.byType(PopupSurface));
    expect(popup.top, closeTo(WorkspaceSize.titleBar + 4, .01));
    expect(popup.right, closeTo(1000 - 8, .01));
  });

  testWidgets('Esc and a click outside close it without touching any transfer', (tester) async {
    final fake = _FakeTransfers(_mixed);
    await _openFromButton(tester, fake);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(TransfersPanel), findsNothing);

    await tester.tap(find.byType(TransfersButton));
    await tester.pumpAndSettle();
    expect(find.byType(TransfersPanel), findsOneWidget);
    await tester.tapAt(const Offset(20, 450));
    await tester.pumpAndSettle();
    expect(find.byType(TransfersPanel), findsNothing);

    expect(fake.calls, isEmpty);
    final container = ProviderScope.containerOf(tester.element(find.byType(Scaffold)));
    expect(container.read(transfersProvider), orderedEquals(_mixed));
  });

  testWidgets('every row action and clearing history work from inside, keeping it open', (tester) async {
    final fake = _FakeTransfers(_mixed);
    await _openFromButton(tester, fake);

    Future<void> tapAndStayOpen(Finder finder) async {
      await tester.tap(finder);
      await tester.pumpAndSettle();
      expect(find.byType(TransfersPanel), findsOneWidget);
    }

    await tapAndStayOpen(find.byTooltip('Pause'));
    await tapAndStayOpen(find.byTooltip('Cancel'));
    await tapAndStayOpen(find.byTooltip('Resume'));
    await tapAndStayOpen(find.byTooltip('Reconnect'));
    // Newest first: the failed row's remove button comes before the paused one's.
    await tapAndStayOpen(find.byTooltip('Remove').first);
    await tapAndStayOpen(find.text('Clear finished'));

    expect(fake.calls, ['pause run', 'cancel run', 'resume pau', 'retry fai', 'remove fai', 'clearFinished']);
  });
}

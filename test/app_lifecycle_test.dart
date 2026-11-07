import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/app/composition.dart';
import 'package:sshairy/features/files/api.dart';
import 'package:sshairy/features/forwarding/api.dart';
import 'package:sshairy/foundation/data_dir.dart';
import 'package:sshairy/foundation/ids.dart';
import 'package:sshairy/main.dart';
import 'package:sshairy/platform/desktop_window.dart';

const _rule = ForwardRule(
  id: ForwardId('test-forward'),
  hostId: HostId('test-host'),
  listenPort: 49180,
  destinationPort: 22,
);

/// Records the order of window visibility changes and cleanup so the quit path can be checked.
final _events = <String>[];

class _RecordingWindow extends DesktopWindow {
  _RecordingWindow() : super(windows: false);

  @override
  Future<void> hide() async => _events.add('hide');

  @override
  Future<void> show() async => _events.add('show');
}

class _ActiveForwards extends Forwards {
  int stops = 0;
  bool resumed = false;
  bool failStop = false;

  @override
  List<ForwardState> build() => const [ForwardState(_rule, phase: ForwardPhase.running)];

  @override
  Future<void> shutdown() async {
    stops++;
    _events.add('stop');
    if (failStop) throw const ForwardError(ForwardErrors.stopFailed);
  }

  @override
  void resumeAfterShutdown() => resumed = true;
}

/// Real shutdown methods write asynchronously, which a widget test's gated zone never delivers; these leave the
/// disk alone so the quit flow can be exercised without dangling file handles.
class _QuietTransfers extends TransferManager {
  @override
  Future<void> shutdown({Duration grace = const Duration(seconds: 3)}) async {}

  @override
  void resumeAfterShutdown() {}
}

class _QuietEdits extends ExternalEdits {
  @override
  Future<void> shutdown() async {}

  @override
  void resumeAfterShutdown() {}
}

void main() {
  late Directory dir;
  setUp(() {
    _events.clear();
    dir = Directory.systemTemp.createTempSync('sshairy-lifecycle-');
    File('${dir.path}/settings.json').writeAsStringSync(jsonEncode({'schemaVersion': 1, 'locale': 'en'}));
  });
  tearDown(() async {
    // A pending configuration write can still hold a file briefly after the test body ends.
    for (var i = 0; i < 40; i++) {
      try {
        dir.deleteSync(recursive: true);
        return;
      } on FileSystemException {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
    dir.deleteSync(recursive: true);
  });

  Future<void> start(WidgetTester tester, {_ActiveForwards? forwards, DesktopWindow? window}) async {
    // Unmounting stops watchers and open files while the test zone is still live.
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          dataDirProvider.overrideWithValue(dir.path),
          ...appOverrides(),
          transfersProvider.overrideWith(_QuietTransfers.new),
          editsProvider.overrideWith(_QuietEdits.new),
          if (forwards != null) forwardsProvider.overrideWith(() => forwards),
        ],
        child: SshairyApp(window: window),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('an active forward alone asks before quitting; cancelling leaves it running', (tester) async {
    final forwards = _ActiveForwards();
    await start(tester, forwards: forwards);
    final request = tester.binding.handleRequestAppExit();
    await tester.pumpAndSettle();
    expect(find.text('1 forwards running'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(await request, ui.AppExitResponse.cancel);
    expect(forwards.stops, 0);
    // A cancelled request does not poison subsequent close requests.
    final again = tester.binding.handleRequestAppExit();
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(await again, ui.AppExitResponse.cancel);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a failed forward shutdown returns to the app instead of claiming it stopped', (tester) async {
    final forwards = _ActiveForwards()..failStop = true;
    await start(tester, forwards: forwards);
    final request = tester.binding.handleRequestAppExit();
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Quit'));
    await tester.pumpAndSettle();
    expect(find.text('Return to app'), findsOneWidget);
    expect(forwards.stops, 1);
    await tester.tap(find.text('Return to app'));
    await tester.pumpAndSettle();
    expect(await request, ui.AppExitResponse.cancel);
    expect(forwards.resumed, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('confirming quit hides the window before cleanup runs', (tester) async {
    final forwards = _ActiveForwards();
    final window = _RecordingWindow();
    addTearDown(window.dispose);
    await start(tester, forwards: forwards, window: window);
    final request = tester.binding.handleRequestAppExit();
    await tester.pumpAndSettle();
    expect(_events, isEmpty, reason: 'the confirmation stays on screen');
    await tester.tap(find.widgetWithText(TextButton, 'Quit'));
    await tester.pumpAndSettle();
    expect(await request, ui.AppExitResponse.exit);
    expect(_events, ['hide', 'stop']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a failed cleanup shows the window again and a retry hides it before trying again', (tester) async {
    final forwards = _ActiveForwards()..failStop = true;
    final window = _RecordingWindow();
    addTearDown(window.dispose);
    await start(tester, forwards: forwards, window: window);
    final request = tester.binding.handleRequestAppExit();
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Quit'));
    await tester.pumpAndSettle();
    expect(_events, ['hide', 'stop', 'show']);
    forwards.failStop = false;
    await tester.tap(find.widgetWithText(TextButton, 'Retry'));
    await tester.pumpAndSettle();
    expect(await request, ui.AppExitResponse.exit);
    expect(_events, ['hide', 'stop', 'show', 'hide', 'stop']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a corrupt config is preserved and blocks workflows until repaired', (tester) async {
    final file = File('${dir.path}/hosts.json')..writeAsStringSync('{ broken');
    await start(tester);
    expect(find.text('Could not safely open hosts.json'), findsOneWidget);
    expect(file.readAsStringSync(), '{ broken');
    expect(find.byTooltip('New connection'), findsNothing);
    file.writeAsStringSync(jsonEncode({'schemaVersion': 1, 'hosts': []}));
    await tester.tap(find.widgetWithText(FilledButton, 'Retry'));
    await tester.pumpAndSettle();
    expect(find.text('Could not safely open hosts.json'), findsNothing);
    expect(find.byTooltip('New connection'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a future schema remains untouched instead of loading defaults', (tester) async {
    final file = File('${dir.path}/settings.json');
    final original = jsonEncode({'schemaVersion': 99, 'locale': 'en', 'future': true});
    file.writeAsStringSync(original);
    await start(tester);
    expect(find.text('Could not safely open settings.json'), findsOneWidget);
    expect(file.readAsStringSync(), original);
    expect(tester.takeException(), isNull);
  });
}

import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/design/window_chrome.dart';
import 'package:sshairy/platform/desktop_window.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('sshairy/window-test');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<MethodCall> calls;
  late DesktopWindow window;

  setUp(() {
    calls = [];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'initialize') return {'maximized': false, 'active': true};
      return null;
    });
    window = DesktopWindow(channel: channel, windows: true);
  });
  tearDown(() {
    window.dispose();
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
  });

  test('initialization enables controls and native notifications update maximize state', () async {
    await window.initialize();
    await window.initialize();
    expect(calls.where((call) => call.method == 'initialize').length, 1);
    expect(window.value.supported, isTrue);
    expect(window.value.maximized, isFalse);
    await messenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('state', {'maximized': true, 'active': false, 'maximizeHovered': true}),
      ),
      (_) {},
    );
    expect(window.value.maximized, isTrue);
    expect(window.value.active, isFalse);
    expect(window.value.maximizeHovered, isTrue);
  });

  test('hit-test rectangle uses physical pixels and is cleared explicitly', () async {
    await window.initialize();
    await window.setMaximizeRect(const Rect.fromLTRB(100, 0, 144, 40), 1.5);
    expect(calls.last.method, 'maximizeRect');
    expect(calls.last.arguments, [150.0, 0.0, 216.0, 60.0]);
    await window.setMaximizeRect(null, 1);
    expect(calls.last.arguments, isNull);
  });

  test('close asks for a cancelable exit and respects a cancelled response', () async {
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      expect(call.method, 'System.exitApplication');
      expect(call.arguments['type'], 'cancelable');
      return {'response': 'cancel'};
    });
    expect(await window.close(), AppExitResponse.cancel);
  });

  test('other desktop runners do not invoke an absent native channel', () async {
    final other = DesktopWindow(channel: channel, windows: false);
    addTearDown(other.dispose);
    await other.initialize();
    await other.minimize();
    await other.toggleMaximize();
    expect(other.value.supported, isFalse);
    expect(calls, isEmpty);
  });

  testWidgets('window controls have labels and route keyboard actions through the adapter', (tester) async {
    await window.initialize();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WindowControls(
            window: window,
            minimizeLabel: 'Minimize',
            maximizeLabel: 'Maximize',
            restoreLabel: 'Restore',
            closeLabel: 'Close window',
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byTooltip('Minimize'), findsOneWidget);
    expect(find.byTooltip('Maximize'), findsOneWidget);
    expect(find.byTooltip('Close window'), findsOneWidget);
    await tester.tap(find.byTooltip('Minimize'));
    await tester.pump();
    expect(calls.any((call) => call.method == 'minimize'), isTrue);
    await tester.tap(find.byTooltip('Maximize'));
    await tester.pump();
    expect(calls.any((call) => call.method == 'toggleMaximize'), isTrue);
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    final dialog = showDialog<void>(
      context: tester.element(find.byType(WindowControls)),
      builder: (_) => const AlertDialog(content: Text('Confirm')),
    );
    await tester.pumpAndSettle();
    expect(calls.lastWhere((call) => call.method == 'maximizeRect').arguments, isNull);
    navigator.pop();
    await dialog;
    await tester.pumpAndSettle();
    expect(calls.lastWhere((call) => call.method == 'maximizeRect').arguments, isNotNull);
    // Unmount before the adapter is disposed, clearing its native hit-test rectangle.
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

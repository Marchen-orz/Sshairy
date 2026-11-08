import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/design/window_chrome.dart';
import 'package:sshairy/design/interface_scale.dart';
import 'package:sshairy/platform/desktop_window.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('sshairy/window-test');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<MethodCall> calls;
  late DesktopWindow window;
  late bool rejectIcon;

  setUp(() {
    calls = [];
    rejectIcon = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'initialize') return {'maximized': false, 'active': true};
      if (call.method == 'brandIcon' && rejectIcon) throw PlatformException(code: 'invalid_icon');
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

  test('quit can hide the window and show it again through the native channel', () async {
    await window.initialize();
    await window.hide();
    await window.show();
    expect(calls.skip(1).map((call) => call.method), ['hide', 'show']);
  });

  test('brand icon sends the accent name and brightness only when the icon changes', () async {
    await window.setBrandIcon('blue', dark: false);
    expect(calls.where((call) => call.method == 'brandIcon'), isEmpty, reason: 'not supported before initialize');
    await window.initialize();
    await window.setBrandIcon('blue', dark: false);
    await window.setBrandIcon('blue', dark: false);
    await window.setBrandIcon('blue', dark: true);
    await window.setBrandIcon('deepSea', dark: true);
    await window.setBrandIcon('deepSea', dark: true);
    final icons = calls.where((call) => call.method == 'brandIcon').map((call) => call.arguments).toList();
    expect(icons, [
      {'theme': 'blue', 'dark': false},
      {'theme': 'blue', 'dark': true},
      {'theme': 'deepSea', 'dark': true},
    ]);
  });

  test('concurrent identical brand icon requests send one native call', () async {
    await window.initialize();
    await Future.wait([window.setBrandIcon('pink', dark: false), window.setBrandIcon('pink', dark: false)]);
    expect(calls.where((call) => call.method == 'brandIcon').length, 1);
  });

  test('a rejected brand icon does not throw and is retried on the next request', () async {
    await window.initialize();
    rejectIcon = true;
    await window.setBrandIcon('violet', dark: true);
    rejectIcon = false;
    await window.setBrandIcon('violet', dark: true);
    await window.setBrandIcon('violet', dark: true);
    expect(calls.where((call) => call.method == 'brandIcon').length, 2);
  });

  test('close asks for a cancelable exit and respects a cancelled response', () async {
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      expect(call.method, 'System.exitApplication');
      expect(call.arguments['type'], 'cancelable');
      return {'response': 'cancel'};
    });
    expect(await window.close(), AppExitResponse.cancel);
  });

  test('a native close request takes the same path as the close button', () async {
    final closing = _ClosingWindow(channel);
    addTearDown(closing.dispose);
    await closing.initialize();
    await messenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(const MethodCall('closeRequested')),
      (_) {},
    );
    expect(await closing.closed.future.timeout(const Duration(seconds: 1)), isTrue);
  });

  test('other desktop runners do not invoke an absent native channel', () async {
    final other = DesktopWindow(channel: channel, windows: false);
    addTearDown(other.dispose);
    await other.initialize();
    await other.minimize();
    await other.toggleMaximize();
    await other.setBrandIcon('green', dark: true);
    await other.hide();
    await other.show();
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

  testWidgets('scaled maximize hit area matches the whole painted button in physical pixels', (tester) async {
    await window.initialize();
    await tester.pumpWidget(
      MaterialApp(
        builder: (_, child) => InterfaceScale(scale: 1.5, child: child!),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topRight,
            child: WindowControls(
              window: window,
              minimizeLabel: 'Minimize',
              maximizeLabel: 'Maximize',
              restoreLabel: 'Restore',
              closeLabel: 'Close window',
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    final rect = tester.getRect(find.byType(TextButton).at(1));
    final dpr = tester.view.devicePixelRatio;
    expect(rect.width, closeTo(54, .001));
    final bounds = calls.lastWhere((call) => call.method == 'maximizeRect').arguments as List;
    expect(bounds[0], closeTo(rect.left * dpr, .001));
    expect(bounds[1], closeTo(rect.top * dpr, .001));
    expect(bounds[2], closeTo(rect.right * dpr, .001));
    expect(bounds[3], closeTo(rect.bottom * dpr, .001));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('window buttons are rounded 36x28 with a margin after close and a danger hover', (tester) async {
    await window.initialize();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topRight,
            child: WindowControls(
              window: window,
              minimizeLabel: 'Minimize',
              maximizeLabel: 'Maximize',
              restoreLabel: 'Restore',
              closeLabel: 'Close window',
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    final buttons = find.byType(TextButton);
    expect(buttons, findsNWidgets(3));
    final rects = [for (var i = 0; i < 3; i++) tester.getRect(buttons.at(i))];
    for (final rect in rects) {
      expect(rect.size, const Size(36, 28));
    }
    expect(rects[1].left - rects[0].right, 2);
    expect(rects[2].left - rects[1].right, 2);
    expect(tester.getRect(find.byType(WindowControls)).right - rects[2].right, 8);
    final close = tester.widget<TextButton>(buttons.at(2)).style!;
    expect(
      close.shape!.resolve({}),
      isA<RoundedRectangleBorder>().having((s) => s.borderRadius, 'radius', isNot(BorderRadius.zero)),
    );
    final scheme = Theme.of(tester.element(buttons.at(2))).colorScheme;
    expect(close.backgroundColor!.resolve({WidgetState.hovered}), scheme.error);
    final minimize = tester.widget<TextButton>(buttons.at(0)).style!;
    expect(minimize.overlayColor!.resolve({WidgetState.hovered}), isNotNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

class _ClosingWindow extends DesktopWindow {
  _ClosingWindow(MethodChannel channel) : super(channel: channel, windows: true);

  final closed = Completer<bool>();

  @override
  Future<AppExitResponse> close() async {
    closed.complete(true);
    return AppExitResponse.cancel;
  }
}

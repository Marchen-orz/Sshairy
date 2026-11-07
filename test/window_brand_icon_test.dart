import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/app/window_brand_icon.dart';
import 'package:sshairy/design/theme.dart';
import 'package:sshairy/platform/desktop_window.dart';

void main() {
  testWidgets('window icon follows the effective theme including system brightness changes', (tester) async {
    const channel = MethodChannel('sshairy/window-brand-test');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final icons = <Object?>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'initialize') return {'maximized': false, 'active': true};
      if (call.method == 'brandIcon') icons.add(call.arguments);
      return null;
    });
    final window = DesktopWindow(channel: channel, windows: true);
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    addTearDown(window.dispose);
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    await window.initialize();
    var accent = Accent.blue;
    var mode = ThemeMode.system;
    late StateSetter rebuild;
    await tester.pumpWidget(
      StatefulBuilder(
        builder: (context, setState) {
          rebuild = setState;
          return MaterialApp(
            theme: buildTheme(Brightness.light, accent),
            darkTheme: buildTheme(Brightness.dark, accent),
            themeMode: mode,
            builder: (context, child) => WindowBrandIcon(window: window, child: child!),
            home: const Scaffold(),
          );
        },
      ),
    );
    await tester.pumpAndSettle();
    expect(icons.last, {'theme': 'blue', 'dark': false});

    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    await tester.pumpAndSettle();
    expect(icons.last, {'theme': 'blue', 'dark': true});
    rebuild(() => accent = Accent.pink);
    await tester.pumpAndSettle();
    expect(icons.last, {'theme': 'pink', 'dark': true});
    rebuild(() => mode = ThemeMode.light);
    await tester.pumpAndSettle();
    expect(icons.last, {'theme': 'pink', 'dark': false});
    final count = icons.length;
    rebuild(() {});
    await tester.pumpAndSettle();
    expect(icons, hasLength(count), reason: 'unrelated rebuilds do not update the native icon');
  });
}

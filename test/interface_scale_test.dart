import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/design/interface_scale.dart';
import 'package:sshairy/design/popup.dart';

void main() {
  for (final factor in [.8, 1.25, 1.5]) {
    testWidgets('interface scale $factor sizes controls and anchors popups in the same viewport', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      const buttonKey = ValueKey('anchor'), popupKey = ValueKey('popup');
      Size? viewport;
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => InterfaceScale(scale: factor, child: child!),
          home: Scaffold(
            body: Builder(
              builder: (context) {
                viewport = MediaQuery.sizeOf(context);
                return Stack(
                  children: [
                    Positioned(
                      left: 120,
                      top: 80,
                      child: Builder(
                        builder: (buttonContext) => SizedBox(
                          key: buttonKey,
                          width: 120,
                          height: 32,
                          child: TextButton(
                            onPressed: () => showAnchoredPopup<void>(
                              context: buttonContext,
                              anchor: anchorOf(buttonContext),
                              width: 140,
                              builder: (_) => const PopupSurface(
                                child: SizedBox(key: popupKey, height: 80, child: Text('Options')),
                              ),
                            ),
                            child: const Text('Open'),
                          ),
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      );
      expect(viewport!.width, closeTo(1200 / factor, .001));
      expect(viewport!.height, closeTo(800 / factor, .001));
      final button = tester.getRect(find.byKey(buttonKey));
      expect(button.left, closeTo(120 * factor, .001));
      expect(button.width, closeTo(120 * factor, .001));
      expect(button.height, closeTo(32 * factor, .001));
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      final popup = tester.getRect(find.byKey(popupKey));
      expect(popup.left, closeTo(button.left, .001));
      expect(popup.top, closeTo(button.bottom + 4 * factor, .001));
      expect(popup.width, closeTo(140 * factor, .001));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('pointer-anchored context menus use scaled navigator coordinates', (tester) async {
    const factor = 1.5;
    await tester.pumpWidget(
      MaterialApp(
        builder: (_, child) => InterfaceScale(scale: factor, child: child!),
        home: Scaffold(
          body: Builder(
            builder: (context) => GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (event) => showAnchoredPopup<void>(
                context: context,
                anchor: anchorAt(event.globalPosition),
                width: 120,
                builder: (_) => const SizedBox(key: ValueKey('context-menu'), height: 80, child: Text('Menu')),
              ),
              child: const SizedBox.expand(),
            ),
          ),
        ),
      ),
    );
    await tester.tapAt(const Offset(300, 200));
    await tester.pumpAndSettle();
    final popup = tester.getRect(find.byKey(const ValueKey('context-menu')));
    expect(popup.left, closeTo(300, .001));
    expect(popup.top, closeTo(206, .001));
    expect(tester.takeException(), isNull);
  });

  testWidgets('changing scale retains the navigator, an open route and page state', (tester) async {
    final scale = ValueNotifier(1.0);
    addTearDown(scale.dispose);
    const pageKey = ValueKey('page');
    await tester.pumpWidget(
      MaterialApp(
        builder: (_, child) => ValueListenableBuilder<double>(
          valueListenable: scale,
          child: child,
          builder: (_, value, child) => InterfaceScale(scale: value, child: child!),
        ),
        home: const Scaffold(body: TextField(key: pageKey)),
      ),
    );
    await tester.enterText(find.byKey(pageKey), 'keep this draft');
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    navigator.push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('Second page'))));
    await tester.pumpAndSettle();
    scale.value = 1.5;
    await tester.pumpAndSettle();
    expect(tester.state<NavigatorState>(find.byType(Navigator)), same(navigator));
    expect(find.text('Second page'), findsOneWidget);
    navigator.pop();
    await tester.pumpAndSettle();
    expect(find.text('keep this draft'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

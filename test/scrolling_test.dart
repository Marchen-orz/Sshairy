import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/design/icon_rail.dart';
import 'package:sshairy/design/scrolling.dart';
import 'package:sshairy/design/theme.dart';

void main() {
  for (final direction in TextDirection.values) {
    testWidgets('vertical content reserves a stable scrollbar gutter in $direction', (tester) async {
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      final rowKey = GlobalKey();
      const headerKey = ValueKey('header');
      Future<void> show(int count) => tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(Brightness.light).copyWith(platform: TargetPlatform.windows),
          scrollBehavior: const AppScrollBehavior(),
          home: Directionality(
            textDirection: direction,
            child: Center(
              child: SizedBox(
                width: 300,
                height: 200,
                child: Column(
                  children: [
                    const ScrollGutter(
                      child: SizedBox(key: headerKey, height: 20, width: double.infinity),
                    ),
                    Expanded(
                      child: ListView.builder(
                        controller: scroll,
                        padding: EdgeInsets.zero,
                        itemCount: count,
                        itemExtent: 40,
                        itemBuilder: (_, i) => SizedBox(key: i == 0 ? rowKey : null, child: Text('row $i')),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await show(1);
      final bounds = tester.getRect(find.byType(Scrollbar));
      final fits = tester.getRect(find.byKey(rowKey));
      expect(fits.width, 300 - Space.lg);
      expect(scroll.position.maxScrollExtent, 0);
      await show(30);
      await tester.pumpAndSettle();
      final overflowing = tester.getRect(find.byKey(rowKey));
      expect(overflowing, fits);
      final header = tester.getRect(find.byKey(headerKey));
      expect(header.left, overflowing.left);
      expect(header.right, overflowing.right);
      expect(find.byType(Scrollbar), findsOneWidget);
      expect(scroll.position.maxScrollExtent, greaterThan(0));
      final barX = direction == TextDirection.ltr ? bounds.right - 3 : bounds.left + 3;
      final gutter = direction == TextDirection.ltr ? bounds.right - overflowing.right : overflowing.left - bounds.left;
      expect(gutter, Space.lg);
      scroll.jumpTo(1);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      final drag = await tester.startGesture(Offset(barX, bounds.top + 10));
      await drag.moveBy(const Offset(0, 20));
      await drag.moveBy(const Offset(0, 60));
      await drag.up();
      await tester.pumpAndSettle();
      expect(scroll.offset, greaterThan(1), reason: 'the gutter scrollbar controls its own list');
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('multiline editors reserve one gutter and keep the caret visible', (tester) async {
    final controller = TextEditingController(text: List.filled(20, 'line').join('\n'));
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light).copyWith(platform: TargetPlatform.windows),
        scrollBehavior: const AppScrollBehavior(),
        home: Scaffold(
          body: Center(
            child: SizedBox(width: 300, height: 120, child: TextField(controller: controller, maxLines: null)),
          ),
        ),
      ),
    );
    final editable = find.byType(EditableText);
    final field = tester.getRect(find.byType(Scrollbar));
    final render = tester.state<EditableTextState>(editable).renderEditable;
    final contentRight = render.localToGlobal(Offset(render.size.width, 0)).dx;
    expect(field.right - contentRight, Space.lg);
    expect(find.byType(Scrollbar), findsOneWidget);
    await tester.enterText(find.byType(TextField), controller.text);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    final caret = render.getLocalRectForCaret(controller.selection.extent);
    final caretBottom = render.localToGlobal(caret.bottomRight);
    expect(caretBottom.dx, lessThan(field.right - Space.lg));
    expect(caretBottom.dy, lessThanOrEqualTo(field.bottom + 1));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('horizontal views keep their full viewport width', (tester) async {
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light).copyWith(platform: TargetPlatform.windows),
        scrollBehavior: const AppScrollBehavior(),
        home: Center(
          child: SizedBox(
            width: 300,
            height: 100,
            child: ListView.builder(
              controller: scroll,
              scrollDirection: Axis.horizontal,
              itemCount: 30,
              itemExtent: 40,
              itemBuilder: (_, i) => Text('$i'),
            ),
          ),
        ),
      ),
    );
    expect(scroll.position.viewportDimension, 300);
    expect(find.byType(Scrollbar), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('grid rows use the narrower viewport and compact navigation stays centered', (tester) async {
    const gridKey = ValueKey('grid item');
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light).copyWith(platform: TargetPlatform.windows),
        scrollBehavior: const AppScrollBehavior(),
        home: Row(
          children: [
            IconRail(
              expanded: false,
              toggleLabel: 'Expand',
              onToggle: () {},
              header: const SizedBox(),
              expandedHeader: const SizedBox(),
              groups: [
                [for (var i = 0; i < 30; i++) RailItem(icon: Icons.home_outlined, label: '$i', onTap: () {})],
              ],
              bottom: const [],
            ),
            SizedBox(
              width: 300,
              child: GridView.builder(
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 2),
                itemCount: 30,
                itemBuilder: (_, i) => SizedBox(key: i == 0 ? gridKey : null),
              ),
            ),
          ],
        ),
      ),
    );
    expect(tester.getSize(find.byKey(gridKey)).width, (300 - Space.lg) / 2);
    expect(tester.getCenter(find.byIcon(Icons.home_outlined).first).dx, WorkspaceSize.rail / 2);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

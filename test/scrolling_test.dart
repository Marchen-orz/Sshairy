import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/design/icon_rail.dart';
import 'package:sshairy/design/menu.dart';
import 'package:sshairy/design/scrolling.dart';
import 'package:sshairy/design/theme.dart';

void main() {
  for (final direction in TextDirection.values) {
    testWidgets('vertical content reserves a scrollbar gutter only while it overflows in $direction', (tester) async {
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      final rowKey = GlobalKey();
      const headerKey = ValueKey('header');
      Future<void> show(int count) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: buildTheme(Brightness.light).copyWith(platform: TargetPlatform.windows),
            scrollBehavior: const AppScrollBehavior(),
            home: Directionality(
              textDirection: direction,
              child: Center(
                child: SizedBox(
                  width: 300,
                  height: 200,
                  child: ScrollGutterScope(
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
          ),
        );
        await tester.pumpAndSettle();
      }

      void expectAligned(double rowWidth) {
        final row = tester.getRect(find.byKey(rowKey));
        final header = tester.getRect(find.byKey(headerKey));
        expect(row.width, rowWidth);
        expect(header.left, row.left, reason: 'the heading follows the rows');
        expect(header.right, row.right, reason: 'the heading follows the rows');
      }

      await show(1);
      expect(scroll.position.maxScrollExtent, 0);
      expectAligned(300);

      await show(30);
      expect(scroll.position.maxScrollExtent, greaterThan(0));
      expectAligned(300 - ScrollSize.gutter);
      expect(find.byType(Scrollbar), findsOneWidget);
      final bounds = tester.getRect(find.byType(Scrollbar));
      final row = tester.getRect(find.byKey(rowKey));
      final barX = direction == TextDirection.ltr ? bounds.right - 3 : bounds.left + 3;
      final gutter = direction == TextDirection.ltr ? bounds.right - row.right : row.left - bounds.left;
      expect(gutter, ScrollSize.gutter);
      scroll.jumpTo(1);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      final drag = await tester.startGesture(Offset(barX, bounds.top + 10));
      await drag.moveBy(const Offset(0, 20));
      await drag.moveBy(const Offset(0, 60));
      await drag.up();
      await tester.pumpAndSettle();
      expect(scroll.offset, greaterThan(1), reason: 'the gutter scrollbar controls its own list');

      await show(2);
      expect(scroll.position.maxScrollExtent, 0);
      expectAligned(300);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('a scope reserves the widest gap of the views below it and drops it when they leave', (tester) async {
    late StateSetter rebuild;
    var rows = 30;
    double? seen;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light).copyWith(platform: TargetPlatform.windows),
        scrollBehavior: const AppScrollBehavior(),
        home: Center(
          child: SizedBox(
            width: 300,
            height: 200,
            child: ScrollGutterScope(
              child: StatefulBuilder(
                builder: (context, setState) {
                  rebuild = setState;
                  seen = ScrollGutterScope.gapOf(context);
                  return rows == 0
                      ? const SizedBox.expand()
                      : ListView.builder(itemCount: rows, itemExtent: 40, itemBuilder: (_, i) => Text('row $i'));
                },
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(seen, ScrollSize.gutter);
    rebuild(() => rows = 0);
    await tester.pumpAndSettle();
    expect(seen, 0, reason: 'the list left the tree with its gap');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('menus reserve the gutter only when their items overflow', (tester) async {
    var count = 4;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light).copyWith(platform: TargetPlatform.windows),
        scrollBehavior: const AppScrollBehavior(),
        home: Scaffold(
          body: Center(
            child: AppMenuButton<int>(
              onSelected: (_) {},
              items: () => [
                for (var i = 0; i < count; i++)
                  AppMenuItem(value: i, label: 'A wide menu entry without an empty column'),
              ],
            ),
          ),
        ),
      ),
    );

    Future<double> gutter() async {
      await tester.tap(find.byType(IconButton));
      await tester.pumpAndSettle();
      final box = tester.getSize(find.byType(Scrollbar)).width;
      final label = find.text('A wide menu entry without an empty column').first;
      final row = find.ancestor(of: label, matching: find.byType(Row)).first;
      expect(
        tester.getRect(row).right,
        closeTo(tester.getRect(label).right, .1),
        reason: 'the label has no extra empty trailing column',
      );
      final width = box - tester.getSize(find.byType(IntrinsicWidth).last).width;
      await tester.tapAt(const Offset(1, 1));
      await tester.pumpAndSettle();
      return width;
    }

    expect(await gutter(), 0, reason: 'a short menu has nothing to scroll');
    count = 40;
    expect(await gutter(), ScrollSize.gutter, reason: 'a long menu scrolls beside its thumb');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('multiline editors reserve one gutter while they overflow and keep the caret visible', (tester) async {
    final controller = TextEditingController(text: List.filled(20, 'line').join('\n'));
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light).copyWith(platform: TargetPlatform.windows),
        scrollBehavior: const AppScrollBehavior(),
        home: Scaffold(
          resizeToAvoidBottomInset: false,
          body: Center(
            child: SizedBox(width: 300, height: 120, child: TextField(controller: controller, maxLines: null)),
          ),
        ),
      ),
    );
    await tester.pump();
    final editable = find.byType(EditableText);
    final field = tester.getRect(find.byType(Scrollbar));
    final render = tester.state<EditableTextState>(editable).renderEditable;
    double contentRight() => render.localToGlobal(Offset(render.size.width, 0)).dx;
    expect(field.right - contentRight(), ScrollSize.gutter);
    expect(find.byType(Scrollbar), findsOneWidget);
    await tester.enterText(find.byType(TextField), controller.text);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
    final caret = render.getLocalRectForCaret(controller.selection.extent);
    final caretBottom = render.localToGlobal(caret.bottomRight);
    expect(caretBottom.dx, lessThan(field.right - ScrollSize.gutter));
    expect(caretBottom.dy, lessThanOrEqualTo(field.bottom + 1));

    controller.text = 'one\ntwo';
    await tester.pump();
    await tester.pump();
    expect(field.right - contentRight(), 0, reason: 'two lines fit, so the editor takes its full width');
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
    await tester.pump();
    expect(tester.getSize(find.byKey(gridKey)).width, (300 - ScrollSize.gutter) / 2);
    expect(tester.getCenter(find.byIcon(Icons.home_outlined).first).dx, WorkspaceSize.rail / 2);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

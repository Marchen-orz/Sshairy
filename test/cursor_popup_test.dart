import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/design/cursor_popup.dart';
import 'package:sshairy/design/theme.dart';

void main() {
  const key = ValueKey('candidates');
  Future<Rect> show(WidgetTester tester, Rect cursor, {Size size = const Size(700, 500)}) async {
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: size.width,
            height: size.height,
            child: CustomSingleChildLayout(
              delegate: CursorPopupLayout(cursor: cursor, preferredSize: const Size(300, 180)),
              child: const SizedBox(key: key, width: 300, height: 180),
            ),
          ),
        ),
      ),
    );
    return tester.getRect(find.byKey(key));
  }

  testWidgets('the popup follows the right edge of the caret and opens below it', (tester) async {
    var popup = await show(tester, const Rect.fromLTWH(100, 80, 8, 18));
    expect(popup.topLeft, const Offset(108 + Space.xs, 98 + Space.xs));
    popup = await show(tester, const Rect.fromLTWH(180, 80, 8, 18));
    expect(popup.left, 188 + Space.xs);
    expect(popup.top, 98 + Space.xs);
  });

  testWidgets('the popup flips above at the bottom and clamps at the right edge', (tester) async {
    final popup = await show(tester, const Rect.fromLTWH(650, 460, 8, 18));
    expect(popup.right, 700 - Space.sm);
    expect(popup.bottom, 460 - Space.xs);
    expect(popup.left, greaterThanOrEqualTo(Space.sm));
  });

  testWidgets('a narrow pane constrains candidate size without covering the caret row', (tester) async {
    final popup = await show(tester, const Rect.fromLTWH(160, 200, 8, 18), size: const Size(220, 260));
    expect(popup.width, 220 - Space.sm * 2);
    expect(popup.height, 180);
    expect(popup.bottom, 200 - Space.xs);
    expect(popup.right, lessThanOrEqualTo(220 - Space.sm));
    expect(tester.takeException(), isNull);
  });
}

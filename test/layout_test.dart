import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/features/workspace/domain/layout.dart';
import 'package:sshairy/features/workspace/presentation/split_view.dart';
import 'package:sshairy/foundation/ids.dart';

void main() {
  const a = PaneId('a'), b = PaneId('b'), c = PaneId('c');
  const sa = SessionId('sa'), sb = SessionId('sb'), sc = SessionId('sc');

  test('splitting in the same direction shares the target space instead of nesting', () {
    final l = Layout.single(a, sa).split(a, SplitAxis.horizontal, b, sb)!.split(b, SplitAxis.horizontal, c, sc)!;
    final root = l.root as PaneSplit;
    expect(root.children, hasLength(3));
    expect(root.ratios, [0.5, 0.25, 0.25]);
    expect(l.focused, c);
  });

  test('splitting across nests and keeps other ratios', () {
    final l = Layout.single(a, sa).split(a, SplitAxis.horizontal, b, sb)!.split(b, SplitAxis.vertical, c, sc)!;
    final root = l.root as PaneSplit;
    expect(root.ratios, [0.5, 0.5]);
    expect((root.children[1] as PaneSplit).axis, SplitAxis.vertical);
  });

  test('removing collapses single-child splits and moves focus to a neighbour', () {
    final l = Layout.single(a, sa).split(a, SplitAxis.horizontal, b, sb)!.split(b, SplitAxis.vertical, c, sc)!;
    final r = l.remove(c)!;
    expect(r.focused, b);
    expect((r.root as PaneSplit).children.every((n) => n is Leaf), isTrue);
    expect(r.remove(a)!.root, isA<Leaf>());
    expect(Layout.single(a, sa).remove(a), isNull);
  });

  test('removal redistributes in proportion', () {
    final l = Layout.single(a, sa).split(a, SplitAxis.horizontal, b, sb)!.split(b, SplitAxis.horizontal, c, sc)!;
    final r = l.remove(a)!;
    expect((r.root as PaneSplit).ratios, [0.5, 0.5]);
  });

  test('at most 8 panes', () {
    var l = Layout.single(const PaneId('0'), const SessionId('0'));
    for (var i = 1; i < Layout.maxPanes; i++) {
      l = l.split(l.focused, SplitAxis.horizontal, PaneId('$i'), SessionId('$i'))!;
    }
    expect(l.split(l.focused, SplitAxis.horizontal, const PaneId('x'), const SessionId('x')), isNull);
  });

  test('resize normalises and json round-trips', () {
    final l = Layout.single(a, sa).split(a, SplitAxis.horizontal, b, sb)!.resize(const [], [3, 1]);
    expect((l.root as PaneSplit).ratios, [0.75, 0.25]);
    final copy = Layout.fromJson(l.toJson());
    expect(copy.leaves.map((x) => x.session), [sa, sb]);
    expect(copy.focused, b);
  });

  for (final side in PaneSide.values) {
    test('inserting a tree on ${side.name} preserves its identities and orientation', () {
      final incoming = Layout.single(b, sb).split(b, SplitAxis.vertical, c, sc)!.resize(const [], [1, 3]);
      final moved = Layout.single(a, sa).insert(a, side, incoming)!;
      final root = moved.root as PaneSplit;
      expect(root.axis, side.axis);
      expect(root.ratios, [0.5, 0.5]);
      expect(identical(root.children[side.before ? 0 : 1], incoming.root), isTrue);
      expect(moved.focused, c);
      expect(moved.leaves.map((l) => l.session), side.before ? [sb, sc, sa] : [sa, sb, sc]);
      expect((incoming.root as PaneSplit).ratios, [0.25, 0.75]);
    });
  }

  test('same direction insertion splits only its target share and keeps the incoming subtree intact', () {
    final target = Layout.single(a, sa).split(a, SplitAxis.horizontal, b, sb)!.resize(const [], [1, 3]);
    final incoming = Layout.single(c, sc).split(c, SplitAxis.horizontal, const PaneId('d'), const SessionId('sd'))!;
    final moved = target.insert(b, PaneSide.left, incoming)!;
    final root = moved.root as PaneSplit;
    expect(root.children, hasLength(3));
    expect(root.ratios, [0.25, 0.375, 0.375]);
    expect(identical(root.children[1], incoming.root), isTrue);
    expect(Layout.fromJson(moved.toJson()).leaves.map((l) => l.pane), [a, c, const PaneId('d'), b]);
  });

  test('inserting rejects missing targets, duplicate pane/session identities and overfull trees', () {
    final target = Layout.single(a, sa);
    expect(target.insert(b, PaneSide.left, Layout.single(c, sc)), isNull);
    expect(target.insert(a, PaneSide.left, Layout.single(a, sc)), isNull);
    expect(target.insert(a, PaneSide.left, Layout.single(c, sa)), isNull);
    var full = target;
    for (var i = 1; i < Layout.maxPanes; i++) {
      full = full.split(a, SplitAxis.horizontal, PaneId('p$i'), SessionId('s$i'))!;
    }
    expect(full.insert(a, PaneSide.bottom, Layout.single(c, sc)), isNull);
  });

  testWidgets('resizing a split narrower than the pane minimum keeps positive ratios', (tester) async {
    final layout = Layout.single(a, sa).split(a, SplitAxis.horizontal, b, sb)!;
    List<double>? resized;
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 201,
            height: 300,
            child: LayoutView(
              root: layout.root,
              leaf: (_) => const SizedBox.expand(),
              onResize: (_, ratios) => resized = ratios,
            ),
          ),
        ),
      ),
    );
    final split = tester.getRect(find.byType(LayoutView));
    await tester.dragFrom(split.center, const Offset(30, 0));
    await tester.pump(const Duration(milliseconds: 350));
    expect(resized, [0.5, 0.5]);
    expect(tester.takeException(), isNull);
  });

  test('rejects broken layouts', () {
    expect(
      () => Layout.fromJson({
        'root': {
          'type': 'split',
          'axis': 'horizontal',
          'children': [
            {'type': 'leaf', 'pane': 'a', 'session': 's'},
            {'type': 'leaf', 'pane': 'a', 'session': 's'},
          ],
          'ratios': [0.5, 0.5],
        },
        'focused': 'a',
      }),
      throwsFormatException,
    );
  });
}

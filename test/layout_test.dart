import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/features/workspace/domain/layout.dart';
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

import '../../../foundation/ids.dart';

enum SplitAxis { horizontal, vertical }

enum PaneSide {
  left,
  right,
  top,
  bottom;

  SplitAxis get axis => this == left || this == right ? SplitAxis.horizontal : SplitAxis.vertical;
  bool get before => this == left || this == top;
}

/// Split tree from docs/MODULES.md §3: leaves show sessions, splits divide space by ratios that sum to 1.
sealed class PaneNode {
  const PaneNode();

  Map<String, Object?> toJson();

  static PaneNode fromJson(Map<String, Object?> j) => switch (j['type']) {
    'leaf' => Leaf(PaneId(j['pane']! as String), SessionId(j['session']! as String)),
    'split' => PaneSplit(
      SplitAxis.values.byName(j['axis']! as String),
      [for (final c in j['children']! as List<Object?>) fromJson((c! as Map).cast())],
      [for (final r in j['ratios']! as List<Object?>) (r! as num).toDouble()],
    ),
    _ => throw FormatException('unknown pane node ${j['type']}'),
  };
}

final class Leaf extends PaneNode {
  const Leaf(this.pane, this.session);

  final PaneId pane;
  final SessionId session;

  @override
  Map<String, Object?> toJson() => {'type': 'leaf', 'pane': pane.value, 'session': session.value};
}

final class PaneSplit extends PaneNode {
  const PaneSplit(this.axis, this.children, this.ratios);

  final SplitAxis axis;
  final List<PaneNode> children;
  final List<double> ratios;

  @override
  Map<String, Object?> toJson() => {
    'type': 'split',
    'axis': axis.name,
    'children': [for (final c in children) c.toJson()],
    'ratios': ratios,
  };
}

/// Immutable; every change returns a new layout that keeps the invariants: unique panes, no empty or
/// single-child splits, positive ratios summing to 1, focus on an existing leaf.
class Layout {
  const Layout._(this.root, this.focused);

  factory Layout.single(PaneId pane, SessionId session) => Layout._(Leaf(pane, session), pane);

  static const maxPanes = 8;

  final PaneNode root;
  final PaneId focused;

  Iterable<Leaf> get leaves => _leaves(root);

  static Iterable<Leaf> _leaves(PaneNode n) sync* {
    switch (n) {
      case Leaf():
        yield n;
      case PaneSplit(:final children):
        for (final c in children) {
          yield* _leaves(c);
        }
    }
  }

  Leaf get focusedLeaf => leaves.firstWhere((l) => l.pane == focused);

  Layout focus(PaneId pane) => leaves.any((l) => l.pane == pane) ? Layout._(root, pane) : this;

  /// Puts [session] after [target]; null when the layout is full or an identity is already present.
  Layout? split(PaneId target, SplitAxis axis, PaneId pane, SessionId session) =>
      insert(target, axis == SplitAxis.horizontal ? PaneSide.right : PaneSide.bottom, Layout.single(pane, session));

  /// Moves an existing tree beside one leaf without changing its internal ratios or identities.
  Layout? insert(PaneId target, PaneSide side, Layout incoming) {
    final existing = leaves.toList(), added = incoming.leaves.toList();
    final panes = {...existing.map((l) => l.pane)}, sessions = {...existing.map((l) => l.session)};
    if (panes.length != existing.length ||
        sessions.length != existing.length ||
        !panes.contains(target) ||
        existing.length + added.length > maxPanes) {
      return null;
    }
    for (final leaf in added) {
      if (!panes.add(leaf.pane) || !sessions.add(leaf.session)) return null;
    }
    PaneNode visit(PaneNode n) {
      switch (n) {
        case Leaf():
          if (n.pane != target) return n;
          return PaneSplit(side.axis, side.before ? [incoming.root, n] : [n, incoming.root], const [0.5, 0.5]);
        case PaneSplit(:final axis, :final children, :final ratios):
          final i = children.indexWhere((c) => c is Leaf && c.pane == target);
          if (i >= 0 && axis == side.axis) {
            final half = ratios[i] / 2;
            return PaneSplit(
              axis,
              [...children]..insert(side.before ? i : i + 1, incoming.root),
              [...ratios]
                ..[i] = half
                ..insert(side.before ? i : i + 1, half),
            );
          }
          return PaneSplit(axis, [for (final c in children) visit(c)], ratios);
      }
    }

    return Layout._(visit(root), incoming.focused);
  }

  /// Null when [pane] was the last one. Siblings share its space in proportion; other splits keep their ratios.
  Layout? remove(PaneId pane) {
    final order = leaves.map((l) => l.pane).toList();
    final index = order.indexOf(pane);
    if (index < 0) return this;
    if (order.length == 1) return null;

    PaneNode? visit(PaneNode n) {
      switch (n) {
        case Leaf():
          return n.pane == pane ? null : n;
        case PaneSplit(:final axis, :final children, :final ratios):
          final kept = <PaneNode>[], keptRatios = <double>[];
          for (var i = 0; i < children.length; i++) {
            final c = visit(children[i]);
            if (c != null) {
              kept.add(c);
              keptRatios.add(ratios[i]);
            }
          }
          if (kept.length == 1) return kept.single;
          final sum = keptRatios.fold(0.0, (a, b) => a + b);
          return PaneSplit(axis, kept, [for (final r in keptRatios) r / sum]);
      }
    }

    final next = focused == pane ? order[index > 0 ? index - 1 : 1] : focused;
    return Layout._(visit(root)!, next);
  }

  /// Sets the ratios of the split at [path] (child indexes from the root). Ratios are clamped and normalised.
  Layout resize(List<int> path, List<double> ratios) {
    PaneNode visit(PaneNode n, int depth) {
      if (n is! PaneSplit) return n;
      if (depth == path.length) {
        if (ratios.length != n.children.length) return n;
        final clamped = [for (final r in ratios) r.clamp(0.05, double.infinity)];
        final sum = clamped.fold(0.0, (a, b) => a + b);
        return PaneSplit(n.axis, n.children, [for (final r in clamped) r / sum]);
      }
      final i = path[depth];
      return PaneSplit(n.axis, [
        for (var k = 0; k < n.children.length; k++) k == i ? visit(n.children[k], depth + 1) : n.children[k],
      ], n.ratios);
    }

    return Layout._(visit(root, 0), focused);
  }

  Map<String, Object?> toJson() => {'root': root.toJson(), 'focused': focused.value};

  /// Throws [FormatException] for a layout that breaks the invariants.
  factory Layout.fromJson(Map<String, Object?> j) {
    final root = PaneNode.fromJson((j['root']! as Map).cast());
    final panes = _leaves(root).map((l) => l.pane).toList();
    if (panes.isEmpty || panes.toSet().length != panes.length) throw const FormatException('bad panes');
    void check(PaneNode n) {
      if (n is! PaneSplit) return;
      if (n.children.length < 2 || n.children.length != n.ratios.length || n.ratios.any((r) => r <= 0)) {
        throw const FormatException('bad split');
      }
      n.children.forEach(check);
    }

    check(root);
    final focused = PaneId(j['focused'] as String? ?? '');
    return Layout._(root, panes.contains(focused) ? focused : panes.first);
  }
}

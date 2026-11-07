import 'package:flutter/material.dart';

import '../domain/layout.dart';

/// Draws a split tree. Dividers are 1 px lines with an 8 px grab area (docs/UI.md §4). Dragging shows a guide
/// and applies the ratio on release, so terminals resize once instead of on every frame; double-click evens out.
class LayoutView extends StatelessWidget {
  const LayoutView({super.key, required this.root, required this.leaf, required this.onResize});

  final PaneNode root;
  final Widget Function(Leaf leaf) leaf;
  final void Function(List<int> path, List<double> ratios) onResize;

  @override
  Widget build(BuildContext context) => _node(root, const []);

  Widget _node(PaneNode n, List<int> path) => switch (n) {
    Leaf() => leaf(n),
    PaneSplit() => _SplitView(
      split: n,
      child: (i) => _node(n.children[i], [...path, i]),
      onResize: (ratios) => onResize(path, ratios),
    ),
  };
}

class _SplitView extends StatefulWidget {
  const _SplitView({required this.split, required this.child, required this.onResize});

  final PaneSplit split;
  final Widget Function(int index) child;
  final void Function(List<double> ratios) onResize;

  @override
  State<_SplitView> createState() => _SplitViewState();
}

class _SplitViewState extends State<_SplitView> {
  static const _line = 1.0, _grab = 8.0, _minPane = 120.0;

  /// Divider being dragged and where its guide is, in pixels from the start.
  int? _dragging;
  double _guide = 0;

  @override
  Widget build(BuildContext context) {
    final split = widget.split;
    final horizontal = split.axis == SplitAxis.horizontal;
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final total = horizontal ? constraints.maxWidth : constraints.maxHeight;
        final available = total - _line * (split.children.length - 1);
        final sizes = [for (final r in split.ratios) r * available];
        final offsets = <double>[];
        var at = 0.0;
        for (var i = 0; i < sizes.length - 1; i++) {
          at += sizes[i];
          offsets.add(at);
          at += _line;
        }

        Widget sized(double size, Widget child) =>
            horizontal ? SizedBox(width: size, child: child) : SizedBox(height: size, child: child);

        final children = <Widget>[];
        for (var i = 0; i < sizes.length; i++) {
          if (i > 0) children.add(sized(_line, ColoredBox(color: scheme.outlineVariant)));
          children.add(sized(sizes[i], widget.child(i)));
        }

        void end() {
          final i = _dragging!;
          setState(() => _dragging = null);
          final start = i == 0 ? 0.0 : offsets[i - 1] + _line;
          final pair = sizes[i] + sizes[i + 1];
          final first = (_guide - start).clamp(_minPane, pair - _minPane);
          final ratios = [...split.ratios];
          ratios[i] = first / available;
          ratios[i + 1] = (pair - first) / available;
          widget.onResize(ratios);
        }

        return Stack(
          children: [
            Flex(direction: horizontal ? Axis.horizontal : Axis.vertical, children: children),
            for (var i = 0; i < offsets.length; i++)
              Positioned(
                left: horizontal ? offsets[i] - (_grab - _line) / 2 : 0,
                right: horizontal ? null : 0,
                top: horizontal ? 0 : offsets[i] - (_grab - _line) / 2,
                bottom: horizontal ? 0 : null,
                width: horizontal ? _grab : null,
                height: horizontal ? null : _grab,
                child: MouseRegion(
                  cursor: horizontal ? SystemMouseCursors.resizeColumn : SystemMouseCursors.resizeRow,
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onDoubleTap: () => widget.onResize(List.filled(split.children.length, 1 / split.children.length)),
                    onPanStart: (_) => setState(() {
                      _dragging = i;
                      _guide = offsets[i];
                    }),
                    onPanUpdate: (d) => setState(() => _guide += horizontal ? d.delta.dx : d.delta.dy),
                    onPanEnd: (_) => end(),
                    onPanCancel: () => setState(() => _dragging = null),
                  ),
                ),
              ),
            if (_dragging != null)
              Positioned(
                left: horizontal ? _guide - 1 : 0,
                right: horizontal ? null : 0,
                top: horizontal ? 0 : _guide - 1,
                bottom: horizontal ? 0 : null,
                width: horizontal ? 2 : null,
                height: horizontal ? null : 2,
                child: IgnorePointer(child: ColoredBox(color: scheme.primary)),
              ),
          ],
        );
      },
    );
  }
}

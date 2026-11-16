import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'theme.dart';

enum DockSide { left, right, bottom }

/// A window outline with the panel's share filled in on the side it docks to. Size and colour come from the
/// surrounding [IconTheme], so it sits in a menu row like any icon.
class DockSideIcon extends StatelessWidget {
  const DockSideIcon(this.side, {super.key});

  final DockSide side;

  @override
  Widget build(BuildContext context) {
    final icon = IconTheme.of(context);
    return CustomPaint(
      size: Size.square(icon.size ?? 16),
      painter: _DockSidePainter(side, icon.color ?? Theme.of(context).colorScheme.onSurface),
    );
  }
}

class _DockSidePainter extends CustomPainter {
  const _DockSidePainter(this.side, this.color);

  final DockSide side;
  final Color color;

  static const _stroke = 1.5, _share = .4;

  @override
  void paint(Canvas canvas, Size size) {
    final frame = (Offset(0, size.height * .1) & Size(size.width, size.height * .8)).deflate(_stroke / 2);
    final window = RRect.fromRectAndRadius(frame, const Radius.circular(2.5));
    final panel = switch (side) {
      DockSide.left => Rect.fromLTRB(frame.left, frame.top, frame.left + frame.width * _share, frame.bottom),
      DockSide.right => Rect.fromLTRB(frame.right - frame.width * _share, frame.top, frame.right, frame.bottom),
      DockSide.bottom => Rect.fromLTRB(frame.left, frame.bottom - frame.height * _share, frame.right, frame.bottom),
    };
    canvas
      ..save()
      ..clipRRect(window)
      ..drawRect(panel, Paint()..color = color.withValues(alpha: .55))
      ..restore()
      ..drawRRect(
        window,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = _stroke,
      );
  }

  @override
  bool shouldRepaint(_DockSidePainter old) => old.side != side || old.color != color;
}

/// A resizable panel docked to one side of the main view (docs/UI.md). A left or right panel that
/// would squeeze the main view below [WorkspaceSize.terminalMin] covers it instead.
class DockPanel extends StatefulWidget {
  const DockPanel({
    super.key,
    required this.child,
    required this.panel,
    required this.open,
    required this.onClose,
    required this.closeLabel,
    required this.resizeLabel,
    this.side = DockSide.right,
    this.actions = const [],
    this.showHeader = true,
  });

  final Widget child, panel;
  final bool open;
  final DockSide side;
  final VoidCallback onClose;
  final String closeLabel, resizeLabel;

  /// Extra buttons in the panel's header, before close.
  final List<Widget> actions;

  /// False when the panel puts docking and close actions in its own toolbar.
  final bool showHeader;

  @override
  State<DockPanel> createState() => _DockPanelState();
}

class _DockPanelState extends State<DockPanel> with SingleTickerProviderStateMixin {
  final _panelKey = GlobalKey();
  final _focus = FocusNode();
  // Pointer focus keeps the arrow keys working without leaving the divider highlighted after the drag.
  var _pointerFocus = false;
  var _width = WorkspaceSize.toolPanel;
  var _height = WorkspaceSize.dockBottom;
  double? _guide;

  // The main view resizes once when the panel opens and once after it has left, never frame by frame, so a terminal
  // there is not reflowed throughout the animation (UI §4).
  late final _presence = AnimationController(vsync: this, duration: Motion.panel, value: widget.open ? 1 : 0)
    ..addStatusListener((status) {
      if (status.isDismissed && mounted) setState(() {});
    });
  // What a closing panel shows on its way out, as its owner may already have dropped it.
  late Widget _leaving = widget.panel;

  bool get _vertical => widget.side == DockSide.bottom;

  @override
  void didUpdateWidget(DockPanel old) {
    super.didUpdateWidget(old);
    if (old.open) _leaving = old.panel;
    _presence.duration = Motion.of(context, Motion.panel);
    if (widget.open != old.open) {
      widget.open ? _presence.forward() : _presence.reverse();
    } else if (widget.open && widget.side != old.side) {
      _presence.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _presence.dispose();
    _focus.dispose();
    super.dispose();
  }

  (double, double) _range(BoxConstraints c) => _vertical
      ? (WorkspaceSize.dockBottomMin, max(WorkspaceSize.dockBottomMin, c.maxHeight * WorkspaceSize.dockBottomMaxShare))
      : (WorkspaceSize.toolPanelMin, WorkspaceSize.toolPanelMax);

  double _clamp(double v, BoxConstraints c) {
    final (lo, hi) = _range(c);
    return v.clamp(lo, hi).toDouble();
  }

  void _resize(double v, BoxConstraints c) => setState(() {
    if (_vertical) {
      _height = _clamp(v, c);
    } else {
      _width = _clamp(v, c);
    }
  });

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final scheme = Theme.of(context).colorScheme;
      final extent = _vertical ? _clamp(_height, constraints) : _width;
      final overlay = !_vertical && constraints.maxWidth < _width + WorkspaceSize.terminalMin + WorkspaceSize.divider;
      final size = min(extent, _vertical ? constraints.maxHeight : constraints.maxWidth);
      final present = widget.open || !_presence.isDismissed;
      final edge = switch (widget.side) {
        DockSide.left => AxisDirection.left,
        DockSide.right => AxisDirection.right,
        DockSide.bottom => AxisDirection.down,
      };
      final panel = KeyedSubtree(
        key: _panelKey,
        child: IgnorePointer(
          ignoring: !widget.open,
          child: Material(
            color: scheme.surface,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (widget.showHeader)
                  SizedBox(
                    height: WorkspaceSize.control,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        ...widget.actions,
                        IconButton(
                          tooltip: widget.closeLabel,
                          onPressed: widget.onClose,
                          icon: const Icon(Icons.close, size: 16),
                        ),
                        const SizedBox(width: Space.xs),
                      ],
                    ),
                  ),
                Expanded(child: widget.open ? widget.panel : _leaving),
              ],
            ),
          ),
        ),
      );
      final divider = _vertical
          ? const Divider(height: WorkspaceSize.divider)
          : const VerticalDivider(width: WorkspaceSize.divider);
      final docked = present && !overlay;
      final main = Expanded(child: widget.child);
      final slid = ClipRect(
        child: EdgeSlide(animation: _presence, from: edge, child: panel),
      );
      final sized = _vertical ? SizedBox(height: size, child: slid) : SizedBox(width: size, child: slid);
      final children = switch (widget.side) {
        DockSide.left => [
          if (docked) ...[sized, divider],
          main,
        ],
        DockSide.right || DockSide.bottom => [
          main,
          if (docked) ...[divider, sized],
        ],
      };
      final step = Space.xl;
      // Moving toward the main view grows the panel.
      final growKey = switch (widget.side) {
        DockSide.left => LogicalKeyboardKey.arrowRight,
        DockSide.right => LogicalKeyboardKey.arrowLeft,
        DockSide.bottom => LogicalKeyboardKey.arrowUp,
      };
      final shrinkKey = switch (widget.side) {
        DockSide.left => LogicalKeyboardKey.arrowLeft,
        DockSide.right => LogicalKeyboardKey.arrowRight,
        DockSide.bottom => LogicalKeyboardKey.arrowDown,
      };
      double drag(DragUpdateDetails d) => switch (widget.side) {
        DockSide.left => d.delta.dx,
        DockSide.right => -d.delta.dx,
        DockSide.bottom => -d.delta.dy,
      };
      final grab = WorkspaceSize.dividerGrab;
      Positioned place({required double offset, required double thickness, required Widget child}) =>
          switch (widget.side) {
            DockSide.left => Positioned(top: 0, bottom: 0, left: offset, width: thickness, child: child),
            DockSide.right => Positioned(top: 0, bottom: 0, right: offset, width: thickness, child: child),
            DockSide.bottom => Positioned(left: 0, right: 0, bottom: offset, height: thickness, child: child),
          };
      return Stack(
        fit: StackFit.expand,
        children: [
          _vertical
              ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children)
              : Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
          if (present && overlay) ...[
            FadeTransition(
              opacity: _presence,
              child: ModalBarrier(
                color: Colors.black26,
                dismissible: widget.open,
                onDismiss: widget.onClose,
                semanticsLabel: widget.closeLabel,
              ),
            ),
            place(
              offset: 0,
              thickness: size,
              child: EdgeSlide(
                animation: _presence,
                from: edge,
                full: true,
                child: CallbackShortcuts(
                  bindings: {const SingleActivator(LogicalKeyboardKey.escape): widget.onClose},
                  child: FocusScope(autofocus: true, child: panel),
                ),
              ),
            ),
          ],
          if (widget.open)
            place(
              offset: size - grab / 2,
              thickness: grab,
              child: Semantics(
                label: widget.resizeLabel,
                value: '${extent.round()}',
                increasedValue: '${_clamp(extent + step, constraints).round()}',
                decreasedValue: '${_clamp(extent - step, constraints).round()}',
                onIncrease: () => _resize(extent + step, constraints),
                onDecrease: () => _resize(extent - step, constraints),
                child: MouseRegion(
                  cursor: _vertical ? SystemMouseCursors.resizeRow : SystemMouseCursors.resizeColumn,
                  child: Focus(
                    focusNode: _focus,
                    onFocusChange: (focused) => setState(() => _pointerFocus &= focused),
                    onKeyEvent: (_, event) {
                      if (event is! KeyDownEvent) return KeyEventResult.ignored;
                      if (event.logicalKey == growKey) {
                        _resize(extent + step, constraints);
                        return KeyEventResult.handled;
                      }
                      if (event.logicalKey == shrinkKey) {
                        _resize(extent - step, constraints);
                        return KeyEventResult.handled;
                      }
                      return KeyEventResult.ignored;
                    },
                    child: GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onTapDown: (_) {
                        setState(() => _pointerFocus = true);
                        _focus.requestFocus();
                      },
                      onDoubleTap: () =>
                          _resize(_vertical ? WorkspaceSize.dockBottom : WorkspaceSize.toolPanel, constraints),
                      onPanStart: (_) {
                        setState(() => _pointerFocus = true);
                        _focus.requestFocus();
                        setState(() => _guide = extent);
                      },
                      onPanUpdate: (d) => setState(() => _guide = _clamp(_guide! + drag(d), constraints)),
                      onPanEnd: (_) {
                        final next = _guide!;
                        _guide = null;
                        _resize(next, constraints);
                      },
                      onPanCancel: () => setState(() => _guide = null),
                      child: _guide != null || (_focus.hasFocus && !_pointerFocus)
                          ? ColoredBox(color: scheme.primary.withValues(alpha: .3))
                          : const SizedBox.expand(),
                    ),
                  ),
                ),
              ),
            ),
          if (widget.open && _guide != null)
            place(
              offset: _guide!,
              thickness: 2,
              child: IgnorePointer(child: ColoredBox(color: scheme.primary)),
            ),
        ],
      );
    },
  );
}

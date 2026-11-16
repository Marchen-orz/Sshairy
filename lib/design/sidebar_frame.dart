import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'theme.dart';

/// A panel to the left of the page it shares a row with, such as the server monitor (docs/UI.md). Its
/// divider resizes it the way the navigation and dock panels resize: a guide while dragging, committed on release;
/// double-click restores the default; arrow keys and semantic increase/decrease step it.
///
/// The page keeps [WorkspaceSize.terminalMin]. A stored [width] that no longer fits is shown smaller and is not
/// rewritten, so it comes back with the window. [child] keeps its state while the panel hides, shows or resizes.
class SidebarFrame extends StatefulWidget {
  const SidebarFrame({
    super.key,
    required this.child,
    required this.width,
    required this.onResize,
    required this.resizeLabel,
    this.sidebar,
  });

  final Widget child;

  /// Null while hidden.
  final Widget? sidebar;

  /// The stored width, not yet limited by the space there is.
  final double width;

  /// Called with a width that fits the space, only when it differs from what is shown.
  final ValueChanged<double> onResize;
  final String resizeLabel;

  /// The widest the panel gets in [available] width, never below the minimum.
  static double maxWidth(double available) => max(
    WorkspaceSize.monitorMin,
    min(WorkspaceSize.monitorMax, available - WorkspaceSize.divider - WorkspaceSize.terminalMin),
  );

  static double clampWidth(double width, double available) =>
      width.clamp(WorkspaceSize.monitorMin, maxWidth(available)).toDouble();

  @override
  State<SidebarFrame> createState() => _SidebarFrameState();
}

class _SidebarFrameState extends State<SidebarFrame> {
  final _focus = FocusNode();
  // Pointer focus keeps the arrow keys working without leaving the divider highlighted after the drag.
  var _pointerFocus = false;
  double? _guide;

  @override
  void didUpdateWidget(SidebarFrame old) {
    super.didUpdateWidget(old);
    // A drag cannot finish on a divider that is gone.
    if (widget.sidebar == null) _guide = null;
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final scheme = Theme.of(context).colorScheme;
      final available = constraints.maxWidth;
      final width = SidebarFrame.clampWidth(widget.width, available);
      final sidebar = widget.sidebar;
      const grab = WorkspaceSize.dividerGrab, step = Space.xl;
      double clamp(double w) => SidebarFrame.clampWidth(w, available);
      void resize(double w) {
        final next = clamp(w);
        if (next != width) widget.onResize(next);
      }

      return Stack(
        fit: StackFit.expand,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (sidebar != null) ...[
                SizedBox(width: width, child: sidebar),
                const VerticalDivider(width: WorkspaceSize.divider),
              ],
              // Keyed, so the page is the same element with or without the panel.
              Expanded(key: const ValueKey('sidebar-frame-page'), child: widget.child),
            ],
          ),
          if (sidebar != null)
            Positioned(
              top: 0,
              bottom: 0,
              left: width + WorkspaceSize.divider / 2 - grab / 2,
              width: grab,
              child: Semantics(
                label: widget.resizeLabel,
                value: '${width.round()}',
                increasedValue: '${clamp(width + step).round()}',
                decreasedValue: '${clamp(width - step).round()}',
                onIncrease: () => resize(width + step),
                onDecrease: () => resize(width - step),
                child: MouseRegion(
                  cursor: SystemMouseCursors.resizeColumn,
                  child: Focus(
                    focusNode: _focus,
                    onFocusChange: (focused) => setState(() => _pointerFocus &= focused),
                    onKeyEvent: (_, event) {
                      if (event is! KeyDownEvent) return KeyEventResult.ignored;
                      if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
                        resize(width + step);
                        return KeyEventResult.handled;
                      }
                      if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
                        resize(width - step);
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
                      onDoubleTap: () => resize(WorkspaceSize.monitor),
                      onPanStart: (_) {
                        setState(() => _pointerFocus = true);
                        _focus.requestFocus();
                        setState(() => _guide = width);
                      },
                      onPanUpdate: (d) => setState(() => _guide = clamp(_guide! + d.delta.dx)),
                      onPanEnd: (_) {
                        final next = _guide!;
                        setState(() => _guide = null);
                        resize(next);
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
          if (sidebar != null && _guide != null)
            Positioned(
              top: 0,
              bottom: 0,
              left: _guide,
              width: 2,
              child: IgnorePointer(child: ColoredBox(color: scheme.primary)),
            ),
        ],
      );
    },
  );
}

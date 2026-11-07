import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'theme.dart';

/// Keeps the main view wide; a narrow window presents the same panel over it (docs/UI.md §1).
class ToolPanel extends StatefulWidget {
  const ToolPanel({
    super.key,
    required this.child,
    required this.panel,
    required this.open,
    required this.onClose,
    required this.closeLabel,
    required this.resizeLabel,
  });

  final Widget child, panel;
  final bool open;
  final VoidCallback onClose;
  final String closeLabel, resizeLabel;

  @override
  State<ToolPanel> createState() => _ToolPanelState();
}

class _ToolPanelState extends State<ToolPanel> {
  final _panelKey = GlobalKey();
  final _focus = FocusNode();
  var _width = WorkspaceSize.toolPanel;
  double? _guide;

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  void _resize(double width) =>
      setState(() => _width = width.clamp(WorkspaceSize.toolPanelMin, WorkspaceSize.toolPanelMax));

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final overlay = constraints.maxWidth < _width + WorkspaceSize.terminalMin + WorkspaceSize.divider;
      final width = _width.clamp(0.0, constraints.maxWidth);
      final scheme = Theme.of(context).colorScheme;
      final panel = KeyedSubtree(
        key: _panelKey,
        child: Material(
          color: scheme.surface,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Align(
                alignment: Alignment.centerRight,
                child: IconButton(
                  tooltip: widget.closeLabel,
                  onPressed: widget.onClose,
                  icon: const Icon(Icons.close, size: 18),
                ),
              ),
              Expanded(child: widget.panel),
            ],
          ),
        ),
      );
      return Stack(
        fit: StackFit.expand,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: widget.child),
              if (widget.open && !overlay) ...[
                const VerticalDivider(width: WorkspaceSize.divider),
                SizedBox(width: width, child: panel),
              ],
            ],
          ),
          if (widget.open && overlay) ...[
            ModalBarrier(
              color: Colors.black26,
              dismissible: true,
              onDismiss: widget.onClose,
              semanticsLabel: widget.closeLabel,
            ),
            Positioned(
              top: 0,
              bottom: 0,
              right: 0,
              width: width,
              child: CallbackShortcuts(
                bindings: {const SingleActivator(LogicalKeyboardKey.escape): widget.onClose},
                child: FocusScope(autofocus: true, child: panel),
              ),
            ),
          ],
          if (widget.open)
            Positioned(
              top: 0,
              bottom: 0,
              right: width - WorkspaceSize.dividerGrab / 2,
              width: WorkspaceSize.dividerGrab,
              child: Semantics(
                label: widget.resizeLabel,
                value: '${_width.round()}',
                increasedValue:
                    '${(_width + Space.xl).clamp(WorkspaceSize.toolPanelMin, WorkspaceSize.toolPanelMax).round()}',
                decreasedValue:
                    '${(_width - Space.xl).clamp(WorkspaceSize.toolPanelMin, WorkspaceSize.toolPanelMax).round()}',
                onIncrease: () => _resize(_width + Space.xl),
                onDecrease: () => _resize(_width - Space.xl),
                child: MouseRegion(
                  cursor: SystemMouseCursors.resizeColumn,
                  child: Focus(
                    focusNode: _focus,
                    onFocusChange: (_) => setState(() {}),
                    onKeyEvent: (_, event) {
                      if (event is! KeyDownEvent) return KeyEventResult.ignored;
                      if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
                        _resize(_width + Space.xl);
                        return KeyEventResult.handled;
                      }
                      if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
                        _resize(_width - Space.xl);
                        return KeyEventResult.handled;
                      }
                      return KeyEventResult.ignored;
                    },
                    child: GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onTapDown: (_) => _focus.requestFocus(),
                      onDoubleTap: () => _resize(WorkspaceSize.toolPanel),
                      onHorizontalDragStart: (_) {
                        _focus.requestFocus();
                        setState(() => _guide = _width);
                      },
                      onHorizontalDragUpdate: (d) => setState(
                        () => _guide = (_guide! - d.delta.dx).clamp(
                          WorkspaceSize.toolPanelMin,
                          WorkspaceSize.toolPanelMax,
                        ),
                      ),
                      onHorizontalDragEnd: (_) {
                        final next = _guide!;
                        _guide = null;
                        _resize(next);
                      },
                      onHorizontalDragCancel: () => setState(() => _guide = null),
                      child: _focus.hasFocus
                          ? ColoredBox(color: scheme.primary.withValues(alpha: .3))
                          : const SizedBox.expand(),
                    ),
                  ),
                ),
              ),
            ),
          if (widget.open && _guide != null)
            Positioned(
              top: 0,
              bottom: 0,
              right: _guide!,
              width: 2,
              child: IgnorePointer(child: ColoredBox(color: scheme.primary)),
            ),
        ],
      );
    },
  );
}

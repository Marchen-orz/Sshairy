import 'dart:async';

import 'package:flutter/material.dart';

import '../platform/desktop_window.dart';
import 'theme.dart';

/// Wrap only unused title-bar space: buttons, tabs and inputs retain their own pointer handling.
class DesktopDragRegion extends StatelessWidget {
  const DesktopDragRegion({super.key, required this.child, this.window});

  final Widget child;
  final DesktopWindow? window;

  @override
  Widget build(BuildContext context) {
    final controller = window ?? DesktopWindow.instance;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanStart: (_) => unawaited(controller.beginDrag()),
      onDoubleTap: () => unawaited(controller.toggleMaximize()),
      onSecondaryTapUp: (_) => unawaited(controller.showSystemMenu()),
      child: child,
    );
  }
}

class WindowControls extends StatefulWidget {
  const WindowControls({
    super.key,
    required this.minimizeLabel,
    required this.maximizeLabel,
    required this.restoreLabel,
    required this.closeLabel,
    this.window,
  });

  final String minimizeLabel, maximizeLabel, restoreLabel, closeLabel;
  final DesktopWindow? window;

  @override
  State<WindowControls> createState() => _WindowControlsState();
}

class _WindowControlsState extends State<WindowControls> {
  final _maximizeKey = GlobalKey();
  var _boundsScheduled = false;

  DesktopWindow get _window => widget.window ?? DesktopWindow.instance;

  void _scheduleBounds() {
    if (_boundsScheduled) return;
    _boundsScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _boundsScheduled = false;
      if (!mounted) return;
      final box = _maximizeKey.currentContext?.findRenderObject() as RenderBox?;
      final bounds = box != null && box.hasSize && (ModalRoute.of(context)?.isCurrent ?? true)
          ? MatrixUtils.transformRect(box.getTransformTo(null), Offset.zero & box.size)
          : null;
      unawaited(_window.setMaximizeRect(bounds, View.of(context).devicePixelRatio));
    });
  }

  @override
  void dispose() {
    unawaited(_window.setMaximizeRect(null, 1));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Route changes disable native hit testing while a dialog or drawer covers this page.
    ModalRoute.of(context);
    MediaQuery.sizeOf(context);
    return ValueListenableBuilder<DesktopWindowState>(
      valueListenable: _window,
      builder: (context, state, _) {
        _scheduleBounds();
        if (!state.supported || !state.customChrome) return const SizedBox.shrink();
        final scheme = Theme.of(context).colorScheme;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _WindowButton(
              label: widget.minimizeLabel,
              icon: Icons.remove,
              onPressed: () => unawaited(_window.minimize()),
            ),
            const SizedBox(width: _gap),
            _WindowButton(
              key: _maximizeKey,
              label: state.maximized ? widget.restoreLabel : widget.maximizeLabel,
              icon: state.maximized ? Icons.filter_none : Icons.crop_square,
              background: state.maximizeHovered ? scheme.onSurface.withValues(alpha: 0.08) : null,
              onPressed: () => unawaited(_window.toggleMaximize()),
            ),
            const SizedBox(width: _gap),
            _WindowButton(
              label: widget.closeLabel,
              icon: Icons.close,
              destructive: true,
              onPressed: () => unawaited(_window.close()),
            ),
            const SizedBox(width: Space.sm),
          ],
        );
      },
    );
  }
}

const _gap = Space.xs / 2;

class _WindowButton extends StatelessWidget {
  const _WindowButton({
    super.key,
    required this.label,
    required this.icon,
    required this.onPressed,
    this.background,
    this.destructive = false,
  });

  final String label;
  final IconData icon;
  final VoidCallback onPressed;
  final Color? background;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: label,
      child: SizedBox(
        width: 36,
        height: 28,
        child: TextButton(
          onPressed: onPressed,
          style: ButtonStyle(
            padding: const WidgetStatePropertyAll(EdgeInsets.zero),
            minimumSize: const WidgetStatePropertyAll(Size(36, 28)),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            shape: const WidgetStatePropertyAll(
              RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(Radii.control))),
            ),
            overlayColor: WidgetStateProperty.resolveWith((states) {
              if (destructive) return Colors.transparent;
              if (states.contains(WidgetState.pressed)) return scheme.onSurface.withValues(alpha: 0.12);
              if (states.contains(WidgetState.hovered)) return scheme.onSurface.withValues(alpha: 0.08);
              return null;
            }),
            backgroundColor: WidgetStateProperty.resolveWith((states) {
              if (destructive && states.contains(WidgetState.pressed)) return scheme.error.withValues(alpha: 0.85);
              if (destructive && states.contains(WidgetState.hovered)) return scheme.error;
              return background;
            }),
            foregroundColor: WidgetStateProperty.resolveWith((states) {
              if (destructive && states.contains(WidgetState.hovered)) return scheme.onError;
              return scheme.onSurface;
            }),
          ),
          child: Semantics(label: label, child: Icon(icon, size: 14)),
        ),
      ),
    );
  }
}

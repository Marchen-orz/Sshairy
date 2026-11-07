import 'dart:async';

import 'package:flutter/material.dart';

import '../design/brand_palette.dart';
import '../platform/desktop_window.dart';

/// Uses the resolved application theme, including system brightness, for the running window's icon.
class WindowBrandIcon extends StatefulWidget {
  const WindowBrandIcon({super.key, required this.child, this.window});

  final Widget child;
  final DesktopWindow? window;

  @override
  State<WindowBrandIcon> createState() => _WindowBrandIconState();
}

class _WindowBrandIconState extends State<WindowBrandIcon> {
  var _scheduled = false;
  DesktopWindow get _window => widget.window ?? DesktopWindow.instance;

  @override
  void initState() {
    super.initState();
    _window.addListener(_schedule);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _schedule();
  }

  @override
  void didUpdateWidget(WindowBrandIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.window != widget.window) {
      (oldWidget.window ?? DesktopWindow.instance).removeListener(_schedule);
      _window.addListener(_schedule);
      _schedule();
    }
  }

  void _schedule() {
    if (_scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!mounted) return;
      final palette = BrandPalette.of(context);
      unawaited(_window.setBrandIcon(palette.theme.name, dark: palette.brightness == Brightness.dark));
    });
  }

  @override
  void dispose() {
    _window.removeListener(_schedule);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

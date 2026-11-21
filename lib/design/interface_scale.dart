import 'package:flutter/material.dart';

/// A virtual viewport keeps controls, overlays and hit tests in one coordinate system at any interface scale.
class InterfaceScale extends StatelessWidget {
  const InterfaceScale({super.key, required this.scale, required this.child});

  final double scale;
  final Widget child;

  static Size viewportSizeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_ViewportSize>()?.size ?? MediaQuery.sizeOf(context);

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final media = MediaQuery.of(context);
      final size = constraints.biggest / scale;
      return ClipRect(
        child: SizedBox.expand(
          child: FittedBox(
            fit: BoxFit.fill,
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: size.width,
              height: size.height,
              child: MediaQuery(
                data: media.copyWith(
                  size: size,
                  padding: media.padding / scale,
                  viewPadding: media.viewPadding / scale,
                  viewInsets: media.viewInsets / scale,
                  systemGestureInsets: media.systemGestureInsets / scale,
                ),
                child: _ViewportSize(size: constraints.biggest, child: child),
              ),
            ),
          ),
        ),
      );
    },
  );
}

class _ViewportSize extends InheritedWidget {
  const _ViewportSize({required this.size, required super.child});

  final Size size;

  @override
  bool updateShouldNotify(_ViewportSize oldWidget) => size != oldWidget.size;
}

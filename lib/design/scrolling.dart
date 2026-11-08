import 'package:flutter/material.dart';

import 'theme.dart';

/// Keeps desktop scrollbars outside the content without changing horizontal scrolling.
class AppScrollBehavior extends MaterialScrollBehavior {
  const AppScrollBehavior({this.gutter = Space.lg});

  final double gutter;

  static double gutterOf(BuildContext context) {
    final behavior = ScrollConfiguration.of(context);
    return behavior is AppScrollBehavior && behavior._desktop(context) ? behavior.gutter : 0;
  }

  bool _desktop(BuildContext context) => switch (getPlatform(context)) {
    TargetPlatform.windows || TargetPlatform.linux || TargetPlatform.macOS => true,
    _ => false,
  };

  @override
  Widget buildScrollbar(BuildContext context, Widget child, ScrollableDetails details) {
    if (!_desktop(context) || axisDirectionToAxis(details.direction) != Axis.vertical || gutter == 0) {
      return super.buildScrollbar(context, child, details);
    }
    return super.buildScrollbar(
      context,
      Padding(
        padding: EdgeInsetsDirectional.only(end: gutter),
        child: child,
      ),
      details,
    );
  }
}

/// Aligns fixed column headings with the narrower scrolling rows below them.
class ScrollGutter extends StatelessWidget {
  const ScrollGutter({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsetsDirectional.only(end: AppScrollBehavior.gutterOf(context)),
    child: child,
  );
}

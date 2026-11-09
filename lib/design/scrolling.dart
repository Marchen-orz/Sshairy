import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart' show precisionErrorTolerance;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'theme.dart';

/// Keeps desktop scrollbars outside the content without changing horizontal scrolling. The gap at the end of a
/// vertical view exists only while its content overflows; a view that fits keeps its full width.
class AppScrollBehavior extends MaterialScrollBehavior {
  const AppScrollBehavior({this.gutter = ScrollSize.gutter});

  final double gutter;

  bool _desktop(BuildContext context) => switch (getPlatform(context)) {
    TargetPlatform.windows || TargetPlatform.linux || TargetPlatform.macOS => true,
    _ => false,
  };

  @override
  Widget buildScrollbar(BuildContext context, Widget child, ScrollableDetails details) {
    if (!_desktop(context) || axisDirectionToAxis(details.direction) != Axis.vertical || gutter == 0) {
      return super.buildScrollbar(context, child, details);
    }
    return super.buildScrollbar(context, _OverflowGap(gap: gutter, child: child), details);
  }
}

/// Pads the end of its scroll view once the view reports overflowing content. The scrollbar sits outside this
/// widget, so its thumb draws in the gap.
class _OverflowGap extends StatefulWidget {
  const _OverflowGap({required this.gap, required this.child});

  final double gap;
  final Widget child;

  @override
  State<_OverflowGap> createState() => _OverflowGapState();
}

class _OverflowGapState extends State<_OverflowGap> {
  late final _ScrollGutterScopeState? _scope;
  var _reserved = false;

  /// Changes of the gap in a row that no content change caused. Narrower content that gets shorter, such as a
  /// picture at a fixed aspect ratio, would otherwise switch the gap on and off every frame.
  var _flips = 0;

  @override
  void initState() {
    super.initState();
    _scope = context.findAncestorStateOfType<_ScrollGutterScopeState>();
  }

  bool _onMetrics(ScrollMetricsNotification notification) {
    if (notification.depth != 0) return false;
    final metrics = notification.metrics;
    final overflowing = metrics.maxScrollExtent - metrics.minScrollExtent > precisionErrorTolerance;
    if (overflowing == _reserved || _flips >= 2) return false;
    final flip = ++_flips;
    setState(() => _reserved = overflowing);
    _scope?._reserve(this, overflowing ? widget.gap : 0);
    // The relaid view's own notification, if it sends one, is queued before this check and so comes first.
    SchedulerBinding.instance.addPostFrameCallback((_) {
      scheduleMicrotask(() {
        if (_flips == flip) _flips = 0;
      });
    });
    return false;
  }

  @override
  void dispose() {
    _scope?._release(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => NotificationListener<ScrollMetricsNotification>(
    onNotification: _onMetrics,
    child: Padding(
      padding: EdgeInsetsDirectional.only(end: _reserved ? widget.gap : 0),
      child: widget.child,
    ),
  );
}

/// Shares the gap the vertical scroll views below it currently reserve, for what sits beside them: fixed headings
/// and width calculations that must match the rows' real width.
class ScrollGutterScope extends StatefulWidget {
  const ScrollGutterScope({super.key, required this.child});

  final Widget child;

  /// The gap reserved by a scroll view below the nearest scope; zero while none overflows, or without a scope.
  /// Widgets that call this rebuild when it changes.
  static double gapOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<_Gap>()?.gap ?? 0;

  @override
  State<ScrollGutterScope> createState() => _ScrollGutterScopeState();
}

class _ScrollGutterScopeState extends State<ScrollGutterScope> {
  final _reserving = <Object, double>{};

  double get _gap => _reserving.values.fold(0.0, (a, b) => max(a, b));

  void _reserve(Object view, double gap) {
    final before = _gap;
    if (gap == 0) {
      _reserving.remove(view);
    } else {
      _reserving[view] = gap;
    }
    if (_gap != before) setState(() {});
  }

  /// A view leaving the tree cannot rebuild its scope while the tree is locked; the frame after it can.
  void _release(Object view) {
    if (_reserving.remove(view) == null) return;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) => _Gap(gap: _gap, child: widget.child);
}

class _Gap extends InheritedWidget {
  const _Gap({required this.gap, required super.child});

  final double gap;

  @override
  bool updateShouldNotify(_Gap old) => gap != old.gap;
}

/// A [LayoutBuilder] whose builder can read [ScrollGutterScope.gapOf] to size things by the width the rows get.
class ScrollGutterLayout extends StatelessWidget {
  const ScrollGutterLayout({super.key, required this.builder});

  final LayoutWidgetBuilder builder;

  @override
  Widget build(BuildContext context) => ScrollGutterScope(child: LayoutBuilder(builder: builder));
}

/// Aligns fixed column headings with the narrower scrolling rows below them.
class ScrollGutter extends StatelessWidget {
  const ScrollGutter({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsetsDirectional.only(end: ScrollGutterScope.gapOf(context)),
    child: child,
  );
}

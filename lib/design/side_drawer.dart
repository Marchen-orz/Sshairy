import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'popup.dart';
import 'theme.dart';

/// The current navigation width, shared with secondary panels opened from command actions.
class SidePanelAnchor extends InheritedWidget {
  const SidePanelAnchor({super.key, required this.navigationWidth, required super.child});

  final double navigationWidth;

  static double of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SidePanelAnchor>()?.navigationWidth ?? WorkspaceSize.rail;

  @override
  bool updateShouldNotify(SidePanelAnchor oldWidget) => navigationWidth != oldWidget.navigationWidth;
}

/// Edit drawer from docs/UI.md §1: a floating panel on the right; Esc or a click outside closes it.
Future<T?> showSideDrawer<T>(BuildContext context, WidgetBuilder builder, {double width = WorkspaceSize.flyout}) =>
    _showPanel<T>(context, builder, width: width, right: true);

/// A secondary panel beside the icon rail, for keys, forwarding, snippets and trust records.
Future<T?> showFlyout<T>(BuildContext context, WidgetBuilder builder, {double width = WorkspaceSize.flyout}) =>
    _showPanel<T>(context, builder, width: width, right: false);

Future<T?> _showPanel<T>(BuildContext context, WidgetBuilder builder, {required double width, required bool right}) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  final navigationWidth = SidePanelAnchor.of(context);
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Colors.black.withValues(alpha: right ? (dark ? .4 : .18) : (dark ? .25 : .08)),
    transitionDuration: Motion.panel,
    // Focus starts inside, so Escape closes the panel even when nothing in it takes focus.
    pageBuilder: (context, animation, _) => CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): () => Navigator.maybePop(context)},
      child: Focus(
        autofocus: true,
        child: SafeArea(
          child: Padding(
            padding: EdgeInsets.only(
              // Panels stay below the title bar, leaving the tabs' row and the window buttons visible.
              top: WorkspaceSize.titleBar + Space.sm,
              bottom: Space.sm,
              right: right ? Space.sm : 0,
              left: right ? 0 : navigationWidth + Space.xs,
            ),
            child: Align(
              alignment: right ? Alignment.centerRight : Alignment.centerLeft,
              child: SizedBox(
                width: width,
                height: double.infinity,
                child: popupTransition(
                  context,
                  animation,
                  PopupSurface(
                    radius: Radii.panel,
                    padding: const EdgeInsets.all(20),
                    child: Builder(builder: builder),
                  ),
                  // Blending a full-height panel and its shadow every frame costs 40–200 ms under Impeller,
                  // so it wipes in from the rail instead. Skia keeps the short shift (its first clip is costly).
                  offset: right
                      ? Offset(width + Space.sm, 0)
                      : (PopupReveal.byClip ? Offset.zero : const Offset(-32, 0)),
                  fade: !right && !PopupReveal.byClip,
                  clipper: !right && PopupReveal.byClip ? (progress) => _FlyoutReveal(progress) : null,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
    transitionBuilder: (context, animation, _, child) => child,
  );
}

/// Reveals a flyout from the rail's edge without blending the whole panel each frame.
class _FlyoutReveal extends CustomClipper<Rect> {
  _FlyoutReveal(this.progress) : super(reclip: progress);

  final Animation<double> progress;

  @override
  Rect getClip(Size size) {
    // Include the panel's existing shadow, so completion does not suddenly add it.
    final bounds = (Offset.zero & size).inflate(Space.xxl * 2);
    return Rect.fromLTRB(
      bounds.left,
      bounds.top,
      bounds.left + bounds.width * progress.value.clamp(0.0, 1.0),
      bounds.bottom,
    );
  }

  @override
  Rect getApproximateClipRect(Size size) => getClip(size);

  @override
  bool shouldReclip(_FlyoutReveal old) => progress != old.progress;
}

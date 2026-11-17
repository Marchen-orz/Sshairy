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
                  // The right drawer slides in solid from off-screen; a flyout beside the rail fades in from it.
                  offset: right ? Offset(width + Space.sm, 0) : const Offset(-32, 0),
                  fade: !right,
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

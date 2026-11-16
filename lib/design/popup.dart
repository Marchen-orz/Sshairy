import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'theme.dart';

/// Which side of its anchor a popup opens on; it flips when there is no room.
enum PopupPlacement { below, right }

/// The global rectangle [context]'s widget occupies, for anchoring a popup to it.
Rect anchorOf(BuildContext context) {
  final box = context.findRenderObject()! as RenderBox;
  return MatrixUtils.transformRect(box.getTransformTo(null), Offset.zero & box.size);
}

/// A zero-size anchor at a pointer position, for context menus.
Rect anchorAt(Offset position) => Rect.fromLTWH(position.dx, position.dy, 0, 0);

/// Opens [builder] next to [anchor]. Esc, a click outside or popping closes it, and focus returns to where it was.
Future<T?> showAnchoredPopup<T>({
  required BuildContext context,
  required Rect anchor,
  required WidgetBuilder builder,
  PopupPlacement placement = PopupPlacement.below,
  double? width,
  double maxHeight = 440,
  double gap = 4,
}) {
  final navigator = Navigator.of(context);
  final viewport = navigator.context.findRenderObject()! as RenderBox;
  final local = Rect.fromPoints(viewport.globalToLocal(anchor.topLeft), viewport.globalToLocal(anchor.bottomRight));
  return navigator.push(
    _AnchoredRoute<T>(
      anchor: local,
      builder: builder,
      placement: placement,
      width: width,
      maxHeight: maxHeight,
      gap: gap,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      capturedThemes: InheritedTheme.capture(from: context, to: navigator.context),
    ),
  );
}

class _AnchoredRoute<T> extends PopupRoute<T> {
  _AnchoredRoute({
    required this.anchor,
    required this.builder,
    required this.placement,
    required this.width,
    required this.maxHeight,
    required this.gap,
    required this.barrierLabel,
    required this.capturedThemes,
  });

  final Rect anchor;
  final WidgetBuilder builder;
  final PopupPlacement placement;
  final double? width;
  final double maxHeight, gap;
  final CapturedThemes capturedThemes;

  @override
  final String barrierLabel;

  @override
  Color? get barrierColor => null;

  @override
  bool get barrierDismissible => true;

  @override
  Duration get transitionDuration => Motion.normal;

  @override
  Duration get reverseTransitionDuration => Motion.quick;

  @override
  Widget buildPage(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation) =>
      CustomSingleChildLayout(
        delegate: _AnchorLayout(anchor, placement, width, maxHeight, gap),
        child: capturedThemes.wrap(Builder(builder: builder)),
      );

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => popupTransition(
    context,
    animation,
    child,
    offset: placement == PopupPlacement.below ? const Offset(0, -4) : const Offset(-4, 0),
    scale: .96,
    alignment: placement == PopupPlacement.below ? Alignment.topCenter : Alignment.centerLeft,
  );
}

class _AnchorLayout extends SingleChildLayoutDelegate {
  const _AnchorLayout(this.anchor, this.placement, this.width, this.maxHeight, this.gap);

  static const _margin = 8.0;

  final Rect anchor;
  final PopupPlacement placement;
  final double? width;
  final double maxHeight, gap;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final maxW = max(0.0, constraints.maxWidth - 2 * _margin);
    final maxH = min(maxHeight, max(0.0, constraints.maxHeight - 2 * _margin));
    final w = width == null ? null : min(width!, maxW);
    return BoxConstraints(minWidth: w ?? 0, maxWidth: w ?? maxW, maxHeight: maxH);
  }

  @override
  Offset getPositionForChild(Size size, Size child) {
    double clampX(double x) => x.clamp(_margin, max(_margin, size.width - child.width - _margin)).toDouble();
    double clampY(double y) => y.clamp(_margin, max(_margin, size.height - child.height - _margin)).toDouble();
    if (placement == PopupPlacement.right) {
      var x = anchor.right + gap;
      if (x + child.width > size.width - _margin) x = anchor.left - gap - child.width;
      return Offset(clampX(x), clampY(anchor.top));
    }
    var y = anchor.bottom + gap;
    if (y + child.height > size.height - _margin && anchor.top - gap - child.height >= _margin) {
      y = anchor.top - gap - child.height;
    }
    return Offset(clampX(anchor.left), clampY(y));
  }

  @override
  bool shouldRelayout(_AnchorLayout old) =>
      anchor != old.anchor ||
      placement != old.placement ||
      width != old.width ||
      maxHeight != old.maxHeight ||
      gap != old.gap;
}

/// The rounded, bordered, shadowed card every popup draws on.
class PopupSurface extends StatelessWidget {
  const PopupSurface({super.key, required this.child, this.radius = Radii.card, this.padding = EdgeInsets.zero});

  final Widget child;
  final double radius;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        boxShadow: overlayShadow(theme.brightness),
      ),
      child: Material(
        color: scheme.surfaceContainerHigh,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
          side: BorderSide(color: scheme.outlineVariant),
        ),
        clipBehavior: Clip.antiAlias,
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}

/// Up and down move between the focusable rows of a popup list.
class PopupKeys extends StatelessWidget {
  const PopupKeys({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Shortcuts(
    shortcuts: const {
      SingleActivator(LogicalKeyboardKey.arrowDown): NextFocusIntent(),
      SingleActivator(LogicalKeyboardKey.arrowUp): PreviousFocusIntent(),
    },
    child: FocusTraversalGroup(child: child),
  );
}

/// One row of a menu or option list: hover and focus tint, keyboard activation, a rounded highlight.
class PopupRow extends StatelessWidget {
  const PopupRow({
    super.key,
    required this.child,
    required this.onTap,
    this.selected = false,
    this.autofocus = false,
    this.height = 32,
  });

  final Widget child;
  final VoidCallback? onTap;
  final bool selected, autofocus;
  final double height;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Space.xs),
      child: Material(
        color: selected ? scheme.primary.withValues(alpha: .12) : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          autofocus: autofocus,
          onTap: onTap,
          hoverColor: scheme.onSurface.withValues(alpha: .06),
          focusColor: scheme.primary.withValues(alpha: .14),
          highlightColor: scheme.onSurface.withValues(alpha: .08),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: height),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Align(alignment: AlignmentDirectional.centerStart, widthFactor: 1, child: child),
            ),
          ),
        ),
      ),
    );
  }
}

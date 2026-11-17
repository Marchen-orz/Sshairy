import 'dart:async';

import 'package:flutter/material.dart';

import '../platform/desktop_window.dart';
import 'popup.dart';
import 'theme.dart';

/// A centred modal for security confirmations, authentication, quitting and settings (UI §5). A dialog that opens while
/// the window is minimized or behind others brings it to the front so the user notices the question.
Future<T?> showAppDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
}) {
  final window = DesktopWindow.instance;
  if (!window.value.active) unawaited(window.show());
  final dark = Theme.of(context).brightness == Brightness.dark;
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Colors.black.withValues(alpha: dark ? .5 : .28),
    transitionDuration: Motion.panel,
    pageBuilder: (context, _, _) => Builder(builder: builder),
    // Only the card animates: fading the full-screen page blended a whole window-sized layer every frame.
    transitionBuilder: (context, animation, _, child) => _DialogMotion(animation: animation, child: child),
  );
}

class _DialogMotion extends InheritedWidget {
  const _DialogMotion({required this.animation, required super.child});

  final Animation<double> animation;

  static Animation<double>? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_DialogMotion>()?.animation;

  @override
  bool updateShouldNotify(_DialogMotion oldWidget) => animation != oldWidget.animation;
}

/// Applies a dialog's entrance to its card instead of the whole page (UI §2).
class DialogMotion extends StatelessWidget {
  const DialogMotion({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final animation = _DialogMotion.of(context);
    if (animation == null) return child;
    final clip = PopupReveal.byClip;
    return popupTransition(
      context,
      animation,
      child,
      offset: clip ? Offset.zero : const Offset(0, 12),
      fade: !clip,
      clipper: clip ? (progress) => _DialogReveal(progress) : null,
    );
  }
}

/// Reveals a centred card from its top edge without blending the whole window each frame.
class _DialogReveal extends CustomClipper<Rect> {
  _DialogReveal(this.progress) : super(reclip: progress);

  final Animation<double> progress;

  @override
  Rect getClip(Size size) {
    // Include the card's existing shadow, so completion does not suddenly add it.
    final bounds = (Offset.zero & size).inflate(Space.xxl * 2);
    return Rect.fromLTRB(
      bounds.left,
      bounds.top,
      bounds.right,
      bounds.top + bounds.height * progress.value.clamp(0.0, 1.0),
    );
  }

  @override
  Rect getApproximateClipRect(Size size) => getClip(size);

  @override
  bool shouldReclip(_DialogReveal old) => progress != old.progress;
}

class AppDialog extends StatelessWidget {
  const AppDialog({super.key, this.title, this.content, this.actions = const [], this.width = 400, this.icon});

  final Widget? title, content, icon;
  final List<Widget> actions;
  final double width;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final size = MediaQuery.sizeOf(context);
    return Center(
      child: DialogMotion(
        child: Padding(
          padding: const EdgeInsets.all(Space.xl),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: width, maxHeight: size.height - 2 * Space.xl),
            child: PopupSurface(
              radius: Radii.panel,
              padding: const EdgeInsets.fromLTRB(Space.xl, 20, Space.xl, Space.lg),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (title != null)
                    Row(
                      children: [
                        if (icon != null) ...[
                          IconTheme.merge(data: const IconThemeData(size: 20), child: icon!),
                          const SizedBox(width: Space.sm),
                        ],
                        Expanded(
                          child: DefaultTextStyle.merge(style: theme.textTheme.titleSmall, child: title!),
                        ),
                      ],
                    ),
                  if (title != null && content != null) const SizedBox(height: Space.md),
                  if (content != null)
                    Flexible(
                      child: DefaultTextStyle.merge(
                        style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                        child: content!,
                      ),
                    ),
                  if (actions.isNotEmpty) ...[
                    const SizedBox(height: 20),
                    Wrap(alignment: WrapAlignment.end, spacing: Space.sm, runSpacing: Space.sm, children: actions),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

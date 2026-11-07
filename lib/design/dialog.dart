import 'package:flutter/material.dart';

import 'popup.dart';
import 'theme.dart';

/// A centred modal for decisions that cannot wait: security confirmations, authentication, quitting (UI §5).
Future<T?> showAppDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
}) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Colors.black.withValues(alpha: dark ? .5 : .28),
    transitionDuration: Motion.normal,
    pageBuilder: (context, _, _) => Builder(builder: builder),
    transitionBuilder: (context, animation, _, child) {
      final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
      return FadeTransition(
        opacity: curved,
        child: ScaleTransition(scale: Tween(begin: .96, end: 1.0).animate(curved), child: child),
      );
    },
  );
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
                  Wrap(
                    alignment: WrapAlignment.end,
                    spacing: Space.sm,
                    runSpacing: Space.sm,
                    children: actions,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

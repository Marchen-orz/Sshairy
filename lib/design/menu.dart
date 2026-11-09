import 'package:flutter/material.dart';

import 'popup.dart';
import 'theme.dart';

sealed class AppMenuEntry<T> {
  const AppMenuEntry();
}

class AppMenuItem<T> extends AppMenuEntry<T> {
  const AppMenuItem({
    required this.value,
    required this.label,
    this.icon,
    this.glyph,
    this.enabled = true,
    this.checked,
    this.destructive = false,
  });

  final T value;
  final String label;
  final IconData? icon;

  /// A drawn icon in place of [icon], sized and coloured by the surrounding [IconTheme].
  final Widget? glyph;
  final bool enabled, destructive;

  /// Non-null reserves a check column; true shows the mark.
  final bool? checked;
}

class AppMenuDivider<T> extends AppMenuEntry<T> {
  const AppMenuDivider();
}

/// A menu beside [anchor]; resolves to the chosen item's value, or null when dismissed.
Future<T?> showAppMenu<T>({
  required BuildContext context,
  required Rect anchor,
  required List<AppMenuEntry<T>> items,
  PopupPlacement placement = PopupPlacement.below,
}) async => (await _showMenu(context, anchor, items, placement))?.$1;

/// The choice comes back boxed, so a null item value is told apart from a dismissed menu.
Future<(T,)?> _showMenu<T>(
  BuildContext context,
  Rect anchor,
  List<AppMenuEntry<T>> items,
  PopupPlacement placement, {
  double minWidth = _menuMinWidth,
}) => showAnchoredPopup<(T,)>(
  context: context,
  anchor: anchor,
  placement: placement,
  gap: anchor.isEmpty ? 0 : 4,
  builder: (context) => _MenuList<T>(items, minWidth),
);

const _menuMinWidth = 168.0;

class _MenuList<T> extends StatelessWidget {
  const _MenuList(this.items, this.minWidth);

  final List<AppMenuEntry<T>> items;
  final double minWidth;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final checks = items.any((e) => e is AppMenuItem<T> && e.checked != null);
    final icons = items.any((e) => e is AppMenuItem<T> && (e.icon != null || e.glyph != null));
    final first = items.indexWhere((e) => e is AppMenuItem<T> && e.enabled);
    return ConstrainedBox(
      constraints: BoxConstraints(minWidth: minWidth, maxWidth: 320),
      child: PopupSurface(
        padding: const EdgeInsets.symmetric(vertical: Space.xs),
        child: PopupKeys(
          child: SingleChildScrollView(
            child: IntrinsicWidth(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final (i, entry) in items.indexed)
                    switch (entry) {
                      AppMenuDivider() => Padding(
                        padding: const EdgeInsets.symmetric(vertical: Space.xs),
                        child: Divider(color: scheme.outlineVariant.withValues(alpha: .7)),
                      ),
                      AppMenuItem(
                        :final value,
                        :final label,
                        :final icon,
                        :final glyph,
                        :final enabled,
                        :final checked,
                      ) =>
                        Opacity(
                          opacity: enabled ? 1 : .4,
                          child: PopupRow(
                            autofocus: i == first,
                            onTap: enabled ? () => Navigator.pop(context, (value,)) : null,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (checks)
                                  SizedBox(
                                    width: 22,
                                    child: checked == true
                                        ? Icon(
                                            Icons.check,
                                            size: 15,
                                            color: enabled ? scheme.primary : BrandPalette.of(context).textMuted,
                                          )
                                        : null,
                                  ),
                                if (icons)
                                  SizedBox(
                                    width: 24,
                                    child: glyph != null
                                        ? IconTheme(
                                            data: IconThemeData(
                                              size: 16,
                                              color: !enabled
                                                  ? BrandPalette.of(context).textMuted
                                                  : entry.destructive
                                                  ? scheme.error
                                                  : scheme.onSurfaceVariant,
                                            ),
                                            child: Center(child: glyph),
                                          )
                                        : icon == null
                                        ? null
                                        : Icon(
                                            icon,
                                            size: 16,
                                            color: !enabled
                                                ? BrandPalette.of(context).textMuted
                                                : entry.destructive
                                                ? scheme.error
                                                : scheme.onSurfaceVariant,
                                          ),
                                  ),
                                Flexible(
                                  child: Text(
                                    label,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: !enabled
                                          ? BrandPalette.of(context).textMuted
                                          : entry.destructive
                                          ? scheme.error
                                          : null,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: Space.md),
                              ],
                            ),
                          ),
                        ),
                    },
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A button that opens a menu below itself: an icon by default, or any [child].
class AppMenuButton<T> extends StatelessWidget {
  const AppMenuButton({
    super.key,
    required this.items,
    required this.onSelected,
    this.icon = const Icon(Icons.more_horiz),
    this.tooltip,
    this.child,
    this.enabled = true,
    this.minWidth = _menuMinWidth,
  });

  final List<AppMenuEntry<T>> Function() items;
  final ValueChanged<T> onSelected;
  final Widget icon;
  final String? tooltip;
  final Widget? child;
  final bool enabled;

  /// Narrower than the default for a short list of short labels.
  final double minWidth;

  Future<void> _open(BuildContext context) async {
    final picked = await _showMenu<T>(context, anchorOf(context), items(), PopupPlacement.below, minWidth: minWidth);
    if (picked != null && context.mounted) onSelected(picked.$1);
  }

  @override
  Widget build(BuildContext context) => Builder(
    builder: (context) {
      if (child == null) {
        return IconButton(tooltip: tooltip, onPressed: enabled ? () => _open(context) : null, icon: icon);
      }
      final button = Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(Radii.control),
          onTap: enabled ? () => _open(context) : null,
          child: child,
        ),
      );
      return tooltip == null ? button : Tooltip(message: tooltip, child: button);
    },
  );
}

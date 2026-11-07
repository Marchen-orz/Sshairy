import 'package:flutter/material.dart';

import 'theme.dart';

class RailItem {
  const RailItem({required this.icon, required this.label, required this.onTap, this.selected = false});

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool selected;
}

/// The narrow column at the window's left edge (UI §1): pages, then flyouts, with app actions at the bottom.
class IconRail extends StatelessWidget {
  const IconRail({super.key, required this.header, required this.groups, required this.bottom});

  final Widget header;
  final List<List<RailItem>> groups;
  final List<RailItem> bottom;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: WorkspaceSize.rail,
      child: ColoredBox(
        color: scheme.surfaceContainerLow,
        child: FocusTraversalGroup(
          child: Column(
            children: [
              SizedBox(height: WorkspaceSize.titleBar, child: header),
              const SizedBox(height: Space.xs),
              for (final (i, group) in groups.indexed) ...[
                if (i > 0)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: Space.sm),
                    child: SizedBox(width: 20, child: Divider(color: scheme.outlineVariant)),
                  ),
                for (final item in group) _RailButton(item),
              ],
              const Spacer(),
              for (final item in bottom) _RailButton(item),
              const SizedBox(height: Space.sm),
            ],
          ),
        ),
      ),
    );
  }
}

class _RailButton extends StatelessWidget {
  const _RailButton(this.item);

  final RailItem item;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.xs),
      child: Tooltip(
        message: item.label,
        child: Semantics(
          button: true,
          selected: item.selected,
          label: item.label,
          excludeSemantics: true,
          child: Material(
            color: item.selected ? scheme.primary.withValues(alpha: .14) : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: item.onTap,
              hoverColor: scheme.onSurface.withValues(alpha: .06),
              child: SizedBox.square(
                dimension: WorkspaceSize.railItem,
                child: Icon(item.icon, size: 18, color: item.selected ? scheme.primary : scheme.onSurfaceVariant),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'theme.dart';
import 'scrolling.dart';

class RailItem {
  const RailItem({required this.icon, required this.label, required this.onTap, this.selected = false});

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool selected;
}

/// The navigation column keeps its content and focus while switching between icons and full labels.
class IconRail extends StatelessWidget {
  const IconRail({
    super.key,
    required this.header,
    required this.expandedHeader,
    required this.expanded,
    required this.toggleLabel,
    required this.onToggle,
    required this.groups,
    required this.bottom,
    this.width = WorkspaceSize.navigationExpanded,
  });

  final Widget header, expandedHeader;
  final bool expanded;
  final String toggleLabel;
  final VoidCallback onToggle;
  final List<List<RailItem>> groups;
  final List<RailItem> bottom;

  /// The expanded width; collapsed is always [WorkspaceSize.rail].
  final double width;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: expanded ? width : WorkspaceSize.rail,
      child: ColoredBox(
        color: scheme.surfaceContainerLow,
        child: FocusTraversalGroup(
          child: Column(
            children: [
              SizedBox(
                height: expanded ? WorkspaceSize.navigationHeader : WorkspaceSize.titleBar,
                child: expanded ? expandedHeader : header,
              ),
              const SizedBox(height: Space.xs),
              Expanded(
                child: ScrollbarTheme(
                  data: ScrollbarTheme.of(context).copyWith(thickness: const WidgetStatePropertyAll(4)),
                  child: ScrollConfiguration(
                    behavior: AppScrollBehavior(gutter: expanded ? ScrollSize.gutter : 0),
                    child: SingleChildScrollView(
                      child: Column(
                        children: [
                          for (final (i, group) in groups.indexed) ...[
                            if (i > 0)
                              Padding(
                                padding: const EdgeInsets.symmetric(vertical: Space.sm, horizontal: Space.lg),
                                child: SizedBox(width: expanded ? double.infinity : 20, child: const Divider()),
                              ),
                            for (final item in group) _RailButton(item, expanded: expanded),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              _RailButton(
                RailItem(
                  icon: expanded ? Icons.keyboard_double_arrow_left_rounded : Icons.keyboard_double_arrow_right_rounded,
                  label: toggleLabel,
                  onTap: onToggle,
                ),
                expanded: expanded,
              ),
              for (final item in bottom) _RailButton(item, expanded: expanded),
              const SizedBox(height: Space.sm),
            ],
          ),
        ),
      ),
    );
  }
}

class _RailButton extends StatelessWidget {
  const _RailButton(this.item, {required this.expanded});

  final RailItem item;
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final palette = BrandPalette.fromTheme(theme);
    final color = item.selected ? palette.onNavigationSelection : scheme.onSurfaceVariant;
    final icon = Icon(item.icon, size: 18, color: color);
    return Padding(
      padding: EdgeInsets.only(bottom: Space.xs, left: expanded ? Space.sm : 6, right: expanded ? Space.sm : 6),
      child: Tooltip(
        message: item.label,
        child: Semantics(
          button: true,
          selected: item.selected,
          label: item.label,
          excludeSemantics: true,
          child: Material(
            color: item.selected ? palette.navigationSelection : Colors.transparent,
            borderRadius: BorderRadius.circular(Radii.control),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: item.onTap,
              hoverColor: scheme.onSurface.withValues(alpha: .06),
              child: SizedBox(
                width: double.infinity,
                height: expanded ? WorkspaceSize.navigationItem : WorkspaceSize.railItem,
                child: expanded
                    ? Padding(
                        padding: const EdgeInsets.symmetric(horizontal: Space.md),
                        child: Row(
                          children: [
                            icon,
                            const SizedBox(width: Space.md),
                            Expanded(
                              child: Text(
                                item.label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: color,
                                  fontWeight: item.selected ? FontWeight.w600 : FontWeight.w400,
                                ),
                              ),
                            ),
                          ],
                        ),
                      )
                    : Center(child: icon),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The navigation column, its divider and the page. While expanded, the divider resizes the column the way the dock
/// panel resizes: a guide while dragging, committed on release; double-click restores the default; arrow keys and
/// semantic increase/decrease step it.
class NavigationFrame extends StatefulWidget {
  const NavigationFrame({
    super.key,
    required this.navigation,
    required this.child,
    required this.expanded,
    required this.width,
    required this.onResize,
    required this.resizeLabel,
  });

  final Widget navigation, child;
  final bool expanded;
  final double width;
  final ValueChanged<double> onResize;
  final String resizeLabel;

  static double clampWidth(double width) =>
      width.clamp(WorkspaceSize.navigationMin, WorkspaceSize.navigationMax).toDouble();

  @override
  State<NavigationFrame> createState() => _NavigationFrameState();
}

class _NavigationFrameState extends State<NavigationFrame> {
  final _focus = FocusNode();
  // Pointer focus keeps the arrow keys working without leaving the divider highlighted after the drag.
  var _pointerFocus = false;
  double? _guide;

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  void _resize(double width) => widget.onResize(NavigationFrame.clampWidth(width));

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final width = widget.width;
    const grab = WorkspaceSize.dividerGrab, step = Space.xl;
    return Stack(
      fit: StackFit.expand,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            widget.navigation,
            const VerticalDivider(width: WorkspaceSize.divider),
            Expanded(child: widget.child),
          ],
        ),
        if (widget.expanded)
          Positioned(
            top: 0,
            bottom: 0,
            left: width + WorkspaceSize.divider / 2 - grab / 2,
            width: grab,
            child: Semantics(
              label: widget.resizeLabel,
              value: '${width.round()}',
              increasedValue: '${NavigationFrame.clampWidth(width + step).round()}',
              decreasedValue: '${NavigationFrame.clampWidth(width - step).round()}',
              onIncrease: () => _resize(width + step),
              onDecrease: () => _resize(width - step),
              child: MouseRegion(
                cursor: SystemMouseCursors.resizeColumn,
                child: Focus(
                  focusNode: _focus,
                  onFocusChange: (focused) => setState(() => _pointerFocus &= focused),
                  onKeyEvent: (_, event) {
                    if (event is! KeyDownEvent) return KeyEventResult.ignored;
                    if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
                      _resize(width + step);
                      return KeyEventResult.handled;
                    }
                    if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
                      _resize(width - step);
                      return KeyEventResult.handled;
                    }
                    return KeyEventResult.ignored;
                  },
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTapDown: (_) {
                      setState(() => _pointerFocus = true);
                      _focus.requestFocus();
                    },
                    onDoubleTap: () => _resize(WorkspaceSize.navigationExpanded),
                    onPanStart: (_) {
                      setState(() => _pointerFocus = true);
                      _focus.requestFocus();
                      setState(() => _guide = width);
                    },
                    onPanUpdate: (d) => setState(() => _guide = NavigationFrame.clampWidth(_guide! + d.delta.dx)),
                    onPanEnd: (_) {
                      final next = _guide!;
                      setState(() => _guide = null);
                      _resize(next);
                    },
                    onPanCancel: () => setState(() => _guide = null),
                    child: _guide != null || (_focus.hasFocus && !_pointerFocus)
                        ? ColoredBox(color: scheme.primary.withValues(alpha: .3))
                        : const SizedBox.expand(),
                  ),
                ),
              ),
            ),
          ),
        if (widget.expanded && _guide != null)
          Positioned(
            top: 0,
            bottom: 0,
            left: _guide,
            width: 2,
            child: IgnorePointer(child: ColoredBox(color: scheme.primary)),
          ),
      ],
    );
  }
}

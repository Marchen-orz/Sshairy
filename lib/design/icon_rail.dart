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
    final motion = context.dependOnInheritedWidgetOfExactType<_NavigationAnimation>()?.progress;
    if (motion == null) return _build(context, expanded ? 1 : 0);
    return AnimatedBuilder(animation: motion, builder: (context, _) => _build(context, motion.value));
  }

  Widget _build(BuildContext context, double t) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: WorkspaceSize.rail + (width - WorkspaceSize.rail) * t,
      child: ColoredBox(
        color: scheme.surfaceContainerLow,
        child: FocusTraversalGroup(
          child: Column(
            children: [
              SizedBox(
                height: WorkspaceSize.titleBar + (WorkspaceSize.navigationHeader - WorkspaceSize.titleBar) * t,
                child: ClipRect(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Opacity(
                        opacity: 1 - t,
                        child: RepaintBoundary(child: header),
                      ),
                      Opacity(
                        opacity: t,
                        child: OverflowBox(
                          minWidth: width,
                          maxWidth: width,
                          child: RepaintBoundary(child: expandedHeader),
                        ),
                      ),
                    ],
                  ),
                ),
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
                            for (final item in group) _RailButton(item, progress: t, labelWidth: width - 72),
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
                progress: t,
                labelWidth: width - 72,
              ),
              for (final item in bottom) _RailButton(item, progress: t, labelWidth: width - 72),
              const SizedBox(height: Space.sm),
            ],
          ),
        ),
      ),
    );
  }
}

class _RailButton extends StatelessWidget {
  const _RailButton(this.item, {required this.progress, required this.labelWidth});

  final RailItem item;
  final double progress, labelWidth;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final palette = BrandPalette.fromTheme(theme);
    final color = item.selected ? palette.onNavigationSelection : scheme.onSurfaceVariant;
    final icon = Icon(item.icon, size: 18, color: color);
    return Padding(
      padding: EdgeInsets.only(bottom: Space.xs, left: 6 + 2 * progress, right: 6 + 2 * progress),
      child: Tooltip(
        message: item.label,
        child: Semantics(
          button: true,
          selected: item.selected,
          label: item.label,
          excludeSemantics: true,
          child: TweenAnimationBuilder<Color?>(
            tween: ColorTween(
              end: item.selected ? palette.navigationSelection : palette.navigationSelection.withAlpha(0),
            ),
            duration: Motion.of(context, Motion.normal),
            curve: Motion.move,
            builder: (context, color, child) => Material(
              color: color,
              borderRadius: BorderRadius.circular(Radii.control),
              clipBehavior: Clip.antiAlias,
              child: child,
            ),
            child: InkWell(
              onTap: item.onTap,
              hoverColor: scheme.onSurface.withValues(alpha: .06),
              child: SizedBox(
                width: double.infinity,
                height: WorkspaceSize.railItem + (WorkspaceSize.navigationItem - WorkspaceSize.railItem) * progress,
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: 9 + 3 * progress),
                  child: Row(
                    children: [
                      icon,
                      SizedBox(width: Space.md * progress),
                      Expanded(
                        child: ClipRect(
                          child: OverflowBox(
                            alignment: Alignment.centerLeft,
                            minWidth: labelWidth,
                            maxWidth: labelWidth,
                            child: Opacity(
                              opacity: progress,
                              child: Text(
                                item.label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodyMedium?.copyWith(color: color, fontWeight: FontWeight.w500),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
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

class _NavigationAnimation extends InheritedWidget {
  const _NavigationAnimation({required this.progress, required super.child});

  final Animation<double> progress;

  @override
  bool updateShouldNotify(_NavigationAnimation old) => progress != old.progress;
}

class _NavigationFrameState extends State<NavigationFrame> with SingleTickerProviderStateMixin, PanelPresence {
  final _focus = FocusNode();
  // Pointer focus keeps the arrow keys working without leaving the divider highlighted after the drag.
  var _pointerFocus = false;
  double? _guide;

  @override
  bool get initiallyOpen => widget.expanded;

  @override
  void didUpdateWidget(NavigationFrame old) {
    super.didUpdateWidget(old);
    if (widget.expanded != old.expanded) showPanel(widget.expanded);
    if (!widget.expanded) _guide = null;
  }

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
        PanelViewport(
          progress: panelProgress,
          closedExtent: WorkspaceSize.rail + WorkspaceSize.divider,
          extent: width + WorkspaceSize.divider,
          from: AxisDirection.left,
          child: widget.child,
        ),
        AnimatedBuilder(
          animation: panelProgress,
          child: _NavigationAnimation(progress: panelProgress, child: widget.navigation),
          builder: (context, child) => Positioned(
            top: 0,
            bottom: 0,
            left: 0,
            width: WorkspaceSize.rail + (width - WorkspaceSize.rail) * panelProgress.value + WorkspaceSize.divider,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: child!),
                const VerticalDivider(width: WorkspaceSize.divider),
              ],
            ),
          ),
        ),
        if (widget.expanded && settled)
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

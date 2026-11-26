import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

/// How much the interface animates (docs/UI.md §2). The app setting is published by [MotionScope].
///
/// [light] keeps only overlays such as menus, dropdowns, pickers and dialogs; layout and in-place
/// changes switch at once. [off] makes even overlays appear and disappear at once.
enum MotionLevel { off, light, full }

class MotionScope extends InheritedWidget {
  const MotionScope({super.key, required this.level, required super.child});

  final MotionLevel level;

  @override
  bool updateShouldNotify(MotionScope oldWidget) => level != oldWidget.level;
}

/// Motion tokens from docs/UI.md §2.
///
/// Transitions fade and shift without scaling text. Profile measurements over a full terminal show repeated
/// expensive raster frames on Impeller; a repaint boundary alone does not avoid that work.
abstract final class Motion {
  static const quick = Duration(milliseconds: 120), normal = Duration(milliseconds: 180);
  static const panel = Duration(milliseconds: 220), page = Duration(milliseconds: 200);

  /// What arrives decelerates into place; what leaves starts at once and accelerates away. A curve played in reverse
  /// is mirrored in time, so leaving with [enter] would hang still before it moves.
  static const enter = Curves.easeOutCubic, exit = Curves.easeInCubic;

  /// Something already on screen moving or resizing.
  static const move = Curves.easeInOutCubic;

  /// The app's choice, lowered to [MotionLevel.light] when the system asks for less motion. The system
  /// request can only remove motion, never add it back.
  static MotionLevel levelOf(BuildContext context) {
    final chosen = context.dependOnInheritedWidgetOfExactType<MotionScope>()?.level ?? MotionLevel.full;
    return chosen == MotionLevel.off || !reduced(context) ? chosen : MotionLevel.light;
  }

  /// The system's own request, separate from the app's setting.
  static bool reduced(BuildContext context) => MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  /// Layout and in-place changes animate only at [MotionLevel.full].
  static bool layout(BuildContext context) => levelOf(context) == MotionLevel.full;

  /// [duration] for layout and in-place changes, or none when only [MotionLevel.full] animates.
  static Duration of(BuildContext context, Duration duration) => layout(context) ? duration : Duration.zero;

  /// [duration] for overlays, which [MotionLevel.light] keeps; [MotionLevel.off] shows them at once.
  static Duration overlay(BuildContext context, Duration duration) =>
      levelOf(context) == MotionLevel.off ? Duration.zero : duration;

  /// [parent] eased in with [enter] and out with [exit].
  static CurvedAnimation curve(Animation<double> parent) =>
      CurvedAnimation(parent: parent, curve: enter, reverseCurve: exit);

  /// [animation]'s value through [enter] while it runs forward and [exit] while it runs back, without registering a
  /// listener of its own.
  static double eased(Animation<double> animation) =>
      animation.status == AnimationStatus.reverse ? exit.transform(animation.value) : enter.transform(animation.value);
}

/// Finite transitions in progress. [MotionSnapshot] avoids repeatedly drawing a full terminal's glyphs while
/// unrelated interface elements move.
final motionActivity = MotionActivity._();

class MotionActivity extends ChangeNotifier {
  MotionActivity._();

  var _count = 0;

  bool get running => _count > 0;

  void _begin() {
    if (_count++ == 0) notifyListeners();
  }

  void _end() {
    if (--_count == 0) notifyListeners();
  }
}

/// Reports one animation to [motionActivity] while it runs.
class MotionTracker {
  var _on = false;

  void status(AnimationStatus status) => _set(status.isAnimating);

  void _set(bool on) {
    if (on == _on) return;
    _on = on;
    on ? motionActivity._begin() : motionActivity._end();
  }

  void dispose() => _set(false);
}

/// Shows [child] as a snapshot while [motionActivity] runs, and live otherwise. Updates during a transition appear
/// when it ends.
class MotionSnapshot extends StatefulWidget {
  const MotionSnapshot({super.key, required this.child, this.freezeLayout = false});

  final Widget child;

  /// Keep a terminal's character grid fixed while its viewport moves, then resize it once.
  final bool freezeLayout;

  @override
  State<MotionSnapshot> createState() => _MotionSnapshotState();
}

class _MotionSnapshotState extends State<MotionSnapshot> {
  final _controller = SnapshotController(allowSnapshotting: motionActivity.running);

  var _interacting = false;

  void _sync() {
    if (!motionActivity.running) _interacting = false;
    _controller.allowSnapshotting = motionActivity.running && !_interacting;
  }

  void _resume() {
    if (!_controller.allowSnapshotting) return;
    _interacting = true;
    _controller.allowSnapshotting = false;
  }

  bool _key(KeyEvent _) {
    // A shortcut handled by another panel must not unfreeze the terminal underneath its closing animation.
    var inside = false;
    FocusManager.instance.primaryFocus?.context?.visitAncestorElements((element) {
      if (element == context) inside = true;
      return !inside;
    });
    if (inside) _resume();
    return false;
  }

  @override
  void initState() {
    super.initState();
    motionActivity.addListener(_sync);
    HardwareKeyboard.instance.addHandler(_key);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_key);
    motionActivity.removeListener(_sync);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Listener(
    behavior: HitTestBehavior.translucent,
    onPointerDown: (_) => _resume(),
    onPointerSignal: (_) => _resume(),
    onPointerPanZoomStart: (_) => _resume(),
    child: ClipRect(
      child: _SnapshotLayout(
        controller: _controller,
        freeze: widget.freezeLayout,
        child: SnapshotWidget(
          controller: _controller,
          mode: SnapshotMode.permissive,
          autoresize: true,
          child: widget.child,
        ),
      ),
    ),
  );
}

class _SnapshotLayout extends SingleChildRenderObjectWidget {
  const _SnapshotLayout({required this.controller, required this.freeze, required super.child});

  final SnapshotController controller;
  final bool freeze;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderSnapshotLayout(controller, freeze);

  @override
  void updateRenderObject(BuildContext context, _RenderSnapshotLayout renderObject) {
    renderObject.update(controller, freeze);
  }
}

class _RenderSnapshotLayout extends RenderProxyBox {
  _RenderSnapshotLayout(this._controller, this._freeze);

  SnapshotController _controller;
  bool _freeze;
  BoxConstraints? _liveConstraints;
  var _scheduled = false;

  void _changed() {
    // A transition can start inside another page's LayoutBuilder. Notify an unrelated terminal after that layout,
    // rather than trying to dirty a different render subtree while the pipeline is flushing it.
    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      if (_scheduled) return;
      _scheduled = true;
      SchedulerBinding.instance.addPostFrameCallback((_) {
        _scheduled = false;
        if (attached) markNeedsLayout();
      });
    } else {
      markNeedsLayout();
    }
  }

  void update(SnapshotController controller, bool freeze) {
    if (controller == _controller && freeze == _freeze) return;
    if (attached) _controller.removeListener(_changed);
    _controller = controller;
    _freeze = freeze;
    if (attached) _controller.addListener(_changed);
    markNeedsLayout();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _controller.addListener(_changed);
  }

  @override
  void detach() {
    _controller.removeListener(_changed);
    super.detach();
  }

  @override
  void performLayout() {
    if (!_freeze || !_controller.allowSnapshotting || _liveConstraints == null) _liveConstraints = constraints;
    child!.layout(_liveConstraints!, parentUsesSize: true);
    size = constraints.constrain(child!.size);
  }

  /// While the frozen content outgrows (or no longer fills) the box, keep its bottom edge at the box's bottom.
  /// A terminal's view is anchored at its last line, so the lines on screen stay put as the panel takes space
  /// instead of moving up by the whole resize at the end of the transition.
  double _bottomShift(RenderBox child) =>
      _freeze && _controller.allowSnapshotting ? size.height - child.size.height : 0;

  @override
  void paint(PaintingContext context, Offset offset) {
    final child = this.child;
    if (child == null) return;
    context.paintChild(child, offset + Offset(0, _bottomShift(child)));
  }

  @override
  void applyPaintTransform(RenderObject child, Matrix4 transform) {
    transform.translateByDouble(0.0, _bottomShift(child as RenderBox), 0.0, 1.0);
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    final child = this.child;
    if (child == null) return false;
    return child.hitTest(result, position: position - Offset(0, _bottomShift(child)));
  }
}

/// A popup's optional fade and shift (a fade only when motion is reduced). It arrives on its own
/// clock, started once the popup's first frame is built: a route's clock starts with the tap, so a costly first
/// frame would otherwise skip half the entrance.
Widget popupTransition(
  BuildContext context,
  Animation<double> animation,
  Widget child, {
  Offset offset = Offset.zero,
  Duration duration = Motion.panel,
  bool fade = true,
}) {
  final level = Motion.levelOf(context);
  if (level == MotionLevel.off) return child;
  // Light motion keeps overlays but drops their shift, leaving a plain fade.
  return _PopupMotion(
    route: animation,
    offset: level == MotionLevel.full ? offset : Offset.zero,
    duration: duration,
    fade: fade || level == MotionLevel.light,
    child: child,
  );
}

class _PopupMotion extends StatefulWidget {
  const _PopupMotion({
    required this.route,
    required this.offset,
    required this.duration,
    required this.fade,
    required this.child,
  });

  final bool fade;
  final Animation<double> route;
  final Offset offset;
  final Duration duration;
  final Widget child;

  @override
  State<_PopupMotion> createState() => _PopupMotionState();
}

class _PopupMotionState extends State<_PopupMotion> with SingleTickerProviderStateMixin {
  late final _enter = AnimationController(vsync: this);
  late final _fade = Motion.curve(_enter);
  final _tracker = MotionTracker();
  var _started = false;

  @override
  void initState() {
    super.initState();
    _enter.addStatusListener(_track);
    widget.route.addStatusListener(_routeChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _enter.duration = widget.duration;
    _track(widget.route.status);
    if (widget.route.isCompleted) {
      _enter.value = 1;
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || widget.route.status != AnimationStatus.forward) return;
        _enter.forward();
      });
    }
  }

  @override
  void didUpdateWidget(_PopupMotion old) {
    super.didUpdateWidget(old);
    if (widget.route != old.route) {
      old.route.removeStatusListener(_routeChanged);
      widget.route.addStatusListener(_routeChanged);
    }
  }

  void _track(AnimationStatus _) => _tracker._set(_enter.isAnimating || widget.route.status.isAnimating);

  void _routeChanged(AnimationStatus status) {
    if (status == AnimationStatus.reverse) _enter.reverse();
    if (status == AnimationStatus.forward && _started) _enter.forward();
    _track(status);
  }

  @override
  void dispose() {
    widget.route.removeStatusListener(_routeChanged);
    _tracker.dispose();
    _fade.dispose();
    _enter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Keep scrollbars and async content live; a cached first frame can reveal a different width at the end.
    final child = RepaintBoundary(child: widget.child);
    if (!widget.fade && widget.offset == Offset.zero) return child;
    return AnimatedBuilder(
      animation: _fade,
      child: child,
      builder: (context, child) => _Shifted(
        t: _fade.value,
        offset: widget.offset,
        fade: widget.fade,
        // Paint the content before starting the clock; an exactly transparent layer would skip that paint.
        paintAtZero: _enter.value == 0 && widget.route.status == AnimationStatus.forward,
        child: child!,
      ),
    );
  }
}

/// [child] at opacity [t], moved by [offset] scaled by what is left of the way.
class _Shifted extends StatelessWidget {
  const _Shifted({
    required this.t,
    required this.offset,
    required this.child,
    this.paintAtZero = false,
    this.fade = true,
  });

  final double t;
  final Offset offset;
  final Widget child;
  final bool paintAtZero, fade;

  @override
  Widget build(BuildContext context) {
    final shifted = Transform.translate(offset: offset * (1 - t), child: child);
    return fade ? Opacity(opacity: paintAtZero ? 1 / 255 : t.clamp(0.0, 1.0), child: shifted) : shifted;
  }
}

/// Plays once when [child] first appears: it fades in while moving from [offset]. Only [play] as first built counts,
/// so a row rebuilt by scrolling can stay still.
class Entrance extends StatefulWidget {
  const Entrance({
    super.key,
    required this.child,
    this.offset = const Offset(0, 6),
    this.duration = Motion.normal,
    this.play = true,
  });

  final Widget child;
  final Offset offset;
  final Duration duration;
  final bool play;

  @override
  State<Entrance> createState() => _EntranceState();
}

class _EntranceState extends State<Entrance> with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(vsync: this, duration: widget.duration);
  final _tracker = MotionTracker();
  var _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (!widget.play || !Motion.layout(context)) {
      _controller.value = 1;
    } else {
      _controller
        ..addStatusListener(_tracker.status)
        ..forward();
    }
  }

  @override
  void dispose() {
    _tracker.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _controller,
    child: RepaintBoundary(child: widget.child),
    builder: (context, child) => _Shifted(t: Motion.eased(_controller), offset: widget.offset, child: child!),
  );
}

/// Shows [child] while [open], growing it along [axis] and fading it in; closing reverses that. The child is only
/// built while open or closing. With [appear] it also grows in when first shown open.
class Reveal extends StatefulWidget {
  const Reveal({
    super.key,
    required this.open,
    required this.child,
    this.axis = Axis.vertical,
    this.appear = false,
    this.duration = Motion.normal,
  });

  final bool open, appear;
  final Widget child;
  final Axis axis;
  final Duration duration;

  @override
  State<Reveal> createState() => _RevealState();
}

class _RevealState extends State<Reveal> with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: widget.duration,
    value: widget.open && !widget.appear ? 1 : 0,
  )..addStatusListener(_status);
  late final _size = CurvedAnimation(parent: _controller, curve: Motion.move);
  late final _fade = Motion.curve(_controller);
  final _tracker = MotionTracker();
  var _started = false;

  void _status(AnimationStatus status) {
    _tracker.status(status);
    if (status.isDismissed && mounted) setState(() {});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (widget.open && widget.appear) _run();
  }

  @override
  void didUpdateWidget(Reveal old) {
    super.didUpdateWidget(old);
    if (widget.open != old.open) _run();
  }

  void _run() {
    _controller.duration = Motion.of(context, widget.duration);
    widget.open ? _controller.forward() : _controller.reverse();
  }

  @override
  void dispose() {
    _tracker.dispose();
    _size.dispose();
    _fade.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.open && _controller.isDismissed) return const SizedBox.shrink();
    return SizeTransition(
      sizeFactor: _size,
      axis: widget.axis,
      alignment: AlignmentDirectional.topStart,
      child: FadeTransition(opacity: _fade, child: widget.child),
    );
  }
}

/// A page that stays alive while another one shows (UI §2). It must be painted after the page it replaces: with
/// [animate] it fades in over that one, on top of [backdrop], and the replaced page stays as it is underneath until
/// the fade ends, so nothing behind them shows through. Without [animate] it switches at once. A hidden page skips
/// painting, pointer events and focus.
class PageVisibility extends StatefulWidget {
  const PageVisibility({
    super.key,
    required this.visible,
    required this.child,
    this.animate = true,
    this.appear = false,
    this.backdrop = const SizedBox.shrink(),
  });

  final bool visible, animate, appear;
  final Widget child, backdrop;

  @override
  State<PageVisibility> createState() => _PageVisibilityState();
}

class _PageVisibilityState extends State<PageVisibility> with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: Motion.page,
    value: widget.visible && !widget.appear ? 1 : 0,
  )..addStatusListener(_status);
  // Complementary curves preserve the same blend when two partly transitioned pages swap their paint order.
  late final _fade = CurvedAnimation(parent: _controller, curve: Motion.enter, reverseCurve: Motion.enter.flipped);
  final _tracker = MotionTracker();
  var _started = false;

  void _status(AnimationStatus status) {
    _tracker.status(status);
    if (mounted) setState(() {});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (widget.visible && widget.appear) {
      if (!widget.animate || !Motion.layout(context)) {
        _controller.value = 1;
      } else {
        _controller.duration = Motion.of(context, Motion.page);
        _controller.forward();
      }
    }
  }

  @override
  void didUpdateWidget(PageVisibility old) {
    super.didUpdateWidget(old);
    if (widget.visible == old.visible) return;
    if (!widget.animate || !Motion.layout(context)) {
      _controller.value = widget.visible ? 1 : 0;
    } else if (widget.visible) {
      _controller.duration = Motion.of(context, Motion.page);
      _controller.forward();
    } else {
      // The page coming in fades in over this one, which leaves only once that is done.
      _controller.duration = Motion.of(context, Motion.page);
      _controller.reverse();
    }
  }

  @override
  void dispose() {
    _tracker.dispose();
    _fade.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final visible = widget.visible;
    final entering = _controller.status == AnimationStatus.forward;
    return Visibility.maintain(
      visible: visible || !_controller.isDismissed,
      child: IgnorePointer(
        ignoring: !visible,
        child: ExcludeFocus(
          excluding: !visible,
          child: AnimatedBuilder(
            animation: _fade,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (entering) KeyedSubtree(key: const ValueKey('backdrop'), child: widget.backdrop),
                KeyedSubtree(
                  key: const ValueKey('page'),
                  child: RepaintBoundary(child: widget.child),
                ),
              ],
            ),
            builder: (context, child) => Opacity(opacity: entering ? _fade.value : 1, child: child),
          ),
        ),
      ),
    );
  }
}

/// How far a docked panel has come in from its edge, for [DockPanel] and the monitor's [SidebarFrame]. Running, it
/// counts as a transition; it rebuilds its owner when it starts or stops so the owner can lay out the docked or the
/// sliding form.
mixin PanelPresence<T extends StatefulWidget> on State<T>, SingleTickerProviderStateMixin<T> {
  late final presence = AnimationController(vsync: this, duration: Motion.panel, value: initiallyOpen ? 1 : 0)
    ..addStatusListener(_presenceStatus);
  late final panelProgress = Motion.curve(presence);
  final _presenceTracker = MotionTracker();

  bool get initiallyOpen;

  /// The panel lies in its docked place and the main view makes room for it.
  bool get settled => presence.isCompleted;

  /// Somewhere on screen, settled or sliding.
  bool get shown => !presence.isDismissed;

  void _presenceStatus(AnimationStatus status) {
    _presenceTracker.status(status);
    if (mounted) setState(() {});
  }

  void showPanel(bool open) {
    presence.duration = Motion.of(context, Motion.panel);
    open ? presence.forward() : presence.reverse();
  }

  @override
  void dispose() {
    _presenceTracker.dispose();
    panelProgress.dispose();
    presence.dispose();
    super.dispose();
  }
}

/// The main area's boundary follows the adjacent panel. Ordinary interface content lays out continuously;
/// terminals use [MotionSnapshot.freezeLayout] to commit their character-grid resize only once.
class PanelViewport extends StatelessWidget {
  const PanelViewport({
    super.key,
    required this.progress,
    required this.extent,
    required this.from,
    required this.child,
    this.closedExtent = 0,
  });

  final Animation<double> progress;
  final double extent, closedExtent;
  final AxisDirection from;
  final Widget child;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: progress,
    child: RepaintBoundary(child: child),
    builder: (context, child) {
      final room = closedExtent + (extent - closedExtent) * progress.value;
      return Stack(
        fit: StackFit.expand,
        children: [
          Positioned(
            left: from == AxisDirection.left ? room : 0,
            right: from == AxisDirection.right ? room : 0,
            top: from == AxisDirection.up ? room : 0,
            bottom: from == AxisDirection.down ? room : 0,
            child: ClipRect(child: child),
          ),
        ],
      );
    },
  );
}

/// A docked panel sliding in from [from] by its whole size and out again. [presence] is already eased. Solid, so it
/// needs no fade.
class PanelSlide extends StatelessWidget {
  const PanelSlide({super.key, required this.presence, required this.from, required this.child});

  final Animation<double> presence;
  final AxisDirection from;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final direction = switch (from) {
      AxisDirection.left => const Offset(-1, 0),
      AxisDirection.right => const Offset(1, 0),
      AxisDirection.up => const Offset(0, -1),
      AxisDirection.down => const Offset(0, 1),
    };
    return ClipRect(
      child: AnimatedBuilder(
        animation: presence,
        child: RepaintBoundary(child: child),
        // Always the same widgets, so the panel keeps its state when the slide ends.
        builder: (context, child) => FractionalTranslation(translation: direction * (1 - presence.value), child: child),
      ),
    );
  }
}

/// Shows [sliver] while [open], growing its scroll extent and fading it in; closing reverses that while keeping
/// sliver virtualization intact. The sliver is only built while open or closing.
class SliverReveal extends StatefulWidget {
  const SliverReveal({super.key, required this.open, required this.sliver, this.duration = Motion.normal});

  final bool open;
  final Widget sliver;
  final Duration duration;

  @override
  State<SliverReveal> createState() => _SliverRevealState();
}

class _SliverRevealState extends State<SliverReveal> with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(vsync: this, duration: widget.duration, value: widget.open ? 1 : 0)
    ..addStatusListener(_status);
  late final _size = CurvedAnimation(parent: _controller, curve: Motion.move);
  late final _fade = Motion.curve(_controller);
  final _tracker = MotionTracker();

  void _status(AnimationStatus status) {
    _tracker.status(status);
    if (status.isDismissed && mounted) setState(() {});
  }

  @override
  void didUpdateWidget(SliverReveal old) {
    super.didUpdateWidget(old);
    if (widget.open != old.open) {
      _controller.duration = Motion.of(context, widget.duration);
      widget.open ? _controller.forward() : _controller.reverse();
    }
  }

  @override
  void dispose() {
    _tracker.dispose();
    _size.dispose();
    _fade.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.open && _controller.isDismissed) {
      return const SliverToBoxAdapter(child: SizedBox.shrink());
    }
    return AnimatedBuilder(
      animation: _controller,
      child: widget.sliver,
      builder: (context, child) => _SliverRevealBox(factor: _size.value, opacity: _fade.value, child: child),
    );
  }
}

class _SliverRevealBox extends SingleChildRenderObjectWidget {
  const _SliverRevealBox({required this.factor, required this.opacity, super.child});

  final double factor;
  final double opacity;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderSliverReveal(factor: factor, opacity: opacity);

  @override
  void updateRenderObject(BuildContext context, _RenderSliverReveal renderObject) {
    renderObject
      ..factor = factor
      ..opacity = opacity;
  }
}

class _RenderSliverReveal extends RenderProxySliver {
  _RenderSliverReveal({required double factor, required double opacity})
    : _factor = factor.clamp(0.0, 1.0),
      _opacity = opacity.clamp(0.0, 1.0);

  double _factor;
  double _opacity;
  final _clipLayer = LayerHandle<ClipRectLayer>();
  final _opacityLayer = LayerHandle<OpacityLayer>();

  set factor(double value) {
    final clamped = value.clamp(0.0, 1.0);
    if (_factor == clamped) return;
    _factor = clamped;
    markNeedsLayout();
  }

  set opacity(double value) {
    final clamped = value.clamp(0.0, 1.0);
    if (_opacity == clamped) return;
    final wasCompositing = _opacity > 0 && _opacity < 1;
    _opacity = clamped;
    final isCompositing = _opacity > 0 && _opacity < 1;
    if (wasCompositing != isCompositing) markNeedsCompositingBitsUpdate();
    markNeedsPaint();
  }

  @override
  bool get alwaysNeedsCompositing => child != null && _opacity > 0 && _opacity < 1;

  @override
  void performLayout() {
    assert(child != null);
    child!.layout(constraints, parentUsesSize: true);
    final g = child!.geometry!;
    if (_factor <= 0) {
      geometry = SliverGeometry.zero;
      return;
    }
    if (_factor >= 1) {
      geometry = g;
      return;
    }
    final scrollExtent = g.scrollExtent * _factor;
    final maxPaintExtent = g.maxPaintExtent * _factor;
    final rawPaint = calculatePaintOffset(constraints, from: 0, to: scrollExtent);
    final paintExtent = rawPaint.clamp(0.0, math.min(g.paintExtent, maxPaintExtent)).toDouble();
    final layoutExtent = paintExtent.clamp(0.0, g.layoutExtent).toDouble();
    final cacheExtent = calculateCacheOffset(
      constraints,
      from: 0,
      to: scrollExtent,
    ).clamp(0.0, g.cacheExtent).toDouble();
    geometry = SliverGeometry(
      scrollExtent: scrollExtent,
      paintExtent: paintExtent,
      layoutExtent: layoutExtent,
      maxPaintExtent: math.max(maxPaintExtent, paintExtent),
      cacheExtent: cacheExtent,
      hitTestExtent: 0,
      hasVisualOverflow: paintExtent < g.paintExtent || g.hasVisualOverflow,
    );
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final child = this.child;
    final g = geometry;
    if (child == null || g == null || !g.visible || _opacity <= 0) {
      _clipLayer.layer = null;
      _opacityLayer.layer = null;
      return;
    }
    final alpha = Color.getAlphaFromOpacity(_opacity);
    if (alpha == 0) {
      _clipLayer.layer = null;
      _opacityLayer.layer = null;
      return;
    }
    void paintInner(PaintingContext context, Offset offset) {
      if (alpha == 255) {
        _opacityLayer.layer = null;
        context.paintChild(child, offset);
      } else {
        _opacityLayer.layer = context.pushOpacity(
          offset,
          alpha,
          (context, offset) => context.paintChild(child, offset),
          oldLayer: _opacityLayer.layer,
        );
      }
    }

    if (_factor >= 1) {
      _clipLayer.layer = null;
      paintInner(context, offset);
      return;
    }
    final clipRect = switch (constraints.axis) {
      Axis.vertical => Rect.fromLTWH(0, 0, constraints.crossAxisExtent, g.paintExtent),
      Axis.horizontal => Rect.fromLTWH(0, 0, g.paintExtent, constraints.crossAxisExtent),
    };
    _clipLayer.layer = context.pushClipRect(needsCompositing, offset, clipRect, paintInner, oldLayer: _clipLayer.layer);
  }

  @override
  void dispose() {
    _clipLayer.layer = null;
    _opacityLayer.layer = null;
    super.dispose();
  }
}

/// Fade + subtle shift route transition (UI §2, MOBILE §3.1) that never scales page text, respects all three
/// [MotionLevel] tiers, and tracks [motionActivity] so terminals behind or inside the route stay smooth.
Route<T> appPageRoute<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  Offset slideFrom = const Offset(0.06, 0),
  RouteSettings? settings,
  bool maintainState = true,
  bool fullscreenDialog = false,
}) => AppPageRoute<T>(
  builder: builder,
  level: Motion.levelOf(context),
  slideFrom: slideFrom,
  settings: settings,
  maintainState: maintainState,
  fullscreenDialog: fullscreenDialog,
);

class AppPageRoute<T> extends MaterialPageRoute<T> {
  AppPageRoute({
    required super.builder,
    required this.level,
    this.slideFrom = const Offset(0.06, 0),
    super.settings,
    super.maintainState,
    super.fullscreenDialog,
  });

  final MotionLevel level;
  final Offset slideFrom;

  @override
  Duration get transitionDuration => switch (level) {
    MotionLevel.off => Duration.zero,
    MotionLevel.light => Motion.page,
    MotionLevel.full => Motion.panel,
  };

  @override
  Duration get reverseTransitionDuration => switch (level) {
    MotionLevel.off => Duration.zero,
    MotionLevel.light => Motion.normal,
    MotionLevel.full => Motion.page,
  };

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => _RouteTransition(
    animation: animation,
    secondaryAnimation: secondaryAnimation,
    slideFrom: slideFrom,
    child: child,
  );
}

/// Theme-level fallback matching [AppPageRoute] so any standard [MaterialPageRoute] also avoids scaling text.
class AppPageTransitionsBuilder extends PageTransitionsBuilder {
  const AppPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => _RouteTransition(
    animation: animation,
    secondaryAnimation: secondaryAnimation,
    slideFrom: const Offset(0.06, 0),
    child: child,
  );
}

class _RouteTransition extends StatefulWidget {
  const _RouteTransition({
    required this.animation,
    required this.secondaryAnimation,
    required this.slideFrom,
    required this.child,
  });

  final Animation<double> animation;
  final Animation<double> secondaryAnimation;
  final Offset slideFrom;
  final Widget child;

  @override
  State<_RouteTransition> createState() => _RouteTransitionState();
}

class _RouteTransitionState extends State<_RouteTransition> {
  final _tracker = MotionTracker();

  @override
  void initState() {
    super.initState();
    widget.animation.addStatusListener(_statusChanged);
    widget.secondaryAnimation.addStatusListener(_statusChanged);
    _sync();
  }

  @override
  void didUpdateWidget(_RouteTransition old) {
    super.didUpdateWidget(old);
    if (widget.animation != old.animation) {
      old.animation.removeStatusListener(_statusChanged);
      widget.animation.addStatusListener(_statusChanged);
    }
    if (widget.secondaryAnimation != old.secondaryAnimation) {
      old.secondaryAnimation.removeStatusListener(_statusChanged);
      widget.secondaryAnimation.addStatusListener(_statusChanged);
    }
    _sync();
  }

  void _statusChanged(AnimationStatus _) => _sync();

  void _sync() => _tracker._set(widget.animation.status.isAnimating || widget.secondaryAnimation.status.isAnimating);

  @override
  void dispose() {
    widget.animation.removeStatusListener(_statusChanged);
    widget.secondaryAnimation.removeStatusListener(_statusChanged);
    _tracker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final level = Motion.levelOf(context);
    if (level == MotionLevel.off) return widget.child;
    return AnimatedBuilder(
      animation: Listenable.merge([widget.animation, widget.secondaryAnimation]),
      child: widget.child,
      builder: (context, child) {
        if (widget.animation.isCompleted && widget.secondaryAnimation.isDismissed) return child!;
        final enter = Motion.eased(widget.animation);
        Widget out = child!;
        if (level == MotionLevel.full) {
          final leave = Motion.eased(widget.secondaryAnimation);
          final incoming = widget.slideFrom * (1 - enter);
          final outgoing = widget.slideFrom.dx != 0 ? Offset(-widget.slideFrom.dx * .35 * leave, 0) : Offset.zero;
          final shift = incoming + outgoing;
          if (shift != Offset.zero) {
            out = FractionalTranslation(translation: shift, child: out);
          }
        }
        if (enter < 1) {
          out = Opacity(opacity: enter.clamp(0.0, 1.0), child: out);
        }
        return out;
      },
    );
  }
}

/// Modal bottom sheet with duration/curve matched to [MotionLevel] and [motionActivity] tracking so live terminals
/// behind the sheet stay fluid on mobile and tablet.
Future<T?> showAppBottomSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool isScrollControlled = false,
  bool useSafeArea = true,
  bool showDragHandle = true,
  bool isDismissible = true,
  bool enableDrag = true,
}) {
  final level = Motion.levelOf(context);
  final style = switch (level) {
    MotionLevel.off => AnimationStyle.noAnimation,
    MotionLevel.light => const AnimationStyle(
      duration: Motion.quick,
      reverseDuration: Motion.quick,
      curve: Motion.enter,
      reverseCurve: Motion.exit,
    ),
    MotionLevel.full => const AnimationStyle(
      duration: Motion.panel,
      reverseDuration: Motion.normal,
      curve: Motion.enter,
      reverseCurve: Motion.exit,
    ),
  };
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: isScrollControlled,
    useSafeArea: useSafeArea,
    showDragHandle: showDragHandle,
    isDismissible: isDismissible,
    enableDrag: enableDrag,
    sheetAnimationStyle: style,
    builder: (sheetContext) => _SheetMotionScope(child: Builder(builder: builder)),
  );
}

class _SheetMotionScope extends StatefulWidget {
  const _SheetMotionScope({required this.child});

  final Widget child;

  @override
  State<_SheetMotionScope> createState() => _SheetMotionScopeState();
}

class _SheetMotionScopeState extends State<_SheetMotionScope> {
  final _tracker = MotionTracker();
  Animation<double>? _animation;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = ModalRoute.of(context)?.animation;
    if (next == _animation) return;
    _animation?.removeStatusListener(_tracker.status);
    _animation = next;
    if (next != null) {
      next.addStatusListener(_tracker.status);
      _tracker.status(next.status);
    } else {
      _tracker._set(false);
    }
  }

  @override
  void dispose() {
    _animation?.removeStatusListener(_tracker.status);
    _tracker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

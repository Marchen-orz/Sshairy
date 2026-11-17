import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

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

  static bool reduced(BuildContext context) => MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  /// [duration], or none when the system asks for less motion.
  static Duration of(BuildContext context, Duration duration) => reduced(context) ? Duration.zero : duration;

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
}) => _PopupMotion(
  route: animation,
  offset: Motion.reduced(context) ? Offset.zero : offset,
  duration: duration,
  fade: fade || Motion.reduced(context),
  child: child,
);

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
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _fade,
    // Scrollbar gutters and async form content can settle after the first frame. Keep the popup live so those
    // updates appear during entrance, instead of revealing a different width when a cached first frame is released.
    child: RepaintBoundary(child: widget.child),
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
    if (!widget.play || Motion.reduced(context)) {
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
    this.backdrop = const SizedBox.shrink(),
  });

  final bool visible, animate;
  final Widget child, backdrop;

  @override
  State<PageVisibility> createState() => _PageVisibilityState();
}

class _PageVisibilityState extends State<PageVisibility> with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(vsync: this, duration: Motion.page, value: widget.visible ? 1 : 0)
    ..addStatusListener(_status);
  // Complementary curves preserve the same blend when two partly transitioned pages swap their paint order.
  late final _fade = CurvedAnimation(parent: _controller, curve: Motion.enter, reverseCurve: Motion.enter.flipped);
  final _tracker = MotionTracker();

  void _status(AnimationStatus status) {
    _tracker.status(status);
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(PageVisibility old) {
    super.didUpdateWidget(old);
    if (widget.visible == old.visible) return;
    if (!widget.animate || Motion.reduced(context)) {
      _controller.value = widget.visible ? 1 : 0;
    } else if (widget.visible) {
      _controller.forward();
    } else {
      // The page coming in fades in over this one, which leaves only once that is done.
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

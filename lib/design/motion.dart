import 'package:flutter/material.dart';

/// Motion tokens from docs/UI.md §2.
abstract final class Motion {
  static const quick = Duration(milliseconds: 120), normal = Duration(milliseconds: 180);
  static const panel = Duration(milliseconds: 220), page = Duration(milliseconds: 240);

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
}

/// The fade, and unless motion is reduced the shift and scale, every popup arrives with and leaves with.
Widget popupTransition(
  BuildContext context,
  Animation<double> animation,
  Widget child, {
  Offset offset = Offset.zero,
  double scale = 1,
  Alignment alignment = Alignment.center,
}) {
  final curved = Motion.curve(animation);
  if (Motion.reduced(context)) return FadeTransition(opacity: curved, child: child);
  return FadeTransition(
    opacity: curved,
    child: AnimatedBuilder(
      animation: curved,
      child: child,
      builder: (context, child) {
        final t = 1 - curved.value;
        return Transform.translate(
          offset: offset * t,
          child: scale == 1 ? child : Transform.scale(scale: 1 - (1 - scale) * t, alignment: alignment, child: child),
        );
      },
    ),
  );
}

/// Plays once when [child] first appears: it fades in while moving from [offset] and growing from [scale]. Only
/// [play] as first built counts, so a row rebuilt by scrolling can stay still.
class Entrance extends StatefulWidget {
  const Entrance({
    super.key,
    required this.child,
    this.offset = const Offset(0, 6),
    this.scale = 1,
    this.alignment = Alignment.center,
    this.duration = Motion.normal,
    this.play = true,
  });

  final Widget child;
  final Offset offset;
  final double scale;
  final Alignment alignment;
  final Duration duration;
  final bool play;

  @override
  State<Entrance> createState() => _EntranceState();
}

class _EntranceState extends State<Entrance> with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(vsync: this, duration: widget.duration);
  var _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (!widget.play || Motion.reduced(context)) {
      _controller.value = 1;
    } else {
      _controller.forward();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => popupTransition(
    context,
    _controller,
    widget.child,
    offset: widget.offset,
    scale: widget.scale,
    alignment: widget.alignment,
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
  var _started = false;

  void _status(AnimationStatus status) {
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

/// A page that stays alive while another one shows (UI §2). The outgoing page fades out first and the incoming one
/// fades in and settles from a slight zoom. A hidden page skips painting, pointer events and focus.
class PageVisibility extends StatefulWidget {
  const PageVisibility({super.key, required this.visible, required this.child});

  final bool visible;
  final Widget child;

  @override
  State<PageVisibility> createState() => _PageVisibilityState();
}

class _PageVisibilityState extends State<PageVisibility> with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(vsync: this, duration: Motion.page, value: widget.visible ? 1 : 0)
    ..addStatusListener(_status);
  late final _opacity = CurvedAnimation(
    parent: _controller,
    curve: const Interval(.3, 1, curve: Motion.enter),
    reverseCurve: const Interval(.55, 1, curve: Motion.exit),
  );

  void _status(AnimationStatus status) {
    if (status.isDismissed && mounted) setState(() {});
  }

  @override
  void didUpdateWidget(PageVisibility old) {
    super.didUpdateWidget(old);
    if (widget.visible == old.visible) return;
    if (Motion.reduced(context)) {
      _controller.value = widget.visible ? 1 : 0;
    } else {
      widget.visible ? _controller.forward() : _controller.reverse();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final visible = widget.visible;
    return Visibility.maintain(
      visible: visible || !_controller.isDismissed,
      child: IgnorePointer(
        ignoring: !visible,
        child: ExcludeFocus(
          excluding: !visible,
          child: FadeTransition(
            opacity: _opacity,
            child: AnimatedBuilder(
              animation: _opacity,
              child: widget.child,
              // Only the incoming page zooms; the outgoing one just fades. The transform stays in the tree either
              // way, so the page keeps its state.
              builder: (context, child) => Transform.scale(
                scale: _controller.status.isForwardOrCompleted ? .985 + .015 * _opacity.value : 1,
                child: child,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A docked panel's content arriving from its edge and leaving toward it: a short slide and a fade. A covering panel
/// ([full]) slides its whole extent instead.
class EdgeSlide extends StatelessWidget {
  const EdgeSlide({super.key, required this.animation, required this.from, required this.child, this.full = false});

  final Animation<double> animation;
  final AxisDirection from;
  final bool full;
  final Widget child;

  static const _distance = 24.0;

  @override
  Widget build(BuildContext context) {
    final curved = Motion.curve(animation);
    final direction = switch (from) {
      AxisDirection.left => const Offset(-1, 0),
      AxisDirection.right => const Offset(1, 0),
      AxisDirection.up => const Offset(0, -1),
      AxisDirection.down => const Offset(0, 1),
    };
    final faded = FadeTransition(opacity: curved, child: child);
    if (Motion.reduced(context)) return faded;
    return AnimatedBuilder(
      animation: curved,
      child: full ? child : faded,
      builder: (context, child) {
        final t = 1 - curved.value;
        return full
            ? FractionalTranslation(translation: direction * t, child: child)
            : Transform.translate(offset: direction * (_distance * t), child: child);
      },
    );
  }
}

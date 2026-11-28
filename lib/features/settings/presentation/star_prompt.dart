import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../design/brand.dart';
import '../../../design/popup.dart';
import '../../../design/theme.dart';
import '../../../l10n/app_localizations.dart';
import '../application/star_prompt.dart';

const defaultStarTickInterval = Duration(minutes: 1);

/// Tracks active foreground usage and floats a non-blocking GitHub Star reminder card once the
/// schedule is met (docs/UI.md §5). Disabled during tests and probes to keep frames untouched.
class StarPromptHost extends ConsumerStatefulWidget {
  const StarPromptHost({
    super.key,
    required this.child,
    this.enabled = true,
    this.tickInterval = defaultStarTickInterval,
  });

  final Widget child;
  final bool enabled;
  final Duration tickInterval;

  @override
  ConsumerState<StarPromptHost> createState() => _StarPromptHostState();
}

class _StarPromptHostState extends ConsumerState<StarPromptHost> with WidgetsBindingObserver {
  Timer? _timer;
  StarPromptNotifier? _notifier;
  late var _resumed = _isActive(WidgetsBinding.instance.lifecycleState);

  static bool _isActive(AppLifecycleState? state) => state == null || state == AppLifecycleState.resumed;

  @override
  void initState() {
    super.initState();
    if (!widget.enabled) return;
    _notifier = ref.read(starPromptProvider.notifier);
    WidgetsBinding.instance.addObserver(this);
    _syncTimer();
  }

  @override
  void didUpdateWidget(StarPromptHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.enabled != oldWidget.enabled) {
      if (widget.enabled) {
        _notifier = ref.read(starPromptProvider.notifier);
        WidgetsBinding.instance.addObserver(this);
        _resumed = _isActive(WidgetsBinding.instance.lifecycleState);
        _syncTimer();
      } else {
        _timer?.cancel();
        _timer = null;
        WidgetsBinding.instance.removeObserver(this);
      }
    } else if (widget.enabled && widget.tickInterval != oldWidget.tickInterval) {
      _timer?.cancel();
      _timer = null;
      _syncTimer();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!widget.enabled) return;
    final active = _isActive(state);
    if (active == _resumed) return;
    _resumed = active;
    if (active) {
      _syncTimer();
    } else {
      _timer?.cancel();
      _timer = null;
      unawaited(_notifier?.flush());
    }
  }

  void _syncTimer() {
    if (!widget.enabled || !_resumed || _timer != null) return;
    _timer = Timer.periodic(widget.tickInterval, (_) => _onTick());
  }

  void _onTick() {
    if (!mounted || !widget.enabled || !_resumed) return;
    final canShow = ModalRoute.of(context)?.isCurrent ?? true;
    final notifier = ref.read(starPromptProvider.notifier);
    _notifier = notifier;
    notifier.tick(widget.tickInterval, canShow: canShow);
  }

  @override
  void dispose() {
    _timer?.cancel();
    if (widget.enabled) {
      WidgetsBinding.instance.removeObserver(this);
      unawaited(_notifier?.flush());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        const _StarPromptOverlay(),
      ],
    );
  }
}

class _StarPromptOverlay extends ConsumerStatefulWidget {
  const _StarPromptOverlay();

  @override
  ConsumerState<_StarPromptOverlay> createState() => _StarPromptOverlayState();
}

class _StarPromptOverlayState extends ConsumerState<_StarPromptOverlay> with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: Motion.panel,
    value: ref.read(starPromptProvider).visible ? 1 : 0,
  )..addStatusListener(_status);
  final _tracker = MotionTracker();

  void _status(AnimationStatus status) {
    _tracker.status(status);
    if (status.isDismissed && mounted) setState(() {});
  }

  void _animate(bool visible) {
    final duration = Motion.overlay(context, Motion.panel);
    _controller.duration = duration;
    _controller.reverseDuration = duration == Duration.zero ? Duration.zero : Motion.normal;
    if (visible) {
      _controller.forward();
    } else {
      _controller.reverse();
    }
  }

  @override
  void dispose() {
    _tracker.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<bool>(starPromptProvider.select((s) => s.visible), (previous, next) {
      if (previous != next) _animate(next);
    });
    final visible = ref.watch(starPromptProvider.select((s) => s.visible));
    if (!visible && _controller.isDismissed) return const SizedBox.shrink();

    final size = MediaQuery.sizeOf(context);
    final compact = size.width < 600;
    final bottomPadding = MediaQuery.paddingOf(context).bottom;
    final level = Motion.levelOf(context);
    final offset = level == MotionLevel.full ? const Offset(0, 10) : Offset.zero;
    final notifier = ref.read(starPromptProvider.notifier);

    final card = ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 360),
      child: _StarPromptCard(
        onStar: () => unawaited(notifier.star()),
        onLater: notifier.later,
        onNever: () => unawaited(notifier.neverRemind()),
      ),
    );

    final animated = level == MotionLevel.off
        ? card
        : AnimatedBuilder(
            animation: _controller,
            child: RepaintBoundary(child: card),
            builder: (context, child) {
              final t = Motion.eased(_controller).clamp(0.0, 1.0);
              return Opacity(
                opacity: t,
                child: Transform.translate(offset: offset * (1 - t), child: child),
              );
            },
          );

    if (compact) {
      return Positioned(
        left: Space.md,
        right: Space.md,
        bottom: bottomPadding + 72,
        child: IgnorePointer(
          ignoring: !visible,
          child: Align(alignment: Alignment.bottomCenter, child: animated),
        ),
      );
    }
    return Positioned(
      right: Space.lg,
      bottom: Space.lg,
      child: IgnorePointer(ignoring: !visible, child: animated),
    );
  }
}

class _StarPromptCard extends StatelessWidget {
  const _StarPromptCard({required this.onStar, required this.onLater, required this.onNever});

  final VoidCallback onStar;
  final VoidCallback onLater;
  final VoidCallback onNever;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final compactButton = TextButton.styleFrom(
      padding: const EdgeInsets.symmetric(horizontal: Space.sm, vertical: Space.xs),
      minimumSize: const Size(0, 32),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
    final primaryButton = FilledButton.styleFrom(
      padding: const EdgeInsets.symmetric(horizontal: Space.md, vertical: Space.xs),
      minimumSize: const Size(0, 32),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
    return Semantics(
      container: true,
      child: PopupSurface(
        radius: Radii.panel,
        padding: const EdgeInsets.fromLTRB(Space.lg, Space.lg, Space.md, Space.md),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.only(top: 2),
                  child: BrandIllustration(pose: BrandPose.happy, size: 52),
                ),
                const SizedBox(width: Space.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(l.starPromptTitle, style: theme.textTheme.titleSmall),
                      const SizedBox(height: Space.xs),
                      Text(
                        l.starPromptMessage,
                        style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: Space.xs),
                SizedBox(
                  width: 28,
                  height: 28,
                  child: IconButton(
                    padding: EdgeInsets.zero,
                    tooltip: l.close,
                    onPressed: onLater,
                    icon: const Icon(Icons.close, size: 16),
                  ),
                ),
              ],
            ),
            const SizedBox(height: Space.md),
            Wrap(
              alignment: WrapAlignment.end,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: Space.xs,
              runSpacing: Space.xs,
              children: [
                TextButton(style: compactButton, onPressed: onNever, child: Text(l.starPromptNever)),
                TextButton(style: compactButton, onPressed: onLater, child: Text(l.later)),
                FilledButton.icon(
                  style: primaryButton,
                  onPressed: onStar,
                  icon: const Icon(Icons.star_rounded, size: 16),
                  label: Text(l.starPromptAction),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

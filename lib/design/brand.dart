import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import 'theme.dart';

/// Only selected, right-sized artwork is bundled; the original source pack is not a runtime asset.
abstract final class BrandAssets {
  static String mark(Accent theme) => 'assets/brand/${theme.name}/mark.png';
  static String logo(Accent theme, Brightness mode) => 'assets/brand/${theme.name}/logo-${mode.name}.png';
  static String breeze(Accent theme, Brightness mode) => 'assets/brand/${theme.name}/breeze-${mode.name}.png';
  static String cloud(Accent theme, Brightness mode) => 'assets/brand/${theme.name}/cloud-${mode.name}.png';
  static String sparkle(Accent theme, Brightness mode) => 'assets/brand/${theme.name}/sparkle-${mode.name}.png';
  static String wind(Accent theme, Brightness mode) => 'assets/brand/${theme.name}/wind-${mode.name}.png';
  static String pose(Accent theme, BrandPose pose) => 'assets/brand/${theme.name}/pose-${pose.file}.png';
}

/// Mascot poses from the author's pack, one per context (docs/UI.md §brand).
enum BrandPose {
  idle('default'),
  happy('happy'),
  success('success'),
  speed('speed'),
  sleeping('sleeping'),
  thinkingAi('thinking-ai'),
  security('security'),
  codingFocus('coding-focus'),
  sshConnected('ssh-connected'),
  sftpTransfer('sftp-transfer');

  const BrandPose(this.file);
  final String file;
}

/// Decoration is translucent so content keeps the attention; dark surfaces need less.
double _decorOpacity(Brightness mode, {required double light, required double dark}) =>
    mode == Brightness.light ? light : dark;

/// The host library's poses: a random one each time the library appears, cross-fading to another while it stays.
abstract final class BrandRotation {
  static const poses = [BrandPose.idle, BrandPose.happy, BrandPose.success, BrandPose.speed, BrandPose.sleeping];
  static const interval = Duration(seconds: 45), fade = Duration(milliseconds: 1200);

  @visibleForTesting
  static Random random = Random();
}

class _Art extends StatelessWidget {
  const _Art(
    this.asset, {
    super.key,
    required this.width,
    this.height,
    required this.opacity,
    this.alignment = Alignment.center,
  });

  final String asset;
  final double width, opacity;
  final double? height;
  final Alignment alignment;

  /// The same decoded size the widget uses, so a precached image is the one shown.
  static ImageProvider provider(BuildContext context, String asset, double width) =>
      ResizeImage.resizeIfNeeded((width * MediaQuery.devicePixelRatioOf(context)).ceil(), null, AssetImage(asset));

  @override
  Widget build(BuildContext context) => Image(
    image: provider(context, asset, width),
    width: width,
    height: height,
    opacity: AlwaysStoppedAnimation(opacity),
    fit: BoxFit.contain,
    alignment: alignment,
    excludeFromSemantics: true,
  );
}

class _HomePose extends StatefulWidget {
  const _HomePose({
    required this.width,
    required this.height,
    required this.opacity,
    required this.active,
    this.alignment = Alignment.center,
  });

  final double width, height, opacity;
  final bool active;
  final Alignment alignment;

  @override
  State<_HomePose> createState() => _HomePoseState();
}

class _HomePoseState extends State<_HomePose> {
  late var _pose = _pick(null);
  var _visit = 0;
  Timer? _timer;

  static BrandPose _pick(BrandPose? current) {
    final choices = [
      for (final pose in BrandRotation.poses)
        if (pose != current) pose,
    ];
    return choices[BrandRotation.random.nextInt(choices.length)];
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _schedule();
  }

  @override
  void didUpdateWidget(_HomePose oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Coming back into view shows a fresh pose at once, without fading out one nobody saw leave.
    if (widget.active && !oldWidget.active) {
      _pose = _pick(_pose);
      _visit++;
    }
    _schedule();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  /// Only a visible library rotates; reduced motion keeps the pose picked on arrival.
  void _schedule() {
    if (widget.active && !MediaQuery.disableAnimationsOf(context)) {
      _timer ??= Timer.periodic(BrandRotation.interval, (_) => _next());
    } else {
      _timer?.cancel();
      _timer = null;
    }
  }

  Future<void> _next() async {
    final next = _pick(_pose);
    final asset = BrandAssets.pose(BrandPalette.of(context).theme, next);
    await precacheImage(_Art.provider(context, asset, widget.width), context);
    if (mounted && widget.active) setState(() => _pose = next);
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    width: widget.width,
    height: widget.height,
    child: AnimatedSwitcher(
      key: ValueKey(_visit),
      duration: BrandRotation.fade,
      child: _Art(
        BrandAssets.pose(BrandPalette.of(context).theme, _pose),
        key: ValueKey(_pose),
        width: widget.width,
        height: widget.height,
        opacity: widget.opacity,
        alignment: widget.alignment,
      ),
    ),
  );
}

class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.size = 28});

  final double size;

  @override
  Widget build(BuildContext context) => Image.asset(
    BrandAssets.mark(BrandPalette.of(context).theme),
    width: size,
    height: size,
    cacheWidth: (size * MediaQuery.devicePixelRatioOf(context)).ceil(),
    fit: BoxFit.contain,
    semanticLabel: 'Sshairy',
  );
}

class BrandLogo extends StatelessWidget {
  const BrandLogo({super.key, this.width = maxWidth});

  static const maxWidth = 208.0;

  final double width;

  @override
  Widget build(BuildContext context) {
    final palette = BrandPalette.of(context);
    return Image.asset(
      BrandAssets.logo(palette.theme, palette.brightness),
      width: width,
      cacheWidth: (width * MediaQuery.devicePixelRatioOf(context)).ceil(),
      fit: BoxFit.contain,
      semanticLabel: 'Sshairy',
    );
  }
}

/// A quiet illustration for an empty content area; excludes non-interactive art from accessibility.
class BrandEmptyState extends StatelessWidget {
  const BrandEmptyState({super.key, this.child, this.active = true});

  final Widget? child;

  /// Whether the page is on screen; its pose rotates only then.
  final bool active;

  @override
  Widget build(BuildContext context) {
    final palette = BrandPalette.of(context);
    final (theme, mode) = (palette.theme, palette.brightness);
    final hero = _decorOpacity(mode, light: .7, dark: .72);
    final soft = _decorOpacity(mode, light: .4, dark: .32);
    final faint = _decorOpacity(mode, light: .24, dark: .16);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(Space.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ExcludeSemantics(
              child: SizedBox(
                width: 300,
                height: 200,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Positioned(
                      left: 0,
                      top: 24,
                      child: _Art(BrandAssets.cloud(theme, mode), width: 72, opacity: faint),
                    ),
                    Positioned(
                      right: 4,
                      top: 8,
                      child: _Art(BrandAssets.sparkle(theme, mode), width: 18, opacity: soft),
                    ),
                    Positioned(
                      right: 30,
                      top: 34,
                      child: _Art(BrandAssets.sparkle(theme, mode), width: 10, opacity: faint),
                    ),
                    Positioned(
                      left: 12,
                      bottom: 18,
                      child: _Art(BrandAssets.wind(theme, mode), width: 64, opacity: faint),
                    ),
                    Positioned(
                      right: 16,
                      bottom: 6,
                      child: _Art(BrandAssets.breeze(theme, mode), width: 108, opacity: faint),
                    ),
                    _HomePose(width: 190, height: 140, opacity: hero, active: active),
                  ],
                ),
              ),
            ),
            if (child != null) ...[const SizedBox(height: Space.md), child!],
          ],
        ),
      ),
    );
  }
}

/// A static, theme-matched illustration for a quiet empty area.
class BrandIllustration extends StatelessWidget {
  const BrandIllustration({super.key, required this.pose, this.size = 160});

  final BrandPose pose;
  final double size;

  @override
  Widget build(BuildContext context) {
    final palette = BrandPalette.of(context);
    return IgnorePointer(
      child: ExcludeSemantics(
        child: _Art(
          BrandAssets.pose(palette.theme, pose),
          width: size,
          height: size,
          opacity: _decorOpacity(palette.brightness, light: .72, dark: .76),
        ),
      ),
    );
  }
}

/// A small translucent pose above a short label, for an empty list in a flyout or popover.
class BrandHint extends StatelessWidget {
  const BrandHint({super.key, required this.pose, required this.label, this.size = 96});

  final BrandPose pose;
  final String label;
  final double size;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = BrandPalette.fromTheme(theme);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(vertical: Space.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _Art(
              BrandAssets.pose(palette.theme, pose),
              width: size,
              opacity: _decorOpacity(palette.brightness, light: .55, dark: .6),
            ),
            const SizedBox(height: Space.sm),
            Text(label, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }
}

/// A very faint pose for a large blank area; callers show it only where content cannot reach it.
class BrandWatermark extends StatelessWidget {
  const BrandWatermark({super.key, this.active = true});

  static const width = 168.0, height = 130.0;

  /// Whether the page is on screen; its pose rotates only then.
  final bool active;

  @override
  Widget build(BuildContext context) {
    final palette = BrandPalette.of(context);
    return IgnorePointer(
      child: ExcludeSemantics(
        child: _HomePose(
          width: width,
          height: height,
          opacity: _decorOpacity(palette.brightness, light: .12, dark: .09),
          active: active,
          alignment: Alignment.bottomRight,
        ),
      ),
    );
  }
}

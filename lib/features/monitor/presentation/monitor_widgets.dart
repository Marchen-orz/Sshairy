import 'dart:math';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';

import '../../../design/theme.dart';
import '../application/monitor.dart';
import '../domain/chart_range.dart';

const tabular = [FontFeature.tabularFigures()];

String formatPercent(double f) => '${(f * 100).round()}%';

/// Top's per-process figure, where 100% is one core: one decimal below 10%.
String formatCpu(double? f) {
  if (f == null) return '–';
  final p = f * 100;
  return p < 10 ? p.toStringAsFixed(1) : p.round().toString();
}

String formatBytes(num bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];
  var v = bytes.toDouble();
  var u = 0;
  while (v >= 1024 && u < units.length - 1) {
    v /= 1024;
    u++;
  }
  return '${v.toStringAsFixed(u == 0 || v >= 100 ? 0 : 1)} ${units[u]}';
}

/// For narrow columns: "1.2G", "512M".
String formatShortBytes(num bytes) {
  const units = ['B', 'K', 'M', 'G', 'T', 'P'];
  var v = bytes.toDouble();
  var u = 0;
  while (v >= 1024 && u < units.length - 1) {
    v /= 1024;
    u++;
  }
  return '${v.toStringAsFixed(u == 0 || v >= 10 ? 0 : 1)}${units[u]}';
}

/// Like ps's etime: `[[d-]hh:]mm:ss`.
String formatElapsed(Duration? d) {
  if (d == null) return '–';
  String two(int n) => n.toString().padLeft(2, '0');
  final (days, h, m, s) = (d.inDays, d.inHours % 24, d.inMinutes % 60, d.inSeconds % 60);
  if (days > 0) return '$days-${two(h)}:${two(m)}:${two(s)}';
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
}

/// Nearly full is worth a glance whatever the metric.
Color fillColor(BuildContext context, double fraction, Color color) =>
    fraction >= .9 ? Theme.of(context).colorScheme.error : color;

class MonitorCard extends StatelessWidget {
  const MonitorCard({super.key, required this.child, this.onTap, this.tooltip});

  final Widget child;
  final VoidCallback? onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final radius = BorderRadius.circular(Radii.card);
    Widget card = Ink(
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: radius,
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: .6)),
      ),
      child: Padding(padding: const EdgeInsets.all(Space.sm), child: child),
    );
    if (onTap != null) card = InkWell(borderRadius: radius, onTap: onTap, child: card);
    if (tooltip != null) card = Tooltip(message: tooltip, child: card);
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.sm),
      child: Material(type: MaterialType.transparency, child: card),
    );
  }
}

/// A percentage ring with its label and figures underneath.
class MonitorRing extends StatelessWidget {
  const MonitorRing({super.key, required this.label, required this.fraction, this.detail, this.color, this.size = 56});

  final String label;
  final double? fraction;
  final String? detail;
  final Color? color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final f = fraction?.clamp(0.0, 1.0);
    final small = theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant, fontFeatures: tabular);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox.square(
          dimension: size,
          child: TweenAnimationBuilder<double>(
            tween: Tween(end: f ?? 0),
            duration: Motion.normal,
            builder: (context, value, _) => CustomPaint(
              painter: _RingPainter(
                value,
                track: scheme.surfaceContainerHighest,
                fill: fillColor(context, f ?? 0, color ?? scheme.primary),
              ),
              child: Center(
                child: Text(
                  f == null ? '–' : formatPercent(f),
                  style: theme.textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w600, fontFeatures: tabular),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: Space.xs),
        Text(label, style: theme.textTheme.bodySmall, maxLines: 1, overflow: TextOverflow.ellipsis),
        if (detail != null) Text(detail!, style: small, maxLines: 1, overflow: TextOverflow.ellipsis),
      ],
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter(this.fraction, {required this.track, required this.fill});

  final double fraction;
  final Color track, fill;

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 5.0;
    final rect = (Offset.zero & size).deflate(stroke / 2);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(rect, 0, 2 * pi, false, paint..color = track);
    if (fraction > 0) canvas.drawArc(rect, -pi / 2, 2 * pi * fraction, false, paint..color = fill);
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.fraction != fraction || old.track != track || old.fill != fill;
}

class MonitorBar extends StatelessWidget {
  const MonitorBar(this.fraction, {super.key, required this.color, this.height = 4});

  final double fraction;
  final Color color;
  final double height;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final f = fraction.clamp(0.0, 1.0);
    return ClipRRect(
      borderRadius: BorderRadius.circular(height),
      child: SizedBox(
        height: height,
        child: Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(color: scheme.surfaceContainerHighest),
            FractionallySizedBox(
              alignment: Alignment.centerLeft,
              widthFactor: f,
              child: AnimatedContainer(
                duration: Motion.normal,
                decoration: BoxDecoration(
                  color: fillColor(context, f, color),
                  borderRadius: BorderRadius.circular(height),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Lines over the last [ServerMonitor.historyLength] samples. Percentage series get separate, named plots.
class MonitorSpark extends StatelessWidget {
  const MonitorSpark({
    super.key,
    required this.series,
    this.percentage = false,
    this.labels = const [],
    this.height = 32,
  });

  final List<(List<double>, Color)> series;
  final bool percentage;
  final List<String> labels;
  final double height;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final data = [
      for (final (values, color) in series)
        (values.skip(max(0, values.length - ServerMonitor.historyLength)).toList(), color),
    ];
    Widget plot(List<(List<double>, Color)> lines, MonitorRange range) => SizedBox(
      height: height,
      child: CustomPaint(painter: _SparkPainter(lines, range, theme.colorScheme.outlineVariant)),
    );
    if (!percentage) return plot(data, MonitorRange.network(data.expand((s) => s.$1)));
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < data.length; i++) ...[
          if (i > 0) const SizedBox(height: Space.xs),
          Builder(
            builder: (context) {
              final line = data[i], range = MonitorRange.percentage(data[i].$1);
              final label = i < labels.length ? labels[i] : '';
              final extent = '${(range.min * 100).toStringAsFixed(1)}–${(range.max * 100).toStringAsFixed(1)}%';
              return Tooltip(
                message: [label, extent].where((s) => s.isNotEmpty).join(' · '),
                child: Row(
                  children: [
                    if (label.isNotEmpty)
                      SizedBox(
                        width: 42,
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                        ),
                      ),
                    Expanded(child: plot([line], range)),
                  ],
                ),
              );
            },
          ),
        ],
      ],
    );
  }
}

class _SparkPainter extends CustomPainter {
  _SparkPainter(this.series, this.range, this.grid);

  final List<(List<double>, Color)> series;
  final MonitorRange range;
  final Color grid;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawLine(
      Offset(0, size.height - .5),
      Offset(size.width, size.height - .5),
      Paint()..color = grid.withValues(alpha: .5),
    );
    final step = size.width / (ServerMonitor.historyLength - 1);
    for (final (values, color) in series) {
      final start = size.width - (values.length - 1) * step;
      final stroke = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..strokeJoin = StrokeJoin.round;
      final fill = Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [color.withValues(alpha: .22), color.withValues(alpha: 0)],
        ).createShader(Offset.zero & size);
      Path? line;
      Offset? first, last;
      void finish() {
        if (line == null) return;
        if (first == last) {
          canvas.drawCircle(first!, 1.5, Paint()..color = color);
        } else {
          final area = Path.from(line!)
            ..lineTo(last!.dx, size.height)
            ..lineTo(first!.dx, size.height)
            ..close();
          canvas.drawPath(area, fill);
          canvas.drawPath(line!, stroke);
        }
        line = null;
      }

      for (var i = 0; i < values.length; i++) {
        if (!values[i].isFinite) {
          finish();
          continue;
        }
        final point = Offset(start + i * step, size.height - 1 - range.fraction(values[i]) * (size.height - 2));
        if (line == null) {
          first = point;
          line = Path()..moveTo(point.dx, point.dy);
        } else {
          line!.lineTo(point.dx, point.dy);
        }
        last = point;
      }
      finish();
    }
  }

  @override
  bool shouldRepaint(_SparkPainter old) {
    if (range.min != old.range.min ||
        range.max != old.range.max ||
        grid != old.grid ||
        series.length != old.series.length) {
      return true;
    }
    for (var i = 0; i < series.length; i++) {
      if (series[i].$2 != old.series[i].$2 || !listEquals(series[i].$1, old.series[i].$1)) return true;
    }
    return false;
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../design/theme.dart';
import '../../../l10n/app_localizations.dart';
import '../../connections/api.dart';
import '../../hosts/api.dart';
import '../application/monitor.dart';

/// The server's vital signs beside its terminal (docs/MODULES.md §8). Polls only while [active].
class MonitorPanel extends ConsumerStatefulWidget {
  const MonitorPanel({super.key, required this.host, required this.active});

  final Host host;
  final bool active;

  @override
  ConsumerState<MonitorPanel> createState() => _MonitorPanelState();
}

class _MonitorPanelState extends ConsumerState<MonitorPanel> {
  late ServerMonitor _monitor = _create();

  ServerMonitor _create() {
    final m = ServerMonitor(ref.read(connectionManagerProvider), widget.host);
    if (widget.active) m.start();
    return m;
  }

  @override
  void didUpdateWidget(MonitorPanel old) {
    super.didUpdateWidget(old);
    if (old.host.id != widget.host.id) {
      _monitor.dispose();
      _monitor = _create();
    } else if (widget.active != old.active) {
      widget.active ? _monitor.start() : _monitor.stop();
    }
  }

  @override
  void dispose() {
    _monitor.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: WorkspaceSize.monitor,
      child: ColoredBox(
        color: scheme.surfaceContainerLow,
        child: ListenableBuilder(
          listenable: _monitor,
          builder: (context, _) => _Content(monitor: _monitor, host: widget.host),
        ),
      ),
    );
  }
}

const _tabular = [FontFeature.tabularFigures()];

class _Content extends StatelessWidget {
  const _Content({required this.monitor, required this.host});

  final ServerMonitor monitor;
  final Host host;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant, fontFeatures: _tabular);
    final snap = monitor.snapshot;
    final s = snap?.sample;
    final notice = switch (monitor.state) {
      MonitorState.offline => l.monitorOffline,
      MonitorState.unsupported => l.monitorUnsupported,
      MonitorState.failed => l.monitorFailed,
      _ => null,
    };
    String? uptime;
    if (s?.uptime case final up?) {
      final d = up.inDays, h = up.inHours % 24, m = up.inMinutes % 60;
      uptime = d > 0 ? l.uptimeDays(d, h) : l.uptimeHours(h, m);
    }

    return ListView(
      padding: const EdgeInsets.all(Space.sm),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Space.xs, Space.xs, Space.xs, Space.sm),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  host.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
              if (uptime != null)
                Tooltip(
                  message: l.uptime,
                  child: Text(uptime, style: muted),
                ),
            ],
          ),
        ),
        if (notice != null)
          _Card(
            child: Row(
              children: [
                Icon(
                  monitor.state == MonitorState.offline ? Icons.link_off : Icons.info_outline,
                  size: 16,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: Space.sm),
                Expanded(child: Text(notice, style: muted)),
              ],
            ),
          )
        else if (snap == null)
          const Padding(
            padding: EdgeInsets.all(Space.xl),
            child: Center(child: SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))),
          ),
        if (snap != null && s != null && monitor.state != MonitorState.unsupported) ...[
          _Card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Headline(label: l.cpu, value: snap.cpu == null ? '–' : _percent(snap.cpu!)),
                const SizedBox(height: Space.sm),
                _Spark(series: [(monitor.cpu, scheme.primary)], max: 1),
                const SizedBox(height: Space.sm),
                Text(
                  [
                    if (s.cores != null) l.cores(s.cores!),
                    if (s.load.isNotEmpty) '${l.load} ${s.load.map((v) => v.toStringAsFixed(2)).join(' ')}',
                  ].join(' · '),
                  style: muted,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          _Card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Headline(label: l.memory, value: _percent(snap.memory)),
                const SizedBox(height: Space.sm),
                _Bar(snap.memory, color: scheme.secondary),
                const SizedBox(height: Space.xs),
                Text(
                  '${_bytes((s.memTotalKib - s.memAvailableKib) * 1024)} / ${_bytes(s.memTotalKib * 1024)}',
                  style: muted,
                ),
                if (s.swapTotalKib > 0) ...[
                  const SizedBox(height: Space.sm),
                  _Meter(
                    label: l.swap,
                    fraction: snap.swap,
                    detail: '${_bytes((s.swapTotalKib - s.swapFreeKib) * 1024)} / ${_bytes(s.swapTotalKib * 1024)}',
                    color: scheme.secondary,
                  ),
                ],
              ],
            ),
          ),
          _Card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Text(l.network, style: theme.textTheme.labelMedium),
                    const Spacer(),
                    _Rate(Icons.south_rounded, snap.rxPerSecond, scheme.primary),
                    const SizedBox(width: Space.sm),
                    _Rate(Icons.north_rounded, snap.txPerSecond, scheme.tertiary),
                  ],
                ),
                const SizedBox(height: Space.sm),
                _Spark(series: [(monitor.rx, scheme.primary), (monitor.tx, scheme.tertiary)]),
              ],
            ),
          ),
          for (final g in s.gpus)
            _Card(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _Headline(label: l.gpu, value: g.utilization == null ? '–' : _percent(g.utilization!)),
                  Text(
                    [g.name, if (g.temperature != null) '${g.temperature}°C'].join(' · '),
                    style: muted,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (g.utilization case final u?) ...[
                    const SizedBox(height: Space.sm),
                    _Bar(u, color: scheme.primary),
                  ],
                  if (g.memoryFraction case final f?) ...[
                    const SizedBox(height: Space.sm),
                    _Meter(
                      label: l.memory,
                      fraction: f,
                      detail: '${_bytes(g.memoryUsedMib! << 20)} / ${_bytes(g.memoryTotalMib! << 20)}',
                      color: scheme.secondary,
                    ),
                  ],
                ],
              ),
            ),
          if (s.disks.isNotEmpty)
            _Card(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(l.disks, style: theme.textTheme.labelMedium),
                  for (final d in s.disks) ...[
                    const SizedBox(height: Space.sm),
                    _Meter(
                      label: d.mount,
                      fraction: d.fraction,
                      detail: '${_bytes(d.usedKib * 1024)} / ${_bytes(d.totalKib * 1024)}',
                      color: scheme.primary,
                    ),
                  ],
                ],
              ),
            ),
        ],
      ],
    );
  }
}

String _percent(double f) => '${(f * 100).round()}%';

String _bytes(num bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];
  var v = bytes.toDouble();
  var u = 0;
  while (v >= 1024 && u < units.length - 1) {
    v /= 1024;
    u++;
  }
  return '${v.toStringAsFixed(u == 0 || v >= 100 ? 0 : 1)} ${units[u]}';
}

class _Card extends StatelessWidget {
  const _Card({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.sm),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(Radii.card),
          border: Border.all(color: scheme.outlineVariant.withValues(alpha: .6)),
        ),
        child: Padding(padding: const EdgeInsets.all(Space.md), child: child),
      ),
    );
  }
}

class _Headline extends StatelessWidget {
  const _Headline({required this.label, required this.value});

  final String label, value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(label, style: theme.textTheme.labelMedium),
        const Spacer(),
        Text(
          value,
          style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600, fontFeatures: _tabular),
        ),
      ],
    );
  }
}

/// A label and its figures over a thin bar.
class _Meter extends StatelessWidget {
  const _Meter({required this.label, required this.fraction, required this.detail, required this.color});

  final String label, detail;
  final double fraction;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
      fontFeatures: _tabular,
    );
    return Tooltip(
      message: detail,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall),
              ),
              Text(_percent(fraction), style: muted),
            ],
          ),
          const SizedBox(height: 3),
          _Bar(fraction, color: color, height: 4),
        ],
      ),
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar(this.fraction, {required this.color, this.height = 6});

  final double fraction;
  final Color color;
  final double height;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final f = fraction.clamp(0.0, 1.0);
    // Nearly full is worth a glance whatever the metric.
    final fill = f >= .9 ? scheme.error : color;
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
                decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(height)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Rate extends StatelessWidget {
  const _Rate(this.icon, this.perSecond, this.color);

  final IconData icon;
  final double? perSecond;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 12, color: color),
        Text(
          perSecond == null ? '–' : '${_bytes(perSecond!)}/s',
          style: theme.textTheme.bodySmall?.copyWith(fontFeatures: _tabular),
        ),
      ],
    );
  }
}

class _Spark extends StatelessWidget {
  const _Spark({required this.series, this.max});

  final List<(List<double>, Color)> series;

  /// Null scales to the largest value shown.
  final double? max;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 36,
    child: CustomPaint(
      painter: _SparkPainter(
        [for (final (values, color) in series) (List.of(values), color)],
        max,
        Theme.of(context).colorScheme.outlineVariant,
      ),
    ),
  );
}

class _SparkPainter extends CustomPainter {
  _SparkPainter(this.series, this.max, this.grid);

  final List<(List<double>, Color)> series;
  final double? max;
  final Color grid;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawLine(
      Offset(0, size.height - .5),
      Offset(size.width, size.height - .5),
      Paint()..color = grid.withValues(alpha: .5),
    );
    var top = max ?? 0;
    if (max == null) {
      for (final (values, _) in series) {
        for (final v in values) {
          top = v > top ? v : top;
        }
      }
    }
    if (top <= 0) return;
    final step = size.width / (ServerMonitor.historyLength - 1);
    for (final (values, color) in series) {
      if (values.length < 2) continue;
      final start = size.width - (values.length - 1) * step;
      Offset at(int i) => Offset(start + i * step, size.height - (values[i] / top).clamp(0.0, 1.0) * (size.height - 2));
      final line = Path()..moveTo(at(0).dx, at(0).dy);
      for (var i = 1; i < values.length; i++) {
        final p = at(i);
        line.lineTo(p.dx, p.dy);
      }
      final area = Path.from(line)
        ..lineTo(size.width, size.height)
        ..lineTo(start, size.height)
        ..close();
      canvas.drawPath(
        area,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [color.withValues(alpha: .22), color.withValues(alpha: 0)],
          ).createShader(Offset.zero & size),
      );
      canvas.drawPath(
        line,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..strokeJoin = StrokeJoin.round,
      );
    }
  }

  @override
  bool shouldRepaint(_SparkPainter old) => true;
}

import 'dart:math' as math;

/// Percentage histories emphasize changes without magnifying less than one percentage point.
class MonitorRange {
  const MonitorRange(this.min, this.max);

  factory MonitorRange.percentage(Iterable<double> samples) {
    final values = samples.where((v) => v.isFinite).map((v) => v.clamp(0.0, 1.0)).toList();
    if (values.isEmpty) return const MonitorRange(0, .01);
    final low = values.reduce((a, b) => a < b ? a : b), high = values.reduce((a, b) => a > b ? a : b);
    final spread = high - low;
    final padding = math.max(spread * .12, .001);
    final span = math.max(spread + 2 * padding, .01).clamp(.01, 1.0);
    final bottom = ((low + high - span) / 2).clamp(0.0, 1.0 - span);
    return MonitorRange(bottom, bottom + span);
  }

  /// A shared zero baseline keeps upload and download comparable.
  factory MonitorRange.network(Iterable<double> samples) {
    final high = samples.where((v) => v.isFinite && v > 0).fold(0.0, (a, b) => a > b ? a : b);
    return MonitorRange(0, high > 0 ? high : 1);
  }

  final double min, max;
  double fraction(double value) => ((value - min) / (max - min)).clamp(0.0, 1.0);
}

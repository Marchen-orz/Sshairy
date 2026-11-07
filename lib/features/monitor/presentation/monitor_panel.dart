import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../design/controls.dart';
import '../../../design/menu.dart';
import '../../../design/theme.dart';
import '../../../l10n/app_localizations.dart';
import '../../connections/api.dart';
import '../../hosts/api.dart';
import '../../settings/api.dart';
import '../application/monitor.dart';
import '../domain/stats.dart';
import 'monitor_widgets.dart';
import 'process_dialog.dart';

const _intervals = [1, 2, 3, 5, 10];

enum _Page { system, gpu }

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
  var _page = _Page.system;
  var _interface = ServerMonitor.allInterfaces;

  Duration get _interval => Duration(seconds: ref.read(settingsProvider).get(SettingKeys.monitorInterval));

  ServerMonitor _create() {
    final m = ServerMonitor(ref.read(connectionManagerProvider), widget.host, interval: _interval)
      ..gpuVisible = _page == _Page.gpu;
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

  void _show(_Page page) {
    setState(() => _page = page);
    _monitor.gpuVisible = page == _Page.gpu;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    ref.listen(settingsProvider.select((s) => s.get(SettingKeys.monitorInterval)), (_, seconds) {
      _monitor.interval = Duration(seconds: seconds);
    });
    return SizedBox(
      width: WorkspaceSize.monitor,
      child: ColoredBox(
        color: scheme.surfaceContainerLow,
        child: ListenableBuilder(
          listenable: _monitor,
          builder: (context, _) {
            final gpus = _monitor.snapshot?.sample.gpuVendors.isNotEmpty ?? false;
            return _Content(
              monitor: _monitor,
              host: widget.host,
              page: gpus ? _page : _Page.system,
              onPage: gpus ? _show : null,
              interface: _interface,
              onInterface: (name) => setState(() => _interface = name),
            );
          },
        ),
      ),
    );
  }
}

class _Content extends ConsumerWidget {
  const _Content({
    required this.monitor,
    required this.host,
    required this.page,
    required this.onPage,
    required this.interface,
    required this.onInterface,
  });

  final ServerMonitor monitor;
  final Host host;
  final _Page page;

  /// Null while the server shows no graphics card.
  final ValueChanged<_Page>? onPage;
  final String interface;
  final ValueChanged<String> onInterface;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant, fontFeatures: tabular);
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
    final seconds = monitor.interval.inSeconds;

    return ListView(
      padding: const EdgeInsets.all(Space.sm),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Space.xs, 0, 0, Space.xs),
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
              AppMenuButton<int>(
                tooltip: l.monitorInterval,
                items: () => [
                  for (final n in _intervals) AppMenuItem(value: n, label: l.seconds(n), checked: n == seconds),
                ],
                onSelected: (n) => ref.read(settingsProvider.notifier).set(SettingKeys.monitorInterval, n),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Space.xs + 2, vertical: Space.xs),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.timer_outlined, size: 14, color: scheme.onSurfaceVariant),
                      const SizedBox(width: 3),
                      Text('${seconds}s', style: muted),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        _Info(
          icon: Icons.lan_outlined,
          tooltip: l.address,
          text: host.address,
          trailing: IconButton(
            tooltip: l.copyAddress,
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints.tightFor(width: 24, height: 24),
            padding: EdgeInsets.zero,
            iconSize: 13,
            onPressed: () => Clipboard.setData(ClipboardData(text: host.address)),
            icon: const Icon(Icons.copy_rounded),
          ),
        ),
        if (s != null)
          Row(
            children: [
              if (uptime != null)
                Expanded(
                  child: _Info(icon: Icons.schedule, tooltip: l.uptime, text: uptime),
                ),
              if (s.load.isNotEmpty)
                Expanded(
                  child: _Info(
                    icon: Icons.speed,
                    tooltip: l.load,
                    text: s.load.map((v) => v.toStringAsFixed(2)).join(' '),
                  ),
                ),
            ],
          ),
        const SizedBox(height: Space.sm),
        if (onPage != null)
          Padding(
            padding: const EdgeInsets.only(bottom: Space.sm),
            child: Center(
              child: AppSegmented<_Page>(
                segments: {_Page.system: l.monitorSystem, _Page.gpu: l.gpu},
                selected: page,
                onChanged: onPage,
              ),
            ),
          ),
        if (notice != null)
          MonitorCard(
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
          const _Loading(),
        if (snap != null && s != null && monitor.state != MonitorState.unsupported)
          if (page == _Page.system)
            ..._system(context, snap, s)
          else if (s.gpus.isEmpty)
            const _Loading()
          else
            for (final g in s.gpus) _GpuCard(gpu: g, history: monitor.gpuUtilization[g.id] ?? const []),
      ],
    );
  }

  List<Widget> _system(BuildContext context, StatsSnapshot snap, StatsSample s) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant, fontFeatures: tabular);
    final header = theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant);
    final figures = theme.textTheme.bodySmall?.copyWith(fontFeatures: tabular);
    String used(int usedKib, int totalKib) =>
        '${formatShortBytes(usedKib * 1024)}/${formatShortBytes(totalKib * 1024)}';
    final names = snap.interfaceRates.keys.toList()..sort();
    final selected = names.contains(interface) ? interface : ServerMonitor.allInterfaces;
    final rate = snap.interfaceRates[selected];
    final top = snap.top(5);

    return [
      MonitorCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: MonitorRing(
                    label: l.cpu,
                    fraction: snap.cpu,
                    detail: s.cores == null ? null : l.cores(s.cores!),
                  ),
                ),
                Expanded(
                  child: MonitorRing(
                    label: l.memory,
                    fraction: snap.memory,
                    color: scheme.secondary,
                    detail: used(s.memTotalKib - s.memAvailableKib, s.memTotalKib),
                  ),
                ),
                Expanded(
                  child: MonitorRing(
                    label: l.swap,
                    fraction: s.swapTotalKib == 0 ? null : snap.swap,
                    color: scheme.tertiary,
                    detail: s.swapTotalKib == 0 ? null : used(s.swapTotalKib - s.swapFreeKib, s.swapTotalKib),
                  ),
                ),
              ],
            ),
            const SizedBox(height: Space.sm),
            MonitorSpark(
              height: 28,
              max: 1,
              series: [(monitor.memory, scheme.secondary), (monitor.cpu, scheme.primary)],
            ),
          ],
        ),
      ),
      if (top.isNotEmpty)
        MonitorCard(
          tooltip: l.showAllProcesses,
          onTap: () => showProcessDialog(context, monitor),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  SizedBox(
                    width: 48,
                    child: Text(l.memory, style: header, textAlign: TextAlign.right),
                  ),
                  SizedBox(
                    width: 40,
                    child: Text(l.cpu, style: header, textAlign: TextAlign.right),
                  ),
                  const SizedBox(width: Space.sm),
                  Expanded(child: Text(l.processes, style: header)),
                  Icon(Icons.open_in_full_rounded, size: 12, color: scheme.onSurfaceVariant),
                ],
              ),
              const SizedBox(height: 2),
              for (final p in top)
                SizedBox(
                  height: 18,
                  child: Row(
                    children: [
                      SizedBox(
                        width: 48,
                        child: Text(formatShortBytes(p.residentBytes), style: figures, textAlign: TextAlign.right),
                      ),
                      SizedBox(
                        width: 40,
                        child: Text(formatCpu(p.cpu), style: figures, textAlign: TextAlign.right),
                      ),
                      const SizedBox(width: Space.sm),
                      Expanded(
                        child: Text(
                          p.name,
                          style: theme.textTheme.bodySmall,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      MonitorCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                _Rate(Icons.south_rounded, rate?.rx ?? snap.rxPerSecond, scheme.primary),
                const SizedBox(width: Space.sm),
                _Rate(Icons.north_rounded, rate?.tx ?? snap.txPerSecond, scheme.tertiary),
                const Spacer(),
                if (names.length > 1)
                  AppMenuButton<String>(
                    tooltip: l.network,
                    items: () => [
                      AppMenuItem(
                        value: ServerMonitor.allInterfaces,
                        label: l.allInterfaces,
                        checked: selected == ServerMonitor.allInterfaces,
                      ),
                      const AppMenuDivider(),
                      for (final n in names) AppMenuItem(value: n, label: n, checked: n == selected),
                    ],
                    onSelected: onInterface,
                    child: Padding(
                      padding: const EdgeInsets.only(left: Space.xs),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 64),
                            child: Text(
                              selected == ServerMonitor.allInterfaces ? l.network : selected,
                              style: muted,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          Icon(Icons.arrow_drop_down, size: 16, color: scheme.onSurfaceVariant),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: Space.xs),
            MonitorSpark(
              series: [
                (monitor.rx[selected] ?? const [], scheme.primary),
                (monitor.tx[selected] ?? const [], scheme.tertiary),
              ],
            ),
          ],
        ),
      ),
      if (s.disks.isNotEmpty)
        MonitorCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(child: Text(l.disks, style: header)),
                  Text(l.diskFree, style: header),
                ],
              ),
              for (final d in s.disks)
                Tooltip(
                  message: '${formatBytes(d.usedKib * 1024)} / ${formatBytes(d.totalKib * 1024)}',
                  child: Padding(
                    padding: const EdgeInsets.only(top: Space.xs),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                d.mount,
                                style: theme.textTheme.bodySmall,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            Text(
                              '${formatShortBytes(d.availableKib * 1024)}/${formatShortBytes(d.totalKib * 1024)}',
                              style: muted,
                            ),
                          ],
                        ),
                        const SizedBox(height: 2),
                        MonitorBar(d.fraction, color: scheme.primary, height: 3),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
    ];
  }
}

class _Loading extends StatelessWidget {
  const _Loading();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.all(Space.xl),
    child: Center(child: SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))),
  );
}

/// An icon that names the figure beside it; the tooltip says it in words.
class _Info extends StatelessWidget {
  const _Info({required this.icon, required this.tooltip, required this.text, this.trailing});

  final IconData icon;
  final String tooltip, text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return SizedBox(
      height: 24,
      child: Row(
        children: [
          const SizedBox(width: Space.xs),
          Tooltip(
            message: tooltip,
            child: Icon(icon, size: 13, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(width: Space.xs + 2),
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(fontFeatures: tabular),
            ),
          ),
          ?trailing,
        ],
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
          perSecond == null ? '–' : '${formatBytes(perSecond!)}/s',
          style: theme.textTheme.bodySmall?.copyWith(fontFeatures: tabular),
        ),
      ],
    );
  }
}

/// One card per graphics card, laid out like the drivers' own panels.
class _GpuCard extends StatelessWidget {
  const _GpuCard({required this.gpu, required this.history});

  final Gpu gpu;
  final List<double> history;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final figures = theme.textTheme.bodySmall?.copyWith(fontFeatures: tabular);
    final muted = figures?.copyWith(color: scheme.onSurfaceVariant);
    final (used, total) = (gpu.memoryUsedBytes, gpu.memoryTotalBytes);
    String? watts(double? v) => v?.round().toString();
    final power = [watts(gpu.powerWatts), watts(gpu.powerLimitWatts)].nonNulls.join('/');
    final fan = gpu.fanPercent != null
        ? '${gpu.fanPercent!.round()}%'
        : gpu.fanRpm != null
        ? '${gpu.fanRpm} RPM'
        : null;
    final stats = [
      if (gpu.temperature case final t?) (Icons.thermostat_outlined, l.gpuTemperature, '${t.round()}°C'),
      if (power.isNotEmpty) (Icons.bolt_outlined, l.gpuPower, '$power W'),
      if (fan != null) (Icons.air, l.gpuFan, fan),
      if (gpu.coreClockMhz case final c?) (Icons.developer_board_outlined, l.gpuCoreClock, '$c MHz'),
      if (gpu.memoryClockMhz case final c?) (Icons.memory_outlined, l.gpuMemoryClock, '$c MHz'),
    ];

    return MonitorCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            [if (gpu.index != null) '#${gpu.index}', gpu.name].join(' '),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: Space.sm),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: MonitorRing(label: l.gpu, fraction: gpu.utilization),
              ),
              Expanded(
                child: MonitorRing(
                  label: l.gpuMemory,
                  fraction: gpu.memoryFraction,
                  color: scheme.secondary,
                  detail: used == null || total == null ? null : '${formatShortBytes(used)}/${formatShortBytes(total)}',
                ),
              ),
            ],
          ),
          if (stats.isNotEmpty) ...[
            const SizedBox(height: Space.sm),
            Wrap(
              runSpacing: 2,
              children: [
                for (final (icon, label, value) in stats)
                  FractionallySizedBox(
                    widthFactor: .5,
                    child: Tooltip(
                      message: label,
                      child: Row(
                        children: [
                          Icon(icon, size: 13, color: scheme.onSurfaceVariant),
                          const SizedBox(width: Space.xs),
                          Flexible(
                            child: Text(value, style: figures, maxLines: 1, overflow: TextOverflow.ellipsis),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ],
          const SizedBox(height: Space.sm),
          MonitorSpark(height: 28, max: 1, series: [(history, scheme.primary)]),
          if (gpu.processes.isNotEmpty) ...[
            const SizedBox(height: Space.sm),
            for (final p in gpu.processes)
              Tooltip(
                message: [p.user, p.command ?? p.name].nonNulls.join(' · '),
                child: SizedBox(
                  height: 18,
                  child: Row(
                    children: [
                      SizedBox(width: 48, child: Text('${p.pid}', style: muted)),
                      Expanded(
                        child: Text(
                          p.name,
                          style: theme.textTheme.bodySmall,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (p.memoryBytes case final m?) Text(formatShortBytes(m), style: figures),
                    ],
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../design/dialog.dart';
import '../../../design/menu.dart';
import '../../../design/scrolling.dart';
import '../../../design/theme.dart';
import '../../../foundation/result.dart';
import '../../../l10n/app_localizations.dart';
import '../application/monitor.dart';
import '../domain/stats.dart';
import 'monitor_widgets.dart';

/// Every process of the host, refreshed with the panel (docs/MODULES.md §8): htop's view, driven by the mouse.
Future<void> showProcessDialog(BuildContext context, ServerMonitor monitor) => showAppDialog<void>(
  context: context,
  builder: (_) => ProcessDialog(monitor: monitor),
);

enum _Column { pid, user, cpu, memory, resident, state, threads, elapsed, command }

class ProcessDialog extends StatefulWidget {
  const ProcessDialog({super.key, required this.monitor});

  final ServerMonitor monitor;

  @override
  State<ProcessDialog> createState() => _ProcessDialogState();
}

class _ProcessDialogState extends State<ProcessDialog> {
  late final VoidCallback _unwatch = widget.monitor.watchProcesses();
  final _search = TextEditingController();
  final _scroll = ScrollController();
  final _horizontal = ScrollController();
  final _widths = <_Column, double>{};
  final _focus = FocusNode();
  var _sort = _Column.cpu;
  var _descending = true;
  var _paused = false;
  int? _selected;
  double? _dragWidth;

  /// What the table shows while paused.
  StatsSnapshot? _frozen;

  @override
  void initState() {
    super.initState();
    _unwatch;
  }

  @override
  void dispose() {
    _unwatch();
    _search.dispose();
    _scroll.dispose();
    _horizontal.dispose();
    _focus.dispose();
    super.dispose();
  }

  static const _defaultWidths = {
    _Column.pid: 64.0,
    _Column.user: 96.0,
    _Column.cpu: 60.0,
    _Column.memory: 60.0,
    _Column.resident: 72.0,
    _Column.state: 44.0,
    _Column.threads: 56.0,
    _Column.elapsed: 92.0,
    _Column.command: 240.0,
  };

  static const _minimumWidths = {
    _Column.pid: 56.0,
    _Column.user: 64.0,
    _Column.cpu: 56.0,
    _Column.memory: 56.0,
    _Column.resident: 64.0,
    _Column.state: 44.0,
    _Column.threads: 56.0,
    _Column.elapsed: 80.0,
    _Column.command: 160.0,
  };

  static const _numeric = {
    _Column.pid,
    _Column.cpu,
    _Column.memory,
    _Column.resident,
    _Column.threads,
    _Column.elapsed,
  };

  String _label(AppLocalizations l, _Column c) => switch (c) {
    _Column.pid => 'PID',
    _Column.user => l.processUser,
    _Column.cpu => '${l.cpu}%',
    _Column.memory => '${l.memory}%',
    _Column.resident => l.processResident,
    _Column.state => l.processState,
    _Column.threads => l.processThreads,
    _Column.elapsed => l.processElapsed,
    _Column.command => l.processCommand,
  };

  int _compare(ProcessInfo a, ProcessInfo b) {
    final c = switch (_sort) {
      _Column.pid => a.pid.compareTo(b.pid),
      _Column.user => (a.owner?.user ?? '').compareTo(b.owner?.user ?? ''),
      _Column.cpu => (a.cpu ?? -1).compareTo(b.cpu ?? -1),
      _Column.memory || _Column.resident => a.residentBytes.compareTo(b.residentBytes),
      _Column.state => a.stat.state.compareTo(b.stat.state),
      _Column.threads => a.stat.threads.compareTo(b.stat.threads),
      _Column.elapsed => (a.elapsed ?? Duration.zero).compareTo(b.elapsed ?? Duration.zero),
      _Column.command => a.command.toLowerCase().compareTo(b.command.toLowerCase()),
    };
    // Ties keep a fixed order, so rows do not swap places between samples.
    return c != 0 ? (_descending ? -c : c) : a.pid.compareTo(b.pid);
  }

  void _sortBy(_Column c) => setState(() {
    if (_sort == c) {
      _descending = !_descending;
    } else {
      _sort = c;
      // Text reads naturally ascending; figures are most useful largest first.
      _descending = _numeric.contains(c) && c != _Column.pid;
    }
  });

  List<ProcessInfo> _rows(StatsSnapshot? snap) {
    final query = _search.text.trim().toLowerCase();
    return [
      for (final p in snap?.processes ?? const <ProcessInfo>[])
        if (query.isEmpty ||
            '${p.pid}' == query ||
            p.command.toLowerCase().contains(query) ||
            p.name.toLowerCase().contains(query) ||
            (p.owner?.user.toLowerCase().contains(query) ?? false))
          p,
    ]..sort(_compare);
  }

  Future<void> _signal(ProcessInfo p, ProcessSignal signal) async {
    final l = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final ok = await showAppDialog<bool>(
      context: context,
      builder: (context) => AppDialog(
        content: Text(signal == ProcessSignal.term ? l.terminateConfirm(p.name, p.pid) : l.killConfirm(p.name, p.pid)),
        actions: [
          TextButton(autofocus: true, onPressed: () => Navigator.pop(context, false), child: Text(l.cancel)),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: scheme.error),
            onPressed: () => Navigator.pop(context, true),
            child: Text(signal == ProcessSignal.term ? l.terminateProcess : l.killProcess),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final result = await widget.monitor.signal(p.pid, signal);
    if (result case Err(:final error)) {
      messenger?.showSnackBar(
        SnackBar(content: Text(l.signalFailed(error.detail.isEmpty ? error.code : error.detail))),
      );
    }
  }

  Future<void> _menu(ProcessInfo p, Offset at) async {
    final l = AppLocalizations.of(context);
    setState(() => _selected = p.pid);
    final action = await showAppMenu<VoidCallback>(
      context: context,
      anchor: at & Size.zero,
      items: [
        AppMenuItem(
          value: () => Clipboard.setData(ClipboardData(text: '${p.pid}')),
          label: l.copyPid,
          icon: Icons.tag,
        ),
        AppMenuItem(
          value: () => Clipboard.setData(ClipboardData(text: p.command)),
          label: l.copyCommand,
          icon: Icons.content_copy,
        ),
        const AppMenuDivider(),
        AppMenuItem(
          value: () => _signal(p, ProcessSignal.term),
          label: l.terminateProcess,
          icon: Icons.stop_circle_outlined,
          destructive: true,
        ),
        AppMenuItem(
          value: () => _signal(p, ProcessSignal.kill),
          label: l.killProcess,
          icon: Icons.dangerous_outlined,
          destructive: true,
        ),
      ],
    );
    action?.call();
  }

  KeyEventResult _key(List<ProcessInfo> rows, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    final index = rows.indexWhere((p) => p.pid == _selected);
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowDown || key == LogicalKeyboardKey.arrowUp) {
      if (rows.isEmpty) return KeyEventResult.handled;
      final next = (index + (key == LogicalKeyboardKey.arrowDown ? 1 : -1)).clamp(0, rows.length - 1);
      setState(() => _selected = rows[next].pid);
      final offset = next * WorkspaceSize.treeRow;
      final view = _scroll.position.viewportDimension;
      if (offset < _scroll.offset) _scroll.jumpTo(offset);
      if (offset + WorkspaceSize.treeRow > _scroll.offset + view) _scroll.jumpTo(offset + WorkspaceSize.treeRow - view);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.delete && index >= 0) {
      _signal(rows[index], ProcessSignal.term);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final size = MediaQuery.sizeOf(context);
    return AppDialog(
      width: min(1100, size.width - 2 * Space.xl),
      icon: const Icon(Icons.view_list_outlined),
      title: Text(widget.monitor.host.title),
      content: SizedBox(
        height: max(320, size.height * .72),
        child: ListenableBuilder(
          listenable: widget.monitor,
          builder: (context, _) {
            final live = widget.monitor.snapshot;
            final snap = _paused ? (_frozen ??= live) : live;
            final rows = _rows(snap);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (snap != null) _Summary(snap: snap),
                const SizedBox(height: Space.md),
                _toolbar(l, rows.length),
                const SizedBox(height: Space.sm),
                Expanded(child: _table(l, rows)),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _table(AppLocalizations l, List<ProcessInfo> rows) => ScrollGutterLayout(
    builder: (context, constraints) {
      final gutter = ScrollGutterScope.gapOf(context);
      final available = max(0.0, constraints.maxWidth - gutter);
      final widths = {
        for (final c in _Column.values)
          c: (_widths[c] ?? _defaultWidths[c]!)
              .clamp(_minimumWidths[c]!, max(_minimumWidths[c]!, available))
              .toDouble(),
      };
      final fixed = widths.entries
          .where((entry) => entry.key != _Column.command)
          .fold(0.0, (sum, entry) => sum + entry.value);
      widths[_Column.command] = max(widths[_Column.command]!, available - fixed);
      final width = widths.values.fold(0.0, (sum, value) => sum + value) + gutter;
      final overflowing = width > constraints.maxWidth;
      final behavior = ScrollConfiguration.of(context);
      return Scrollbar(
        controller: _horizontal,
        thumbVisibility: overflowing,
        notificationPredicate: (notification) => notification.metrics.axis == Axis.horizontal,
        child: Padding(
          padding: EdgeInsets.only(bottom: overflowing ? Space.md : 0),
          child: ScrollConfiguration(
            behavior: behavior.copyWith(scrollbars: false),
            child: SingleChildScrollView(
              controller: _horizontal,
              scrollDirection: Axis.horizontal,
              child: ScrollConfiguration(
                behavior: behavior,
                child: SizedBox(
                  width: width,
                  height: constraints.maxHeight - (overflowing ? Space.md : 0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      ScrollGutter(child: _header(l, widths, available)),
                      Expanded(
                        child: Focus(
                          focusNode: _focus,
                          onKeyEvent: (_, event) => _key(rows, event),
                          child: ListView.builder(
                            controller: _scroll,
                            itemExtent: WorkspaceSize.treeRow,
                            itemCount: rows.length,
                            itemBuilder: (context, i) => _row(rows[i], widths),
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
      );
    },
  );

  void _resize(_Column column, double width, double available) => setState(() {
    _widths[column] = width.clamp(_minimumWidths[column]!, max(_minimumWidths[column]!, available)).toDouble();
  });

  Widget _toolbar(AppLocalizations l, int count) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Row(
      children: [
        SizedBox(
          width: 280,
          height: WorkspaceSize.control,
          child: TextField(
            controller: _search,
            autofocus: true,
            onChanged: (_) => setState(() {}),
            style: theme.textTheme.bodySmall,
            decoration: InputDecoration(
              isDense: true,
              hintText: l.searchProcesses,
              prefixIcon: const Icon(Icons.search, size: 16),
              prefixIconConstraints: const BoxConstraints(minWidth: 32),
            ),
          ),
        ),
        const SizedBox(width: Space.xs),
        IconButton(
          tooltip: _paused ? l.resume : l.pause,
          isSelected: _paused,
          onPressed: () => setState(() {
            _paused = !_paused;
            _frozen = null;
          }),
          icon: Icon(_paused ? Icons.play_arrow_rounded : Icons.pause_rounded, size: 18),
        ),
        const Spacer(),
        Text('$count', style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
        const SizedBox(width: Space.xs),
        IconButton(tooltip: l.close, onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close, size: 18)),
      ],
    );
  }

  Widget _header(AppLocalizations l, Map<_Column, double> widths, double available) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final style = theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant, fontWeight: FontWeight.w600);
    Widget cell(_Column c) {
      final active = c == _sort;
      final numeric = _numeric.contains(c);
      final label = Row(
        mainAxisAlignment: numeric ? MainAxisAlignment.end : MainAxisAlignment.start,
        children: [
          Flexible(
            child: Text(
              _label(l, c),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: active ? style?.copyWith(color: scheme.onSurface) : style,
            ),
          ),
          if (active) Icon(_descending ? Icons.arrow_downward : Icons.arrow_upward, size: 11, color: scheme.onSurface),
        ],
      );
      final button = InkWell(
        onTap: () => _sortBy(c),
        borderRadius: BorderRadius.circular(Radii.control),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Space.sm, vertical: Space.xs),
          child: label,
        ),
      );
      final width = widths[c]!;
      const step = Space.sm;
      double clamp(double value) => value.clamp(_minimumWidths[c]!, max(_minimumWidths[c]!, available)).toDouble();
      return SizedBox(
        key: ValueKey('process-header-${c.name}'),
        width: width,
        child: Stack(
          children: [
            button,
            Positioned(
              top: 0,
              bottom: 0,
              right: 0,
              width: WorkspaceSize.dividerGrab,
              child: Semantics(
                label: _label(l, c),
                value: '${width.round()}',
                increasedValue: '${clamp(width + step).round()}',
                decreasedValue: '${clamp(width - step).round()}',
                onIncrease: () => _resize(c, width + step, available),
                onDecrease: () => _resize(c, width - step, available),
                child: MouseRegion(
                  cursor: SystemMouseCursors.resizeColumn,
                  child: Focus(
                    onKeyEvent: (_, event) {
                      if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
                      if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
                        _resize(c, width + step, available);
                        return KeyEventResult.handled;
                      }
                      if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
                        _resize(c, width - step, available);
                        return KeyEventResult.handled;
                      }
                      return KeyEventResult.ignored;
                    },
                    child: Builder(
                      builder: (context) {
                        final focused = Focus.of(context).hasFocus;
                        return GestureDetector(
                          key: ValueKey('process-resize-${c.name}'),
                          behavior: HitTestBehavior.opaque,
                          onTapDown: (_) => Focus.of(context).requestFocus(),
                          onDoubleTap: () => setState(() => _widths.remove(c)),
                          onHorizontalDragStart: (_) {
                            Focus.of(context).requestFocus();
                            _dragWidth = width;
                          },
                          onHorizontalDragUpdate: (details) {
                            _dragWidth = clamp((_dragWidth ?? width) + details.delta.dx);
                            _resize(c, _dragWidth!, available);
                          },
                          onHorizontalDragEnd: (_) => _dragWidth = null,
                          onHorizontalDragCancel: () => _dragWidth = null,
                          child: Center(
                            child: ColoredBox(
                              color: focused ? scheme.primary : scheme.outlineVariant,
                              child: const SizedBox(width: WorkspaceSize.divider, height: Space.lg),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }

    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Row(children: [for (final c in _Column.values) cell(c)]),
    );
  }

  Widget _row(ProcessInfo p, Map<_Column, double> widths) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final style = theme.textTheme.bodySmall?.copyWith(fontFeatures: tabular);
    final hot = (p.cpu ?? 0) >= .5;
    Widget cell(_Column c, String text, {Color? color}) {
      final child = Padding(
        padding: const EdgeInsets.symmetric(horizontal: Space.sm),
        child: Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: _numeric.contains(c) ? TextAlign.right : TextAlign.left,
          style: color == null ? style : style?.copyWith(color: color),
        ),
      );
      return SizedBox(key: ValueKey('process-cell-${p.pid}-${c.name}'), width: widths[c], child: child);
    }

    final selected = p.pid == _selected;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        setState(() => _selected = p.pid);
        _focus.requestFocus();
      },
      onSecondaryTapUp: (d) => _menu(p, d.globalPosition),
      child: Container(
        decoration: BoxDecoration(
          color: selected ? scheme.primary.withValues(alpha: .14) : null,
          borderRadius: BorderRadius.circular(Radii.control),
        ),
        child: Row(
          children: [
            cell(_Column.pid, '${p.pid}', color: scheme.onSurfaceVariant),
            cell(_Column.user, p.owner?.user ?? ''),
            cell(_Column.cpu, formatCpu(p.cpu), color: hot ? scheme.error : null),
            cell(_Column.memory, (p.memory * 100).toStringAsFixed(1)),
            cell(_Column.resident, formatShortBytes(p.residentBytes)),
            cell(_Column.state, p.stat.state, color: scheme.onSurfaceVariant),
            cell(_Column.threads, '${p.stat.threads}'),
            cell(_Column.elapsed, formatElapsed(p.elapsed), color: scheme.onSurfaceVariant),
            cell(_Column.command, p.command),
          ],
        ),
      ),
    );
  }
}

/// htop's header: a bar per core, then memory, swap, tasks and load.
class _Summary extends StatelessWidget {
  const _Summary({required this.snap});

  final StatsSnapshot snap;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final s = snap.sample;
    final muted = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant, fontFeatures: tabular);
    Widget meter(String label, double fraction, String figure, Color color) => Row(
      children: [
        SizedBox(
          width: 40,
          child: Text(label, style: muted, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
        Expanded(child: MonitorBar(fraction, color: color, height: 6)),
        SizedBox(
          width: 96,
          child: Text(figure, style: muted, textAlign: TextAlign.right, maxLines: 1),
        ),
      ],
    );
    final cores = snap.coreUsage;
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = max(1, min(4, (constraints.maxWidth / 240).floor()));
        final cell = (constraints.maxWidth - (columns - 1) * Space.lg) / columns;
        String kib(int used, int total) => '${formatShortBytes(used * 1024)}/${formatShortBytes(total * 1024)}';
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: Space.lg,
              runSpacing: 3,
              children: [
                for (final (i, f) in cores.indexed)
                  SizedBox(width: cell, child: meter('$i', f, formatPercent(f), scheme.primary)),
              ],
            ),
            if (cores.isNotEmpty) const SizedBox(height: Space.sm),
            Wrap(
              spacing: Space.lg,
              runSpacing: 3,
              children: [
                SizedBox(
                  width: cell,
                  child: meter(
                    l.memory,
                    snap.memory,
                    kib(s.memTotalKib - s.memAvailableKib, s.memTotalKib),
                    scheme.secondary,
                  ),
                ),
                if (s.swapTotalKib > 0)
                  SizedBox(
                    width: cell,
                    child: meter(
                      l.swap,
                      snap.swap,
                      kib(s.swapTotalKib - s.swapFreeKib, s.swapTotalKib),
                      scheme.tertiary,
                    ),
                  ),
                SizedBox(
                  width: cell,
                  child: Text(
                    [
                      if (s.tasks != null) l.tasks(s.tasks!),
                      if (s.load.isNotEmpty) '${l.load} ${s.load.map((v) => v.toStringAsFixed(2)).join(' ')}',
                    ].join(' · '),
                    style: muted,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

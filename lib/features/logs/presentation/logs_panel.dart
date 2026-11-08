import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../design/select.dart';
import '../../../design/theme.dart';
import '../../../foundation/diagnostics.dart';
import '../../../l10n/app_localizations.dart';

class LogsPanel extends ConsumerStatefulWidget {
  const LogsPanel({super.key});

  @override
  ConsumerState<LogsPanel> createState() => _LogsPanelState();
}

class _LogsPanelState extends ConsumerState<LogsPanel> {
  late final DiagnosticLog _log;
  StreamSubscription<void>? _subscription;
  Timer? _timer;
  var _snapshot = const DiagnosticSnapshot([]);
  DiagnosticRecord? _selected;
  DiagnosticArea? _area;
  DiagnosticOutcome? _outcome;
  var _paused = false, _reading = false, _loading = true, _failed = false, _dirty = false;
  var _epoch = 0;

  @override
  void initState() {
    super.initState();
    _log = ref.read(diagnosticLogProvider);
    _subscription = _log.changes.listen((_) => _changed());
    _load();
  }

  @override
  void dispose() {
    _epoch++;
    _timer?.cancel();
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  void _changed() {
    if (_paused || !mounted) return;
    _dirty = true;
    _timer ??= Timer(const Duration(milliseconds: 80), () {
      _timer = null;
      _load();
    });
  }

  Future<void> _load() async {
    _timer?.cancel();
    _timer = null;
    if (_reading) {
      _dirty = true;
      return;
    }
    _reading = true;
    _dirty = false;
    final epoch = _epoch;
    try {
      final snapshot = await _log.readRecent();
      if (!mounted || epoch != _epoch) return;
      setState(() {
        _snapshot = snapshot;
        final previous = _selected?.text;
        _selected = snapshot.records.where((record) => record.text == previous).firstOrNull;
        _failed = false;
      });
    } on Object {
      if (mounted && epoch == _epoch) setState(() => _failed = true);
    } finally {
      _reading = false;
      if (mounted) {
        setState(() => _loading = false);
        if (_dirty && !_paused) _changed();
      }
    }
  }

  void _pause() {
    setState(() {
      _paused = !_paused;
      _epoch++;
      _timer?.cancel();
      _timer = null;
    });
    if (!_paused) _load();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final rows = [
      for (final record in _snapshot.records)
        if ((_area == null || record.area == _area) && (_outcome == null || record.outcome == _outcome)) record,
    ];
    final selected = rows.contains(_selected) ? _selected : null;
    final notices = [
      if (!_log.enabled) l.logDisabled,
      if (_log.failed) l.logWriterFailed,
      if (_failed) l.logReadFailed,
      if (_snapshot.skipped > 0) l.logSkipped(_snapshot.skipped),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: Text(l.logs, style: theme.textTheme.titleMedium)),
            Text('${rows.length}', style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
            IconButton(
              tooltip: _paused ? l.resume : l.pause,
              onPressed: _pause,
              icon: Icon(_paused ? Icons.play_arrow_rounded : Icons.pause_rounded, size: 18),
            ),
            IconButton(tooltip: l.refresh, onPressed: _load, icon: const Icon(Icons.refresh, size: 18)),
            IconButton(
              tooltip: l.logCopyRecord,
              onPressed: selected == null ? null : () => Clipboard.setData(ClipboardData(text: selected.text)),
              icon: const Icon(Icons.copy_rounded, size: 16),
            ),
            IconButton(tooltip: l.closePane, onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close)),
          ],
        ),
        const SizedBox(height: Space.sm),
        Row(
          children: [
            Expanded(
              child: AppSelect<DiagnosticArea?>(
                label: l.logArea,
                value: _area,
                options: [
                  AppOption(null, l.logAllAreas),
                  for (final area in DiagnosticArea.values) AppOption(area, _areaLabel(l, area)),
                ],
                onChanged: (area) => setState(() => _area = area),
              ),
            ),
            const SizedBox(width: Space.sm),
            Expanded(
              child: AppSelect<DiagnosticOutcome?>(
                label: l.logOutcome,
                value: _outcome,
                options: [
                  AppOption(null, l.logAllOutcomes),
                  for (final outcome in DiagnosticOutcome.values) AppOption(outcome, _outcomeLabel(l, outcome)),
                ],
                onChanged: (outcome) => setState(() => _outcome = outcome),
              ),
            ),
          ],
        ),
        for (final notice in notices)
          Padding(
            padding: const EdgeInsets.only(top: Space.sm),
            child: Text(notice, style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
          ),
        const SizedBox(height: Space.sm),
        Expanded(
          child: _loading
              ? const Center(child: SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)))
              : rows.isEmpty
              ? Center(child: Text(l.logEmpty, style: theme.textTheme.bodySmall))
              : ListView.builder(itemCount: rows.length, itemBuilder: (context, index) => _row(rows[index], l)),
        ),
      ],
    );
  }

  Widget _row(DiagnosticRecord record, AppLocalizations l) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final time = record.time.toLocal();
    String pair(int number) => number.toString().padLeft(2, '0');
    final stamp =
        '${MaterialLocalizations.of(context).formatShortDate(time)} '
        '${pair(time.hour)}:${pair(time.minute)}:${pair(time.second)}';
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.xs),
      child: Material(
        color: identical(_selected, record) ? scheme.primaryContainer : scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(Radii.control),
        child: InkWell(
          borderRadius: BorderRadius.circular(Radii.control),
          onTap: () => setState(() => _selected = record),
          child: Padding(
            padding: const EdgeInsets.all(Space.sm),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(child: Text(_areaLabel(l, record.area), style: theme.textTheme.labelMedium)),
                    Text(stamp, style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                  ],
                ),
                const SizedBox(height: Space.xs),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${_actionLabel(l, record.action)} · ${_outcomeLabel(l, record.outcome)}',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                    if (record.elapsedMilliseconds case final elapsed?)
                      Text(l.logElapsed(elapsed), style: theme.textTheme.bodySmall),
                  ],
                ),
                if (record.dropped > 0)
                  Text(l.logDropped(record.dropped), style: theme.textTheme.bodySmall?.copyWith(color: scheme.error)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

String _areaLabel(AppLocalizations l, DiagnosticArea area) => switch (area) {
  DiagnosticArea.application => l.logAreaApplication,
  DiagnosticArea.connection => l.logAreaConnection,
  DiagnosticArea.transfer => l.logAreaTransfer,
  DiagnosticArea.configuration => l.logAreaConfiguration,
};

String _outcomeLabel(AppLocalizations l, DiagnosticOutcome outcome) => switch (outcome) {
  DiagnosticOutcome.started => l.logOutcomeStarted,
  DiagnosticOutcome.succeeded => l.logOutcomeSucceeded,
  DiagnosticOutcome.failed => l.logOutcomeFailed,
  DiagnosticOutcome.cancelled => l.logOutcomeCancelled,
  DiagnosticOutcome.interrupted => l.logOutcomeInterrupted,
};

String _actionLabel(AppLocalizations l, DiagnosticAction action) => switch (action) {
  DiagnosticAction.start => l.logActionStart,
  DiagnosticAction.dial => l.logActionDial,
  DiagnosticAction.copy => l.logActionCopy,
  DiagnosticAction.pause => l.logActionPause,
  DiagnosticAction.cancel => l.logActionCancel,
  DiagnosticAction.read => l.logActionRead,
  DiagnosticAction.write => l.logActionWrite,
  DiagnosticAction.recover => l.logActionRecover,
  DiagnosticAction.uncaught => l.logActionUncaught,
  DiagnosticAction.shutdown => l.logActionShutdown,
};

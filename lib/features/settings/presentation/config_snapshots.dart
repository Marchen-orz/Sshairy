import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../design/dialog.dart';
import '../../../design/select.dart';
import '../../../design/theme.dart';
import '../../../foundation/diagnostics.dart';
import '../../../foundation/json_file.dart';
import '../../../l10n/app_localizations.dart';

/// A configuration file the user may roll back from settings; [reset] reloads its owner after a restore.
class ConfigStore {
  const ConfigStore(this.label, this.file, this.reset);

  final String Function(AppLocalizations l) label;
  final JsonFile Function() file;
  final VoidCallback reset;
}

/// Settings cannot import the features owning these files, so the app wires them in.
final configStoresProvider = Provider<List<ConfigStore>>((_) => const []);

/// Lists valid snapshots of [stores] and restores the picked one; pops with the restored store, or null.
class ConfigSnapshotDialog extends ConsumerStatefulWidget {
  const ConfigSnapshotDialog(this.stores, {super.key});

  final List<({String label, JsonFile file})> stores;

  @override
  ConsumerState<ConfigSnapshotDialog> createState() => _ConfigSnapshotDialogState();
}

class _ConfigSnapshotDialogState extends ConsumerState<ConfigSnapshotDialog> {
  var _store = 0;
  List<JsonSnapshot> _snapshots = const [];
  JsonSnapshot? _selected;
  bool _busy = false, _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    _selected = null;
    _failed = false;
    try {
      _snapshots = widget.stores[_store].file.availableSnapshots();
    } on Object {
      _snapshots = const [];
      _failed = true;
    }
  }

  Future<void> _restore() async {
    final selected = _selected;
    if (selected == null || _busy) return;
    setState(() {
      _busy = true;
      _failed = false;
    });
    final log = ref.read(diagnosticLogProvider);
    try {
      await widget.stores[_store].file.restore(selected);
      log.record(DiagnosticArea.configuration, DiagnosticAction.recover, DiagnosticOutcome.succeeded);
      if (mounted) Navigator.of(context).pop(_store);
    } on Object {
      log.record(DiagnosticArea.configuration, DiagnosticAction.recover, DiagnosticOutcome.failed);
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final dates = MaterialLocalizations.of(context);
    return PopScope(
      canPop: !_busy,
      child: AppDialog(
        width: 488,
        title: Text(l.configRestoreSnapshots),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.stores.length > 1) ...[
              AppSelect<int>(
                value: _store,
                options: [for (var i = 0; i < widget.stores.length; i++) AppOption(i, widget.stores[i].label)],
                onChanged: _busy
                    ? null
                    : (i) => setState(() {
                        _store = i;
                        _load();
                      }),
              ),
              const SizedBox(height: Space.md),
            ],
            if (_snapshots.isEmpty) Text(l.configNoSnapshots),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final snapshot in _snapshots)
                    ListTile(
                      selected: identical(_selected, snapshot),
                      leading: Icon(
                        identical(_selected, snapshot) ? Icons.radio_button_checked : Icons.radio_button_off,
                      ),
                      title: Text(l.configSnapshotRevision(snapshot.revision)),
                      subtitle: Text(
                        '${dates.formatMediumDate(snapshot.created)} '
                        '${dates.formatTimeOfDay(TimeOfDay.fromDateTime(snapshot.created))}',
                      ),
                      onTap: _busy ? null : () => setState(() => _selected = snapshot),
                    ),
                ],
              ),
            ),
            if (_failed) ...[
              const SizedBox(height: Space.md),
              Text(l.configRestoreFailed, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
          ],
        ),
        actions: [
          TextButton(onPressed: _busy ? null : () => Navigator.of(context).pop(), child: Text(l.cancel)),
          FilledButton(onPressed: _selected == null || _busy ? null : _restore, child: Text(l.configRestore)),
        ],
      ),
    );
  }
}

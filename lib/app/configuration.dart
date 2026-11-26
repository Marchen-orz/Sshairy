import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderException;

import '../design/dialog.dart';
import '../design/theme.dart';
import '../features/connections/api.dart';
import '../features/credentials/api.dart';
import '../features/files/api.dart';
import '../features/forwarding/api.dart';
import '../features/hosts/api.dart';
import '../features/settings/api.dart';
import '../features/snippets/api.dart';
import '../features/terminal/api.dart';
import '../features/workspace/api.dart';
import '../foundation/data_dir.dart';
import '../foundation/diagnostics.dart';
import '../foundation/json_file.dart';
import '../foundation/open_external.dart';
import '../l10n/app_localizations.dart';

class ConfigurationIssue {
  const ConfigurationIssue(this.file, this.retry, {this.recovery});
  final String file;
  final VoidCallback retry;
  final JsonFile? recovery;
}

/// Read each persisted model before showing any workflow that could change it. Failed reads remain protected by
/// JsonFile; the error page offers repair/retry, never an implicit new empty library.
final configurationCheckProvider = Provider<ConfigurationIssue?>((ref) {
  final checks = [
    (name: 'settings.json', load: () => ref.read(settingsProvider), reset: () => ref.invalidate(settingsProvider)),
    (name: 'keys.json', load: () => ref.read(keysProvider), reset: () => ref.invalidate(keysProvider)),
    (name: 'hosts.json', load: () => ref.read(hostsProvider), reset: () => ref.invalidate(hostsProvider)),
    (name: 'trust.json', load: () => ref.read(hostTrustProvider), reset: () => ref.invalidate(hostTrustProvider)),
    (name: 'snippets.json', load: () => ref.read(snippetsProvider), reset: () => ref.invalidate(snippetsProvider)),
    (
      name: 'local_terminals.json',
      load: () => ref.read(localProfilesProvider),
      reset: () => ref.invalidate(localProfilesProvider),
    ),
    (name: 'forwards.json', load: () => ref.read(forwardsProvider), reset: () => ref.invalidate(forwardsProvider)),
    (name: 'transfers.json', load: () => ref.read(transfersProvider), reset: () => ref.invalidate(transfersProvider)),
    (name: 'edits.json', load: () => ref.read(editsProvider), reset: () => ref.invalidate(editsProvider)),
    (name: 'workspace.json', load: () => ref.read(workspaceProvider), reset: () => ref.invalidate(workspaceProvider)),
  ];
  for (final check in checks) {
    try {
      check.load();
    } on Object catch (error) {
      var cause = error;
      while (cause is ProviderException) {
        cause = cause.exception;
      }
      return ConfigurationIssue(check.name, () {
        check.reset();
        ref.invalidateSelf();
      }, recovery: cause is JsonFileError ? cause.recovery : null);
    }
  }
  return null;
});

class ConfigurationErrorPage extends ConsumerWidget {
  const ConfigurationErrorPage(this.issue, {super.key});
  final ConfigurationIssue issue;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(Space.xl),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l.configUnavailable(issue.file), style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: Space.md),
                Text(l.configPreserved),
                const SizedBox(height: Space.xl),
                Wrap(
                  spacing: Space.sm,
                  runSpacing: Space.sm,
                  children: [
                    FilledButton(onPressed: issue.retry, child: Text(l.retryAction)),
                    if (issue.recovery case final storage?)
                      TextButton(
                        onPressed: () async {
                          final restored = await showAppDialog<bool>(
                            context: context,
                            barrierDismissible: false,
                            builder: (_) => _SnapshotDialog(storage),
                          );
                          if (restored == true && context.mounted) issue.retry();
                        },
                        child: Text(l.configRestoreSnapshots),
                      ),
                    TextButton(onPressed: () => openExternal(ref.read(dataDirProvider)), child: Text(l.openDataFolder)),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SnapshotDialog extends ConsumerStatefulWidget {
  const _SnapshotDialog(this.storage);
  final JsonFile storage;

  @override
  ConsumerState<_SnapshotDialog> createState() => _SnapshotDialogState();
}

class _SnapshotDialogState extends ConsumerState<_SnapshotDialog> {
  List<JsonSnapshot> _snapshots = const [];
  JsonSnapshot? _selected;
  bool _busy = false, _failed = false;

  @override
  void initState() {
    super.initState();
    try {
      _snapshots = widget.storage.availableSnapshots();
    } on Object {
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
      await widget.storage.restore(selected);
      log.record(DiagnosticArea.configuration, DiagnosticAction.recover, DiagnosticOutcome.succeeded);
      if (mounted) Navigator.of(context).pop(true);
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
          children: [
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
          TextButton(onPressed: _busy ? null : () => Navigator.of(context).pop(false), child: Text(l.cancel)),
          FilledButton(onPressed: _selected == null || _busy ? null : _restore, child: Text(l.configRestore)),
        ],
      ),
    );
  }
}

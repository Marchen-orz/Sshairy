import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/theme.dart';
import '../features/connections/api.dart';
import '../features/credentials/api.dart';
import '../features/files/api.dart';
import '../features/forwarding/api.dart';
import '../features/hosts/api.dart';
import '../features/settings/api.dart';
import '../features/snippets/api.dart';
import '../features/workspace/api.dart';
import '../foundation/data_dir.dart';
import '../foundation/open_external.dart';
import '../l10n/app_localizations.dart';

class ConfigurationIssue {
  const ConfigurationIssue(this.file, this.retry);
  final String file;
  final VoidCallback retry;
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
    (name: 'forwards.json', load: () => ref.read(forwardsProvider), reset: () => ref.invalidate(forwardsProvider)),
    (name: 'transfers.json', load: () => ref.read(transfersProvider), reset: () => ref.invalidate(transfersProvider)),
    (name: 'edits.json', load: () => ref.read(editsProvider), reset: () => ref.invalidate(editsProvider)),
    (name: 'workspace.json', load: () => ref.read(workspaceProvider), reset: () => ref.invalidate(workspaceProvider)),
  ];
  for (final check in checks) {
    try {
      check.load();
    } on Object {
      return ConfigurationIssue(check.name, () {
        check.reset();
        ref.invalidateSelf();
      });
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

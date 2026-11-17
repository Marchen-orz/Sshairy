import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../design/dialog.dart';
import '../../../design/theme.dart';
import '../../../foundation/open_external.dart';
import '../../../l10n/app_localizations.dart';
import '../application/updates.dart';

/// Checks the project's published releases on demand; nothing is fetched until the user asks.
class UpdateCheckControl extends ConsumerWidget {
  const UpdateCheckControl({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final state = ref.watch(updateCheckProvider);
    final status = switch (state.status) {
      UpdateStatus.idle => null,
      UpdateStatus.checking => l.checkingForUpdates,
      UpdateStatus.upToDate => l.upToDate,
      UpdateStatus.available => l.updateAvailable(state.latest!.version),
      UpdateStatus.failed => l.updateFailed,
    };
    return Wrap(
      spacing: Space.sm,
      runSpacing: Space.sm,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (status != null)
          Text(
            status,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: state.status == UpdateStatus.failed ? theme.colorScheme.error : null,
            ),
          ),
        if (state.status == UpdateStatus.available)
          FilledButton(onPressed: () => _notes(context, state), child: Text(l.releaseNotes))
        else
          TextButton(
            onPressed: state.status == UpdateStatus.checking
                ? null
                : () => ref.read(updateCheckProvider.notifier).check(),
            child: Text(l.checkForUpdates),
          ),
      ],
    );
  }

  void _notes(BuildContext context, UpdateState state) {
    showAppDialog<void>(
      context: context,
      builder: (context) {
        final l = AppLocalizations.of(context);
        final theme = Theme.of(context);
        return AppDialog(
          width: 520,
          title: Text(l.releaseNotes),
          content: SizedBox(
            height: 360,
            child: ListView.separated(
              itemCount: state.releases.length,
              separatorBuilder: (_, _) => const Divider(height: Space.xl),
              itemBuilder: (context, index) {
                final release = state.releases[index];
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${release.version} · ${release.title}', style: theme.textTheme.titleSmall),
                    if (release.notes.isNotEmpty) ...[const SizedBox(height: Space.xs), SelectableText(release.notes)],
                  ],
                );
              },
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.maybePop(context), child: Text(l.close)),
            FilledButton(
              onPressed: () {
                openExternal(state.latest!.url);
                Navigator.maybePop(context);
              },
              child: Text(l.openReleasePage),
            ),
          ],
        );
      },
    );
  }
}

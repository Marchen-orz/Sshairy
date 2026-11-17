import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../design/dialog.dart';
import '../../../design/theme.dart';
import '../../../foundation/open_external.dart';
import '../../../l10n/app_localizations.dart';
import '../application/updates.dart';

/// Checks the published releases once at start-up and, when one is newer, shows its notes.
class StartupUpdatePrompt extends ConsumerStatefulWidget {
  const StartupUpdatePrompt({super.key, required this.child, this.enabled = true});

  final Widget child;

  /// Tests and probes measure their own frames, so they keep the network and the dialog out of start-up.
  final bool enabled;

  @override
  ConsumerState<StartupUpdatePrompt> createState() => _StartupUpdatePromptState();
}

class _StartupUpdatePromptState extends ConsumerState<StartupUpdatePrompt> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
  }

  Future<void> _check() async {
    if (!mounted || !widget.enabled) return;
    await ref.read(updateCheckProvider.notifier).check();
    if (!mounted) return;
    final state = ref.read(updateCheckProvider);
    if (state.status == UpdateStatus.available) await showReleaseNotes(context, state);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

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
          FilledButton(onPressed: () => showReleaseNotes(context, state), child: Text(l.releaseNotes))
        else
          TextButton(
            onPressed: state.status == UpdateStatus.checking
                ? null
                : () => ref.read(updateCheckProvider.notifier).check(),
            child: Text(l.checkForUpdates),
          ),
        if (state.status != UpdateStatus.available)
          TextButton(onPressed: () => _showNotes(context, ref), child: Text(l.releaseNotes)),
      ],
    );
  }

  /// Release notes stay reachable whether or not there is an update; the first look fetches them.
  Future<void> _showNotes(BuildContext context, WidgetRef ref) async {
    var state = ref.read(updateCheckProvider);
    if (state.releases.isEmpty) {
      await ref.read(updateCheckProvider.notifier).check();
      if (!context.mounted) return;
      state = ref.read(updateCheckProvider);
    }
    if (state.releases.isEmpty) return;
    if (context.mounted) await showReleaseNotes(context, state);
  }
}

Future<void> showReleaseNotes(BuildContext context, UpdateState state) {
  final latest = state.latest;
  if (latest == null) return Future.value();
  return showAppDialog<void>(
    context: context,
    builder: (context) {
      final l = AppLocalizations.of(context);
      final theme = Theme.of(context);
      return AppDialog(
        width: 520,
        title: Text(state.status == UpdateStatus.available ? l.updateAvailable(latest.version) : l.releaseNotes),
        content: SizedBox(
          height: 360,
          child: ListView.separated(
            itemCount: state.releases.length,
            separatorBuilder: (_, _) => const Divider(height: Space.xl),
            itemBuilder: (context, index) {
              final release = state.releases[index];
              final notes = releaseNotesFor(release.notes, Localizations.localeOf(context).languageCode);
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${release.version} · ${release.title}', style: theme.textTheme.titleSmall),
                  if (notes.isNotEmpty) ...[const SizedBox(height: Space.xs), _ReleaseNotes(notes)],
                ],
              );
            },
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.maybePop(context), child: Text(l.close)),
          FilledButton(
            onPressed: () {
              openExternal(latest.url);
              Navigator.maybePop(context);
            },
            child: Text(l.openReleasePage),
          ),
        ],
      );
    },
  );
}

/// Release bodies are Markdown, and the dialog stacks several of them, so the type stays compact.
class _ReleaseNotes extends StatelessWidget {
  const _ReleaseNotes(this.data);

  final String data;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final text = theme.textTheme.bodySmall;
    final codeTint = scheme.primary.withValues(alpha: .18);
    return MarkdownBody(
      data: data,
      selectable: true,
      fitContent: false,
      styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(
        p: text,
        h1: theme.textTheme.titleSmall,
        h2: theme.textTheme.titleSmall,
        h3: theme.textTheme.labelLarge,
        h4: theme.textTheme.labelLarge,
        h5: theme.textTheme.labelMedium,
        h6: theme.textTheme.labelMedium,
        a: text?.copyWith(color: scheme.primary, decoration: TextDecoration.underline),
        listBullet: text,
        // Selection is painted before text backgrounds, so this fill must stay translucent.
        code: mono(context, text).copyWith(backgroundColor: codeTint),
        blockSpacing: Space.xs,
        listIndent: Space.md,
        listBulletPadding: const EdgeInsets.only(right: Space.xs),
        horizontalRuleDecoration: BoxDecoration(
          border: Border(top: BorderSide(color: scheme.outlineVariant)),
        ),
      ),
      imageBuilder: (_, _, alt) => Text(alt ?? '', style: text?.copyWith(color: scheme.onSurfaceVariant)),
      onTapLink: (_, href, _) {
        final uri = href == null ? null : Uri.tryParse(href);
        if (uri == null ||
            !const {'http', 'https'}.contains(uri.scheme) ||
            uri.host.isEmpty ||
            uri.userInfo.isNotEmpty) {
          return;
        }
        unawaited(openExternal(uri.toString()));
      },
    );
  }
}

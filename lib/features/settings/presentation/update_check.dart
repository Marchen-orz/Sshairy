import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../design/dialog.dart';
import '../../../design/theme.dart';
import '../../../foundation/open_external.dart';
import '../../../l10n/app_localizations.dart';
import '../../../platform/desktop_window.dart';
import '../adapters/release_notes_view.dart';
import '../application/update_download.dart';
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
    if (state.status == UpdateStatus.available) {
      await showReleaseNotes(context, state);
    }
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
    builder: (context) => _ReleaseNotesDialog(
      latest: latest,
      releases: state.releases,
      available: state.status == UpdateStatus.available,
    ),
  );
}

class _ReleaseNotesDialog extends ConsumerStatefulWidget {
  const _ReleaseNotesDialog({required this.latest, required this.releases, required this.available});

  final ReleaseNote latest;
  final List<ReleaseNote> releases;
  final bool available;

  @override
  ConsumerState<_ReleaseNotesDialog> createState() => _ReleaseNotesDialogState();
}

class _ReleaseNotesDialogState extends ConsumerState<_ReleaseNotesDialog> {
  UpdateDownloader? _downloader;
  UpdateDownloadState _download = const UpdateDownloadState.idle();
  ReleaseAsset? _asset;

  @override
  void initState() {
    super.initState();
    if (widget.available) {
      _asset = UpdateDelivery.current().assetFor(widget.latest.assets);
    }
  }

  @override
  void dispose() {
    _downloader?.cancel();
    super.dispose();
  }

  Future<void> _startDownload() async {
    final asset = _asset;
    if (asset == null || _downloader != null) return;
    final downloader = _downloader = ref.read(updateDownloaderProvider)();
    setState(() => _download = const UpdateDownloadState(UpdateDownloadStatus.downloading));
    try {
      await downloader.download(
        widget.latest,
        asset: asset,
        onProgress: (state) {
          if (mounted && identical(_downloader, downloader)) {
            setState(() => _download = state);
          }
        },
      );
    } on UpdateDownloadCancelled {
      if (mounted && identical(_downloader, downloader)) {
        setState(() => _download = const UpdateDownloadState.idle());
      }
    } on Object {
      if (mounted && identical(_downloader, downloader)) {
        setState(() => _download = const UpdateDownloadState(UpdateDownloadStatus.failed));
      }
    } finally {
      if (identical(_downloader, downloader)) _downloader = null;
    }
  }

  void _cancelDownload() {
    _downloader?.cancel();
    setState(() => _download = const UpdateDownloadState.idle());
  }

  Future<void> _install() async {
    final path = _download.path;
    if (path == null) return;
    await DesktopWindow.instance.installAndQuit(path);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final latest = widget.latest;
    final status = _download.status;
    final asset = _asset;
    return AppDialog(
      width: 520,
      title: Text(widget.available ? l.updateAvailable(latest.version) : l.releaseNotes),
      content: SizedBox(
        height: 360,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.available && asset == null) ...[
              Text(l.updateNoPackage, style: theme.textTheme.bodySmall),
              const SizedBox(height: Space.md),
            ],
            if (status != UpdateDownloadStatus.idle) ...[
              _DownloadStatus(download: _download),
              const SizedBox(height: Space.md),
            ],
            Expanded(
              child: ListView.separated(
                itemCount: widget.releases.length,
                separatorBuilder: (_, _) => const Divider(height: Space.xl),
                itemBuilder: (context, index) {
                  final release = widget.releases[index];
                  final notes = releaseNotesFor(release.notes, Localizations.localeOf(context).languageCode);
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${release.version} · ${release.title}', style: theme.textTheme.titleSmall),
                      if (notes.isNotEmpty) ...[const SizedBox(height: Space.xs), ReleaseNotesView(notes)],
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.maybePop(context),
          child: Text(status == UpdateDownloadStatus.ready ? l.later : l.close),
        ),
        TextButton(
          onPressed: () {
            openExternal(latest.url);
            Navigator.maybePop(context);
          },
          child: Text(l.openReleasePage),
        ),
        if (widget.available && asset != null) ...[
          if (status == UpdateDownloadStatus.ready)
            FilledButton(onPressed: _install, child: Text(l.installNow))
          else if (status == UpdateDownloadStatus.failed)
            FilledButton(onPressed: _startDownload, child: Text(l.retryAction))
          else if (status == UpdateDownloadStatus.downloading || status == UpdateDownloadStatus.verifying)
            TextButton(onPressed: _cancelDownload, child: Text(l.cancelDownload))
          else
            FilledButton(onPressed: _startDownload, child: Text(l.updateDownload)),
        ],
      ],
    );
  }
}

class _DownloadStatus extends StatelessWidget {
  const _DownloadStatus({required this.download});

  final UpdateDownloadState download;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final text = theme.textTheme.bodySmall;
    final percent = download.progress == null ? null : (download.progress! * 100).round();
    return switch (download.status) {
      UpdateDownloadStatus.downloading => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: Text(l.updateDownloading, style: text)),
              if (percent != null) Text('$percent%', style: text),
            ],
          ),
          const SizedBox(height: Space.xs),
          LinearProgressIndicator(value: download.progress, minHeight: 4),
        ],
      ),
      UpdateDownloadStatus.verifying => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l.updateVerifying, style: text),
          const SizedBox(height: Space.xs),
          const LinearProgressIndicator(minHeight: 4),
        ],
      ),
      UpdateDownloadStatus.ready => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SelectableText(l.updateDownloaded(download.path ?? ''), style: text),
          const SizedBox(height: Space.xs),
          Text(l.updateInstallPrompt, style: text),
        ],
      ),
      UpdateDownloadStatus.failed => Text(
        l.updateDownloadFailed,
        style: text?.copyWith(color: theme.colorScheme.error),
      ),
      UpdateDownloadStatus.idle => const SizedBox.shrink(),
    };
  }
}

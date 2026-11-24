import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../design/dialog.dart';
import '../../../design/theme.dart';
import '../../../foundation/open_external.dart';
import '../../../l10n/app_localizations.dart';
import '../../../platform/desktop_window.dart';
import '../../../platform/mobile_platform.dart';
import '../adapters/release_notes_view.dart';
import '../application/update_download.dart';
import '../application/updates.dart';

const runtimeUpdateInterval = Duration(minutes: 30);

/// Checks the published releases once at start-up and, when one is newer, shows its notes.
/// While the app stays open it looks again every [interval]; later looks stay quiet.
class StartupUpdatePrompt extends ConsumerStatefulWidget {
  const StartupUpdatePrompt({
    super.key,
    required this.child,
    this.enabled = true,
    this.interval = runtimeUpdateInterval,
  });

  final Widget child;

  /// Tests and probes measure their own frames, so they keep the network and the dialog out of start-up.
  final bool enabled;

  final Duration interval;

  @override
  ConsumerState<StartupUpdatePrompt> createState() => _StartupUpdatePromptState();
}

class _StartupUpdatePromptState extends ConsumerState<StartupUpdatePrompt> {
  Timer? _timer;
  StreamSubscription<void>? _offers;
  StreamSubscription<void>? _pushes;
  StreamSubscription<PeerUpdate>? _peerUpdates;
  final _prompted = <String>{};
  var _showingUpdate = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  @override
  void dispose() {
    _timer?.cancel();
    unawaited(_offers?.cancel());
    unawaited(_pushes?.cancel());
    unawaited(_peerUpdates?.cancel());
    super.dispose();
  }

  Future<void> _start() async {
    if (!mounted || !widget.enabled) return;
    _offers = ref.read(updateOffersProvider)?.listen((_) => unawaited(_check(preferRelay: true)));
    _pushes = ref.read(updatePushesProvider)?.listen((_) => unawaited(_check(preferRelay: true, autoDownload: true)));
    _peerUpdates = ref.read(updateSuggestionsProvider)?.listen((peer) => unawaited(_promptPeerUpdate(peer)));
    if (_offers != null) {
      ref.listenManual(updateRelayProvider, (previous, next) {
        if (previous == null && next != null && ref.read(updateCheckProvider).status == UpdateStatus.failed) {
          unawaited(_check(preferRelay: true));
        }
      });
    }
    await _check();
    if (!mounted || !widget.enabled) return;
    _timer = Timer.periodic(widget.interval, (_) => _recheck());
  }

  Future<void> _check({bool preferRelay = false, bool autoDownload = false}) async {
    if (!mounted || !widget.enabled || _showingUpdate) return;
    _showingUpdate = true;
    try {
      await ref.read(updateCheckProvider.notifier).check(preferRelay: preferRelay);
      if (!mounted) return;
      final state = ref.read(updateCheckProvider);
      if (state.status == UpdateStatus.available) {
        await showReleaseNotes(context, state, preferRelay: preferRelay, autoDownload: autoDownload);
      }
    } finally {
      _showingUpdate = false;
    }
  }

  /// A phone just connected to this desktop; offer the Android build it reported behind.
  Future<void> _promptPeerUpdate(PeerUpdate peer) async {
    if (!mounted || !widget.enabled || _showingUpdate) return;
    final push = ref.read(updatePushProvider);
    final key = '${peer.deviceId}@${peer.version}';
    if (push == null || _prompted.contains(key)) return;
    var state = ref.read(updateCheckProvider);
    if (state.releases.isEmpty) {
      await ref.read(updateCheckProvider.notifier).check(silent: true);
      if (!mounted) return;
      state = ref.read(updateCheckProvider);
    }
    if (!mounted || _showingUpdate) return;
    final latest = latestAndroidRelease(state.releases);
    if (latest == null || !isNewerVersion(latest.version, peer.version)) return;
    _prompted.add(key);
    _showingUpdate = true;
    try {
      final l = AppLocalizations.of(context);
      final accepted = await showAppDialog<bool>(
        context: context,
        builder: (context) => AppDialog(
          width: 420,
          title: Text(l.updatePhoneAvailable(latest.version)),
          content: Text(l.updatePhonePrompt(peer.name, peer.version, latest.version)),
          actions: [
            TextButton(onPressed: () => Navigator.maybePop(context, false), child: Text(l.later)),
            FilledButton(onPressed: () => Navigator.maybePop(context, true), child: Text(l.updatePush)),
          ],
        ),
      );
      if (accepted == true && mounted && !await push(peer.deviceId) && mounted) {
        ScaffoldMessenger.maybeOf(context)
            ?.showSnackBar(SnackBar(content: Text(AppLocalizations.of(context).linkUpdateOfferFailed)));
      }
    } finally {
      _showingUpdate = false;
    }
  }

  /// Later checks only feed the title-bar reminder; the start-up dialog stays a one-time interruption.
  Future<void> _recheck() async {
    if (!mounted) return;
    await ref.read(updateCheckProvider.notifier).check(silent: true);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// A quiet title-bar reminder that a newer release exists; it opens the same notes as a manual check.
class UpdateAvailableButton extends ConsumerWidget {
  const UpdateAvailableButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(updateCheckProvider);
    final latest = state.latest;
    if (state.status != UpdateStatus.available || latest == null) return const SizedBox.shrink();
    return IconButton(
      tooltip: AppLocalizations.of(context).updateAvailable(latest.version),
      onPressed: () => showReleaseNotes(context, state),
      icon: Badge(
        smallSize: 6,
        backgroundColor: Theme.of(context).colorScheme.primary,
        child: const Icon(Icons.system_update_alt, size: 18),
      ),
    );
  }
}

/// Checks the project's published releases on demand; nothing is fetched until the user asks.
class UpdateCheckControl extends ConsumerWidget {
  const UpdateCheckControl({super.key, this.alignment = WrapAlignment.start, this.compact = false});

  final WrapAlignment alignment;
  final bool compact;

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
    final textButtonStyle = compact
        ? TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: Space.sm, vertical: Space.xs),
            minimumSize: const Size(0, 32),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          )
        : null;
    final filledButtonStyle = compact
        ? FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: Space.md, vertical: Space.xs),
            minimumSize: const Size(0, 32),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          )
        : null;
    final actions = <Widget>[
      if (state.status == UpdateStatus.available)
        FilledButton(
          style: filledButtonStyle,
          onPressed: () => showReleaseNotes(context, state),
          child: Text(l.updateDownload),
        )
      else ...[
        TextButton(
          style: textButtonStyle,
          onPressed: state.status == UpdateStatus.checking
              ? null
              : () => ref.read(updateCheckProvider.notifier).check(),
          child: Text(l.checkForUpdates),
        ),
        TextButton(style: textButtonStyle, onPressed: () => _showNotes(context, ref), child: Text(l.releaseNotes)),
      ],
    ];
    if (compact) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: alignment == WrapAlignment.end ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          Wrap(
            alignment: alignment,
            spacing: Space.xs,
            runSpacing: Space.xs,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: actions,
          ),
          if (status != null)
            Padding(
              padding: const EdgeInsets.only(top: 2, left: Space.sm, right: Space.sm),
              child: Text(
                status,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: state.status == UpdateStatus.failed
                      ? theme.colorScheme.error
                      : theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      );
    }
    return Wrap(
      alignment: alignment,
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
        ...actions,
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

Future<void> showReleaseNotes(
  BuildContext context,
  UpdateState state, {
  bool preferRelay = false,
  bool autoDownload = false,
}) {
  final latest = state.latest;
  if (latest == null) return Future.value();
  final available = state.status == UpdateStatus.available;
  return showAppDialog<void>(
    context: context,
    builder: (context) => _ReleaseNotesDialog(
      latest: latest,
      releases: available ? state.newerReleases.toList(growable: false) : state.releases,
      available: available,
      preferRelay: preferRelay,
      autoDownload: autoDownload,
    ),
  );
}

final updateDeliveryProvider = FutureProvider<UpdateDelivery>(
  (_) async => UpdateDelivery.current(androidAbis: Platform.isAndroid ? await MobilePlatform.updateAbis() : const []),
);

class _ReleaseNotesDialog extends ConsumerStatefulWidget {
  const _ReleaseNotesDialog({
    required this.latest,
    required this.releases,
    required this.available,
    required this.preferRelay,
    this.autoDownload = false,
  });

  final ReleaseNote latest;
  final List<ReleaseNote> releases;
  final bool available, preferRelay, autoDownload;

  @override
  ConsumerState<_ReleaseNotesDialog> createState() => _ReleaseNotesDialogState();
}

class _ReleaseNotesDialogState extends ConsumerState<_ReleaseNotesDialog> {
  UpdateDownloader? _downloader;
  UpdateDownloadState _download = const UpdateDownloadState.idle();
  var _installing = false;
  var _autoStarted = false;
  MobileUpdateInstallResult? _installResult;

  @override
  void dispose() {
    _downloader?.cancel();
    super.dispose();
  }

  Future<void> _startDownload(ReleaseAsset asset, {OpenUpdateRelay? openRelay}) async {
    if (_downloader != null) return;
    final downloader = _downloader = ref.read(updateDownloaderProvider)();
    setState(() => _download = const UpdateDownloadState(UpdateDownloadStatus.downloading));
    try {
      await downloader.download(
        widget.latest,
        asset: asset,
        openRelay: openRelay,
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

  Future<void> _install({required bool android}) async {
    final path = _download.path;
    if (path == null || _installing) return;
    setState(() {
      _installing = true;
      _installResult = null;
    });
    try {
      if (android) {
        final result = await MobilePlatform.installUpdate(path, widget.latest.version);
        if (mounted) setState(() => _installResult = result);
      } else {
        await DesktopWindow.instance.installAndQuit(path);
      }
    } on Object {
      if (mounted) setState(() => _installResult = MobileUpdateInstallResult.failed);
    } finally {
      if (mounted) setState(() => _installing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final latest = widget.latest;
    final status = _download.status;
    final delivery = widget.available ? ref.watch(updateDeliveryProvider).value : null;
    final asset = delivery?.assetFor(latest.assets);
    final android = delivery?.operatingSystem == 'android';
    final relay = android ? ref.watch(updateRelayProvider) : null;
    final downloading = status == UpdateDownloadStatus.downloading || status == UpdateDownloadStatus.verifying;
    if (widget.autoDownload && !_autoStarted && asset != null) {
      _autoStarted = true;
      final openRelay = android ? relay : null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _downloader == null && _download.status == UpdateDownloadStatus.idle) {
          unawaited(_startDownload(asset, openRelay: openRelay));
        }
      });
    }
    final installNotice = switch (_installResult) {
      MobileUpdateInstallResult.permission => l.updateAllowInstall,
      MobileUpdateInstallResult.failed => android ? l.updateApkFailed : l.updateLaunchFailed,
      _ => null,
    };
    return AppDialog(
      width: 520,
      title: Text(widget.available ? l.updateAvailable(latest.version) : l.releaseNotes),
      content: SizedBox(
        height: 360,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (delivery != null && asset == null) ...[
              Text(l.updateNoPackage, style: theme.textTheme.bodySmall),
              const SizedBox(height: Space.md),
            ],
            Expanded(
              child: SingleChildScrollView(
                primary: false,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final (index, release) in widget.releases.indexed) ...[
                      if (index > 0) const Divider(height: Space.xl),
                      Text('${release.version} · ${release.title}', style: theme.textTheme.titleSmall),
                      if (releaseNotesFor(release.notes, Localizations.localeOf(context).languageCode) case final notes
                          when notes.isNotEmpty) ...[
                        const SizedBox(height: Space.xs),
                        ReleaseNotesView(notes),
                      ],
                    ],
                  ],
                ),
              ),
            ),
            if (status != UpdateDownloadStatus.idle && !(android && status == UpdateDownloadStatus.ready)) ...[
              const SizedBox(height: Space.md),
              _DownloadStatus(download: _download),
            ],
            if (installNotice != null)
              Text(installNotice, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error)),
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
        if (asset != null) ...[
          if (status == UpdateDownloadStatus.ready)
            FilledButton(
              onPressed: _installing ? null : () => _install(android: android),
              child: Text(android ? l.updateInstallApk : l.installNow),
            )
          else if (downloading)
            TextButton(onPressed: _cancelDownload, child: Text(l.cancelDownload))
          else ...[
            if (widget.preferRelay && relay != null) ...[
              TextButton(onPressed: () => _startDownload(asset), child: Text(l.updateDownload)),
              FilledButton(
                onPressed: () => _startDownload(asset, openRelay: relay),
                child: Text(l.updateViaComputer),
              ),
            ] else ...[
              if (relay != null)
                TextButton(
                  onPressed: () => _startDownload(asset, openRelay: relay),
                  child: Text(l.updateViaComputer),
                ),
              FilledButton(
                onPressed: () => _startDownload(asset),
                child: Text(status == UpdateDownloadStatus.failed ? l.retryAction : l.updateDownload),
              ),
            ],
          ],
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
      UpdateDownloadStatus.ready => SelectableText(l.updateDownloaded(download.path ?? ''), style: text),
      UpdateDownloadStatus.failed => Text(
        l.updateDownloadFailed,
        style: text?.copyWith(color: theme.colorScheme.error),
      ),
      UpdateDownloadStatus.idle => const SizedBox.shrink(),
    };
  }
}

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../design/dialog.dart';
import '../../../design/theme.dart';
import '../../../foundation/cancellation.dart';
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
  StreamSubscription<IncomingUpdate>? _pushes;
  StreamSubscription<PeerUpdate>? _peerUpdates;
  UpdateDownloader? _receiving;
  final _prompted = <String>{};
  var _showingUpdate = false;
  var _showingPeerUpdate = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _receiving?.cancel();
    unawaited(_offers?.cancel());
    unawaited(_pushes?.cancel());
    unawaited(_peerUpdates?.cancel());
    super.dispose();
  }

  Future<void> _start() async {
    if (!mounted || !widget.enabled) return;
    _offers = ref.read(updateOffersProvider)?.listen((_) => unawaited(_check(preferRelay: true)));
    _pushes = ref.read(updatePushesProvider)?.listen((incoming) => unawaited(_receiveUpdate(incoming)));
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

  Future<void> _check({bool preferRelay = false}) async {
    if (!mounted || !widget.enabled || _showingUpdate) return;
    _showingUpdate = true;
    try {
      await ref.read(updateCheckProvider.notifier).check(preferRelay: preferRelay);
      if (!mounted) return;
      final state = ref.read(updateCheckProvider);
      if (state.status == UpdateStatus.available) {
        await showReleaseNotes(context, state, preferRelay: preferRelay);
      }
    } finally {
      _showingUpdate = false;
    }
  }

  Future<void> _promptPeerUpdate(PeerUpdate peer) async {
    if (!mounted || !widget.enabled || _showingPeerUpdate || peer.lifetime.isCancelled) return;
    final push = ref.read(updatePushProvider);
    final key = '${peer.deviceId}@${peer.version}';
    if (push == null || (!peer.requested && _prompted.contains(key))) return;
    _showingPeerUpdate = true;
    try {
      var state = ref.read(updateCheckProvider);
      if (state.releases.isEmpty) {
        await ref.read(updateCheckProvider.notifier).check(silent: !peer.requested);
        if (!mounted || peer.lifetime.isCancelled) return;
        state = ref.read(updateCheckProvider);
      }
      final latest = latestAndroidUpdate(state.releases, peer.abis);
      if (latest == null || !isNewerVersion(latest.release.version, peer.version)) {
        if (peer.requested) {
          final l = AppLocalizations.of(context);
          final message = state.status == UpdateStatus.failed
              ? l.updateFailed
              : latest == null
              ? l.updateNoPackage
              : l.upToDate;
          ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(message)));
        }
        return;
      }
      _prompted.add(key);
      await showAppDialog<void>(
        context: context,
        builder: (_) => _PeerUpdateDialog(peer: peer, update: latest, push: push),
      );
    } finally {
      _showingPeerUpdate = false;
    }
  }

  Future<void> _receiveUpdate(IncomingUpdate incoming) async {
    if (!mounted || _receiving != null) {
      await incoming.complete(false);
      return;
    }
    final downloader = _receiving = ref.read(updateDownloaderProvider)();
    try {
      String? path;
      try {
        path = (await downloader.receive(incoming)).path;
      } on UpdateDownloadFailure {
        if (mounted) {
          final l = AppLocalizations.of(context);
          ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(l.updateDownloadFailed)));
        }
      } on UpdateDownloadCancelled {
        // The app closed while the package was arriving.
      } finally {
        await incoming.complete(path != null && mounted);
      }
      if (!mounted || path == null) return;
      await showAppDialog<void>(
        context: context,
        builder: (_) => _ReceivedUpdateDialog(path: path!, version: incoming.package.version),
      );
    } finally {
      _receiving = null;
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

Future<void> showReleaseNotes(BuildContext context, UpdateState state, {bool preferRelay = false}) {
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
  });

  final ReleaseNote latest;
  final List<ReleaseNote> releases;
  final bool available, preferRelay;

  @override
  ConsumerState<_ReleaseNotesDialog> createState() => _ReleaseNotesDialogState();
}

class _ReleaseNotesDialogState extends ConsumerState<_ReleaseNotesDialog> {
  UpdateDownloader? _downloader;
  UpdateDownloadState _download = const UpdateDownloadState.idle();
  var _installing = false;
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

class _PeerUpdateDialog extends ConsumerStatefulWidget {
  const _PeerUpdateDialog({required this.peer, required this.update, required this.push});

  final PeerUpdate peer;
  final AndroidUpdate update;
  final PushPeerUpdate push;

  @override
  ConsumerState<_PeerUpdateDialog> createState() => _PeerUpdateDialogState();
}

class _PeerUpdateDialogState extends ConsumerState<_PeerUpdateDialog> {
  CancellationToken? _cancel;
  UpdateDownloadState _download = const UpdateDownloadState.idle();
  bool? _sent;

  @override
  void dispose() {
    _cancel?.cancel();
    super.dispose();
  }

  Future<void> _start() async {
    if (_cancel != null || widget.peer.lifetime.isCancelled) return;
    final cancel = CancellationToken();
    setState(() {
      _cancel = cancel;
      _download = const UpdateDownloadState(UpdateDownloadStatus.downloading);
      _sent = null;
    });
    try {
      final sent = await ref
          .read(updateDownloaderProvider)()
          .downloadAndPush(
            widget.peer,
            widget.update,
            push: widget.push,
            cancellation: cancel,
            onProgress: (download) {
              if (mounted && !cancel.isCancelled) setState(() => _download = download);
            },
          );
      if (mounted) setState(() => _sent = sent);
    } on Object {
      if (mounted) setState(() => _download = const UpdateDownloadState(UpdateDownloadStatus.failed));
    } finally {
      if (mounted) setState(() => _cancel = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final version = widget.update.release.version;
    final busy = _cancel != null;
    final errorStyle = TextStyle(color: Theme.of(context).colorScheme.error);
    return AppDialog(
      width: 420,
      title: Text(l.updatePhoneAvailable(version)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l.updatePhonePrompt(widget.peer.name, widget.peer.version, version)),
          if (_download.status != UpdateDownloadStatus.idle) const SizedBox(height: Space.md),
          if (_sent case final sent?)
            Text(sent ? l.linkUpdateOffered : l.linkUpdateOfferFailed, style: sent ? null : errorStyle)
          else if (_download.status == UpdateDownloadStatus.ready) ...[
            Text(l.updateSending),
            const SizedBox(height: Space.xs),
            const LinearProgressIndicator(minHeight: 4),
          ] else
            _DownloadStatus(download: _download),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () {
            _cancel?.cancel();
            Navigator.maybePop(context);
          },
          child: Text(
            busy
                ? l.cancel
                : _sent == true
                ? l.close
                : l.later,
          ),
        ),
        if (!busy && _sent != true && !widget.peer.lifetime.isCancelled)
          FilledButton(onPressed: _start, child: Text(l.updatePush)),
      ],
    );
  }
}

class _ReceivedUpdateDialog extends StatefulWidget {
  const _ReceivedUpdateDialog({required this.path, required this.version});

  final String path, version;

  @override
  State<_ReceivedUpdateDialog> createState() => _ReceivedUpdateDialogState();
}

class _ReceivedUpdateDialogState extends State<_ReceivedUpdateDialog> {
  var _installing = false;
  MobileUpdateInstallResult? _result;

  Future<void> _install() async {
    if (_installing) return;
    setState(() => _installing = true);
    final result = await MobilePlatform.installUpdate(widget.path, widget.version);
    if (!mounted) return;
    if (result == MobileUpdateInstallResult.opened) {
      await Navigator.maybePop(context);
    } else {
      setState(() {
        _result = result;
        _installing = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final notice = switch (_result) {
      MobileUpdateInstallResult.permission => l.updateAllowInstall,
      MobileUpdateInstallResult.failed => l.updateApkFailed,
      _ => null,
    };
    return AppDialog(
      title: Text(l.updateReadyToInstall(widget.version)),
      content: notice == null ? null : Text(notice),
      actions: [
        TextButton(onPressed: () => Navigator.maybePop(context), child: Text(l.later)),
        FilledButton(onPressed: _installing ? null : _install, child: Text(l.updateInstallApk)),
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

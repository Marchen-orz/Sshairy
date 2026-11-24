import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../design/popup.dart';
import '../../../design/theme.dart';
import '../../../l10n/app_localizations.dart';
import '../../connections/api.dart';
import '../../hosts/api.dart';
import '../../settings/api.dart';
import '../application/browser.dart';
import '../application/edits.dart';
import '../application/file_systems.dart';
import '../application/transfers.dart';
import '../domain/transfer.dart';
import 'directory_tree.dart';
import 'file_pane.dart';
import 'transfers_panel.dart';

const _idleDelay = Duration(seconds: 30);

/// A late connection request cannot put a dialog over a page the user has left.
class _ActivePrompts implements ConnectPrompts {
  _ActivePrompts(this.delegate, this.active);
  final ConnectPrompts delegate;
  final bool Function() active;

  @override
  Future<TrustChoice> hostKey(HostKeyPrompt prompt) =>
      active() ? delegate.hostKey(prompt) : Future.value(TrustChoice.reject);

  @override
  Future<SecretAnswer?> secret(SecretRequest request) => active() ? delegate.secret(request) : Future.value(null);
}

/// The SFTP page: this computer on the left, a host on the right by default; either side can show either.
class FilesPage extends ConsumerStatefulWidget {
  const FilesPage({super.key, this.active = true});
  final bool active;

  @override
  ConsumerState<FilesPage> createState() => _FilesPageState();
}

class _FilesPageState extends ConsumerState<FilesPage> {
  late final FileBrowser _left, _right;
  Timer? _idleTimer;
  var _generation = 0;

  @override
  void initState() {
    super.initState();
    final connections = ref.read(connectionManagerProvider);
    final hidden = ref.read(settingsProvider).get(SettingKeys.showHidden);
    _left = FileBrowser(connections, showHidden: hidden);
    _right = FileBrowser(connections, showHidden: hidden);
    if (widget.active) _left.open(null, const NoPrompts());
    _idle();
  }

  @override
  void didUpdateWidget(FilesPage old) {
    super.didUpdateWidget(old);
    if (old.active == widget.active) return;
    _generation++;
    _idleTimer?.cancel();
    if (widget.active) {
      final gen = _generation;
      final prompts = _ActivePrompts(DialogPrompts(context), () => mounted && widget.active && gen == _generation);
      if (_left.status == BrowserStatus.idle && !_left.suspended) {
        _left.open(null, const NoPrompts());
      } else {
        _left.resume(prompts);
      }
      _right.resume(prompts);
    } else {
      for (final browser in [_left, _right]) {
        if (browser.status == BrowserStatus.connecting) browser.suspend();
      }
      _idle();
    }
  }

  void _idle() {
    if (widget.active) return;
    _idleTimer?.cancel();
    _idleTimer = Timer(_idleDelay, () {
      if (!mounted || widget.active) return;
      final left = _left.suspend(), right = _right.suspend();
      if (!left || !right) _idle();
    });
  }

  @override
  void dispose() {
    _idleTimer?.cancel();
    _left.dispose();
    _right.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TickerMode(
    enabled: widget.active,
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: FilePane(browser: _left, other: _right, pickHost: true),
        ),
        const VerticalDivider(width: 1),
        Expanded(
          child: FilePane(browser: _right, other: _left, pickHost: true),
        ),
      ],
    ),
  );
}

/// The terminal's side panel: one pane on [host], or this computer when it is null, reopened when the focused
/// pane moves to another target.
class SideFilesPanel extends ConsumerStatefulWidget {
  const SideFilesPanel({
    super.key,
    required this.host,
    this.location,
    this.active = true,
    this.tree = false,
    this.directory,
    this.listing,
    this.toolbarActions = const [],
  });

  /// Null for this computer.
  final Host? host;

  /// A linked terminal's files; takes the place of [host].
  final FileLocation? location;
  final bool active;

  /// Docked below: a directory tree beside the list.
  final bool tree;

  /// The terminal's working directory, which the panel follows while it is open (docs/MODULES.md §4).
  final ValueListenable<String?>? directory;

  /// Bumped after a command that may have changed the files on screen.
  final ValueListenable<int>? listing;

  final List<Widget> toolbarActions;

  @override
  ConsumerState<SideFilesPanel> createState() => _SideFilesPanelState();
}

class _SideFilesPanelState extends ConsumerState<SideFilesPanel> {
  late final FileBrowser _browser = FileBrowser(
    ref.read(connectionManagerProvider),
    showHidden: ref.read(settingsProvider).get(SettingKeys.showHidden),
  );

  String? _lastDirectory;

  /// Where the terminal went while the browser could not follow yet.
  String? _wanted;
  Timer? _idleTimer;
  var _generation = 0;

  @override
  void initState() {
    super.initState();
    if (widget.active) {
      widget.directory?.addListener(_follow);
      widget.listing?.addListener(_listingChanged);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.active) _activate();
    });
    _idle();
  }

  @override
  void didUpdateWidget(SideFilesPanel old) {
    super.didUpdateWidget(old);
    final directoryChanged = !identical(old.directory, widget.directory);
    final listingChanged = !identical(old.listing, widget.listing);
    final hostChanged = old.host?.id != widget.host?.id || old.location?.id != widget.location?.id;
    if (old.active && (!widget.active || directoryChanged)) old.directory?.removeListener(_follow);
    if (old.active && (!widget.active || listingChanged)) old.listing?.removeListener(_listingChanged);
    if (widget.active && (!old.active || directoryChanged)) widget.directory?.addListener(_follow);
    if (widget.active && (!old.active || listingChanged)) widget.listing?.addListener(_listingChanged);
    if (old.active != widget.active || hostChanged) _generation++;
    if (directoryChanged || hostChanged) {
      _lastDirectory = null;
      _wanted = null;
    }
    if (widget.active) _idleTimer?.cancel();
    if (!widget.active) {
      if (hostChanged || _browser.status == BrowserStatus.connecting) _browser.suspend();
      _idle();
    } else if (!old.active || hostChanged) {
      _activate();
    } else if (directoryChanged) {
      _follow();
    }
  }

  void _idle() {
    if (widget.active || (_idleTimer?.isActive ?? false)) return;
    _idleTimer = Timer(_idleDelay, () {
      if (mounted && !widget.active && !_browser.suspend()) _idle();
    });
  }

  Future<void> _activate() async {
    if (!mounted || !widget.active) return;
    final gen = _generation;
    final prompts = _ActivePrompts(DialogPrompts(context), () => mounted && widget.active && gen == _generation);
    final location = widget.location;
    if (location != null) {
      if (_browser.location?.id != location.id || (_browser.status == BrowserStatus.idle && !_browser.suspended)) {
        _wanted = null;
        await _browser.openLocation(location, at: widget.directory?.value);
      } else {
        await _browser.resume(prompts);
      }
    } else if (_browser.host?.id != widget.host?.id || (_browser.status == BrowserStatus.idle && !_browser.suspended)) {
      _wanted = null;
      await _browser.open(widget.host, prompts, at: widget.directory?.value);
    } else {
      await _browser.resume(prompts);
    }
    if (mounted && widget.active && gen == _generation) _follow();
  }

  @override
  void dispose() {
    _idleTimer?.cancel();
    if (widget.active) {
      widget.directory?.removeListener(_follow);
      widget.listing?.removeListener(_listingChanged);
    }
    _browser.dispose();
    super.dispose();
  }

  /// A finished command may have added, removed or renamed entries; the terminal's own directory is followed by
  /// [_follow], while this re-reads whatever the panel shows when it is still the shell's directory.
  void _listingChanged() {
    if (!mounted || !widget.active || _browser.loading) return;
    final to = widget.directory?.value ?? _lastDirectory;
    if (to != null && to != _browser.path) return;
    _browser.refresh(quiet: true);
  }

  void _follow() {
    if (!mounted || !widget.active) return;
    final to = widget.directory?.value;
    // Directory probes clear the value while checking, even if the shell never moved.
    if (to == null) return;
    if (to != _lastDirectory) {
      _lastDirectory = to;
      _wanted = to;
    }
    _catchUp();
  }

  void _catchUp() {
    final to = _wanted;
    if (to == null || !mounted || !widget.active || !_browser.ready || _browser.path.isEmpty) return;
    _wanted = null;
    if (to != _browser.path) _browser.go(to, quiet: true);
  }

  @override
  Widget build(BuildContext context) => TickerMode(
    enabled: widget.active,
    child: FilePane(
      browser: _browser,
      sidebar: widget.tree ? DirectoryTree(browser: _browser) : null,
      toolbarActions: widget.toolbarActions,
    ),
  );
}

/// The transfer queue and edits as a popover under [anchor]; closing it leaves transfers running. Without an
/// anchor (the palette) it opens at the title bar's right edge, where the button is.
Future<void> showTransfers(BuildContext context, {Rect? anchor}) async {
  final viewport = Navigator.of(context).context.findRenderObject()! as RenderBox;
  final container = ProviderScope.containerOf(context, listen: false);
  container.read(_noticeProvider.notifier).seen();
  await showAnchoredPopup<void>(
    context: context,
    anchor: anchor ?? anchorAt(viewport.localToGlobal(Offset(viewport.size.width, WorkspaceSize.titleBar))),
    width: WorkspaceSize.flyoutWide,
    maxHeight: 520,
    builder: (_) => const PopupSurface(padding: EdgeInsets.all(Space.md), child: TransfersPanel()),
  );
  // What ended while the list was open has been seen.
  container.read(_noticeProvider.notifier).seen();
}

/// What ended since the transfer list was last opened; a failure outranks a success.
enum _Notice { none, done, failed }

final _noticeProvider = NotifierProvider<_TransferNotice, _Notice>(_TransferNotice.new);

class _TransferNotice extends Notifier<_Notice> {
  @override
  _Notice build() {
    ref.listen(transfersProvider, (before, now) {
      final running = {
        for (final t in before ?? const <Transfer>[])
          if (t.state.active) t.id,
      };
      for (final t in now) {
        if (!running.contains(t.id) || t.state.active || t.state == TransferState.cancelled) continue;
        _raise(t.state == TransferState.completed ? _Notice.done : _Notice.failed);
      }
    });
    ref.listen(editsProvider, (before, now) {
      final was = {for (final e in before ?? const <ExternalEdit>[]) e.id: e.state};
      for (final e in now) {
        final prior = was[e.id];
        if (prior == e.state && was.containsKey(e.id)) continue;
        if (e.state == EditState.conflict || e.state == EditState.failed) {
          _raise(_Notice.failed);
        } else if (e.state == EditState.clean && (prior == null || prior == EditState.uploading)) {
          _raise(_Notice.done);
        }
      }
    });
    return _Notice.none;
  }

  void _raise(_Notice notice) {
    if (notice.index > state.index) state = notice;
  }

  void seen() => state = _Notice.none;
}

/// The title-bar button: how much is moving, else a dot for what ended unseen.
class TransfersButton extends ConsumerWidget {
  const TransfersButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final active =
        ref.watch(transfersProvider.select((ts) => ts.where((t) => t.state.active).length)) +
        ref.watch(editProgressProvider.select((p) => p.length));
    final notice = ref.watch(_noticeProvider);
    const icon = Icon(Icons.swap_vert, size: 16);
    return IconButton(
      tooltip: l.transfers,
      onPressed: () => showTransfers(context, anchor: anchorOf(context)),
      icon: active > 0
          ? Badge(label: Text('$active'), child: icon)
          : Badge(
              isLabelVisible: notice != _Notice.none,
              backgroundColor: notice == _Notice.failed ? scheme.error : scheme.primary,
              child: icon,
            ),
    );
  }
}

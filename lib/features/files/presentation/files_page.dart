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
import '../application/file_systems.dart';
import '../application/transfers.dart';
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

/// The terminal's side panel: one remote pane on [host], reopened when the focused pane moves to another host.
class SideFilesPanel extends ConsumerStatefulWidget {
  const SideFilesPanel({
    super.key,
    required this.host,
    this.active = true,
    this.tree = false,
    this.directory,
    this.toolbarActions = const [],
  });
  final Host host;
  final bool active;

  /// Docked below: a directory tree beside the list.
  final bool tree;

  /// The terminal's working directory, which the panel follows while it is open (docs/MODULES.md §4).
  final ValueListenable<String?>? directory;

  final List<Widget> toolbarActions;

  @override
  ConsumerState<SideFilesPanel> createState() => _SideFilesPanelState();
}

class _SideFilesPanelState extends ConsumerState<SideFilesPanel> {
  late final FileBrowser _browser = FileBrowser(
    ref.read(connectionManagerProvider),
    showHidden: ref.read(settingsProvider).get(SettingKeys.showHidden),
  );

  /// Where the terminal went while the browser could not follow yet.
  String? _wanted;
  Timer? _idleTimer;
  var _generation = 0;

  @override
  void initState() {
    super.initState();
    if (widget.active) widget.directory?.addListener(_follow);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.active) _activate();
    });
    _idle();
  }

  @override
  void didUpdateWidget(SideFilesPanel old) {
    super.didUpdateWidget(old);
    final directoryChanged = !identical(old.directory, widget.directory);
    final hostChanged = old.host.id != widget.host.id;
    if (old.active && (!widget.active || directoryChanged)) old.directory?.removeListener(_follow);
    if (widget.active && (!old.active || directoryChanged)) widget.directory?.addListener(_follow);
    if (old.active != widget.active || hostChanged) _generation++;
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
    if (_browser.host?.id != widget.host.id || (_browser.status == BrowserStatus.idle && !_browser.suspended)) {
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
    if (widget.active) widget.directory?.removeListener(_follow);
    _browser.dispose();
    super.dispose();
  }

  void _follow() {
    if (!mounted || !widget.active) return;
    final to = widget.directory?.value;
    if (to == null) return;
    _wanted = to;
    _catchUp();
  }

  void _catchUp() {
    final to = _wanted;
    if (to == null || !mounted || !widget.active || !_browser.ready || _browser.path.isEmpty) return;
    _wanted = null;
    if (to != _browser.path) _browser.go(to);
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
Future<void> showTransfers(BuildContext context, {Rect? anchor}) {
  final viewport = Navigator.of(context).context.findRenderObject()! as RenderBox;
  return showAnchoredPopup<void>(
    context: context,
    anchor: anchor ?? anchorAt(viewport.localToGlobal(Offset(viewport.size.width, WorkspaceSize.titleBar))),
    width: WorkspaceSize.flyoutWide,
    maxHeight: 520,
    builder: (_) => const PopupSurface(padding: EdgeInsets.all(Space.md), child: TransfersPanel()),
  );
}

/// The title-bar button: shows how much is running.
class TransfersButton extends ConsumerWidget {
  const TransfersButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final active = ref.watch(transfersProvider.select((ts) => ts.where((t) => t.state.active).length));
    return IconButton(
      tooltip: l.transfers,
      onPressed: () => showTransfers(context, anchor: anchorOf(context)),
      icon: Badge(isLabelVisible: active > 0, label: Text('$active'), child: const Icon(Icons.swap_vert, size: 16)),
    );
  }
}

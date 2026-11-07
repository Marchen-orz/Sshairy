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

/// The SFTP page: this computer on the left, a host on the right by default; either side can show either.
class FilesPage extends ConsumerStatefulWidget {
  const FilesPage({super.key});

  @override
  ConsumerState<FilesPage> createState() => _FilesPageState();
}

class _FilesPageState extends ConsumerState<FilesPage> {
  late final FileBrowser _left, _right;

  @override
  void initState() {
    super.initState();
    final connections = ref.read(connectionManagerProvider);
    final hidden = ref.read(settingsProvider).get(SettingKeys.showHidden);
    _left = FileBrowser(connections, showHidden: hidden);
    _right = FileBrowser(connections, showHidden: hidden);
    _left.open(null, const NoPrompts());
  }

  @override
  void dispose() {
    _left.dispose();
    _right.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Row(
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
  );
}

/// The terminal's side panel: one remote pane on [host], reopened when the focused pane moves to another host.
class SideFilesPanel extends ConsumerStatefulWidget {
  const SideFilesPanel({
    super.key,
    required this.host,
    this.tree = false,
    this.directory,
    this.toolbarActions = const [],
  });
  final Host host;

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

  @override
  void initState() {
    super.initState();
    widget.directory?.addListener(_follow);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _open();
    });
  }

  @override
  void didUpdateWidget(SideFilesPanel old) {
    super.didUpdateWidget(old);
    if (!identical(old.directory, widget.directory)) {
      old.directory?.removeListener(_follow);
      widget.directory?.addListener(_follow);
    }
    if (old.host.id != widget.host.id) {
      _open();
    } else if (!identical(old.directory, widget.directory)) {
      _follow();
    }
  }

  @override
  void dispose() {
    widget.directory?.removeListener(_follow);
    _browser.dispose();
    super.dispose();
  }

  Future<void> _open() async {
    _wanted = null;
    await _browser.open(widget.host, DialogPrompts(context), at: widget.directory?.value);
    _catchUp();
  }

  void _follow() {
    final to = widget.directory?.value;
    if (to == null) return;
    _wanted = to;
    _catchUp();
  }

  void _catchUp() {
    final to = _wanted;
    if (to == null || !mounted || !_browser.ready || _browser.path.isEmpty) return;
    _wanted = null;
    if (to != _browser.path) _browser.go(to);
  }

  @override
  Widget build(BuildContext context) => FilePane(
    browser: _browser,
    sidebar: widget.tree ? DirectoryTree(browser: _browser) : null,
    toolbarActions: widget.toolbarActions,
  );
}

/// The transfer queue and edits as a popover under [anchor]; closing it leaves transfers running. Without an
/// anchor (the palette) it opens at the title bar's right edge, where the button is.
Future<void> showTransfers(BuildContext context, {Rect? anchor}) => showAnchoredPopup<void>(
  context: context,
  anchor: anchor ?? Rect.fromLTWH(MediaQuery.sizeOf(context).width, WorkspaceSize.titleBar, 0, 0),
  width: WorkspaceSize.flyoutWide,
  maxHeight: 520,
  builder: (_) => const PopupSurface(padding: EdgeInsets.all(Space.md), child: TransfersPanel()),
);

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

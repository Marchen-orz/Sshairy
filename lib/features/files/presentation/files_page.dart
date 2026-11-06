import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../design/side_drawer.dart';
import '../../../l10n/app_localizations.dart';
import '../../connections/api.dart';
import '../../hosts/api.dart';
import '../../settings/api.dart';
import '../application/browser.dart';
import '../application/file_systems.dart';
import '../application/transfers.dart';
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
  Widget build(BuildContext context) => Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Expanded(child: FilePane(browser: _left, other: _right, pickHost: true)),
        const VerticalDivider(width: 1),
        Expanded(child: FilePane(browser: _right, other: _left, pickHost: true)),
      ]);
}

/// The terminal's side panel: one remote pane on [host], reopened when the focused pane moves to another host.
class SideFilesPanel extends ConsumerStatefulWidget {
  const SideFilesPanel({super.key, required this.host});
  final Host host;

  @override
  ConsumerState<SideFilesPanel> createState() => _SideFilesPanelState();
}

class _SideFilesPanelState extends ConsumerState<SideFilesPanel> {
  late final FileBrowser _browser = FileBrowser(
    ref.read(connectionManagerProvider),
    showHidden: ref.read(settingsProvider).get(SettingKeys.showHidden),
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _browser.open(widget.host, DialogPrompts(context));
    });
  }

  @override
  void didUpdateWidget(SideFilesPanel old) {
    super.didUpdateWidget(old);
    if (old.host.id != widget.host.id) _browser.open(widget.host, DialogPrompts(context));
  }

  @override
  void dispose() {
    _browser.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FilePane(browser: _browser);
}

/// The transfer queue and edits, from the title bar or the palette.
Future<void> showTransfers(BuildContext context) => showSideDrawer<void>(context, (_) => const TransfersPanel());

/// The title-bar button: shows how much is running.
class TransfersButton extends ConsumerWidget {
  const TransfersButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final active = ref.watch(transfersProvider.select((ts) => ts.where((t) => t.state.active).length));
    return IconButton(
      tooltip: l.transfers,
      onPressed: () => showTransfers(context),
      icon: Badge(
        isLabelVisible: active > 0,
        label: Text('$active'),
        child: const Icon(Icons.swap_vert, size: 18),
      ),
    );
  }
}

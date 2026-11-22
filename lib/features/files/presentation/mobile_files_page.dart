import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../design/format.dart';
import '../../../design/select.dart';
import '../../../design/theme.dart';
import '../../../foundation/file_system.dart';
import '../../../l10n/app_localizations.dart';
import '../../connections/api.dart';
import '../../hosts/api.dart';
import '../../settings/api.dart';
import '../adapters/desktop.dart';
import '../adapters/mobile_files.dart';
import '../application/browser.dart';
import '../application/file_ops.dart';
import '../application/file_systems.dart';
import '../application/transfers.dart';
import '../domain/transfer.dart';
import 'file_pane.dart' show queueCopy;
import 'file_text.dart';
import 'transfers_panel.dart' show TransferRow;

const _maxInlineEditBytes = 512 * 1024;

/// An entry long-pressed out of a pane.
class _Drag {
  const _Drag(this.from, this.entry, this.path);
  final FileBrowser from;
  final FileEntry entry;
  final String path;
}

/// Two panes on a phone (docs/MOBILE.md §3.3): side by side when turned, stacked or side by side upright, and
/// compact while upright. Each pane picks its own place; an entry dropped on the other pane is copied into its folder.
class MobileFilesPage extends ConsumerStatefulWidget {
  const MobileFilesPage({super.key, this.host, this.initialPath, this.onSendPathToTerminal, this.onAskAiry});

  /// Opens in the first pane beside this phone; without it, this phone sits beside the linked computer.
  final Host? host;
  final String? initialPath;
  final ValueChanged<String>? onSendPathToTerminal;
  final ValueChanged<String>? onAskAiry;

  @override
  ConsumerState<MobileFilesPage> createState() => _MobileFilesPageState();
}

class _MobileFilesPageState extends ConsumerState<MobileFilesPage> {
  late final List<FileBrowser> _panes;
  final _opened = DateTime.now();
  var _busy = false;
  String? _banner;

  late final _phone = FileLocation(
    id: 'phone',
    label: AppLocalizations.of(context).mobileThisPhone,
    open: () => openMobileStorage(ask: true),
  );

  @override
  void initState() {
    super.initState();
    final connections = ref.read(connectionManagerProvider);
    final hidden = ref.read(settingsProvider).get(SettingKeys.showHidden);
    _panes = [for (var i = 0; i < 2; i++) FileBrowser(connections, showHidden: hidden)];
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final host = widget.host;
      if (host != null) {
        unawaited(_panes[0].open(host, DialogPrompts(context), at: widget.initialPath));
        unawaited(_panes[1].openLocation(_phone));
        return;
      }
      unawaited(_panes[0].openLocation(_phone));
      final computer = ref.read(fileLocationsProvider).where((p) => p.kind == FileLocationKind.computer).firstOrNull;
      if (computer != null) unawaited(_panes[1].openLocation(computer));
    });
  }

  @override
  void dispose() {
    for (final b in _panes) {
      b.dispose();
    }
    super.dispose();
  }

  void _flash(String text) {
    if (!mounted) return;
    setState(() => _banner = text);
    Future<void>.delayed(const Duration(seconds: 3), () {
      if (mounted && _banner == text) setState(() => _banner = null);
    });
  }

  void _report(Object? failure) {
    if (failure != null && mounted) _flash(fileError(AppLocalizations.of(context), failure));
  }

  Future<void> _run(Future<Object?> Function() op) async {
    setState(() => _busy = true);
    try {
      _report(await op());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  static String _idOf(FileBrowser b) => b.location?.id ?? (b.host == null ? '' : 'host:${b.host!.id.value}');

  static String _labelOf(Object place) => switch (place) {
    FileLocation p => p.label,
    Host h => h.title,
    _ => '',
  };

  static IconData _placeIcon(Object place) => switch (place) {
    FileLocation(kind: FileLocationKind.computer) => Icons.computer,
    FileLocation(kind: FileLocationKind.server) => Icons.lan_outlined,
    FileLocation() => Icons.smartphone,
    _ => Icons.dns_outlined,
  };

  void _go(FileBrowser b, Object place) {
    if (place is FileLocation) unawaited(b.openLocation(place));
    if (place is Host) unawaited(b.open(place, DialogPrompts(context)));
  }

  void _copy(_Drag drag, FileBrowser to) =>
      _report(queueCopy(ref.read(transfersProvider.notifier), drag.from, [drag.path], to, to.path));

  /// Whether a finished copy landed in the folder [b] lists.
  bool _shows(FileBrowser b, FileEnd end) =>
      b.ready && end.host == b.host?.id && end.locationId == b.location?.id && b.style.parent(end.path) == b.path;

  Future<String?> _askName(String title, {String initial = '', String? hint}) async {
    final l = AppLocalizations.of(context);
    final controller = TextEditingController(text: initial);
    final name = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (context) => Padding(
        padding: EdgeInsets.fromLTRB(Space.lg, 0, Space.lg, MediaQuery.viewInsetsOf(context).bottom + Space.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: Space.md),
            TextField(
              controller: controller,
              autofocus: true,
              decoration: InputDecoration(hintText: hint),
              onSubmitted: (v) => Navigator.pop(context, v.trim()),
            ),
            const SizedBox(height: Space.md),
            FilledButton(onPressed: () => Navigator.pop(context, controller.text.trim()), child: Text(l.save)),
          ],
        ),
      ),
    );
    controller.dispose();
    return name == null || name.isEmpty || !mounted ? null : name;
  }

  /// Picked files are streamed in and never replace an existing name.
  Future<void> _upload(FileBrowser b) async {
    final picked = await pickUploadFileStreams();
    final fs = b.fs;
    if (picked.isEmpty || fs == null || !mounted) return;
    await _run(() async {
      try {
        for (final file in picked) {
          if (!validCopyName(file.name, fs.style)) throw const OpFailure('badName');
          await writeVerified(fs, fs.style.join(b.path, file.name), file.openRead(), expectedSize: file.size);
        }
        return null;
      } on FsError catch (e) {
        return e;
      } on OpFailure catch (e) {
        return e;
      } finally {
        await b.refresh();
      }
    });
  }

  Future<void> _newFile(FileBrowser b) async {
    final l = AppLocalizations.of(context);
    final name = await _askName(l.mobileNewFile, hint: 'config.yaml');
    final fs = b.fs;
    if (name == null || fs == null) return;
    await _run(() async {
      try {
        if (badName(name, fs.style) != null) throw const OpFailure('badName');
        await fs.create(fs.style.join(b.path, name), Stream.value(Uint8List(0)));
        return null;
      } on FsError catch (e) {
        return e;
      } on OpFailure catch (e) {
        return e;
      } finally {
        await b.refresh();
      }
    });
  }

  Future<void> _newFolder(FileBrowser b) async {
    final name = await _askName(AppLocalizations.of(context).mobileNewFolder, hint: 'logs');
    if (name != null) await _run(() => b.mkdir(name));
  }

  Future<void> _rename(FileBrowser b, FileEntry entry) async {
    final name = await _askName(AppLocalizations.of(context).rename, initial: entry.name);
    if (name != null && name != entry.name) await _run(() => b.rename(entry, name));
  }

  Future<void> _delete(FileBrowser b, FileEntry entry) async {
    final l = AppLocalizations.of(context);
    final ok = await showModalBottomSheet<bool>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      builder: (context) => Padding(
        padding: const EdgeInsets.fromLTRB(Space.lg, 0, Space.lg, Space.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(l.delete, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: Space.sm),
            Text(entry.name, style: mono(context, Theme.of(context).textTheme.bodyMedium)),
            const SizedBox(height: Space.lg),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(onPressed: () => Navigator.pop(context, false), child: Text(l.cancel)),
                ),
                const SizedBox(width: Space.sm),
                Expanded(
                  child: FilledButton(
                    style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
                    onPressed: () => Navigator.pop(context, true),
                    child: Text(l.delete),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
    if (ok == true && mounted) await _run(() => b.delete([entry]));
  }

  Future<void> _openEditor(FileBrowser b, FileEntry entry) async {
    final fs = b.fs;
    if (fs == null) return;
    if ((entry.size ?? 0) > _maxInlineEditBytes) {
      _flash(AppLocalizations.of(context).mobileFileTooLarge);
      return;
    }
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => _MobileFileEditorPage(
          fs: fs,
          placeLabel: b.location?.label ?? b.host?.title ?? '',
          remotePath: b.pathOf(entry),
          fileName: entry.name,
          onAskAiry: widget.onAskAiry,
        ),
      ),
    );
    if (saved == true && mounted) await b.refresh();
  }

  void _showEntryActions(FileBrowser b, FileEntry entry) {
    final l = AppLocalizations.of(context);
    final fullPath = b.pathOf(entry);
    final toTerminal = widget.onSendPathToTerminal;
    showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      builder: (context) {
        Widget action(IconData icon, String label, VoidCallback run, {Color? color}) => ListTile(
          leading: Icon(icon, color: color),
          title: Text(label, style: color == null ? null : TextStyle(color: color)),
          onTap: () {
            Navigator.pop(context);
            run();
          },
        );
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: Icon(entry.browsable ? Icons.folder_outlined : Icons.description_outlined),
                title: Text(entry.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(fullPath, style: mono(context, Theme.of(context).textTheme.bodySmall), maxLines: 1),
              ),
              const Divider(height: 1),
              if (!entry.browsable)
                action(Icons.edit_outlined, l.mobileFileEditor, () => unawaited(_openEditor(b, entry))),
              if (toTerminal != null && b.host != null && b.host!.id == widget.host?.id)
                action(Icons.terminal, l.mobileSendPathToTerminal, () {
                  toTerminal(fullPath);
                  Navigator.of(this.context).maybePop();
                }),
              action(Icons.copy_outlined, l.copy, () {
                unawaited(Clipboard.setData(ClipboardData(text: fullPath)));
                _flash(l.linkCopied);
              }),
              action(Icons.drive_file_rename_outline, l.rename, () => unawaited(_rename(b, entry))),
              action(
                Icons.delete_outline,
                l.delete,
                () => unawaited(_delete(b, entry)),
                color: Theme.of(context).colorScheme.error,
              ),
            ],
          ),
        );
      },
    );
  }

  void _showAddSheet(FileBrowser b) {
    final l = AppLocalizations.of(context);
    showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      builder: (context) {
        Widget action(IconData icon, String label, Future<void> Function(FileBrowser) run) => ListTile(
          leading: Icon(icon),
          title: Text(label),
          onTap: () {
            Navigator.pop(context);
            unawaited(run(b));
          },
        );
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              action(Icons.upload_file_outlined, l.mobileUploadFile, _upload),
              action(Icons.create_new_folder_outlined, l.mobileNewFolder, _newFolder),
              action(Icons.note_add_outlined, l.mobileNewFile, _newFile),
            ],
          ),
        );
      },
    );
  }

  IconData _iconFor(FileEntry e) {
    if (e.browsable) return Icons.folder_rounded;
    final lower = e.name.toLowerCase();
    if (lower.endsWith('.log') || lower.endsWith('.txt') || lower.endsWith('.md')) return Icons.article_outlined;
    if (lower.endsWith('.json') || lower.endsWith('.yaml') || lower.endsWith('.yml') || lower.endsWith('.toml')) {
      return Icons.data_object_outlined;
    }
    if (lower.endsWith('.sh') || lower.endsWith('.py') || lower.endsWith('.dart') || lower.endsWith('.conf')) {
      return Icons.code_rounded;
    }
    if (lower.endsWith('.png') || lower.endsWith('.jpg') || lower.endsWith('.jpeg') || lower.endsWith('.webp')) {
      return Icons.image_outlined;
    }
    return Icons.insert_drive_file_outlined;
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final palette = BrandPalette.of(context);
    final hidden = ref.watch(settingsProvider.select((s) => s.get(SettingKeys.showHidden)));
    ref.listen(settingsProvider.select((s) => s.get(SettingKeys.showHidden)), (_, value) {
      for (final b in _panes) {
        b.setShowHidden(value);
      }
    });
    ref.listen(fileLocationsProvider, (_, _) {
      for (final b in _panes) {
        b.checkLocation();
      }
    });
    ref.listen(transfersProvider, (before, now) {
      final running = {
        for (final t in before ?? const <Transfer>[])
          if (t.state.active) t.id,
      };
      for (final t in now) {
        if (!running.contains(t.id) || t.state.active) continue;
        for (final b in _panes) {
          if (_shows(b, t.target)) unawaited(b.refresh());
        }
      }
    });
    final places = <String, Object>{
      _phone.id: _phone,
      for (final p in ref.watch(fileLocationsProvider)) p.id: p,
      for (final h in sortHosts(ref.watch(hostsProvider), recent: true)) 'host:${h.id.value}': h,
    };
    final mine = [
      for (final t in ref.watch(transfersProvider).reversed)
        if (!t.created.isBefore(_opened)) t,
    ];
    final landscape = MediaQuery.orientationOf(context) == Orientation.landscape;
    final columns = landscape || ref.watch(settingsProvider.select((s) => s.get(SettingKeys.mobileFilesColumns)));
    return Scaffold(
      backgroundColor: palette.background,
      appBar: AppBar(
        backgroundColor: palette.surface,
        surfaceTintColor: Colors.transparent,
        toolbarHeight: 44,
        actions: [
          if (!landscape)
            IconButton(
              key: const ValueKey('mobile-files-split'),
              tooltip: columns ? l.splitDown : l.splitRight,
              icon: Icon(columns ? Icons.horizontal_split_outlined : Icons.vertical_split_outlined),
              onPressed: () => ref.read(settingsProvider.notifier).set(SettingKeys.mobileFilesColumns, !columns),
            ),
          IconButton(
            tooltip: l.hiddenFiles,
            icon: Icon(hidden ? Icons.visibility_outlined : Icons.visibility_off_outlined),
            onPressed: () => ref.read(settingsProvider.notifier).set(SettingKeys.showHidden, !hidden),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_busy) const LinearProgressIndicator(minHeight: 2),
            if (_banner != null)
              Container(
                color: scheme.primaryContainer,
                padding: const EdgeInsets.symmetric(horizontal: Space.lg, vertical: Space.sm),
                child: Text(
                  _banner!,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onPrimaryContainer),
                ),
              ),
            Expanded(
              child: Flex(
                direction: columns ? Axis.horizontal : Axis.vertical,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: _pane(0, places, compact: !landscape, narrow: columns && !landscape),
                  ),
                  if (columns) const VerticalDivider(width: 1) else const Divider(height: 1),
                  Expanded(
                    child: _pane(1, places, compact: !landscape, narrow: columns && !landscape),
                  ),
                ],
              ),
            ),
            if (mine.isNotEmpty)
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 148),
                child: Material(
                  color: palette.surface,
                  child: ListView(
                    shrinkWrap: true,
                    padding: const EdgeInsets.fromLTRB(Space.lg, Space.sm, Space.sm, 0),
                    children: [for (final t in mine) TransferRow(t)],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// [narrow] panes drop the refresh button for pull to refresh.
  Widget _pane(int index, Map<String, Object> places, {required bool compact, required bool narrow}) {
    final b = _panes[index];
    final l = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final palette = BrandPalette.of(context);
    return ListenableBuilder(
      listenable: b,
      builder: (context, _) {
        final crumbs = b.ready && b.path.isNotEmpty ? b.style.crumbs(b.path) : const <(String, String)>[];
        return DragTarget<_Drag>(
          onWillAcceptWithDetails: (d) => d.data.from != b && b.ready,
          onAcceptWithDetails: (d) => _copy(d.data, b),
          builder: (context, candidates, _) => DecoratedBox(
            key: ValueKey('mobile-files-pane-$index'),
            decoration: BoxDecoration(
              border: Border.all(color: candidates.isNotEmpty ? scheme.primary : Colors.transparent, width: 2),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: compact
                      ? const EdgeInsets.fromLTRB(Space.sm, Space.xs, 0, 0)
                      : const EdgeInsets.fromLTRB(Space.lg, Space.sm, Space.sm, Space.xs),
                  child: Row(
                    children: [
                      Expanded(
                        child: AppSelect<String>(
                          value: _idOf(b),
                          hint: '—',
                          searchable: places.length > 8,
                          options: [
                            for (final MapEntry(:key, :value) in places.entries)
                              AppOption(key, _labelOf(value), icon: _placeIcon(value)),
                          ],
                          onChanged: (id) => _go(b, places[id]!),
                        ),
                      ),
                      if (!narrow)
                        IconButton(
                          tooltip: l.refresh,
                          visualDensity: compact ? VisualDensity.compact : null,
                          icon: const Icon(Icons.refresh_rounded),
                          onPressed: b.ready ? () => unawaited(b.refresh()) : null,
                        ),
                      IconButton(
                        key: ValueKey('mobile-files-add-$index'),
                        tooltip: l.more,
                        visualDensity: compact ? VisualDensity.compact : null,
                        icon: const Icon(Icons.add),
                        onPressed: b.ready && !_busy ? () => _showAddSheet(b) : null,
                      ),
                    ],
                  ),
                ),
                if (crumbs.isNotEmpty)
                  SizedBox(
                    height: compact ? 30 : 36,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      reverse: true,
                      padding: EdgeInsets.symmetric(horizontal: compact ? Space.sm : Space.lg),
                      itemCount: crumbs.length,
                      separatorBuilder: (_, _) => Icon(Icons.chevron_right, size: 16, color: scheme.onSurfaceVariant),
                      itemBuilder: (context, i) {
                        final (label, target) = crumbs[crumbs.length - 1 - i];
                        final last = i == 0;
                        return Center(
                          child: ActionChip(
                            visualDensity: VisualDensity.compact,
                            materialTapTargetSize: compact ? MaterialTapTargetSize.shrinkWrap : null,
                            labelPadding: compact ? const EdgeInsets.symmetric(horizontal: Space.xs) : null,
                            backgroundColor: last ? scheme.primaryContainer : palette.raised,
                            side: BorderSide.none,
                            label: Text(
                              label,
                              style: mono(
                                context,
                                Theme.of(context).textTheme.labelMedium,
                              ).copyWith(color: last ? scheme.onPrimaryContainer : scheme.onSurface),
                            ),
                            onPressed: last ? null : () => unawaited(b.go(target)),
                          ),
                        );
                      },
                    ),
                  ),
                SizedBox(height: 2, child: b.loading ? const LinearProgressIndicator(minHeight: 2) : null),
                Expanded(child: _body(b, places, compact)),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _body(FileBrowser b, Map<String, Object> places, bool compact) {
    final l = AppLocalizations.of(context);
    final muted = Theme.of(context).textTheme.bodyMedium
        ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant);
    switch (b.status) {
      case BrowserStatus.idle:
        return ListView(
          children: [
            for (final MapEntry(:value) in places.entries)
              ListTile(
                dense: compact,
                leading: Icon(_placeIcon(value)),
                title: Text(_labelOf(value), maxLines: 1, overflow: TextOverflow.ellipsis),
                onTap: () => _go(b, value),
              ),
          ],
        );
      case BrowserStatus.connecting:
        return const Center(child: CircularProgressIndicator());
      case BrowserStatus.failed || BrowserStatus.lost:
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(Space.lg),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  b.connectError != null
                      ? connectErrorText(l, b.connectError)
                      : b.listError != null
                      ? fileError(l, b.listError)
                      : l.disconnected,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: Space.md),
                FilledButton.icon(
                  onPressed: () => unawaited(b.reconnect(DialogPrompts(context))),
                  icon: const Icon(Icons.refresh),
                  label: Text(l.retry),
                ),
              ],
            ),
          ),
        );
      case BrowserStatus.ready:
        final items = b.visible;
        if (items.isEmpty) {
          return Center(child: Text(b.listError != null ? fileError(l, b.listError) : l.emptyFolder, style: muted));
        }
        return RefreshIndicator(
          onRefresh: b.refresh,
          child: ListView.builder(
            padding: const EdgeInsets.only(bottom: Space.lg),
            itemCount: items.length,
            itemBuilder: (context, i) => _row(b, items[i], compact),
          ),
        );
    }
  }

  Widget _row(FileBrowser b, FileEntry e, bool compact) {
    final scheme = Theme.of(context).colorScheme;
    final palette = BrandPalette.of(context);
    final theme = Theme.of(context);
    final tint = e.browsable ? palette.primary : scheme.onSurfaceVariant;
    final row = InkWell(
      onTap: () => unawaited(e.browsable ? b.enter(e) : _openEditor(b, e)),
      child: Padding(
        padding: compact
            ? const EdgeInsets.fromLTRB(Space.sm, 2, 0, 2)
            : const EdgeInsets.fromLTRB(Space.lg, Space.xs, Space.xs, Space.xs),
        child: Row(
          children: [
            Container(
              width: compact ? 28 : 36,
              height: compact ? 28 : 36,
              decoration: BoxDecoration(
                color: (e.browsable ? palette.primary : scheme.secondary).withValues(alpha: .12),
                borderRadius: BorderRadius.circular(compact ? Radii.control : 10),
              ),
              child: Icon(_iconFor(e), size: compact ? 16 : 18, color: tint),
            ),
            SizedBox(width: compact ? Space.sm : Space.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    e.name,
                    style: compact ? theme.textTheme.bodyMedium : theme.textTheme.titleSmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    [
                      if (!e.browsable && e.size != null) formatFileSize(e.size!),
                      if (e.mode != null) formatMode(e.mode),
                    ].join(' · '),
                    style: mono(context, theme.textTheme.labelSmall).copyWith(color: scheme.onSurfaceVariant),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            IconButton(
              visualDensity: compact ? VisualDensity.compact : null,
              icon: Icon(Icons.more_vert, size: compact ? 18 : 20),
              onPressed: () => _showEntryActions(b, e),
            ),
          ],
        ),
      ),
    );
    return LongPressDraggable<_Drag>(
      data: _Drag(b, e, b.pathOf(e)),
      onDragStarted: HapticFeedback.selectionClick,
      childWhenDragging: Opacity(opacity: .4, child: row),
      feedback: Material(
        color: palette.raised,
        elevation: 6,
        borderRadius: BorderRadius.circular(Radii.card),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Space.md, vertical: Space.sm),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(_iconFor(e), size: 18, color: tint),
              const SizedBox(width: Space.sm),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 200),
                child: Text(e.name, maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
            ],
          ),
        ),
      ),
      child: row,
    );
  }
}

class _MobileFileEditorPage extends StatefulWidget {
  const _MobileFileEditorPage({
    required this.fs,
    required this.placeLabel,
    required this.remotePath,
    required this.fileName,
    this.onAskAiry,
  });

  final FileSystem fs;
  final String placeLabel;
  final String remotePath;
  final String fileName;
  final ValueChanged<String>? onAskAiry;

  @override
  State<_MobileFileEditorPage> createState() => _MobileFileEditorPageState();
}

class _MobileFileEditorPageState extends State<_MobileFileEditorPage> {
  final _controller = TextEditingController();
  var _loading = true;
  var _saving = false;
  var _editing = false;
  var _dirty = false;
  String? _error;

  /// The file as it was read; saving refuses if it changed since.
  FileEntry? _loaded;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final loaded = await widget.fs.stat(widget.remotePath);
      if (loaded == null) throw const FsError(FsFailure.notFound);
      final buffer = BytesBuilder(copy: false);
      await for (final chunk in widget.fs.read(widget.remotePath)) {
        buffer.add(chunk);
        if (buffer.length > _maxInlineEditBytes) throw const OpFailure('tooLarge');
      }
      final text = utf8.decode(buffer.takeBytes(), allowMalformed: true);
      if (!mounted) return;
      _loaded = loaded;
      _controller.text = text;
      setState(() => _loading = false);
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = fileError(AppLocalizations.of(context), e);
      });
    }
  }

  /// Written beside the file, checked, then swapped in only if the file is still the one that was read.
  Future<void> _save() async {
    final loaded = _loaded;
    if (_saving || loaded == null) return;
    setState(() => _saving = true);
    final l = AppLocalizations.of(context);
    try {
      final bytes = utf8.encode(_controller.text);
      await writeVerified(
        widget.fs,
        widget.remotePath,
        Stream.value(bytes),
        expectedSize: bytes.length,
        replacing: loaded,
      );
      if (!mounted) return;
      setState(() {
        _saving = false;
        _dirty = false;
        _editing = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.mobileFileSaved)));
      Navigator.of(context).pop(true);
    } on Object catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(fileError(l, e))));
    }
  }

  void _askAiry() {
    final cb = widget.onAskAiry;
    if (cb == null) return;
    final excerpt = _controller.text.length > 4000 ? _controller.text.substring(0, 4000) : _controller.text;
    cb('Analyze `${widget.remotePath}` on `${widget.placeLabel}`:\n```\n$excerpt\n```');
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final palette = BrandPalette.of(context);
    return Scaffold(
      backgroundColor: palette.background,
      appBar: AppBar(
        backgroundColor: palette.surface,
        surfaceTintColor: Colors.transparent,
        title: Text(widget.fileName, overflow: TextOverflow.ellipsis),
        actions: [
          if (widget.onAskAiry != null && !_loading && _error == null)
            IconButton(tooltip: l.mobileAskAiry, icon: const Icon(Icons.auto_awesome_outlined), onPressed: _askAiry),
          if (!_loading && _error == null)
            _editing
                ? TextButton(
                    onPressed: _saving || !_dirty ? null : () => unawaited(_save()),
                    child: _saving
                        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                        : Text(l.save),
                  )
                : IconButton(
                    tooltip: l.mobileFileEditor,
                    icon: const Icon(Icons.edit_outlined),
                    onPressed: () => setState(() => _editing = true),
                  ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(
              child: Padding(padding: const EdgeInsets.all(Space.xl), child: Text(_error!)),
            )
          : Padding(
              padding: const EdgeInsets.symmetric(horizontal: Space.lg, vertical: Space.md),
              child: TextField(
                controller: _controller,
                readOnly: !_editing,
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
                style: mono(context, Theme.of(context).textTheme.bodySmall),
                decoration: const InputDecoration(border: InputBorder.none),
                onChanged: (_) {
                  if (!_dirty) setState(() => _dirty = true);
                },
              ),
            ),
    );
  }
}

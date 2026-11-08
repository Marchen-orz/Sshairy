import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../design/controls.dart';
import '../../../design/dialog.dart';
import '../../../design/menu.dart';
import '../../../design/popup.dart';
import '../../../design/text_prompt.dart';
import '../../../design/theme.dart';
import '../../../foundation/file_system.dart';
import '../../../foundation/open_external.dart';
import '../../../foundation/result.dart';
import '../../../l10n/app_localizations.dart';
import '../../connections/api.dart';
import '../../hosts/api.dart';
import '../adapters/desktop.dart';
import '../application/browser.dart';
import '../application/edits.dart';
import '../application/file_ops.dart';
import '../application/transfers.dart';
import '../domain/transfer.dart';
import 'file_text.dart';

const _rowHeight = 28.0;

/// Entries dragged out of a pane.
class FileDrag {
  const FileDrag(this.from, this.entries);
  final FileBrowser from;
  final List<FileEntry> entries;
}

/// One directory listing with its toolbar (docs/MODULES.md §4). The two-pane page and the terminal's side panel
/// both use it; with [other] set, items can be sent or dragged to that pane, otherwise downloads ask for a folder.
class FilePane extends ConsumerStatefulWidget {
  const FilePane({
    super.key,
    required this.browser,
    this.other,
    this.pickHost = false,
    this.sidebar,
    this.toolbarActions = const [],
  });

  final FileBrowser browser;
  final FileBrowser? other;

  /// Shows a host chooser in the toolbar, for the two-pane page.
  final bool pickHost;

  /// Left of the list, under the toolbar, once connected: the directory tree of the panel docked below.
  final Widget? sidebar;

  /// Docking and close controls share the path toolbar instead of a separate panel header.
  final List<Widget> toolbarActions;

  @override
  ConsumerState<FilePane> createState() => _FilePaneState();
}

class _FilePaneState extends ConsumerState<FilePane> {
  final _list = FocusNode(debugLabel: 'file list');
  final _scroll = ScrollController();
  final _filter = TextEditingController();
  final _pathField = TextEditingController();
  var _editingPath = false, _dropping = false;
  var _typed = '';
  Timer? _typedReset;

  FileBrowser get b => widget.browser;
  AppLocalizations get l => AppLocalizations.of(context);
  TransferManager get _transfers => ref.read(transfersProvider.notifier);

  @override
  void dispose() {
    _typedReset?.cancel();
    _list.dispose();
    _scroll.dispose();
    _filter.dispose();
    _pathField.dispose();
    super.dispose();
  }

  void _toast(String text) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  void _report(Object? failure) {
    if (failure != null) _toast(fileError(l, failure));
  }

  Future<void> _open(FileEntry e) async {
    if (e.browsable) return b.enter(e);
    if (e.kind != FileKind.file) return;
    final host = b.host;
    if (host == null) {
      await openFile(b.pathOf(e));
      return;
    }
    final result = await ref.read(editsProvider.notifier).open(host, b.pathOf(e));
    if (result case Err(:final error)) _toast(fileErrorCode(l, error.code));
  }

  List<FileEntry> _targets(FileEntry? clicked) {
    final sel = b.selection;
    if (clicked == null || sel.any((e) => e.name == clicked.name)) return sel;
    return [clicked];
  }

  void _send(List<FileEntry> items, FileBrowser to) {
    if (items.isEmpty || !to.ready) return;
    _transfers.enqueue(from: b.host, paths: [for (final e in items) b.pathOf(e)], to: to.host, targetDir: to.path);
  }

  Future<void> _downloadTo(List<FileEntry> items) async {
    final dir = await pickDirectory();
    if (dir == null || items.isEmpty) return;
    _transfers.enqueue(from: b.host, paths: [for (final e in items) b.pathOf(e)], to: null, targetDir: dir);
  }

  Future<void> _uploadPicked() async {
    _upload(await pickFiles());
  }

  void _upload(List<String> localPaths) {
    if (localPaths.isEmpty || !b.ready) return;
    _transfers.enqueue(from: null, paths: localPaths, to: b.host, targetDir: b.path);
  }

  Future<void> _newFolder() async {
    final name = await showAppDialog<String>(
      context: context,
      builder: (_) => TextPromptDialog(title: l.newFolder),
    );
    if (name != null && name.trim().isNotEmpty) _report(await b.mkdir(name));
  }

  Future<void> _rename(FileEntry e) async {
    final name = await showAppDialog<String>(
      context: context,
      builder: (_) => TextPromptDialog(title: l.rename, initial: e.name),
    );
    if (name != null && name.trim().isNotEmpty) _report(await b.rename(e, name));
  }

  Future<void> _delete(List<FileEntry> items) async {
    if (items.isEmpty) return;
    String text;
    if (items.length > 1) {
      text = l.deleteMany(items.length);
    } else if (items.single.isDir) {
      final count = await countTree(b.fs!, b.pathOf(items.single), items.single).catchError((_) => 1);
      text = count > 1 ? l.deleteTree(items.single.name, count - 1) : l.deleteOne(items.single.name);
    } else {
      text = l.deleteOne(items.single.name);
    }
    if (!mounted) return;
    final ok = await showAppDialog<bool>(
      context: context,
      builder: (context) => AppDialog(
        content: Text(text),
        actions: [
          TextButton(autofocus: true, onPressed: () => Navigator.pop(context, false), child: Text(l.cancel)),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.pop(context, true),
            child: Text(l.delete),
          ),
        ],
      ),
    );
    if (ok ?? false) _report(await b.delete(items));
  }

  Future<void> _chmod(FileEntry e) async {
    final mode = await showAppDialog<int>(context: context, builder: (_) => _ModeDialog(e.name, e.mode ?? 0));
    if (mode != null) _report(await b.chmod(e, mode));
  }

  Future<void> _menu(Offset at, FileEntry? clicked) async {
    if (clicked != null && !b.selected.contains(clicked.name)) b.select(clicked.name);
    final items = _targets(clicked);
    final other = widget.other;
    final fs = b.fs;
    AppMenuItem<VoidCallback> item(String label, IconData icon, VoidCallback? run) =>
        AppMenuItem(value: run ?? () {}, label: label, icon: icon, enabled: run != null);
    final single = items.length == 1 ? items.single : null;
    final run = await showAppMenu<VoidCallback>(
      context: context,
      anchor: anchorAt(at),
      items: [
        if (single != null) ...[
          item(
            single.browsable || b.local ? l.open : l.editFile,
            single.browsable ? Icons.folder_open_outlined : Icons.edit_outlined,
            single.browsable || single.kind == FileKind.file ? () => _open(single) : null,
          ),
        ],
        if (items.isNotEmpty) ...[
          if (other != null)
            item(l.sendToOther, Icons.swap_horiz, other.ready ? () => _send(items, other) : null)
          else if (!b.local)
            item(l.downloadTo, Icons.download_outlined, () => _downloadTo(items)),
          if (single != null) item(l.rename, Icons.drive_file_rename_outline, () => _rename(single)),
          if (single != null && fs != null && fs.canChmod && single.mode != null)
            item(l.permissions, Icons.lock_outline, () => _chmod(single)),
          item(
            l.copyPath,
            Icons.content_copy,
            () => Clipboard.setData(ClipboardData(text: items.map(b.pathOf).join('\n'))),
          ),
          item(l.delete, Icons.delete_outline, () => _delete(items)),
          const AppMenuDivider(),
        ],
        item(l.newFolder, Icons.create_new_folder_outlined, _newFolder),
        if (!b.local) item(l.uploadFiles, Icons.upload_outlined, _uploadPicked),
        item(l.refresh, Icons.refresh, b.refresh),
      ],
    );
    run?.call();
  }

  void _tap(FileEntry e) {
    _list.requestFocus();
    final keys = HardwareKeyboard.instance;
    b.select(e.name, toggle: keys.isControlPressed || keys.isMetaPressed, range: keys.isShiftPressed);
  }

  void _reveal(String name) {
    final i = b.visible.indexWhere((e) => e.name == name);
    if (i < 0 || !_scroll.hasClients) return;
    final top = i * _rowHeight, view = _scroll.position.viewportDimension;
    if (top < _scroll.offset) {
      _scroll.jumpTo(top);
    } else if (top + _rowHeight > _scroll.offset + view) {
      _scroll.jumpTo(top + _rowHeight - view);
    }
  }

  void _editPath() => setState(() {
    _pathField.text = b.path;
    _editingPath = true;
  });

  void _move(int delta, {required bool extend}) {
    final names = b.visible.map((e) => e.name).toList();
    if (names.isEmpty) return;
    final current = b.selection.isEmpty
        ? -1
        : names.indexOf(delta > 0 ? b.selection.last.name : b.selection.first.name);
    final next = (current + delta).clamp(0, names.length - 1);
    b.select(names[next], range: extend);
    _reveal(names[next]);
  }

  /// The list's keys from MODULES §4; a focused text field or dialog gets its keys first.
  KeyEventResult _onKey(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    final keys = HardwareKeyboard.instance;
    final ctrl = keys.isControlPressed || keys.isMetaPressed;
    final sel = b.selection;
    switch (event.logicalKey) {
      case LogicalKeyboardKey.enter when sel.length == 1:
        _open(sel.single);
      case LogicalKeyboardKey.backspace:
        b.up();
      case LogicalKeyboardKey.f2 when sel.length == 1:
        _rename(sel.single);
      case LogicalKeyboardKey.f5:
        b.refresh();
      case LogicalKeyboardKey.delete when sel.isNotEmpty:
        _delete(sel);
      case LogicalKeyboardKey.keyA when ctrl:
        b.selectAll();
      case LogicalKeyboardKey.keyL when ctrl:
        _editPath();
      case LogicalKeyboardKey.arrowDown:
        _move(1, extend: keys.isShiftPressed);
      case LogicalKeyboardKey.arrowUp:
        _move(-1, extend: keys.isShiftPressed);
      case LogicalKeyboardKey.escape when sel.isNotEmpty:
        b.clearSelection();
      default:
        final ch = event.character;
        if (ctrl || keys.isAltPressed || ch == null || ch.trim().isEmpty || ch.codeUnitAt(0) < 32) {
          return KeyEventResult.ignored;
        }
        // Typing jumps to the first name that starts with what was typed in the last moment.
        _typed += ch.toLowerCase();
        _typedReset?.cancel();
        _typedReset = Timer(const Duration(milliseconds: 800), () => _typed = '');
        final hit = b.visible.where((e) => e.name.toLowerCase().startsWith(_typed)).firstOrNull;
        if (hit != null) {
          b.select(hit.name);
          _reveal(hit.name);
        }
    }
    return KeyEventResult.handled;
  }

  /// Whether a transfer that ended at [end] changed what this pane lists.
  bool _shows(FileEnd end) {
    if (!b.ready || end.host != b.host?.id) return false;
    final sep = b.style.separator;
    return b.style.parent(end.path) == b.path || b.path == end.path || b.path.startsWith('${end.path}$sep');
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    ref.listen(transfersProvider, (before, now) {
      final running = {
        for (final t in before ?? const <Transfer>[])
          if (t.state.active) t.id,
      };
      if (now.any((t) => running.contains(t.id) && !t.state.active && _shows(t.target))) b.refresh();
    });
    return ListenableBuilder(
      listenable: b,
      builder: (context, _) => OsDropZone(
        enabled: b.ready,
        onHover: (on) => setState(() => _dropping = on),
        onDrop: _upload,
        child: DragTarget<FileDrag>(
          onWillAcceptWithDetails: (d) => d.data.from != b && b.ready,
          onAcceptWithDetails: (d) => FilePaneSend(d.data, b).run(_transfers),
          builder: (context, candidates, _) => DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(
                color: _dropping || candidates.isNotEmpty ? scheme.primary : Colors.transparent,
                width: 2,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _toolbar(context),
                const Divider(),
                Expanded(
                  child: widget.sidebar == null || !b.ready
                      ? _body(context)
                      : Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            SizedBox(width: WorkspaceSize.directoryTree, child: widget.sidebar),
                            const VerticalDivider(width: WorkspaceSize.divider),
                            Expanded(child: _body(context)),
                          ],
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _toolbar(BuildContext context) {
    final theme = Theme.of(context);
    Widget icon(String tip, IconData i, VoidCallback? run) => IconButton(
      tooltip: tip,
      onPressed: run,
      constraints: const BoxConstraints.tightFor(width: 28, height: 28),
      style: IconButton.styleFrom(minimumSize: const Size(28, 28), padding: EdgeInsets.zero),
      icon: Icon(i, size: 16),
    );
    final ready = b.ready;
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = widget.toolbarActions.isNotEmpty && constraints.maxWidth < 560;
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: Space.xs, vertical: Space.xs),
          child: Row(
            children: [
              if (widget.pickHost) _HostPicker(browser: b),
              if (!compact) ...[
                icon(l.back, Icons.arrow_back, ready && b.canBack ? b.back : null),
                icon(l.forward, Icons.arrow_forward, ready && b.canForward ? b.forward : null),
              ],
              icon(l.up, Icons.arrow_upward, ready ? b.up : null),
              const SizedBox(width: Space.xs),
              Expanded(child: ready ? _path(theme) : const SizedBox.shrink()),
              const SizedBox(width: Space.xs),
              SizedBox(
                width: compact ? 80 : 120,
                height: 28,
                child: TextField(
                  controller: _filter,
                  enabled: ready,
                  onChanged: b.setFilter,
                  style: theme.textTheme.bodySmall,
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: l.filter,
                    prefixIcon: const Icon(Icons.filter_list, size: 16),
                    prefixIconConstraints: const BoxConstraints(minWidth: 28),
                    contentPadding: const EdgeInsets.symmetric(vertical: Space.sm),
                  ),
                ),
              ),
              icon(l.refresh, Icons.refresh, ready ? b.refresh : null),
              AppMenuButton<VoidCallback>(
                tooltip: l.more,
                enabled: ready,
                icon: const Icon(Icons.more_horiz, size: 16),
                onSelected: (run) => run(),
                items: () => [
                  if (compact) ...[
                    AppMenuItem(value: b.back, label: l.back, icon: Icons.arrow_back, enabled: b.canBack),
                    AppMenuItem(value: b.forward, label: l.forward, icon: Icons.arrow_forward, enabled: b.canForward),
                    const AppMenuDivider(),
                  ],
                  AppMenuItem(value: _newFolder, label: l.newFolder),
                  if (!b.local) AppMenuItem(value: _uploadPicked, label: l.uploadFiles),
                  AppMenuItem(checked: b.showHidden, value: b.toggleHidden, label: l.hiddenFiles),
                  AppMenuItem(
                    value: () => Clipboard.setData(ClipboardData(text: b.path)),
                    label: l.copyPath,
                  ),
                ],
              ),
              ...widget.toolbarActions,
            ],
          ),
        );
      },
    );
  }

  /// Breadcrumbs; clicking the empty space after them or the last one turns them into a path field. The click target
  /// lies under them rather than beside, so a long path keeps the whole width.
  Widget _path(ThemeData theme) {
    if (_editingPath) {
      return SizedBox(
        height: 28,
        child: TextField(
          controller: _pathField,
          autofocus: true,
          style: mono(context, theme.textTheme.bodySmall),
          decoration: const InputDecoration(
            isDense: true,
            contentPadding: EdgeInsets.symmetric(horizontal: Space.sm, vertical: Space.sm),
          ),
          onTapOutside: (_) => setState(() => _editingPath = false),
          onSubmitted: (text) async {
            final error = await b.goTyped(text);
            if (!mounted) return;
            setState(() => _editingPath = error != null);
            _report(error);
          },
        ),
      );
    }
    final crumbs = b.style.crumbs(b.path);
    return Stack(
      children: [
        Positioned.fill(
          child: Tooltip(
            message: l.editPath,
            waitDuration: const Duration(milliseconds: 600),
            child: InkWell(onTap: _editPath),
          ),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            reverse: true,
            child: Row(
              children: [
                for (final (i, (label, path)) in crumbs.indexed) ...[
                  if (i > 0 && !(i == 1 && crumbs.first.$1 == '/'))
                    Icon(Icons.chevron_right, size: 14, color: theme.colorScheme.onSurfaceVariant),
                  InkWell(
                    borderRadius: BorderRadius.circular(Radii.control),
                    // The current folder has nowhere to go, so it edits the path; a long path may leave no empty space.
                    onTap: i == crumbs.length - 1 ? _editPath : () => b.go(path),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: Space.xs, vertical: Space.xs),
                      child: label.isEmpty
                          ? Icon(Icons.computer, size: 16, color: theme.colorScheme.onSurfaceVariant)
                          : Text(label, style: theme.textTheme.bodySmall),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _body(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    switch (b.status) {
      case BrowserStatus.idle when b.suspended:
        return const SizedBox.shrink();
      case BrowserStatus.idle when widget.pickHost:
        return _HostList(browser: b);
      case BrowserStatus.idle || BrowserStatus.connecting:
        return const Center(child: SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)));
      case BrowserStatus.failed || BrowserStatus.lost:
        final text = b.status == BrowserStatus.lost ? l.errFsLost : connectErrorText(l, b.connectError);
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                text,
                style: TextStyle(color: theme.colorScheme.error),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: Space.md),
              FilledButton.tonal(onPressed: () => b.reconnect(DialogPrompts(context)), child: Text(l.retry)),
            ],
          ),
        );
      case BrowserStatus.ready:
        break;
    }
    final items = b.visible;
    return LayoutBuilder(
      builder: (context, box) {
        final wide = box.maxWidth >= 560, medium = box.maxWidth >= 380;
        final columns = _Columns(modified: medium, size: box.maxWidth >= 300, mode: wide && !b.local);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (b.listError != null)
              Container(
                color: theme.colorScheme.errorContainer.withValues(alpha: 0.3),
                padding: const EdgeInsets.symmetric(horizontal: Space.md, vertical: Space.xs),
                child: Text(
                  fileError(l, b.listError),
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
                ),
              ),
            _Header(browser: b, columns: columns),
            if (b.loading) const LinearProgressIndicator(minHeight: 2) else const SizedBox(height: 2),
            Expanded(
              child: Focus(
                focusNode: _list,
                onKeyEvent: _onKey,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    _list.requestFocus();
                    b.clearSelection();
                  },
                  onSecondaryTapUp: (d) => _menu(d.globalPosition, null),
                  child: items.isEmpty
                      ? Center(child: Text(l.emptyFolder, style: muted))
                      : ListView.builder(
                          controller: _scroll,
                          itemExtent: _rowHeight,
                          itemCount: items.length,
                          itemBuilder: (context, i) {
                            final e = items[i];
                            final row = _Row(
                              entry: e,
                              columns: columns,
                              selected: b.selected.contains(e.name),
                              onTap: () => _tap(e),
                              onDoubleTap: () => _open(e),
                              onSecondaryTap: (p) => _menu(p, e),
                            );
                            return Draggable<FileDrag>(
                              data: FileDrag(b, _targets(e)),
                              dragAnchorStrategy: pointerDragAnchorStrategy,
                              onDragStarted: () {
                                if (!b.selected.contains(e.name)) b.select(e.name);
                              },
                              feedback: _DragFeedback(_targets(e)),
                              child: row,
                            );
                          },
                        ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// A drop of [drag] onto [to]; split out so the page's own drop zones queue the same way.
class FilePaneSend {
  const FilePaneSend(this.drag, this.to);
  final FileDrag drag;
  final FileBrowser to;

  void run(TransferManager transfers) {
    final from = drag.from;
    if (drag.entries.isEmpty || !to.ready) return;
    transfers.enqueue(
      from: from.host,
      paths: [for (final e in drag.entries) from.pathOf(e)],
      to: to.host,
      targetDir: to.path,
    );
  }
}

class _Columns {
  const _Columns({required this.modified, required this.size, required this.mode});
  final bool modified, size, mode;
}

class _Header extends StatelessWidget {
  const _Header({required this.browser, required this.columns});

  final FileBrowser browser;
  final _Columns columns;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final style = theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    Widget cell(String text, FileSort? sort, {TextAlign align = TextAlign.start}) {
      final active = sort != null && browser.sort == sort;
      final label = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(text, style: style, overflow: TextOverflow.ellipsis),
          ),
          if (active)
            Icon(browser.descending ? Icons.arrow_downward : Icons.arrow_upward, size: 12, color: style?.color),
        ],
      );
      return sort == null
          ? label
          : InkWell(
              onTap: () => browser.setSort(sort),
              child: Align(
                alignment: align == TextAlign.end ? Alignment.centerRight : Alignment.centerLeft,
                child: label,
              ),
            );
    }

    return SizedBox(
      height: 26,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Space.md),
        child: Row(
          children: [
            const SizedBox(width: 24),
            Expanded(child: cell(l.colName, FileSort.name)),
            if (columns.modified) SizedBox(width: 128, child: cell(l.colModified, FileSort.modified)),
            if (columns.size) SizedBox(width: 72, child: cell(l.colSize, FileSort.size, align: TextAlign.end)),
            if (columns.mode) ...[
              const SizedBox(width: Space.md),
              SizedBox(width: 150, child: cell('${l.permissions} · ${l.colOwner}', null)),
            ],
          ],
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.entry,
    required this.columns,
    required this.selected,
    required this.onTap,
    required this.onDoubleTap,
    required this.onSecondaryTap,
  });

  final FileEntry entry;
  final _Columns columns;
  final bool selected;
  final VoidCallback onTap, onDoubleTap;
  final void Function(Offset) onSecondaryTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    final e = entry;
    final icon = switch (e.kind) {
      FileKind.directory => Icons.folder,
      FileKind.link when e.linkToDir => Icons.folder_open,
      FileKind.link => Icons.link,
      FileKind.file => Icons.description_outlined,
      FileKind.other => Icons.insert_drive_file_outlined,
    };
    return Material(
      color: selected ? scheme.primary.withValues(alpha: 0.14) : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        onDoubleTap: onDoubleTap,
        onSecondaryTapUp: (d) => onSecondaryTap(d.globalPosition),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Space.md),
          child: Row(
            children: [
              Icon(icon, size: 16, color: e.browsable ? scheme.primary : scheme.onSurfaceVariant),
              const SizedBox(width: Space.sm),
              Expanded(
                child: Text(
                  e.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: e.hidden ? theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant) : null,
                ),
              ),
              if (columns.modified) SizedBox(width: 128, child: Text(formatTime(e.modified), style: muted)),
              if (columns.size)
                SizedBox(
                  width: 72,
                  child: Text(e.isDir ? '' : formatSize(e.size), style: muted, textAlign: TextAlign.end),
                ),
              if (columns.mode) ...[
                const SizedBox(width: Space.md),
                SizedBox(
                  width: 150,
                  child: Text(
                    [formatMode(e.mode), ?e.owner].join(' '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: mono(context, muted),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _DragFeedback extends StatelessWidget {
  const _DragFeedback(this.entries);
  final List<FileEntry> entries;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      elevation: 4,
      borderRadius: BorderRadius.circular(Radii.control),
      color: scheme.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Space.md, vertical: Space.sm),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(entries.length == 1 && entries.single.isDir ? Icons.folder : Icons.description_outlined, size: 16),
            const SizedBox(width: Space.sm),
            Text(entries.length == 1 ? entries.single.name : '${entries.first.name} +${entries.length - 1}'),
          ],
        ),
      ),
    );
  }
}

/// This computer or a saved host, for the two-pane page.
class _HostPicker extends ConsumerWidget {
  const _HostPicker({required this.browser});
  final FileBrowser browser;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final hosts = sortHosts(ref.watch(hostsProvider), recent: true);
    final current = browser.host;
    return AppMenuButton<Host?>(
      onSelected: (h) => browser.open(h, DialogPrompts(context)),
      items: () => [
        AppMenuItem(value: null, label: l.thisComputer, icon: Icons.computer),
        for (final h in hosts) AppMenuItem(value: h, label: h.title, icon: Icons.dns_outlined),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Space.sm, vertical: Space.xs),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 160),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(current == null && browser.fs != null ? Icons.computer : Icons.dns_outlined, size: 16),
              const SizedBox(width: Space.sm),
              Flexible(
                child: Text(
                  current?.title ?? (browser.fs != null ? l.thisComputer : '—'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const Icon(Icons.keyboard_arrow_down_rounded, size: 16),
            ],
          ),
        ),
      ),
    );
  }
}

/// What an unopened pane shows: the places it can open.
class _HostList extends ConsumerWidget {
  const _HostList({required this.browser});
  final FileBrowser browser;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final hosts = sortHosts(ref.watch(hostsProvider), recent: true);
    final muted = Theme.of(context).textTheme.bodySmall
        ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant);
    return ListView(
      padding: const EdgeInsets.all(Space.md),
      children: [
        ListTile(
          dense: true,
          leading: const Icon(Icons.computer),
          title: Text(l.thisComputer),
          onTap: () => browser.open(null, DialogPrompts(context)),
        ),
        for (final h in hosts)
          ListTile(
            dense: true,
            leading: const Icon(Icons.dns_outlined),
            title: Text(h.title),
            subtitle: Text(h.target, style: muted),
            onTap: () => browser.open(h, DialogPrompts(context)),
          ),
      ],
    );
  }
}

class _ModeDialog extends StatefulWidget {
  const _ModeDialog(this.name, this.mode);
  final String name;
  final int mode;

  @override
  State<_ModeDialog> createState() => _ModeDialogState();
}

class _ModeDialogState extends State<_ModeDialog> {
  late int _mode = widget.mode & 0xFFF;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final monoStyle = mono(context, Theme.of(context).textTheme.bodyMedium);
    final rows = [(l.permOwner, 6), (l.permGroup, 3), (l.permOthers, 0)];
    final cols = [(l.permRead, 2), (l.permWrite, 1), (l.permExecute, 0)];
    return AppDialog(
      title: Text(widget.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Table(
            defaultColumnWidth: const IntrinsicColumnWidth(),
            defaultVerticalAlignment: TableCellVerticalAlignment.middle,
            children: [
              TableRow(
                children: [
                  const SizedBox.shrink(),
                  for (final (label, _) in cols)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: Space.sm),
                      child: Text(label, textAlign: TextAlign.center),
                    ),
                ],
              ),
              for (final (label, shift) in rows)
                TableRow(
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(right: Space.md),
                      child: Text(label),
                    ),
                    for (final (_, bit) in cols)
                      Padding(
                        padding: const EdgeInsets.all(Space.sm),
                        child: Center(
                          child: AppCheckbox(
                            value: _mode & (1 << (shift + bit)) != 0,
                            onChanged: (v) => setState(() => _mode ^= 1 << (shift + bit)),
                          ),
                        ),
                      ),
                  ],
                ),
            ],
          ),
          const SizedBox(height: Space.md),
          Text('${(_mode & 0x1FF).toRadixString(8).padLeft(3, '0')}  ${formatMode(_mode)}', style: monoStyle),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(l.cancel)),
        FilledButton(onPressed: () => Navigator.pop(context, _mode), child: Text(l.save)),
      ],
    );
  }
}

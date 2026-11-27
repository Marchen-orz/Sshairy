import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../design/controls.dart';
import '../../../design/double_click.dart';
import '../../../design/dialog.dart';
import '../../../design/menu.dart';
import '../../../design/popup.dart';
import '../../../design/scrolling.dart';
import '../../../design/text_prompt.dart';
import '../../../design/theme.dart';
import '../../../foundation/file_system.dart';
import '../../../foundation/open_external.dart';
import '../../../foundation/result.dart';
import '../../../l10n/app_localizations.dart';
import '../../../platform/file_drop.dart';
import '../../connections/api.dart';
import '../../hosts/api.dart';
import '../../settings/api.dart';
import '../adapters/desktop.dart';
import '../application/bookmarks.dart';
import '../application/browser.dart';
import '../application/edits.dart';
import '../application/file_ops.dart';
import '../application/file_systems.dart';
import '../application/open_with.dart';
import '../application/transfers.dart';
import '../domain/transfer.dart';
import 'file_text.dart';
import 'open_with_dialog.dart';

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
  var _clicks = DoubleClick();
  String? _clicked;
  final _scroll = ScrollController();
  final _filter = TextEditingController();
  final _pathField = TextEditingController();
  var _editingPath = false, _dropping = false;
  var _editedPath = '';
  var _typed = '';
  Timer? _typedReset;

  FileBrowser get b => widget.browser;
  AppLocalizations get l => AppLocalizations.of(context);
  TransferManager get _transfers => ref.read(transfersProvider.notifier);

  @override
  void initState() {
    super.initState();
    b.setShowHidden(ref.read(settingsProvider).get(SettingKeys.showHidden));
    b.addListener(_browserChanged);
  }

  @override
  void didUpdateWidget(FilePane old) {
    super.didUpdateWidget(old);
    if (old.browser != b) {
      old.browser.removeListener(_browserChanged);
      b.addListener(_browserChanged);
      b.setShowHidden(ref.read(settingsProvider).get(SettingKeys.showHidden));
    }
  }

  /// Any move, from this pane, the tree or the terminal, closes the path field and the filter the browser dropped.
  void _browserChanged() {
    if (_editingPath && b.path != _editedPath) setState(() => _editingPath = false);
    if (_filter.text != b.filter) _filter.text = b.filter;
  }

  @override
  void dispose() {
    b.removeListener(_browserChanged);
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
      if (b.location == null) await openFile(b.pathOf(e));
      return;
    }
    final result = await ref.read(editsProvider.notifier).open(host, b.pathOf(e));
    if (result case Err(:final error)) _toast(fileErrorCode(l, error.code));
  }

  /// Opens a remote file in a program picked now; the pick also becomes the file type's default unless declined.
  Future<void> _openWith(FileEntry e) async {
    final host = b.host;
    if (host == null) return;
    final choice = await showOpenWithDialog(context, e.name);
    if (choice == null || !mounted) return;
    if (choice.remember) {
      final saved = await ref.read(editorAppsProvider.notifier).setDefault(e.name, choice.app);
      if (saved case Err(:final error)) _toast(fileErrorCode(l, error.code));
      if (!mounted) return;
    }
    final result = await ref.read(editsProvider.notifier).open(host, b.pathOf(e), app: choice.app);
    if (result case Err(:final error)) _toast(fileErrorCode(l, error.code));
  }

  List<FileEntry> _targets(FileEntry? clicked) {
    final sel = b.selection;
    if (clicked == null || sel.any((e) => e.name == clicked.name)) return sel;
    return [clicked];
  }

  void _send(List<FileEntry> items, FileBrowser to) => _report(FilePaneSend(FileDrag(b, items), to).run(_transfers));

  Future<void> _downloadTo(List<FileEntry> items) async {
    final dir = await pickDirectory();
    if (dir == null || items.isEmpty) return;
    _report(queueCopy(_transfers, b, [for (final e in items) b.pathOf(e)], null, dir));
  }

  Future<void> _uploadPicked() async {
    _upload(await pickFiles());
  }

  void _upload(List<String> localPaths) {
    if (localPaths.isEmpty || !b.ready) return;
    _report(queueCopy(_transfers, null, localPaths, b, b.path));
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
            single.browsable || b.host == null ? l.open : l.editFile,
            single.browsable ? Icons.folder_open_outlined : Icons.edit_outlined,
            single.browsable || single.kind == FileKind.file && b.location == null ? () => _open(single) : null,
          ),
          if (single.kind == FileKind.file && b.host != null && ref.read(editorLauncherProvider).canChoose)
            item(l.openWith, Icons.open_in_new, () => _openWith(single)),
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
    final modified = keys.isControlPressed || keys.isMetaPressed || keys.isShiftPressed;
    if (modified || _clicked != e.name) _clicks = DoubleClick();
    _clicked = e.name;
    b.select(e.name, toggle: keys.isControlPressed || keys.isMetaPressed, range: keys.isShiftPressed);
    if (!modified && _clicks.hit) {
      _clicks = DoubleClick();
      unawaited(_open(e));
    }
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
    _pathField.text = _editedPath = b.path;
    _pathField.selection = TextSelection(baseOffset: 0, extentOffset: b.path.length);
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
    if (!b.ready || end.host != b.host?.id || end.locationId != b.location?.id) return false;
    final sep = b.style.separator;
    return b.style.parent(end.path) == b.path || b.path == end.path || b.path.startsWith('${end.path}$sep');
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    ref.listen(settingsProvider.select((s) => s.get(SettingKeys.showHidden)), (_, value) => b.setShowHidden(value));
    ref.listen(fileLocationsProvider, (_, _) => b.checkLocation());
    ref.listen(transfersProvider, (before, now) {
      final running = {
        for (final t in before ?? const <Transfer>[])
          if (t.state.active) t.id,
      };
      if (now.any((t) => running.contains(t.id) && !t.state.active && _shows(t.target))) b.refresh();
    });
    return ListenableBuilder(
      listenable: b,
      builder: (context, _) => FileDropZone(
        enabled: b.ready,
        onHover: (on) => setState(() => _dropping = on),
        onDrop: (paths, _) => _upload(paths),
        child: DragTarget<FileDrag>(
          onWillAcceptWithDetails: (d) => d.data.from != b && b.ready,
          onAcceptWithDetails: (d) => _report(FilePaneSend(d.data, b).run(_transfers)),
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
              if (_bookmarkKey case final key?) _bookmarkMenu(key, ready),
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
                  AppMenuItem(
                    checked: b.showHidden,
                    value: () => ref.read(settingsProvider.notifier).set(SettingKeys.showHidden, !b.showHidden),
                    label: l.hiddenFiles,
                  ),
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

  /// Bookmarks belong to a saved host or this computer; a phone's folders have no stable owner to keep them under.
  String? get _bookmarkKey => b.local ? Bookmarks.local : b.host?.id.value;

  Widget _bookmarkMenu(String key, bool ready) {
    final paths = ref.watch(bookmarksProvider)[key] ?? const [];
    final marked = paths.contains(b.path);
    final bookmarks = ref.read(bookmarksProvider.notifier);
    return AppMenuButton<VoidCallback>(
      tooltip: l.bookmarks,
      enabled: ready,
      icon: Icon(marked ? Icons.bookmark : Icons.bookmark_border, size: 16),
      onSelected: (run) => run(),
      items: () => [
        AppMenuItem(
          value: () => unawaited(bookmarks.toggle(key, b.path)),
          label: marked ? l.removeBookmark : l.addBookmark,
          icon: marked ? Icons.bookmark_remove_outlined : Icons.bookmark_add_outlined,
          enabled: marked || paths.length < Bookmarks.maxPerHost,
        ),
        if (paths.isNotEmpty) const AppMenuDivider(),
        for (final path in paths) AppMenuItem(value: () => b.go(path), label: path, checked: path == b.path),
      ],
    );
  }

  /// Breadcrumbs; clicking the empty space after them or double clicking the current folder turns them into a path
  /// field. The click target lies under them rather than beside, so a long path keeps the whole width.
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
                    // The current folder has nowhere to go; double clicking it edits the path when no space is left.
                    onTap: i == crumbs.length - 1 ? null : () => b.go(path),
                    onDoubleTap: i == crumbs.length - 1 ? _editPath : null,
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
    final host = b.host?.id;
    final opening = {
      for (final p in ref.watch(editProgressProvider).values)
        if (p.host == host && !p.upload) p.remotePath: p,
    };
    return ScrollGutterLayout(
      builder: (context, box) {
        final width = box.maxWidth - ScrollGutterScope.gapOf(context);
        final wide = width >= 560, medium = width >= 380;
        final columns = _Columns(modified: medium, size: width >= 300, mode: wide && !b.local);
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
            ScrollGutter(
              child: _Header(browser: b, columns: columns),
            ),
            if (b.loading || b.refreshingQuietly)
              const LinearProgressIndicator(minHeight: 2)
            else
              const SizedBox(height: 2),
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
                              opening: opening[b.pathOf(e)],
                              onTap: () => _tap(e),
                              onSecondaryTap: (p) => _menu(p, e),
                            );
                            if (widget.other == null) return row;
                            final targets = _targets(e);
                            void onStart() {
                              if (!b.selected.contains(e.name)) b.select(e.name);
                            }

                            final touch = switch (theme.platform) {
                              TargetPlatform.android || TargetPlatform.iOS => true,
                              _ => false,
                            };
                            if (touch) {
                              return LongPressDraggable<FileDrag>(
                                data: FileDrag(b, targets),
                                dragAnchorStrategy: pointerDragAnchorStrategy,
                                onDragStarted: () {
                                  unawaited(HapticFeedback.selectionClick());
                                  onStart();
                                },
                                feedback: _DragFeedback(targets),
                                child: row,
                              );
                            }
                            return Draggable<FileDrag>(
                              data: FileDrag(b, targets),
                              dragAnchorStrategy: pointerDragAnchorStrategy,
                              onDragStarted: onStart,
                              feedback: _DragFeedback(targets),
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

  /// The failure, if the copy could not be queued.
  Object? run(TransferManager transfers) {
    final from = drag.from;
    if (drag.entries.isEmpty || !to.ready) return null;
    return queueCopy(transfers, from, [for (final e in drag.entries) from.pathOf(e)], to, to.path);
  }
}

/// Queues [paths] on [from] into [targetDir] on [to], either null for this device; the failure, if any.
Object? queueCopy(TransferManager transfers, FileBrowser? from, List<String> paths, FileBrowser? to, String targetDir) {
  try {
    transfers.enqueue(
      from: from?.host,
      paths: paths,
      to: to?.host,
      targetDir: targetDir,
      fromLocation: from?.placement,
      toLocation: to?.placement,
    );
    return null;
  } on OpFailure catch (e) {
    return e;
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
    this.opening,
    required this.onTap,
    required this.onSecondaryTap,
  });

  final FileEntry entry;
  final _Columns columns;
  final bool selected;

  /// The download that will open this file in an editor.
  final EditProgress? opening;
  final VoidCallback onTap;
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
        onSecondaryTapUp: (d) => onSecondaryTap(d.globalPosition),
        child: Stack(
          alignment: Alignment.center,
          children: [
            Padding(
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
            if (opening != null)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: LinearProgressIndicator(value: opening!.fraction, minHeight: 2),
              ),
          ],
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
    final places = ref.watch(fileLocationsProvider);
    final current = browser.host;
    final location = browser.location;
    return AppMenuButton<Object?>(
      onSelected: (v) => v is FileLocation ? browser.openLocation(v) : browser.open(v as Host?, DialogPrompts(context)),
      items: () => [
        AppMenuItem(value: null, label: l.thisComputer, icon: Icons.computer),
        for (final p in places) AppMenuItem(value: p, label: p.label, icon: Icons.smartphone),
        for (final h in hosts) AppMenuItem(value: h, label: h.title, icon: Icons.dns_outlined),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Space.sm, vertical: Space.xs),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 160),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                location != null
                    ? Icons.smartphone
                    : current == null && browser.fs != null
                    ? Icons.computer
                    : Icons.dns_outlined,
                size: 16,
              ),
              const SizedBox(width: Space.sm),
              Flexible(
                child: Text(
                  location?.label ?? current?.title ?? (browser.fs != null ? l.thisComputer : '—'),
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
        for (final p in ref.watch(fileLocationsProvider))
          ListTile(
            dense: true,
            leading: const Icon(Icons.smartphone),
            title: Text(p.label),
            onTap: () => browser.openLocation(p),
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

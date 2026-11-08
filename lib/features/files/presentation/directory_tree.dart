import 'package:flutter/material.dart';

import '../../../design/theme.dart';
import '../../../foundation/file_system.dart';
import '../application/browser.dart';

/// The folders of [browser]'s file system from the root, beside the list when the panel is docked below
/// (docs/MODULES.md §4). Children are listed when a folder opens; the current path's ancestors open by themselves.
class DirectoryTree extends StatefulWidget {
  const DirectoryTree({super.key, required this.browser});

  final FileBrowser browser;

  @override
  State<DirectoryTree> createState() => _DirectoryTreeState();
}

class _DirectoryTreeState extends State<DirectoryTree> {
  static const _indent = 12.0;

  /// Folder names by path; a path being listed has no entry yet, one that failed has an empty list.
  final _children = <String, List<String>>{};
  final _listing = <String>{};
  final _open = <String>{};
  final _scroll = ScrollController();
  var _childCount = 0;
  var _generation = 0;
  FileSystem? _fs;
  var _path = '';
  var _hidden = false;

  FileBrowser get b => widget.browser;

  @override
  void initState() {
    super.initState();
    b.addListener(_changed);
    _changed();
  }

  @override
  void didUpdateWidget(DirectoryTree old) {
    super.didUpdateWidget(old);
    if (identical(old.browser, b)) return;
    old.browser.removeListener(_changed);
    b.addListener(_changed);
    _changed();
  }

  @override
  void dispose() {
    b.removeListener(_changed);
    _scroll.dispose();
    super.dispose();
  }

  /// `/` on a server; a drive, or the list of drives, on Windows.
  String get _root => b.style.crumbs(b.path).first.$2;

  void _changed() {
    final fs = b.fs;
    if (!identical(fs, _fs) || b.showHidden != _hidden) {
      _fs = fs;
      _hidden = b.showHidden;
      _generation++;
      _children.clear();
      _listing.clear();
      _open.clear();
      _childCount = 0;
      _path = '';
    }
    if (fs == null || !b.ready || b.path.isEmpty) {
      if (mounted) setState(() {});
      return;
    }
    // The browser already listed where it is: that keeps the tree in step with folders made, renamed or deleted.
    if (!b.loading && b.listError == null) _cache(b.path, _folders(b.entries));
    if (b.path != _path) {
      _path = b.path;
      for (final (_, ancestor) in b.style.crumbs(b.path)) {
        _open.add(ancestor);
        _load(ancestor);
      }
    }
    if (mounted) setState(() {});
  }

  List<String> _folders(List<FileEntry> entries) => [
    for (final e in entries)
      if (e.browsable && (_hidden || !e.hidden)) e.name,
  ]..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

  void _cache(String path, List<String> folders) {
    _childCount -= _children.remove(path)?.length ?? 0;
    _children[path] = folders;
    _childCount += folders.length;
    _prune();
  }

  void _prune() {
    final protected = {for (final (_, path) in b.style.crumbs(b.path)) path};
    // shortcut: current ancestors can exceed the cache targets; never truncate a real directory listing.
    while (_children.length > 128 || _childCount > 8192) {
      final candidates = _children.keys.where((path) => !protected.contains(path)).toList();
      if (candidates.isEmpty) break;
      final path = candidates.firstWhere(
        (path) => b.style.crumbs(path).any((crumb) => !_open.contains(crumb.$2)),
        orElse: () => candidates.first,
      );
      _childCount -= _children.remove(path)!.length;
      _open.remove(path);
    }
    // Expansion state for evicted descendants is cheap to recreate when their parent opens again.
    _open.removeWhere((path) => !_children.containsKey(path) && !_listing.contains(path) && !protected.contains(path));
  }

  Future<void> _load(String path) async {
    final fs = _fs;
    if (fs == null) return;
    final cached = _children.remove(path);
    if (cached != null) {
      _children[path] = cached;
      return;
    }
    if (!_listing.add(path)) return;
    final gen = _generation;
    List<String> folders;
    try {
      folders = _folders(await fs.list(path));
    } on FsError {
      folders = const [];
    }
    if (!mounted || gen != _generation || !identical(fs, _fs)) return;
    _listing.remove(path);
    setState(() => _cache(path, folders));
  }

  void _toggle(String path) {
    setState(() {
      if (!_open.remove(path)) {
        _open.add(path);
        _load(path);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final rows = <(String path, String name, int depth)>[];
    void walk(String path, String name, int depth) {
      rows.add((path, name, depth));
      if (!_open.contains(path)) return;
      for (final child in _children[path] ?? const <String>[]) {
        walk(b.style.join(path, child), child, depth + 1);
      }
    }

    if (_fs != null && b.ready && b.path.isNotEmpty) walk(_root, _root, 0);
    return ListView.builder(
      controller: _scroll,
      itemExtent: WorkspaceSize.treeRow,
      padding: const EdgeInsets.symmetric(vertical: Space.xs),
      itemCount: rows.length,
      itemBuilder: (context, i) {
        final (path, name, depth) = rows[i];
        final open = _open.contains(path);
        final known = _children[path];
        final current = path == b.path;
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: Space.xs),
          // Keep selection and ink on the row's own material so the viewport clips both while scrolling.
          child: Material(
            color: current ? scheme.primary.withValues(alpha: .14) : Colors.transparent,
            borderRadius: BorderRadius.circular(Radii.control),
            child: InkWell(
              borderRadius: BorderRadius.circular(Radii.control),
              onTap: () => current ? _toggle(path) : b.go(path),
              child: Row(
                children: [
                  SizedBox(width: depth * _indent),
                  SizedBox.square(
                    dimension: 20,
                    child: known != null && known.isEmpty
                        ? null
                        : InkResponse(
                            radius: 12,
                            onTap: () => _toggle(path),
                            child: Icon(
                              open ? Icons.expand_more : Icons.chevron_right,
                              size: 16,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                  ),
                  Icon(open ? Icons.folder_open : Icons.folder, size: 16, color: scheme.primary),
                  const SizedBox(width: Space.xs),
                  Expanded(
                    child: Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(color: current ? scheme.onSurface : null),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

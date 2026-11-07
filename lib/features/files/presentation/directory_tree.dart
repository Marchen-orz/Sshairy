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
      _children.clear();
      _listing.clear();
    }
    if (fs == null || !b.ready || b.path.isEmpty) return;
    // The browser already listed where it is: that keeps the tree in step with folders made, renamed or deleted.
    if (!b.loading && b.listError == null) _children[b.path] = _folders(b.entries);
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

  Future<void> _load(String path) async {
    final fs = _fs;
    if (fs == null || _children.containsKey(path) || !_listing.add(path)) return;
    List<String> folders;
    try {
      folders = _folders(await fs.list(path));
    } on FsError {
      folders = const [];
    }
    _listing.remove(path);
    if (!mounted || !identical(fs, _fs)) return;
    setState(() => _children[path] = folders);
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
          child: InkWell(
            borderRadius: BorderRadius.circular(Radii.control),
            onTap: () => current ? _toggle(path) : b.go(path),
            child: Ink(
              decoration: BoxDecoration(
                color: current ? scheme.primary.withValues(alpha: .14) : null,
                borderRadius: BorderRadius.circular(Radii.control),
              ),
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

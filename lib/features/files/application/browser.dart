import 'package:flutter/foundation.dart';

import '../../../foundation/file_system.dart';
import '../../connections/api.dart';
import '../../hosts/api.dart';
import 'file_ops.dart';
import 'file_systems.dart';

enum BrowserStatus { idle, connecting, ready, failed, lost }

enum FileSort { name, modified, size }

/// What one pane browses, on its own SFTP channel (docs/CONTRACTS.md §2): disposing the browser releases it.
class FileBrowser extends ChangeNotifier {
  FileBrowser(this._connections, {this.showHidden = false});

  final ConnectionManager _connections;

  /// Null for this computer.
  Host? host;
  FileSystem? fs;
  TransportLease? _lease;
  BrowserStatus status = BrowserStatus.idle;
  ConnectError? connectError;

  String path = '';
  List<FileEntry> entries = const [];
  FsError? listError;
  var loading = false;
  final _back = <String>[], _forward = <String>[];

  bool showHidden;
  String filter = '';
  FileSort sort = FileSort.name;
  var descending = false;

  /// Names in [path].
  Set<String> selected = {};
  String? _anchor;

  /// Results of a load or connect that has since been replaced are dropped.
  var _generation = 0;
  var _disposed = false;
  var _suspended = false;
  var _operations = 0;

  bool get local => host == null;
  bool get suspended => _suspended;
  bool get ready => status == BrowserStatus.ready && fs != null;
  bool get canBack => _back.isNotEmpty;
  bool get canForward => _forward.isNotEmpty;
  PathStyle get style => fs?.style ?? (local ? localFiles.style : PathStyle.posix);

  /// Directories first, then by [sort]; hidden files and the filter applied.
  List<FileEntry> get visible {
    final f = filter.toLowerCase();
    final out = [
      for (final e in entries)
        if ((showHidden || !e.hidden) && (f.isEmpty || e.name.toLowerCase().contains(f))) e,
    ];
    int by(FileEntry a, FileEntry b) => switch (sort) {
      FileSort.name => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
      FileSort.modified => (a.modified ?? DateTime(0)).compareTo(b.modified ?? DateTime(0)),
      FileSort.size => (a.size ?? -1).compareTo(b.size ?? -1),
    };
    out.sort((a, b) {
      if (a.browsable != b.browsable) return a.browsable ? -1 : 1;
      final c = by(a, b);
      return descending ? -c : c;
    });
    return out;
  }

  List<FileEntry> get selection => [
    for (final e in visible)
      if (selected.contains(e.name)) e,
  ];

  String pathOf(FileEntry e) => style.join(path, e.name);

  /// Starts over on [target] (null for this computer). A host connects through the shared transport, so a
  /// terminal already logged in means no second password.
  Future<void> open(Host? target, ConnectPrompts prompts, {String? at}) => _open(target, prompts, at: at);

  Future<void> _open(Host? target, ConnectPrompts prompts, {String? at, bool restoring = false}) async {
    if (_disposed) return;
    _closeFs();
    _suspended = false;
    host = target;
    final gen = ++_generation;
    status = BrowserStatus.connecting;
    connectError = null;
    entries = const [];
    selected = {};
    loading = false;
    listError = null;
    if (!restoring) {
      path = at ?? '';
      filter = '';
      _back.clear();
      _forward.clear();
    }
    _notify();
    try {
      if (target == null) {
        fs = localFiles;
      } else {
        final (lease, opened) = await _connections.open(
          target,
          prompts,
          (l) => l.openFiles(),
          purpose: LeasePurpose.files,
        );
        if (gen != _generation || _disposed) {
          opened.close().whenComplete(lease.release).ignore();
          return;
        }
        _lease = lease;
        fs = opened;
        lease.done.whenComplete(() {
          if (gen == _generation && !_disposed) {
            status = BrowserStatus.lost;
            _notify();
          }
        }).ignore();
      }
      status = BrowserStatus.ready;
      final start = at ?? await fs!.home();
      if (!await _load(start, gen) && at != null && gen == _generation) await _load(await fs!.home(), gen);
    } on ConnectError catch (e) {
      if (gen != _generation) return;
      status = BrowserStatus.failed;
      connectError = e;
      _notify();
    } on FsError catch (e) {
      if (gen != _generation) return;
      listError = e;
      _notify();
    }
  }

  /// Releases only the browsing channel. Transfers and editors own independent resources.
  /// A mutation must finish before the page retries its idle cleanup.
  bool suspend() {
    if (_operations != 0) return false;
    if (_disposed || (status == BrowserStatus.idle && !_suspended)) return true;
    _closeFs();
    _suspended = true;
    status = BrowserStatus.idle;
    entries = const [];
    selected = {};
    _anchor = null;
    loading = false;
    connectError = null;
    listError = null;
    _notify();
    return true;
  }

  /// An unopened pane stays unopened; the other metadata survives idle release.
  Future<void> resume(ConnectPrompts prompts) async {
    if (!_suspended || _disposed) return;
    await _open(host, prompts, at: path.isEmpty ? null : path, restoring: true);
  }

  /// Back where it was, after the connection dropped.
  Future<void> reconnect(ConnectPrompts prompts) => open(host, prompts, at: path);

  /// A typed path is resolved first, so `~` and `..` work and a mistyped path changes nothing.
  Future<FsError?> goTyped(String typed) async {
    final fs = this.fs;
    if (fs == null) return null;
    try {
      final resolved = await fs.resolve(typed.trim());
      return await go(resolved) ? null : listError;
    } on FsError catch (e) {
      return e;
    }
  }

  Future<bool> go(String to) async {
    final from = path;
    final ok = await _load(to, _generation);
    if (ok && from != to) {
      _remember(_back, from);
      _forward.clear();
      _notify();
    }
    return ok;
  }

  Future<void> enter(FileEntry e) => go(pathOf(e));
  Future<void> up() => go(style.parent(path));

  void _remember(List<String> history, String path) {
    history.add(path);
    if (history.length > 100) history.removeAt(0);
  }

  Future<void> back() async {
    if (_back.isEmpty) return;
    final to = _back.last, from = path;
    if (await _load(to, _generation)) {
      _back.removeLast();
      _remember(_forward, from);
      _notify();
    }
  }

  Future<void> forward() async {
    if (_forward.isEmpty) return;
    final to = _forward.last, from = path;
    if (await _load(to, _generation)) {
      _forward.removeLast();
      _remember(_back, from);
      _notify();
    }
  }

  Future<void> refresh() => _load(path, _generation, keepSelection: true);

  Future<bool> _load(String to, int gen, {bool keepSelection = false}) async {
    final fs = this.fs;
    if (fs == null || gen != _generation) return false;
    loading = true;
    _notify();
    try {
      final list = await fs.list(to);
      if (gen != _generation) return false;
      final changed = to != path;
      path = to;
      entries = list;
      listError = null;
      if (changed || !keepSelection) {
        selected = {};
        _anchor = null;
        filter = changed ? '' : filter;
      } else {
        selected = selected.intersection({for (final e in list) e.name});
      }
      return true;
    } on FsError catch (e) {
      if (gen == _generation) listError = e;
      return false;
    } finally {
      if (gen == _generation) {
        loading = false;
        _notify();
      }
    }
  }

  void setSort(FileSort s) {
    descending = sort == s ? !descending : false;
    sort = s;
    _notify();
  }

  void setFilter(String f) {
    filter = f;
    _notify();
  }

  void setShowHidden(bool value) {
    if (showHidden == value) return;
    showHidden = value;
    _notify();
  }

  void toggleHidden() => setShowHidden(!showHidden);

  /// Click semantics: plain replaces, [toggle] (Ctrl/Cmd) adds or removes, [range] (Shift) extends from the anchor.
  void select(String name, {bool toggle = false, bool range = false}) {
    final names = visible.map((e) => e.name).toList();
    if (range && _anchor != null && names.contains(_anchor)) {
      final a = names.indexOf(_anchor!), b = names.indexOf(name);
      final span = names.sublist(a < b ? a : b, (a < b ? b : a) + 1);
      selected = toggle ? {...selected, ...span} : span.toSet();
    } else if (toggle) {
      selected = selected.contains(name) ? ({...selected}..remove(name)) : {...selected, name};
      _anchor = name;
    } else {
      selected = {name};
      _anchor = name;
    }
    _notify();
  }

  void selectAll() {
    selected = {for (final e in visible) e.name};
    _notify();
  }

  void clearSelection() {
    selected = {};
    _notify();
  }

  /// Each operation returns the failure, or null; the listing is refreshed either way.
  Future<Object?> mkdir(String name) => _op(() async {
    if (badName(name, style) != null) throw const OpFailure('badName');
    await fs!.mkdir(style.join(path, name.trim()));
    selected = {name.trim()};
  });

  Future<Object?> rename(FileEntry e, String name) => _op(() async {
    if (badName(name, style) != null) throw const OpFailure('badName');
    if (name.trim() == e.name) return;
    await fs!.rename(pathOf(e), style.join(path, name.trim()));
    selected = {name.trim()};
  });

  Future<Object?> delete(List<FileEntry> items) => _op(() async {
    for (final e in items) {
      await deleteTree(fs!, pathOf(e), e);
    }
  });

  Future<Object?> chmod(FileEntry e, int mode) => _op(() => fs!.chmod(pathOf(e), mode));

  Future<Object?> _op(Future<void> Function() run) async {
    if (!ready) return const FsError(FsFailure.lost);
    final gen = _generation;
    _operations++;
    try {
      Object? failure;
      try {
        await run();
      } on FsError catch (e) {
        failure = e;
      } on OpFailure catch (e) {
        failure = e;
      }
      if (gen == _generation) await refresh();
      return failure;
    } finally {
      _operations--;
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _closeFs() {
    _generation++;
    final fs = this.fs, lease = _lease;
    this.fs = null;
    _lease = null;
    if (fs != null && lease != null) fs.close().whenComplete(lease.release).ignore();
  }

  @override
  void dispose() {
    _disposed = true;
    _closeFs();
    super.dispose();
  }
}

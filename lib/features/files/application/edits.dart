import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../foundation/data_dir.dart';
import '../../../foundation/file_system.dart';
import '../../../foundation/ids.dart';
import '../../../foundation/json_file.dart';
import '../../../foundation/open_external.dart';
import '../../../foundation/result.dart';
import '../../connections/api.dart';
import '../../hosts/api.dart';
import 'file_ops.dart';
import 'file_systems.dart';
import 'transfers.dart';

/// [conflict]: the remote file changed since it was downloaded; the user decides what wins.
enum EditState { clean, modified, uploading, conflict, failed }

/// A remote file opened in a local program. The local copy lives in the data directory, which only the
/// current user can read, and stays until the user ends the edit (docs/MODULES.md §4).
class ExternalEdit {
  const ExternalEdit({
    required this.id,
    required this.host,
    required this.hostLabel,
    required this.remotePath,
    required this.localPath,
    required this.baseline,
    this.state = EditState.clean,
    this.autoUpload = false,
    this.error,
  });

  final String id;
  final HostId host;
  final String hostLabel, remotePath, localPath;

  /// The remote file as last downloaded or uploaded; a different one there means someone else changed it.
  final FileEntry baseline;
  final EditState state;
  final bool autoUpload;
  final String? error;

  String get name => PathStyle.posix.name(remotePath);
  bool get unsaved => state != EditState.clean;

  ExternalEdit copyWith({
    String? remotePath,
    FileEntry? baseline,
    EditState? state,
    bool? autoUpload,
    String? Function()? error,
  }) => ExternalEdit(
    id: id,
    host: host,
    hostLabel: hostLabel,
    remotePath: remotePath ?? this.remotePath,
    localPath: localPath,
    baseline: baseline ?? this.baseline,
    state: state ?? this.state,
    autoUpload: autoUpload ?? this.autoUpload,
    error: error == null ? this.error : error(),
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'host': host.value,
    'hostLabel': hostLabel,
    'remotePath': remotePath,
    'localPath': localPath,
    if (baseline.size != null) 'size': baseline.size,
    if (baseline.modified != null) 'modified': baseline.modified!.millisecondsSinceEpoch,
    'unsaved': unsaved,
    if (autoUpload) 'autoUpload': true,
  };

  factory ExternalEdit.fromJson(Map<String, dynamic> j) => ExternalEdit(
    id: j['id'] as String,
    host: HostId(j['host'] as String),
    hostLabel: j['hostLabel'] as String? ?? '',
    remotePath: j['remotePath'] as String,
    localPath: j['localPath'] as String,
    baseline: FileEntry(
      PathStyle.posix.name(j['remotePath'] as String),
      FileKind.file,
      size: j['size'] as int?,
      modified: j['modified'] == null ? null : DateTime.fromMillisecondsSinceEpoch(j['modified'] as int),
    ),
    state: j['unsaved'] == true ? EditState.modified : EditState.clean,
    autoUpload: j['autoUpload'] == true,
  );
}

/// Larger files belong in a transfer, not an editor round trip.
const maxEditSize = 64 * 1024 * 1024;

final editsProvider = NotifierProvider<ExternalEdits, List<ExternalEdit>>(ExternalEdits.new);

/// The local deletion port is separate so locked-editor failures can be verified without changing OS permissions.
final editCleanupProvider = Provider<Future<void> Function(String)>((_) => (path) async {
  final directory = Directory(path);
  if (await directory.exists()) await directory.delete(recursive: true);
});

/// Owns edit copies and their watchers (docs/CONTRACTS.md §2).
class ExternalEdits extends Notifier<List<ExternalEdit>> {
  late final String _root = '${ref.read(dataDirProvider)}${Platform.pathSeparator}edits';
  late final JsonFile _file = JsonFile(
    '${ref.read(dataDirProvider)}/edits.json',
    validate: (json) {
      if (json['edits'] is! List) throw const FormatException('invalid edits');
      final ids = <String>{};
      for (final entry in json['edits'] as List) {
        final edit = ExternalEdit.fromJson((entry as Map).cast<String, dynamic>());
        if (!ids.add(edit.id)) throw const FormatException('duplicate edit');
        if (!_ownsCopy(edit)) throw const FormatException('invalid edit copy');
      }
    },
  );
  final _watchers = <String, StreamSubscription<FileSystemEvent>>{};
  final _debounce = <String, Timer>{};
  final _localStamp = <String, (int, DateTime)>{};

  /// Saves while an upload runs are caught up afterwards, so an older upload never has the last word.
  final _uploading = <String>{};
  final _again = <String>{};
  final _finishing = <String, Future<void>>{};
  var _closing = false;
  Completer<void>? _uploadsIdle;

  @override
  List<ExternalEdit> build() {
    ref.onDispose(() {
      for (final w in _watchers.values) {
        w.cancel();
      }
      for (final t in _debounce.values) {
        t.cancel();
      }
    });
    final saved = _file.read()?['edits'] as List<dynamic>? ?? const [];
    final edits = <ExternalEdit>[];
    for (final j in saved) {
      final e = ExternalEdit.fromJson((j as Map).cast());
      _checkCopy(e);
      // A copy that is gone has nothing to recover.
      if (File(e.localPath).existsSync()) edits.add(e);
    }
    Future.microtask(() {
      for (final e in edits) {
        _watch(e);
      }
    });
    return edits;
  }

  Future<void> get saved => _file.idle;

  int get unsavedCount => state.where((e) => e.unsaved).length;

  /// Leaves edit copies on disk and prevents watchers from starting another upload while quitting.
  Future<void> shutdown() async {
    _closing = true;
    for (final timer in _debounce.values) {
      timer.cancel();
    }
    _debounce.clear();
    _again.clear();
    await _uploadsIdle?.future;
    // Editors can replace their file just before quitting, before the watcher debounce has fired.
    for (final edit in [...state]) {
      await _changed(edit.id);
    }
    await saved;
  }

  void resumeAfterShutdown() => _closing = false;

  FileSystems get _pool => ref.read(fileSystemsProvider);
  ExternalEdit? _byId(String id) => state.where((e) => e.id == id).firstOrNull;

  /// Downloads [remotePath] and opens it in the system's program for its type. An edit already open for the
  /// same file is reopened, not downloaded over.
  Future<Result<void>> open(Host host, String remotePath) async {
    if (_closing) return const Err(AppError('closing'));
    final existing = state.where((e) => e.host == host.id && e.remotePath == remotePath).firstOrNull;
    if (existing != null) {
      _checkCopy(existing);
      await openFile(existing.localPath);
      return const Ok(null);
    }
    _pool.remember(host);
    final FsHandle handle;
    try {
      handle = await _pool.acquire(host.id, _prompts);
    } on Object catch (e) {
      return Err(AppError('connect', detail: '$e'));
    }
    final id = newId();
    final dir = Directory('$_root${Platform.pathSeparator}$id');
    var registered = false;
    try {
      final remote = await handle.fs.stat(remotePath);
      if (remote == null || remote.kind != FileKind.file) return const Err(AppError('notAFile'));
      if ((remote.size ?? 0) > maxEditSize) return const Err(AppError('tooLarge'));
      await dir.create(recursive: true);
      final local = '${dir.path}${Platform.pathSeparator}${_safeName(remote.name)}';
      final written = await localFiles.create(local, handle.fs.read(remotePath));
      if (remote.size != null && written != remote.size) throw const OpFailure('sizeMismatch');
      final edit = ExternalEdit(
        id: id,
        host: host.id,
        hostLabel: host.title,
        remotePath: remotePath,
        localPath: local,
        baseline: remote,
      );
      _set([...state, edit]);
      registered = true;
      await saved;
      _remember(edit);
      _watch(edit);
      await openFile(local);
      return const Ok(null);
    } on Object catch (e) {
      if (!registered) await dir.delete(recursive: true).then((_) {}, onError: (Object _) {});
      return Err(e is FsError ? AppError(e.kind.name, detail: e.detail) : AppError('failed', detail: '$e'));
    } finally {
      handle.release();
    }
  }

  Future<void> reopen(String id) async {
    final e = _byId(id);
    if (e != null) await openFile(e.localPath);
  }

  void setAutoUpload(String id, bool on) {
    _change(id, (e) => e.copyWith(autoUpload: on));
    final e = _byId(id);
    if (on && e?.state == EditState.modified) upload(id);
  }

  /// Uploads the local copy over the remote file if that is still the one downloaded; otherwise marks a
  /// conflict. [force] overwrites anyway, [asCopy] uploads beside it and keeps editing the copy.
  Future<void> upload(String id, {bool force = false, bool asCopy = false}) async {
    if (_closing || _finishing.containsKey(id)) return;
    if (_uploading.contains(id)) {
      _again.add(id);
      return;
    }
    final edit = _byId(id);
    if (edit == null) return;
    _uploading.add(id);
    _uploadsIdle ??= Completer<void>();
    _change(id, (e) => e.copyWith(state: EditState.uploading, error: () => null));
    FsHandle? handle;
    try {
      _checkCopy(edit);
      final host = _pool.host(edit.host);
      if (host == null) throw const OpFailure('hostMissing');
      handle = await _pool.acquire(host.id, _prompts);
      final fs = handle.fs;
      final stamp = await _stamp(edit.localPath);
      final remote = await fs.stat(edit.remotePath);
      var target = edit.remotePath;
      FileEntry? replacing = remote;
      if (asCopy) {
        target = await freeName(fs, edit.remotePath, directory: false);
        replacing = null;
      } else if (!force && (remote == null || !remote.sameAs(edit.baseline))) {
        _change(id, (e) => e.copyWith(state: EditState.conflict));
        return;
      }
      await writeVerified(fs, target, localFiles.read(edit.localPath), expectedSize: stamp?.$1, replacing: replacing);
      final now = await fs.stat(target);
      // Saved again during the upload: still modified, and uploaded again below when automatic.
      final later = await _stamp(edit.localPath);
      final dirty = later != stamp;
      _change(
        id,
        (e) => e.copyWith(remotePath: target, baseline: now, state: dirty ? EditState.modified : EditState.clean),
      );
      if (stamp != null) _localStamp[id] = stamp;
      if (dirty && edit.autoUpload) _again.add(id);
    } on Object catch (e) {
      final code = switch (e) {
        OpFailure(:final code) => code,
        FsError(:final kind) => kind.name,
        _ => 'failed',
      };
      _change(id, (x) => x.copyWith(state: EditState.failed, error: () => code));
    } finally {
      handle?.release();
      _uploading.remove(id);
      if (_uploading.isEmpty) {
        _uploadsIdle?.complete();
        _uploadsIdle = null;
      }
      if (_again.remove(id) && !_closing) unawaited(upload(id));
    }
  }

  /// Throws the local changes away and downloads the remote file again.
  Future<void> redownload(String id) async {
    if (_closing || _finishing.containsKey(id) || _uploading.contains(id)) return;
    final edit = _byId(id);
    final host = edit == null ? null : _pool.host(edit.host);
    if (edit == null || host == null) return;
    FsHandle? handle;
    try {
      _checkCopy(edit);
      handle = await _pool.acquire(host.id, _prompts);
      final remote = await handle.fs.stat(edit.remotePath);
      if (remote == null) throw const FsError(FsFailure.notFound);
      final tmp = '${edit.localPath}.download';
      await File(tmp).delete().then((_) {}, onError: (Object _) {});
      await localFiles.create(tmp, handle.fs.read(edit.remotePath));
      await localFiles.replace(tmp, edit.localPath);
      _localStamp[id] = (await _stamp(edit.localPath))!;
      _change(id, (e) => e.copyWith(baseline: remote, state: EditState.clean, error: () => null));
    } on Object catch (e) {
      _change(id, (x) => x.copyWith(state: EditState.failed, error: () => e is FsError ? e.kind.name : 'failed'));
    } finally {
      handle?.release();
    }
  }

  /// Ends the edit and removes the local copy; the caller confirms first when it holds unsaved changes.
  Future<void> finish(String id) => _finishing.putIfAbsent(
    id, () => _finishCopy(id).whenComplete(() { _finishing.remove(id); }),
  );

  Future<void> _finishCopy(String id) async {
    // No new upload for this copy may start while its in-flight upload and watcher are being stopped.
    await _uploadsIdle?.future;
    final edit = _byId(id);
    if (edit == null) return;
    await _watchers.remove(id)?.cancel();
    _debounce.remove(id)?.cancel();
    _again.remove(id);
    try {
      _checkCopy(edit);
      final cleanup = ref.read(editCleanupProvider);
      for (var attempt = 0; ; attempt++) {
        try {
          await cleanup(File(edit.localPath).parent.path);
          break;
        } on Object {
          if (attempt == 2) rethrow;
          await Future<void>.delayed(const Duration(milliseconds: 100));
          _checkCopy(edit);
        }
      }
    } on Object {
      _change(id, (e) => e.copyWith(state: EditState.failed, autoUpload: false, error: () => 'cleanupFailed'));
      await saved;
      return;
    }
    _localStamp.remove(id);
    _set([
      for (final e in state)
        if (e.id != id) e,
    ]);
    await saved;
  }

  bool _ownsCopy(ExternalEdit edit) {
    if (!RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(edit.id)) return false;
    final style = localFiles.style;
    final name = style.name(edit.localPath);
    if (name.isEmpty || name == '.' || name == '..') return false;
    String canonical(String path) {
      final absolute = File(path).absolute.uri.normalizePath().toFilePath();
      return Platform.isWindows ? absolute.toLowerCase() : absolute;
    }
    final directory = style.join(_root, edit.id);
    return canonical(File(edit.localPath).parent.path) == canonical(directory) &&
        canonical(edit.localPath) == canonical(style.join(directory, name));
  }

  void _checkCopy(ExternalEdit edit) {
    if (!_ownsCopy(edit)) throw const FormatException('invalid edit copy');
    final directory = FileSystemEntity.typeSync(File(edit.localPath).parent.path, followLinks: false);
    final file = FileSystemEntity.typeSync(edit.localPath, followLinks: false);
    if ((directory != FileSystemEntityType.directory && directory != FileSystemEntityType.notFound) ||
        (file != FileSystemEntityType.file && file != FileSystemEntityType.notFound)) {
      throw const OpFailure('partInvalid');
    }
  }

  ConnectPrompts get _prompts => ref.read(transfersProvider.notifier).ui?.prompts ?? const NoPrompts();

  /// Watches the directory, not the file: editors that save by replacing the file would end a file watch.
  void _watch(ExternalEdit edit) {
    final dir = File(edit.localPath).parent;
    if (!dir.existsSync() || _watchers.containsKey(edit.id)) return;
    _remember(edit);
    _watchers[edit.id] = dir.watch().listen((_) {
      _debounce[edit.id]?.cancel();
      _debounce[edit.id] = Timer(const Duration(milliseconds: 500), () => _changed(edit.id));
    }, onError: (Object _) {});
  }

  Future<void> _remember(ExternalEdit edit) async {
    final s = await _stamp(edit.localPath);
    if (s != null) _localStamp[edit.id] ??= s;
  }

  Future<void> _changed(String id) async {
    if (_finishing.containsKey(id)) return;
    final edit = _byId(id);
    if (edit == null) return;
    final now = await _stamp(edit.localPath);
    if (now == null || now == _localStamp[id]) return;
    _localStamp[id] = now;
    if (edit.state == EditState.clean || edit.state == EditState.failed) {
      _change(id, (e) => e.copyWith(state: EditState.modified));
    }
    if (edit.autoUpload) unawaited(upload(id));
  }

  static Future<(int, DateTime)?> _stamp(String path) async {
    final s = await FileStat.stat(path);
    return s.type == FileSystemEntityType.notFound ? null : (s.size, s.modified);
  }

  /// Remote names may hold characters Windows refuses in file names.
  static String _safeName(String name) => name.replaceAll(RegExp(r'[\\/:*?"<>|\u0000-\u001f]'), '_');

  void _change(String id, ExternalEdit Function(ExternalEdit) f) =>
      _set([for (final e in state) e.id == id ? f(e) : e]);

  void _set(List<ExternalEdit> next) {
    state = next;
    _file.write({
      'schemaVersion': 1,
      'edits': [for (final e in next) e.toJson()],
    });
  }
}

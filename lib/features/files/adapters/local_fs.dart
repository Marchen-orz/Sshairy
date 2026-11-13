import 'dart:io';
import 'dart:typed_data';

import '../../../foundation/cancellation.dart';
import '../../../foundation/file_system.dart';

/// This computer's files. On Windows the empty path lists the drives.
class LocalFileSystem implements FileSystem {
  const LocalFileSystem();

  @override
  PathStyle get style => Platform.isWindows ? PathStyle.windows : PathStyle.posix;

  @override
  Future<String> home() async => Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'] ?? '/';

  @override
  Future<String> resolve(String path) async {
    if (path.isEmpty && Platform.isWindows) return '';
    var p = path;
    if (p == '~' || p.startsWith('~/') || p.startsWith(r'~\')) p = await home() + p.substring(1);
    try {
      return await Directory(p).resolveSymbolicLinks();
    } on FileSystemException catch (e) {
      throw _map(e);
    }
  }

  @override
  Future<List<FileEntry>> list(String dir) async {
    if (dir.isEmpty && Platform.isWindows) return _drives();
    try {
      final out = <FileEntry>[];
      await for (final e in Directory(dir).list(followLinks: false)) {
        final entry = await _entry(
          e.path,
          e is Link ? FileKind.link : (e is Directory ? FileKind.directory : FileKind.file),
        );
        if (entry != null) out.add(entry);
      }
      return out;
    } on FileSystemException catch (e) {
      throw _map(e);
    }
  }

  @override
  Future<FileEntry?> stat(String path) async {
    final type = await FileSystemEntity.type(path, followLinks: false);
    return switch (type) {
      FileSystemEntityType.notFound => null,
      FileSystemEntityType.link => _entry(path, FileKind.link),
      FileSystemEntityType.directory => _entry(path, FileKind.directory),
      FileSystemEntityType.file => _entry(path, FileKind.file),
      _ => _entry(path, FileKind.other),
    };
  }

  @override
  Future<void> mkdir(String path) => _guard(() async {
    // Directory.create succeeds on an existing directory; mkdir must not.
    if (await stat(path) != null) throw const FsError(FsFailure.exists);
    await Directory(path).create();
  });

  @override
  Future<void> rename(String from, String to, {void Function()? checkCurrent}) => _guard(() async {
    checkCurrent?.call();
    final existing = await stat(to);
    checkCurrent?.call();
    if (existing != null) throw const FsError(FsFailure.exists);
    final type = await FileSystemEntity.type(from, followLinks: false);
    checkCurrent?.call();
    await switch (type) {
      FileSystemEntityType.directory => Directory(from).rename(to),
      FileSystemEntityType.link => Link(from).rename(to),
      _ => File(from).rename(to),
    };
  });

  @override
  bool get canReplace => true;

  /// File.rename replaces the target in one step on Windows (MoveFileEx) and POSIX (rename).
  @override
  Future<void> replace(String from, String to, {void Function()? checkCurrent}) {
    checkCurrent?.call();
    return _guard(() => File(from).rename(to));
  }

  @override
  Future<void> delete(String path) => _guard(() async {
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type == FileSystemEntityType.directory) throw const FsError(FsFailure.failed, 'is a directory');
    await (type == FileSystemEntityType.link ? Link(path).delete() : File(path).delete());
  });

  @override
  Future<void> rmdir(String path) => _guard(() => Directory(path).delete());

  @override
  bool get canChmod => !Platform.isWindows;

  @override
  Future<void> chmod(String path, int mode) => _guard(() async {
    // Arguments go to chmod directly, never through a shell.
    final r = await Process.run('chmod', [(mode & 0xFFF).toRadixString(8), path]);
    if (r.exitCode != 0) throw FsError(FsFailure.permission, '${r.stderr}'.trim());
  });

  @override
  Stream<Uint8List> read(String path, {int offset = 0}) =>
      File(path).openRead(offset).map((c) => c is Uint8List ? c : Uint8List.fromList(c)).handleError((Object e) {
        throw e is FileSystemException ? _map(e) : e;
      });

  @override
  Future<int> create(
    String path,
    Stream<Uint8List> data, {
    void Function(int written)? onProgress,
    CancellationToken? cancel,
    void Function()? checkCurrent,
  }) => _guard(() async {
    void check() {
      if (cancel?.isCancelled ?? false) throw const FsError(FsFailure.failed, 'cancelled');
      checkCurrent?.call();
    }

    check();
    final file = File(path);
    await file.create(exclusive: true);
    check();
    final raf = await file.open(mode: FileMode.writeOnly);
    var written = 0;
    try {
      check();
      await for (final chunk in data) {
        if (cancel?.isCancelled ?? false) break;
        checkCurrent?.call();
        await raf.writeFrom(chunk);
        written += chunk.length;
        onProgress?.call(written);
      }
      await raf.flush();
    } finally {
      await raf.close();
    }
    return written;
  });

  @override
  Future<void> close() async {}

  /// Continues the file at [offset]; a different length means the checkpoint is stale, not to be extended.
  @override
  Future<int> append(
    String path,
    Stream<Uint8List> data, {
    required int offset,
    void Function(int written)? onProgress,
    CancellationToken? cancel,
    void Function()? checkCurrent,
  }) => _guard(() async {
    void check() {
      if (cancel?.isCancelled ?? false) throw const FsError(FsFailure.failed, 'cancelled');
      checkCurrent?.call();
    }

    check();
    final file = File(path);
    if (!await file.exists()) throw const FsError(FsFailure.notFound);
    check();
    final length = await file.length();
    check();
    if (length != offset) throw FsError(FsFailure.partInvalid, '$length/$offset');
    // FileMode.append is the only non-truncating random-access write mode; writeOnly would zero the part.
    final raf = await file.open(mode: FileMode.append);
    var written = 0;
    try {
      check();
      await raf.setPosition(offset);
      await for (final chunk in data) {
        if (cancel?.isCancelled ?? false) break;
        checkCurrent?.call();
        await raf.writeFrom(chunk);
        written += chunk.length;
        onProgress?.call(written);
      }
      await raf.flush();
    } finally {
      await raf.close();
    }
    return written;
  });

  Future<FileEntry?> _entry(String path, FileKind kind) async {
    // FileStat follows links, which is what a link's size and time should show.
    final s = await FileStat.stat(path);
    final name = style.name(path);
    if (s.type == FileSystemEntityType.notFound && kind != FileKind.link) return null;
    return FileEntry(
      name,
      kind,
      size: kind == FileKind.file || (kind == FileKind.link && s.type == FileSystemEntityType.file) ? s.size : null,
      modified: s.type == FileSystemEntityType.notFound ? null : s.modified,
      mode: Platform.isWindows || s.type == FileSystemEntityType.notFound ? null : s.mode & 0xFFF,
      linkToDir: kind == FileKind.link && s.type == FileSystemEntityType.directory,
    );
  }

  Future<List<FileEntry>> _drives() async => [
    for (final letter in 'CDEFGHIJKLMNOPQRSTUVWXYZAB'.split(''))
      if (await Directory('$letter:\\').exists()) FileEntry('$letter:\\', FileKind.directory),
  ];

  static Future<T> _guard<T>(Future<T> Function() run) async {
    try {
      return await run();
    } on FileSystemException catch (e) {
      throw _map(e);
    }
  }

  static FsError _map(FileSystemException e) {
    final code = e.osError?.errorCode;
    // Windows error codes and POSIX errno for the cases callers tell apart.
    final kind = Platform.isWindows
        ? switch (code) {
            2 || 3 => FsFailure.notFound,
            5 => FsFailure.permission,
            80 || 183 => FsFailure.exists,
            _ => FsFailure.failed,
          }
        : switch (code) {
            2 => FsFailure.notFound,
            1 || 13 => FsFailure.permission,
            17 => FsFailure.exists,
            _ => FsFailure.failed,
          };
    return FsError(kind, e.osError?.message ?? e.message);
  }
}

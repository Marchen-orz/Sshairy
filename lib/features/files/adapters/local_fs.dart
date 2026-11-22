import 'dart:io';
import 'dart:typed_data';

import '../../../foundation/cancellation.dart';
import '../../../foundation/file_system.dart';

/// This computer's files. On Windows the empty path lists the drives.
class LocalFileSystem implements FileSystem, BoundedFileListing {
  const LocalFileSystem({this.root});

  /// A mobile directory presented as `/`. The unrooted desktop view uses native paths.
  final String? root;

  Future<String> _native(String path) async {
    final root = this.root;
    if (root == null) return path;
    if (!path.startsWith('/') || path.contains('\x00') || path.split('/').contains('..')) {
      throw const FsError(FsFailure.permission);
    }
    final base = await _guard(() => Directory(root).resolveSymbolicLinks());
    var native = base;
    for (final part in path.split('/').where((part) => part.isNotEmpty && part != '.')) {
      native = '$native/$part';
      if (await FileSystemEntity.type(native, followLinks: false) == FileSystemEntityType.link) {
        throw const FsError(FsFailure.permission);
      }
    }
    return native;
  }

  @override
  Future<BoundedListing> listBounded(
    String dir, {
    required int maxScanned,
    bool Function(String name)? accept,
    CancellationToken? cancel,
  }) async {
    final out = <FileEntry>[];
    var scanned = 0;
    try {
      await for (final e in Directory(await _native(dir)).list(followLinks: false)) {
        if (cancel?.isCancelled ?? false) throw const FsError(FsFailure.failed, 'cancelled');
        if (scanned == maxScanned) return BoundedListing(out, scanned: scanned, complete: false);
        scanned++;
        final name = e.path.substring(e.path.lastIndexOf(Platform.pathSeparator) + 1);
        if (accept != null && !accept(name)) continue;
        final entry = await _entry(
          e.path,
          e is Link ? FileKind.link : (e is Directory ? FileKind.directory : FileKind.file),
        );
        if (entry != null) out.add(entry);
      }
    } on FileSystemException catch (e) {
      throw _map(e);
    }
    return BoundedListing(out, scanned: scanned, complete: true);
  }

  @override
  PathStyle get style => Platform.isWindows ? PathStyle.windows : PathStyle.posix;

  @override
  Future<String> home() async =>
      root != null ? '/' : Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'] ?? '/';

  @override
  Future<String> resolve(String path) async {
    if (root == null && path.isEmpty && Platform.isWindows) return '';
    var p = path;
    if (p == '~' || p.startsWith('~/') || p.startsWith(r'~\')) p = await home() + p.substring(1);
    try {
      final resolved = await Directory(await _native(p)).resolveSymbolicLinks();
      final root = this.root;
      if (root == null) return resolved;
      final base = await Directory(root).resolveSymbolicLinks();
      if (resolved == base) return '/';
      if (!resolved.startsWith('$base/')) throw const FsError(FsFailure.permission);
      return resolved.substring(base.length);
    } on FileSystemException catch (e) {
      throw _map(e);
    }
  }

  @override
  Future<List<FileEntry>> list(String dir) async {
    if (root == null && dir.isEmpty && Platform.isWindows) return _drives();
    try {
      final out = <FileEntry>[];
      await for (final e in Directory(await _native(dir)).list(followLinks: false)) {
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
    return _stat(await _native(path));
  }

  Future<FileEntry?> _stat(String path) async {
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
    await Directory(await _writable(path)).create();
  });

  @override
  Future<void> rename(String from, String to, {void Function()? checkCurrent}) => _guard(() async {
    checkCurrent?.call();
    final existing = await stat(to);
    checkCurrent?.call();
    if (existing != null) throw const FsError(FsFailure.exists);
    final source = await _writable(from), target = await _writable(to);
    final type = await FileSystemEntity.type(source, followLinks: false);
    checkCurrent?.call();
    await switch (type) {
      FileSystemEntityType.directory => Directory(source).rename(target),
      FileSystemEntityType.link => Link(source).rename(target),
      _ => File(source).rename(target),
    };
  });

  @override
  bool get canReplace => true;

  /// File.rename replaces the target in one step on Windows (MoveFileEx) and POSIX (rename).
  @override
  Future<void> replace(String from, String to, {void Function()? checkCurrent}) {
    return _guard(() async {
      final source = await _writable(from), target = await _writable(to);
      checkCurrent?.call();
      await File(source).rename(target);
    });
  }

  @override
  Future<void> delete(String path) => _guard(() async {
    final native = await _writable(path);
    final type = await FileSystemEntity.type(native, followLinks: false);
    if (type == FileSystemEntityType.directory) throw const FsError(FsFailure.failed, 'is a directory');
    await (type == FileSystemEntityType.link ? Link(native).delete() : File(native).delete());
  });

  @override
  Future<void> rmdir(String path) => _guard(() async {
    await Directory(await _writable(path)).delete();
  });

  Future<String> _writable(String path) async {
    if (root != null && path.split('/').every((part) => part.isEmpty || part == '.')) {
      throw const FsError(FsFailure.permission);
    }
    return _native(path);
  }

  @override
  bool get canChmod => root == null && !Platform.isWindows;

  @override
  Future<void> chmod(String path, int mode) => _guard(() async {
    if (!canChmod) throw const FsError(FsFailure.unsupported);
    // Arguments go to chmod directly, never through a shell.
    final r = await Process.run('chmod', [(mode & 0xFFF).toRadixString(8), path]);
    if (r.exitCode != 0) throw FsError(FsFailure.permission, '${r.stderr}'.trim());
  });

  @override
  Stream<Uint8List> read(String path, {int offset = 0}) async* {
    try {
      yield* File(await _native(path)).openRead(offset).map((c) => c is Uint8List ? c : Uint8List.fromList(c));
    } on FileSystemException catch (e) {
      throw _map(e);
    }
  }

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
    final file = File(await _writable(path));
    check();
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
    final file = File(await _writable(path));
    check();
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
      kind == FileKind.file && s.type != FileSystemEntityType.file ? FileKind.other : kind,
      size: kind == FileKind.file || (kind == FileKind.link && s.type == FileSystemEntityType.file) ? s.size : null,
      modified: s.type == FileSystemEntityType.notFound ? null : s.modified,
      mode: Platform.isWindows || s.type == FileSystemEntityType.notFound ? null : s.mode & 0xFFF,
      linkToDir: root == null && kind == FileKind.link && s.type == FileSystemEntityType.directory,
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

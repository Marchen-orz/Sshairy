import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import '../../../foundation/cancellation.dart';
import '../../../foundation/file_system.dart';

/// MODULES §4: 32 KiB per request, at most 16 in flight, for reads and writes alike.
const _chunk = 32 * 1024;
const _inFlight = 16;

/// [FileSystem] over one SFTP channel. Closing it closes only the channel, never the shared transport.
class SftpFileSystem implements FileSystem, BoundedFileListing {
  SftpFileSystem._(this._sftp, this._posixRename);

  static Future<SftpFileSystem> open(SSHClient client) async {
    final sftp = await client.sftp();
    try {
      final hs = await sftp.handshake;
      return SftpFileSystem._(sftp, hs.extensions.containsKey('posix-rename@openssh.com'));
    } on Object catch (e) {
      sftp.close().ignore();
      throw _map(e);
    }
  }

  final SftpClient _sftp;
  final bool _posixRename;

  @override
  PathStyle get style => PathStyle.posix;

  @override
  Future<String> home() => _guard(() => _sftp.absolute('.'));

  @override
  Future<String> resolve(String path) => _guard(() async {
    final abs = await _sftp.absolute(path);
    await _sftp.stat(abs);
    return abs;
  });

  @override
  Future<List<FileEntry>> list(String dir) => _guard(() async {
    final names = await _sftp.listdir(dir);
    final out = <FileEntry>[];
    for (final n in names) {
      if (n.filename == '.' || n.filename == '..') continue;
      var entry = _entry(n.filename, n.attr, n.longname);
      if (entry.kind == FileKind.link) {
        // Only to know whether the link can be entered; failures leave it a plain link.
        final target = await _sftp
            .stat(PathStyle.posix.join(dir, n.filename))
            .then<SftpFileAttrs?>((a) => a, onError: (Object _) => null);
        if (target?.isDirectory ?? false) entry = _entry(n.filename, n.attr, n.longname, linkToDir: true);
      }
      out.add(entry);
    }
    return out;
  });

  /// One READDIR at a time, so the server's pace is the backpressure. dartssh2 closes the directory only after it has
  /// read to the end; stopping earlier leaves it open until [close].
  @override
  Future<BoundedListing> listBounded(
    String dir, {
    required int maxScanned,
    bool Function(String name)? accept,
    CancellationToken? cancel,
  }) => _guard(
    () => scanSftpDirectory(
      _sftp.readdir(dir),
      maxScanned: maxScanned,
      accept: accept,
      cancel: cancel,
      linksToDirectory: (name) => _linksToDir(PathStyle.posix.join(dir, name)),
    ),
  );

  /// Follows the link at [path]. The server saying the target is unreachable leaves it a plain link; a lost
  /// connection is not an answer about the link and surfaces.
  Future<bool> _linksToDir(String path) async {
    try {
      return (await _sftp.stat(path)).isDirectory;
    } on SftpStatusError catch (e) {
      if (e.code == SftpStatusCode.noConnection || e.code == SftpStatusCode.connectionLost) rethrow;
      return false;
    }
  }

  @override
  Future<FileEntry?> stat(String path) async {
    try {
      return _entry(PathStyle.posix.name(path), await _sftp.stat(path, followLink: false), '');
    } on SftpStatusError catch (e) {
      if (e.code == SftpStatusCode.noSuchFile) return null;
      throw _map(e);
    } on Object catch (e) {
      throw _map(e);
    }
  }

  @override
  Future<void> mkdir(String path) => _guard(() => _sftp.mkdir(path));

  @override
  Future<void> rename(String from, String to) => _guard(() async {
    // dartssh2 renames with posix-rename where the server has it, which replaces silently. Checking first
    // leaves a window between the two requests; SFTP has no compare-and-swap to close it (SECURITY §5).
    if (await stat(to) != null) throw const FsError(FsFailure.exists);
    await _sftp.rename(from, to);
  });

  @override
  bool get canReplace => _posixRename;

  @override
  Future<void> replace(String from, String to) => _guard(() async {
    if (!_posixRename) throw const FsError(FsFailure.unsupported, 'posix-rename');
    await _sftp.rename(from, to);
  });

  @override
  Future<void> delete(String path) => _guard(() => _sftp.remove(path));

  @override
  Future<void> rmdir(String path) => _guard(() => _sftp.rmdir(path));

  @override
  bool get canChmod => true;

  @override
  Future<void> chmod(String path, int mode) =>
      _guard(() => _sftp.setStat(path, SftpFileAttrs(mode: SftpFileMode.value(mode & 0xFFF))));

  @override
  Stream<Uint8List> read(String path, {int offset = 0}) async* {
    final SftpFile file;
    try {
      file = await _sftp.open(path);
    } on Object catch (e) {
      throw _map(e);
    }
    try {
      yield* file
          .read(offset: offset, chunkSize: _chunk, maxPendingRequests: _inFlight)
          .handleError((Object e) => throw _map(e));
    } finally {
      await file.close().catchError((_) {});
    }
  }

  /// Continues the part file at [offset]; a different length means the checkpoint is stale, not to be extended.
  @override
  Future<int> append(
    String path,
    Stream<Uint8List> data, {
    required int offset,
    void Function(int written)? onProgress,
    CancellationToken? cancel,
  }) => _guard(() async {
    // Without truncate this opens the existing file and leaves its bytes alone.
    final file = await _sftp.open(path, mode: SftpFileOpenMode.write);
    try {
      final size = (await file.stat()).size;
      if (size != offset) throw FsError(FsFailure.partInvalid, '$size/$offset');
      final writer = file.write(
        data,
        offset: offset,
        onProgress: onProgress,
        chunkSize: _chunk,
        maxPendingRequests: _inFlight,
      );
      cancel?.whenCancelled.then((_) => writer.abort()).ignore();
      await writer.done;
      return writer.progress;
    } finally {
      await file.close().catchError((_) {});
    }
  });

  @override
  Future<int> create(
    String path,
    Stream<Uint8List> data, {
    void Function(int written)? onProgress,
    CancellationToken? cancel,
  }) => _guard(() async {
    final file = await _sftp.open(
      path,
      mode: SftpFileOpenMode.create | SftpFileOpenMode.exclusive | SftpFileOpenMode.write,
    );
    try {
      final writer = file.write(data, onProgress: onProgress, chunkSize: _chunk, maxPendingRequests: _inFlight);
      cancel?.whenCancelled.then((_) => writer.abort()).ignore();
      await writer.done;
      return writer.progress;
    } finally {
      await file.close().catchError((_) {});
    }
  });

  @override
  Future<void> close() => _sftp.close().catchError((_) {});

  static Future<T> _guard<T>(Future<T> Function() run) async {
    try {
      return await run();
    } on FsError {
      rethrow;
    } on Object catch (e) {
      throw _map(e);
    }
  }

  static FsError _map(Object e) => switch (e) {
    FsError() => e,
    SftpStatusError(code: SftpStatusCode.noSuchFile) => FsError(FsFailure.notFound, e.message),
    SftpStatusError(code: SftpStatusCode.permissionDenied) => FsError(FsFailure.permission, e.message),
    SftpStatusError(code: SftpStatusCode.opUnsupported) => FsError(FsFailure.unsupported, e.message),
    SftpStatusError(code: SftpStatusCode.noConnection || SftpStatusCode.connectionLost) => FsError(
      FsFailure.lost,
      e.message,
    ),
    // SFTP v3 has no "exists" status; OpenSSH answers a clashing exclusive create or mkdir with failure.
    SftpStatusError() => FsError(FsFailure.failed, e.message),
    SftpAbortError() || SSHError() => FsError(FsFailure.lost, '$e'),
    _ => FsError(FsFailure.failed, '$e'),
  };

  static FileEntry _entry(String name, SftpFileAttrs a, String longname, {bool linkToDir = false}) {
    // `ls -l` style: mode, links, owner, group, size, date… Servers that send something else get no owner.
    final fields = longname.split(RegExp(r'\s+'));
    final hasOwner = fields.length >= 9;
    return FileEntry(
      name,
      switch (a.type) {
        SftpFileType.regularFile => FileKind.file,
        SftpFileType.directory => FileKind.directory,
        SftpFileType.symbolicLink => FileKind.link,
        _ => FileKind.other,
      },
      size: a.size,
      modified: a.modifyTime == null ? null : DateTime.fromMillisecondsSinceEpoch(a.modifyTime! * 1000),
      mode: a.mode == null ? null : a.mode!.value & 0xFFF,
      owner: hasOwner ? fields[2] : null,
      group: hasOwner ? fields[3] : null,
      linkToDir: linkToDir,
    );
  }
}

/// The scan behind [SftpFileSystem.listBounded], over any stream of READDIR batches so it runs without a server.
/// Reading stops at the first name past [maxScanned]; links are looked at only among the names kept, 16 at a time,
/// so nothing past the limit costs a request. [cancel] is checked between batches and between lookups.
Future<BoundedListing> scanSftpDirectory(
  Stream<List<SftpName>> batches, {
  required int maxScanned,
  required Future<bool> Function(String name) linksToDirectory,
  bool Function(String name)? accept,
  CancellationToken? cancel,
}) async {
  void checkCancelled() {
    if (cancel?.isCancelled ?? false) throw const FsError(FsFailure.failed, 'cancelled');
  }

  final kept = <SftpName>[];
  var scanned = 0;
  var complete = true;
  await for (final batch in batches) {
    checkCancelled();
    for (final name in batch) {
      if (name.filename == '.' || name.filename == '..') continue;
      if (scanned == maxScanned) {
        complete = false;
        break;
      }
      scanned++;
      if (accept == null || accept(name.filename)) kept.add(name);
    }
    if (!complete) break;
  }

  final entries = [for (final n in kept) SftpFileSystem._entry(n.filename, n.attr, n.longname)];
  final links = [
    for (var i = 0; i < entries.length; i++)
      if (entries[i].kind == FileKind.link) i,
  ];
  for (var from = 0; from < links.length; from += _inFlight) {
    checkCancelled();
    final window = links.sublist(from, min(from + _inFlight, links.length));
    final found = await Future.wait([for (final i in window) linksToDirectory(entries[i].name)]);
    for (var k = 0; k < window.length; k++) {
      if (!found[k]) continue;
      final n = kept[window[k]];
      entries[window[k]] = SftpFileSystem._entry(n.filename, n.attr, n.longname, linkToDir: true);
    }
  }
  return BoundedListing(entries, scanned: scanned, complete: complete);
}

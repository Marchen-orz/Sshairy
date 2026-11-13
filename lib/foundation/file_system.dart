import 'dart:typed_data';

import 'cancellation.dart';

enum FileKind { file, directory, link, other }

/// A directory entry or stat result. Fields a file system did not report are null.
class FileEntry {
  const FileEntry(
    this.name,
    this.kind, {
    this.size,
    this.modified,
    this.mode,
    this.owner,
    this.group,
    this.linkToDir = false,
  });

  final String name;
  final FileKind kind;
  final int? size;
  final DateTime? modified;

  /// Permission bits (0o7777); null where the file system has none, as on Windows.
  final int? mode;
  final String? owner, group;

  /// A link that leads to a directory, so a browser can enter it without following links elsewhere.
  final bool linkToDir;

  bool get isDir => kind == FileKind.directory;
  bool get browsable => isDir || linkToDir;
  bool get hidden => name.startsWith('.');

  /// Whether the file is still the one seen before: size and modification time, which is all SFTP offers.
  bool sameAs(FileEntry other) => size == other.size && modified == other.modified && kind == other.kind;
}

enum FsFailure { notFound, exists, permission, unsupported, lost, partInvalid, failed }

class FsError implements Exception {
  const FsError(this.kind, [this.detail = '']);

  final FsFailure kind;
  final String detail;

  @override
  String toString() => 'FsError(${kind.name}, $detail)';
}

/// The path syntax of one file system. Remote paths are always POSIX, whatever the local platform
/// (docs/SECURITY.md §5); never mix the two.
enum PathStyle {
  posix,
  windows;

  String get separator => this == posix ? '/' : r'\';

  bool _isSep(String c) => c == '/' || (this == windows && c == r'\');

  String join(String dir, String name) {
    if (dir.isEmpty) return name;
    return _isSep(dir[dir.length - 1]) ? '$dir$name' : '$dir$separator$name';
  }

  /// The root is its own parent; on Windows the parent of a drive is the empty path that lists drives.
  String parent(String path) {
    if (this == posix) {
      final p = path.length > 1 && path.endsWith('/') ? path.substring(0, path.length - 1) : path;
      final i = p.lastIndexOf('/');
      return i <= 0 ? '/' : p.substring(0, i);
    }
    final p = path.replaceAll('/', r'\');
    if (RegExp(r'^[A-Za-z]:\\?$').hasMatch(p) || p.isEmpty) return '';
    final trimmed = p.endsWith(r'\') ? p.substring(0, p.length - 1) : p;
    final i = trimmed.lastIndexOf(r'\');
    if (i < 0) return '';
    return i == 2 && trimmed[1] == ':' ? trimmed.substring(0, 3) : trimmed.substring(0, i);
  }

  String name(String path) {
    var p = path;
    while (p.length > 1 && _isSep(p[p.length - 1])) {
      p = p.substring(0, p.length - 1);
    }
    final i = [p.lastIndexOf('/'), if (this == windows) p.lastIndexOf(r'\')].reduce((a, b) => a > b ? a : b);
    return i < 0 ? p : p.substring(i + 1);
  }

  /// Each ancestor of [path] with the name to show for it, root first.
  List<(String label, String path)> crumbs(String path) {
    final out = <(String, String)>[];
    for (var p = path; ; p = parent(p)) {
      final label = this == posix && p == '/' ? '/' : (this == windows && p.length <= 3 ? p : name(p));
      out.add((label, p));
      if (p.isEmpty || parent(p) == p) break;
    }
    return out.reversed.toList();
  }
}

/// Files on this computer or on a server, with the same operations and errors for both. Paths are absolute in
/// [style]. Operations that only might be possible say so ([canReplace], [canChmod]) instead of failing late.
abstract interface class FileSystem {
  PathStyle get style;

  /// Where browsing starts.
  Future<String> home();

  /// The absolute, normalised form of [path]; throws [FsError] when it does not exist.
  Future<String> resolve(String path);

  Future<List<FileEntry>> list(String dir);

  /// Null when nothing is there. Other failures throw: an unreadable target is not a missing one.
  /// Links are reported as links, not followed.
  Future<FileEntry?> stat(String path);

  Future<void> mkdir(String path);

  /// Refuses to replace an existing [to]. [checkCurrent] runs before each request, including after awaits.
  Future<void> rename(String from, String to, {void Function()? checkCurrent});

  /// Whether [replace] can swap a file in one step.
  bool get canReplace;

  /// Replaces [to] with [from] atomically; throws [FsFailure.unsupported] where it cannot.
  Future<void> replace(String from, String to, {void Function()? checkCurrent});

  /// A file or link; directories go through [rmdir].
  Future<void> delete(String path);

  /// An empty directory.
  Future<void> rmdir(String path);

  bool get canChmod;
  Future<void> chmod(String path, int mode);

  Stream<Uint8List> read(String path, {int offset = 0});

  /// Creates [path], which must not exist yet, and writes [data] into it. [onProgress] gets the bytes the file
  /// system confirmed; [cancel] stops the write and leaves the partial file for the caller to remove.
  Future<int> create(
    String path,
    Stream<Uint8List> data, {
    void Function(int written)? onProgress,
    CancellationToken? cancel,
    void Function()? checkCurrent,
  });

  /// Continues an existing regular file whose length must equal [offset]; never truncates it.
  /// Returns newly written bytes, and [onProgress] also counts only the new bytes.
  Future<int> append(
    String path,
    Stream<Uint8List> data, {
    required int offset,
    void Function(int written)? onProgress,
    CancellationToken? cancel,
    void Function()? checkCurrent,
  });

  Future<void> close();
}

/// What one bounded scan of a directory saw. [scanned] counts every name read, [entries] only the accepted ones.
class BoundedListing {
  const BoundedListing(this.entries, {required this.scanned, required this.complete});

  final List<FileEntry> entries;
  final int scanned;

  /// False when the scan stopped at its limit with names still unread.
  final bool complete;
}

/// A [FileSystem] that can also read a directory without reading all of it. Optional: [FileSystem.list] stays as it is
/// for callers that want everything, and callers of this check for it with `is`.
abstract interface class BoundedFileListing {
  /// Reads at most [maxScanned] names of [dir], in the order the server gives them, with no entry of `.` or `..`.
  /// A name beyond the limit makes the result incomplete; exactly [maxScanned] names followed by the end of the
  /// directory is complete. Names [accept] refuses count as scanned but are neither kept nor looked at again.
  ///
  /// [cancel] is checked between requests. A scan that ends incomplete, fails or is cancelled may leave the directory
  /// open on the server until the file system is closed, so the owner of the channel closes it then.
  Future<BoundedListing> listBounded(
    String dir, {
    required int maxScanned,
    bool Function(String name)? accept,
    CancellationToken? cancel,
  });
}

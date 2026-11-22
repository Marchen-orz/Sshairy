import 'dart:typed_data';

import '../../../foundation/cancellation.dart';
import '../../../foundation/file_system.dart';
import '../../../foundation/ids.dart';
import '../domain/transfer.dart';

/// A file operation that failed for a reason with a stable [code], such as `sizeMismatch` or `targetChanged`.
class OpFailure implements Exception {
  const OpFailure(this.code, [this.detail = '']);
  final String code, detail;

  @override
  String toString() => 'OpFailure($code, $detail)';
}

/// Thrown by [writeVerified] when [pause] was cancelled: the writes were drained, the part's settled length
/// was re-checked, and the part was left in place for resuming.
class Paused implements Exception {
  const Paused(this.written);
  final int written;

  @override
  String toString() => 'Paused($written)';
}

/// Writes [data] into a hidden `.part` beside [path], checks its length, then publishes it (docs/SECURITY.md §5).
/// With [replacing], the target must still look like that entry and is swapped in one step; without, an
/// existing target is never overwritten. The part is removed whenever publishing does not happen — except on
/// [pause], which stops the copy at a stable length and throws [Paused] instead. [part] overrides where the
/// staging file goes, for callers that derive its name from the transfer so it can be found again.
Future<int> writeVerified(
  FileSystem fs,
  String path,
  Stream<Uint8List> data, {
  int? expectedSize,
  FileEntry? replacing,
  String? part,
  void Function(int written)? onProgress,
  void Function(TransferPhase phase)? onPhase,
  CancellationToken? cancel,
  CancellationToken? pause,
  void Function()? checkCurrent,
}) async {
  if (replacing != null && !fs.canReplace) throw const OpFailure('replaceUnsupported');
  final style = fs.style;
  final partPath = part ?? style.join(style.parent(path), '.${style.name(path)}.${newId().substring(0, 6)}.part');
  var published = false, paused = false, owned = true;
  try {
    checkCurrent?.call();
    final int written;
    try {
      written = await fs.create(partPath, data, onProgress: onProgress, cancel: cancel, checkCurrent: checkCurrent);
    } on FsError catch (e) {
      // A refused exclusive create means the name was somebody else's; anything later is ours to clean up.
      if (e.kind == FsFailure.exists) owned = false;
      rethrow;
    }
    if (cancel?.isCancelled ?? false) return written;
    checkCurrent?.call();
    if (pause?.isCancelled ?? false) {
      // A settled length, not an aborted write: whatever the file system confirmed is on disk.
      final settled = await fs.stat(partPath);
      checkCurrent?.call();
      if (settled == null || settled.kind != FileKind.file || settled.size != written) {
        throw const OpFailure('partInvalid');
      }
      paused = true;
      throw Paused(written);
    }
    onPhase?.call(TransferPhase.verifying);
    final copied = await fs.stat(partPath);
    checkCurrent?.call();
    // A length check catches truncation, not corruption; it is not a hash.
    if (copied?.size != written || (expectedSize != null && written != expectedSize)) {
      throw OpFailure('sizeMismatch', '$written/${expectedSize ?? '?'}');
    }
    onPhase?.call(TransferPhase.publishing);
    if (replacing != null) {
      final now = await fs.stat(path);
      checkCurrent?.call();
      if (now == null || !now.sameAs(replacing)) throw const OpFailure('targetChanged');
      await fs.replace(partPath, path, checkCurrent: checkCurrent);
    } else {
      await fs.rename(partPath, path, checkCurrent: checkCurrent);
    }
    published = true;
    return written;
  } finally {
    if (owned && !published && !paused) {
      await fs.delete(partPath).timeout(const Duration(seconds: 5)).then((_) {}, onError: (Object _) {});
    }
  }
}

/// The first `name (n)` beside [path] that is free.
Future<String> freeName(FileSystem fs, String path, {required bool directory, void Function()? checkCurrent}) async {
  final style = fs.style;
  final dir = style.parent(path), name = style.name(path);
  for (var n = 1; n < 1000; n++) {
    final candidate = style.join(dir, keepBothName(name, n, directory: directory));
    checkCurrent?.call();
    final existing = await fs.stat(candidate);
    checkCurrent?.call();
    if (existing == null) return candidate;
  }
  throw const OpFailure('exists');
}

/// Null when [name] can be a single file name on [style]; otherwise why not.
String? badName(String name, PathStyle style) {
  final n = name.trim();
  if (n.isEmpty || n == '.' || n == '..') return 'empty';
  if (n.contains('/') || n.contains('\u0000')) return 'separator';
  if (style == PathStyle.windows && RegExp(r'[\\:*?"<>|]').hasMatch(n)) return 'separator';
  return null;
}

/// Validate the original name before joining it onto a directory on another device.
bool validCopyName(String name, PathStyle style) {
  if (badName(name, style) != null) return false;
  if (style == PathStyle.posix) return true;
  return !name.endsWith(' ') &&
      !name.endsWith('.') &&
      !RegExp(
        r'[\x00-\x1f]|^(?:CON|PRN|AUX|NUL|COM[0-9¹²³]|LPT[0-9¹²³]) *(?:\.|$)',
        caseSensitive: false,
      ).hasMatch(name);
}

/// Counts what deleting [path] would remove, stopping at [limit].
Future<int> countTree(FileSystem fs, String path, FileEntry entry, {int limit = 20000}) async {
  if (!entry.isDir) return 1;
  var count = 1;
  final pending = [path];
  while (pending.isNotEmpty && count < limit) {
    final dir = pending.removeLast();
    for (final e in await fs.list(dir)) {
      count++;
      if (e.isDir) pending.add(fs.style.join(dir, e.name));
    }
  }
  return count;
}

/// Removes [path] item by item through the file system, never by a shell `rm -rf`. Links are removed, not
/// followed, so deleting a link to a directory leaves the directory alone.
Future<void> deleteTree(
  FileSystem fs,
  String path,
  FileEntry entry, {
  CancellationToken? cancel,
  DateTime? deadline,
  void Function()? checkCurrent,
}) async {
  var visited = 0;
  void check() {
    if (cancel?.isCancelled ?? false) throw const OpFailure('cancelled');
    if (deadline != null && !DateTime.now().isBefore(deadline)) throw const OpFailure('deadlineExceeded');
    checkCurrent?.call();
  }

  Future<void> remove(String at, FileEntry item, int depth) async {
    check();
    if (depth > 64 || ++visited > 20000) throw const OpFailure('treeTooLarge');
    if (!item.isDir) {
      await fs.delete(at);
      return;
    }
    final List<FileEntry> children;
    if (fs is BoundedFileListing) {
      final listing = await (fs as BoundedFileListing).listBounded(at, maxScanned: 20000 - visited, cancel: cancel);
      check();
      if (!listing.complete) throw const OpFailure('treeTooLarge');
      children = listing.entries;
    } else {
      children = await fs.list(at);
    }
    check();
    if (children.length > 20000 - visited) throw const OpFailure('treeTooLarge');
    for (final child in children) {
      if (child.name.isEmpty ||
          child.name == '.' ||
          child.name == '..' ||
          child.name.contains('\x00') ||
          fs.style.name(child.name) != child.name) {
        throw const OpFailure('invalidName');
      }
      await remove(fs.style.join(at, child.name), child, depth + 1);
    }
    check();
    await fs.rmdir(at);
  }

  await remove(path, entry, 0);
}

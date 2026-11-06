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
}) async {
  if (replacing != null && !fs.canReplace) throw const OpFailure('replaceUnsupported');
  final style = fs.style;
  final partPath = part ?? style.join(style.parent(path), '.${style.name(path)}.${newId().substring(0, 6)}.part');
  var published = false, paused = false;
  try {
    final written = await fs.create(partPath, data, onProgress: onProgress, cancel: cancel);
    if (cancel?.isCancelled ?? false) return written;
    if (pause?.isCancelled ?? false) {
      // A settled length, not an aborted write: whatever the file system confirmed is on disk.
      final settled = await fs.stat(partPath);
      if (settled == null || settled.kind != FileKind.file || settled.size != written) {
        throw const OpFailure('partInvalid');
      }
      paused = true;
      throw Paused(written);
    }
    onPhase?.call(TransferPhase.verifying);
    final copied = await fs.stat(partPath);
    // A length check catches truncation, not corruption; it is not a hash.
    if (copied?.size != written || (expectedSize != null && written != expectedSize)) {
      throw OpFailure('sizeMismatch', '$written/${expectedSize ?? '?'}');
    }
    onPhase?.call(TransferPhase.publishing);
    if (replacing != null) {
      final now = await fs.stat(path);
      if (now == null || !now.sameAs(replacing)) throw const OpFailure('targetChanged');
      await fs.replace(partPath, path);
    } else {
      await fs.rename(partPath, path);
    }
    published = true;
    return written;
  } finally {
    if (!published && !paused) {
      await fs.delete(partPath).timeout(const Duration(seconds: 5)).then((_) {}, onError: (Object _) {});
    }
  }
}

/// The first `name (n)` beside [path] that is free.
Future<String> freeName(FileSystem fs, String path, {required bool directory}) async {
  final style = fs.style;
  final dir = style.parent(path), name = style.name(path);
  for (var n = 1; n < 1000; n++) {
    final candidate = style.join(dir, keepBothName(name, n, directory: directory));
    if (await fs.stat(candidate) == null) return candidate;
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
Future<void> deleteTree(FileSystem fs, String path, FileEntry entry, {CancellationToken? cancel}) async {
  if (!entry.isDir) return fs.delete(path);
  for (final e in await fs.list(path)) {
    if (cancel?.isCancelled ?? false) throw const OpFailure('cancelled');
    await deleteTree(fs, fs.style.join(path, e.name), e, cancel: cancel);
  }
  await fs.rmdir(path);
}

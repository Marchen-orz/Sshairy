import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../foundation/cancellation.dart';
import '../../../foundation/data_dir.dart';
import '../../../foundation/diagnostics.dart';
import '../../../foundation/file_system.dart';
import '../../../foundation/ids.dart';
import '../../../foundation/json_file.dart';
import '../../connections/api.dart';
import '../../hosts/api.dart';
import '../../settings/api.dart';
import '../domain/transfer.dart';
import 'file_ops.dart';
import 'file_systems.dart';

/// What the transfer queue asks the user; registered by the window so queued work can ask from anywhere.
abstract interface class TransferUi {
  ConnectPrompts get prompts;

  /// Null when dismissed. [cancel] fires if the transfer is cancelled while asking; close the question then.
  Future<ConflictAnswer?> conflict(Transfer transfer, Conflict conflict, CancellationToken cancel);
}

/// Limits from docs/MODULES.md §4.
const perHostTransfers = 2;
const maxScanDepth = 32;
const maxScanEntries = 20000;
const stallTimeout = Duration(seconds: 30);

final transfersProvider = NotifierProvider<TransferManager, List<Transfer>>(TransferManager.new);

/// Owns every transfer (docs/CONTRACTS.md §2): panes queue work here and only watch it, so closing a pane
/// never stops a copy. Progress reaches listeners at most five times a second.
class TransferManager extends Notifier<List<Transfer>> {
  late final JsonFile _file = JsonFile(
    '${ref.read(dataDirProvider)}/transfers.json',
    validate: (json) {
      if (json['transfers'] is! List) throw const FormatException('invalid transfers');
      final ids = <TransferId>{};
      for (final entry in json['transfers'] as List) {
        final transfer = Transfer.fromJson((entry as Map).cast<String, dynamic>());
        if (!ids.add(transfer.id)) throw const FormatException('duplicate transfer');
      }
    },
  );
  FileSystems get _pool => ref.read(fileSystemsProvider);

  TransferUi? ui;
  final _jobs = <TransferId, _Job>{};
  final _policy = <String, Map<ConflictKind, ConflictChoice>>{};
  Future<void> _asking = Future.value();
  Timer? _flushTimer;
  var _closing = false;

  @override
  List<Transfer> build() {
    ref.onDispose(() {
      _flushTimer?.cancel();
      for (final j in _jobs.values) {
        j.stop.cancel();
      }
    });
    final saved = _file.read()?['transfers'] as List<dynamic>? ?? const [];
    final out = <Transfer>[];
    for (final j in saved) {
      try {
        out.add(Transfer.fromJson((j as Map).cast()));
      } on Object {
        continue;
      }
    }
    return pruneHistory(out, DateTime.now());
  }

  Future<void> get saved => _file.idle;

  int get activeCount => state.where((t) => t.state.active).length;

  @visibleForTesting
  int get rememberedBatchCount => _policy.length;

  Transfer? byId(TransferId id) => state.where((t) => t.id == id).firstOrNull;

  /// An approval follows one attempt, rather than another job resumed or retried under the same ID.
  Object? resourceBinding(TransferId id) => _jobs[id] ?? byId(id);

  /// Copies [paths] on [from] (null for this computer) into [targetDir] on [to]. One call is one batch.
  List<TransferId> enqueue({
    required Host? from,
    required List<String> paths,
    required Host? to,
    required String targetDir,
  }) {
    if (_closing || paths.isEmpty) return const [];
    for (final h in [?from, ?to]) {
      _pool.remember(h);
    }
    final batch = newId();
    final now = DateTime.now();
    final srcStyle = styleOf(from?.id), dstStyle = styleOf(to?.id);
    final added = [
      for (final p in paths)
        Transfer(
          id: TransferId(newId()),
          batch: batch,
          source: FileEnd(from?.id, p, label: from?.title ?? ''),
          target: FileEnd(to?.id, dstStyle.join(targetDir, srcStyle.name(p)), label: to?.title ?? ''),
          created: now,
        ),
    ];
    _set([...state, ...added]);
    _pump();
    return [for (final t in added) t.id];
  }

  static PathStyle styleOf(HostId? host) => host == null ? localFiles.style : PathStyle.posix;

  /// Parks a single-file transfer at a stable length. Called before the source is even known, the park takes
  /// effect at the first stable point; directories and transfers waiting on a conflict are left alone.
  void pause(TransferId id) {
    final job = _jobs[id];
    if (job == null || job.singleFile == false || job.state != TransferState.running) return;
    job.state = TransferState.pausing;
    _replace(job.snapshot());
    job.pause.cancel();
  }

  /// Puts a parked transfer back in the queue; resuming re-validates the source and the part before continuing.
  void resume(TransferId id) {
    if (_closing) return;
    _update(
      id,
      (t) => t.state == TransferState.paused || (t.state == TransferState.interrupted && t.checkpoint?.settled == true)
          ? t.copyWith(state: TransferState.queued, error: () => null, finished: () => null)
          : t,
    );
    _pump();
  }

  Future<void> cancel(TransferId id) async {
    final job = _jobs[id];
    if (job != null) {
      job.stop.cancel();
      await job.finished.future;
      return;
    }
    final t = byId(id);
    if (t == null) return;
    if (t.state == TransferState.paused) {
      await _dropCheckpoint(t);
      return;
    }
    _update(
      id,
      (t) => t.state == TransferState.queued
          ? t.copyWith(state: TransferState.cancelled, finished: () => DateTime.now())
          : t,
    );
  }

  /// From the start. A checkpoint is cleaned up first; a part that will not go keeps its record with the path.
  Future<void> retry(TransferId id) async {
    if (_closing) return;
    final t = byId(id);
    if (t == null || !t.state.canRetry) return;
    if (t.checkpoint != null && !await _cleanupPart(t)) {
      _update(
        id,
        (x) => x.copyWith(state: TransferState.failed, error: () => 'leftoverPart', detail: t.checkpoint!.part),
      );
      return;
    }
    _update(id, (t) => t.state.canRetry ? t.restart(newId()) : t);
    _pump();
  }

  Future<void> remove(TransferId id) async {
    final t = byId(id);
    if (t == null || (t.state.active && t.state != TransferState.paused)) return;
    if (t.checkpoint != null && !await _cleanupPart(t)) {
      _update(
        id,
        (x) => x.copyWith(state: TransferState.failed, error: () => 'leftoverPart', detail: t.checkpoint!.part),
      );
      return;
    }
    _set([
      for (final t in state)
        if (t.id != id) t,
    ]);
  }

  void clearFinished() => _set([
    for (final t in state)
      if (t.state.active || t.checkpoint != null) t,
  ]);

  /// For the shutdown coordinator: stops taking work, cancels what runs and waits a little for it to clean up.
  /// A single file mid-copy parks itself resumable instead of being cut off (docs/TRANSFER_RESUME.md).
  Future<void> shutdown({Duration grace = const Duration(seconds: 3)}) async {
    _closing = true;
    for (final j in _jobs.values) {
      if (j.singleFile == true && j.phase == TransferPhase.copying && j.conflict == null) {
        j.pause.cancel();
      } else {
        j.stop.cancel();
      }
    }
    final running = [for (final j in _jobs.values) j.finished.future];
    await Future.wait(running).timeout(grace);
    _flush();
    _save();
    await _file.idle;
  }

  /// Reopens the queue if the user returns to the app after a failed shutdown.
  void resumeAfterShutdown() {
    _closing = false;
    _pump();
  }

  void _pump() {
    if (_closing) return;
    final limit = ref.read(settingsProvider).get(SettingKeys.transferConcurrency);
    for (final id in runnable(state, global: limit, perHost: perHostTransfers)) {
      final t = byId(id)!;
      final job = _Job(t.copyWith(state: TransferState.running));
      _jobs[id] = job;
      _replace(job.snapshot());
      _run(job);
    }
  }

  Future<void> _run(_Job job) async {
    ref.read(diagnosticLogProvider).record(DiagnosticArea.transfer, DiagnosticAction.copy, DiagnosticOutcome.started);
    final t = job.transfer;
    FsHandle? src, dst;
    FileEntry? entry;
    final prompts = ui?.prompts ?? const NoPrompts();
    try {
      src = await _pool.acquire(t.source.host, prompts);
      job.check();
      dst = await _pool.acquire(t.target.host, prompts);
      job.check();
      // Started only now: connecting may wait on a password dialog for as long as the user likes.
      job.startWatchdog(_touch);
      entry = await src.fs.stat(t.source.path);
      if (entry == null) throw const OpFailure('sourceMissing');
      final copy = _Copy(this, job, src.fs, dst.fs);
      if (t.checkpoint case final cp?) {
        job.resuming = true;
        job.singleFile = true;
        job.directory = false;
        job.total = cp.source.size;
        job.totalFiles = 1;
        await copy.resumeFile(t.source.path, entry, cp);
      } else if (entry.isDir) {
        job.directory = true;
        job.singleFile = false;
        await copy.directory(t.source.path, t.target.path);
      } else if (entry.kind == FileKind.file) {
        job.singleFile = true;
        job.directory = false;
        job.total = entry.size;
        job.totalFiles = 1;
        await copy.file(t.source.path, t.target.path, entry);
      } else {
        throw const OpFailure('unsupportedType');
      }
      _finish(job, TransferState.completed);
    } on _PausedAt catch (p) {
      _park(job, entry!, p);
    } on _Stopped {
      await _cutOff(job, dst);
    } on OpFailure catch (e) {
      job.stop.isCancelled
          ? await _cutOff(job, dst)
          : _finish(job, TransferState.failed, error: e.code, detail: e.detail);
    } on FsError catch (e) {
      job.stop.isCancelled
          ? await _cutOff(job, dst)
          : _finish(job, TransferState.failed, error: e.kind.name, detail: e.detail);
    } on ConnectError catch (e) {
      _finish(job, TransferState.failed, error: 'connect', detail: e.kind.name);
    } on Object catch (e) {
      _finish(job, TransferState.failed, error: 'failed', detail: '$e');
    } finally {
      job.stopWatchdog();
      src?.release();
      dst?.release();
      _jobs.remove(t.id);
      job.finished.complete();
      _pump();
    }
  }

  /// Records where the transfer stopped and parks it: the checkpoint is settled, so a later resume continues
  /// from [p.written] after re-validating the source and the part.
  void _park(_Job job, FileEntry entry, _PausedAt p) {
    job.checkpoint = TransferCheckpoint(
      offset: p.written,
      source: entry,
      target: p.target,
      part: p.part,
      replacing: p.replacing,
      settled: true,
    );
    job.state = TransferState.paused;
    ref
        .read(diagnosticLogProvider)
        .record(DiagnosticArea.transfer, DiagnosticAction.pause, DiagnosticOutcome.succeeded);
    job.phase = null;
    _replace(job.snapshot().copyWith(error: () => null, speed: 0));
  }

  /// Cancels a parked transfer: cleans the part it owns, or keeps the record with the path when it will not go.
  Future<void> _dropCheckpoint(Transfer t) async {
    final ok = await _cleanupPart(t);
    final now = DateTime.now();
    _update(
      t.id,
      (x) => ok
          ? x.copyWith(state: TransferState.cancelled, checkpoint: () => null, speed: 0, finished: () => now)
          : x.copyWith(
              state: TransferState.failed,
              error: () => 'leftoverPart',
              detail: t.checkpoint?.part ?? '',
              finished: () => now,
            ),
    );
  }

  /// Deletes the part a checkpoint owns, re-deriving it from the transfer first: restored history never names
  /// a file to delete (docs/SECURITY.md §5). False when the part may still be there.
  Future<bool> _cleanupPart(Transfer t) async {
    final cp = t.checkpoint;
    if (cp == null) return true;
    if (!partDerived(t, cp, styleOf(t.target.host))) return false;
    FsHandle? dst;
    try {
      dst = await _pool.acquire(t.target.host, ui?.prompts ?? const NoPrompts());
      if (await dst.fs.stat(cp.part) == null) return true;
      await dst.fs.delete(cp.part);
      return true;
    } on Object {
      return false;
    } finally {
      dst?.release();
    }
  }

  /// Best-effort removal of a running transfer's part when it is being cut off; the handle is still open here.
  Future<bool> _discardPart(_Job job, FsHandle? dst) async {
    final cp = job.checkpoint;
    if (cp == null) return true;
    if (!partDerived(job.transfer, cp, styleOf(job.transfer.target.host))) return false;
    final fs = dst?.fs;
    if (fs == null) return false;
    try {
      if (await fs.stat(cp.part) != null) await fs.delete(cp.part);
      job.checkpoint = null;
      return true;
    } on Object {
      return false;
    }
  }

  Future<void> _cutOff(_Job job, FsHandle? dst) async {
    _stopped(job, cleanPart: await _discardPart(job, dst));
  }

  void _stopped(_Job job, {bool cleanPart = true}) => job.stalled
      ? _finish(job, TransferState.failed, error: 'stalled')
      : cleanPart
      ? _finish(job, TransferState.cancelled)
      : _finish(job, TransferState.failed, error: 'leftoverPart', detail: job.checkpoint?.part ?? '');

  void _finish(_Job job, TransferState s, {String? error, String detail = ''}) {
    ref
        .read(diagnosticLogProvider)
        .record(
          DiagnosticArea.transfer,
          DiagnosticAction.copy,
          s == TransferState.completed
              ? DiagnosticOutcome.succeeded
              : s == TransferState.cancelled
              ? DiagnosticOutcome.cancelled
              : DiagnosticOutcome.failed,
        );
    job.state = s;
    job.phase = null;
    // Completed means the part was published; a failure keeps the checkpoint so remove/retry can clean it.
    if (s == TransferState.completed) job.checkpoint = null;
    _replace(job.snapshot().copyWith(error: () => error, detail: detail, finished: () => DateTime.now(), speed: 0));
  }

  /// Asks about one conflict at a time, so parallel transfers do not stack dialogs; an answer for the whole
  /// batch given meanwhile settles the waiting ones without asking again.
  Future<ConflictChoice> _decide(_Job job, Conflict c) async {
    ConflictChoice? remembered() => _policy[job.transfer.batch]?[c.kind];
    if (remembered() case final choice?) return choice;
    final ui = this.ui;
    if (ui == null) throw const OpFailure('conflict');
    final previous = _asking;
    final turn = Completer<void>();
    _asking = turn.future;
    job.waitFor(c);
    _replace(job.snapshot());
    try {
      await previous;
      if (remembered() case final choice?) return choice;
      job.check();
      final answer = await Future.any([
        ui.conflict(job.snapshot(), c, job.stop),
        job.stop.whenCancelled.then((_) => null),
      ]);
      job.check();
      final choice = answer?.choice ?? ConflictChoice.cancel;
      if (choice == ConflictChoice.cancel) throw const _Stopped();
      if (answer!.all) (_policy[job.transfer.batch] ??= {})[c.kind] = choice;
      return choice;
    } finally {
      turn.complete();
      job.resume();
      _replace(job.snapshot());
    }
  }

  void _touch() {
    _flushTimer ??= Timer(const Duration(milliseconds: 200), _flush);
  }

  void _flush() {
    _flushTimer?.cancel();
    _flushTimer = null;
    if (_jobs.isEmpty) return;
    state = [for (final t in state) _jobs[t.id]?.snapshot() ?? t];
  }

  void _replace(Transfer t) {
    final changed = byId(t.id)?.state != t.state;
    _flushTimer?.cancel();
    _flushTimer = null;
    state = [for (final x in state) x.id == t.id ? t : (_jobs[x.id]?.snapshot() ?? x)];
    if (changed) _save();
  }

  void _update(TransferId id, Transfer Function(Transfer) f) => _set([for (final t in state) t.id == id ? f(t) : t]);

  void _set(List<Transfer> next) {
    state = next;
    _save();
  }

  void _save() {
    final kept = pruneHistory(state, DateTime.now());
    if (kept.length != state.length) state = kept;
    final liveBatches = {
      for (final t in kept)
        if (t.state.active || t.checkpoint != null) t.batch,
    };
    _policy.removeWhere((batch, _) => !liveBatches.contains(batch));
    _file.write({
      'schemaVersion': 1,
      'transfers': [for (final t in kept) t.toJson()],
    });
  }
}

class _Stopped implements Exception {
  const _Stopped();
}

/// A transfer parked mid-copy: writes drained, part length stable (docs/TRANSFER_RESUME.md).
class _PausedAt implements Exception {
  const _PausedAt(this.target, this.part, this.replacing, this.written);
  final String target, part;
  final FileEntry? replacing;
  final int written;
}

/// The mutable side of a running transfer; [snapshot] turns it into the immutable value listeners see.
class _Job {
  _Job(this.transfer)
    : state = transfer.state,
      total = transfer.total,
      totalFiles = transfer.totalFiles,
      directory = transfer.directory,
      checkpoint = transfer.checkpoint;

  final Transfer transfer;
  final stop = CancellationToken();

  /// Stopping the source stream parks the copy; only single files may be parked.
  final pause = CancellationToken();
  final finished = Completer<void>();
  final _meter = SpeedMeter();
  TransferState state;
  TransferPhase? phase;
  int bytes = 0, files = 0, skipped = 0;
  int? total, totalFiles;
  Conflict? conflict;
  bool? singleFile;
  bool directory, resuming = false;
  TransferCheckpoint? checkpoint;
  var stalled = false;
  var _lastProgress = DateTime.now();
  Timer? _watchdog;
  void Function()? _notify;

  void check() {
    if (stop.isCancelled) throw const _Stopped();
  }

  void progressed([int? to]) {
    if (to != null) bytes = to;
    _lastProgress = DateTime.now();
    _meter.add(_lastProgress, bytes);
    _notify?.call();
  }

  void waitFor(Conflict c) {
    state = TransferState.waiting;
    conflict = c;
  }

  void resume() {
    state = TransferState.running;
    conflict = null;
    _lastProgress = DateTime.now();
  }

  /// A request can hang without the connection dropping; no progress for [stallTimeout] fails the transfer.
  /// Waiting for the user does not count.
  void startWatchdog(void Function() notify) {
    _notify = notify;
    _watchdog = Timer.periodic(const Duration(seconds: 1), (_) {
      if (state != TransferState.running || stop.isCancelled) return;
      if (DateTime.now().difference(_lastProgress) > stallTimeout) {
        stalled = true;
        stop.cancel();
      }
    });
  }

  void stopWatchdog() {
    _watchdog?.cancel();
    _notify = null;
  }

  Transfer snapshot() => transfer.copyWith(
    state: state,
    phase: () => phase,
    bytes: bytes,
    total: () => total,
    files: files,
    totalFiles: () => totalFiles,
    skipped: skipped,
    speed: _meter.bytesPerSecond,
    conflict: () => conflict,
    directory: directory,
    checkpoint: () => checkpoint,
  );
}

/// Copies one transfer's files: each into a hidden `.part` beside its target, checked, then published
/// (docs/SECURITY.md §5).
class _Copy {
  _Copy(this._manager, this._job, this._src, this._dst);

  final TransferManager _manager;
  final _Job _job;
  final FileSystem _src, _dst;

  Future<void> file(String from, String to, FileEntry incoming) async {
    _job.phase = TransferPhase.copying;
    _job.progressed();
    var path = to;
    FileEntry? baseline;
    final existing = await _dst.stat(path);
    if (existing != null) {
      final kind = existing.isDir ? ConflictKind.fileOnDir : ConflictKind.file;
      switch (await _manager._decide(_job, Conflict(kind, path, existing, incoming))) {
        case ConflictChoice.skip:
          _job.skipped++;
          _job.progressed(_job.bytes + (incoming.size ?? 0));
          return;
        case ConflictChoice.keepBoth:
          path = await freeName(_dst, path, directory: false);
        case ConflictChoice.replace:
          if (!_dst.canReplace) throw const OpFailure('replaceUnsupported');
          baseline = existing;
        case ConflictChoice.merge || ConflictChoice.cancel:
          throw const _Stopped();
      }
    }
    final part = partPathFor(_dst.style, path, _job.transfer.id);
    if (_job.singleFile == true) {
      // Recorded before any byte: a crash leaves the part's location known for cleanup, but not resumable.
      _job.checkpoint = TransferCheckpoint(offset: 0, source: incoming, target: path, part: part, replacing: baseline);
      _manager._replace(_job.snapshot());
      _manager._save();
    }
    final base = _job.bytes;
    try {
      await writeVerified(
        _dst,
        path,
        _until(_src.read(from), parkable: _job.singleFile == true),
        expectedSize: incoming.size,
        replacing: baseline,
        part: part,
        onProgress: (n) => _job.progressed(base + n),
        onPhase: (p) => _job.phase = p,
        cancel: _job.stop,
        // A file inside a directory copy must not park mid-way, even if pause was asked for before the
        // source turned out to be a directory.
        pause: _job.singleFile == true ? _job.pause : null,
      );
    } on Paused catch (p) {
      throw _PausedAt(path, part, baseline, p.written);
    }
    _job.check();
    _job.files++;
    _job.phase = TransferPhase.copying;
    _job.progressed();
  }

  /// Continues a parked transfer from its checkpoint (docs/TRANSFER_RESUME.md): everything the history claimed
  /// is re-checked against the file systems before a single byte is appended.
  Future<void> resumeFile(String from, FileEntry source, TransferCheckpoint cp) async {
    final problem = checkpointProblem(_job.transfer, cp, _dst.style);
    if (problem != null) throw OpFailure(problem);
    if (source.size == null || !source.sameAs(cp.source)) throw const OpFailure('sourceChanged');
    final part = await _dst.stat(cp.part);
    if (part == null || part.kind != FileKind.file || part.size != cp.offset) {
      throw const OpFailure('partInvalid');
    }
    _job.phase = TransferPhase.copying;
    _job.progressed(cp.offset);
    if (cp.offset < source.size!) {
      try {
        await _dst.append(
          cp.part,
          _until(_src.read(from, offset: cp.offset), parkable: true),
          offset: cp.offset,
          onProgress: (n) => _job.progressed(cp.offset + n),
          cancel: _job.stop,
        );
      } on FsError catch (e) {
        // append refuses a part whose length moved: the checkpoint is stale.
        throw e.kind == FsFailure.partInvalid ? const OpFailure('partInvalid') : e;
      }
    }
    _job.check();
    if (_job.pause.isCancelled) {
      final settled = await _dst.stat(cp.part);
      if (settled == null || settled.kind != FileKind.file) throw const OpFailure('partInvalid');
      throw _PausedAt(cp.target, cp.part, cp.replacing, settled.size!);
    }
    _job.phase = TransferPhase.verifying;
    final again = await _src.stat(from);
    if (again == null || !again.sameAs(source)) throw const OpFailure('sourceChanged');
    final done = await _dst.stat(cp.part);
    if (done?.size != source.size) throw OpFailure('sizeMismatch', '${done?.size}/${source.size}');
    _job.phase = TransferPhase.publishing;
    if (cp.replacing case final baseline?) {
      final now = await _dst.stat(cp.target);
      if (now == null || !now.sameAs(baseline)) throw const OpFailure('targetChanged');
      await _dst.replace(cp.part, cp.target);
    } else {
      await _dst.rename(cp.part, cp.target);
    }
    _job.check();
    _job.files++;
    _job.phase = TransferPhase.copying;
    _job.progressed(source.size!);
  }

  /// Scans first, so progress has a total; links and special files are skipped, not followed.
  Future<void> directory(String from, String to) async {
    _job.phase = TransferPhase.scanning;
    _job.progressed();
    var root = to;
    final existing = await _dst.stat(root);
    if (existing != null) {
      final kind = existing.isDir ? ConflictKind.directory : ConflictKind.fileOnDir;
      final incoming = FileEntry(_src.style.name(from), FileKind.directory);
      switch (await _manager._decide(_job, Conflict(kind, root, existing, incoming))) {
        case ConflictChoice.merge:
          break;
        case ConflictChoice.keepBoth:
          root = await freeName(_dst, root, directory: true);
        case ConflictChoice.skip:
          _job.skipped++;
          return;
        case ConflictChoice.replace || ConflictChoice.cancel:
          throw const _Stopped();
      }
    }

    final dirs = <List<String>>[];
    final files = <(List<String>, FileEntry)>[];
    var total = 0, seen = 0;
    final pending = <(String, List<String>)>[(from, const [])];
    while (pending.isNotEmpty) {
      _job.check();
      final (path, rel) = pending.removeAt(0);
      final entries = await _src.list(path);
      entries.sort((a, b) => a.name.compareTo(b.name));
      for (final e in entries) {
        if (++seen > maxScanEntries) throw const OpFailure('tooMany', '$maxScanEntries');
        final child = [...rel, e.name];
        switch (e.kind) {
          case FileKind.directory:
            if (child.length > maxScanDepth) throw const OpFailure('tooDeep', '$maxScanDepth');
            dirs.add(child);
            pending.add((_src.style.join(path, e.name), child));
          case FileKind.file:
            files.add((child, e));
            total += e.size ?? 0;
          case FileKind.link || FileKind.other:
            _job.skipped++;
        }
      }
      _job.total = total;
      _job.totalFiles = files.length;
      _job.progressed();
    }

    _job.phase = TransferPhase.copying;
    if (await _dst.stat(root) == null) await _dst.mkdir(root);
    // A file standing where a directory should be keeps everything under it out.
    final blocked = <String>[];
    bool under(List<String> rel) => blocked.any((b) => rel.join('/').startsWith('$b/') || rel.join('/') == b);
    for (final rel in dirs) {
      if (under(rel)) continue;
      final path = _join(_dst.style, root, rel);
      final there = await _dst.stat(path);
      if (there == null) {
        await _dst.mkdir(path);
      } else if (!there.isDir) {
        final c = Conflict(ConflictKind.fileOnDir, path, there, FileEntry(rel.last, FileKind.directory));
        final choice = await _manager._decide(_job, c);
        if (choice != ConflictChoice.skip) throw const _Stopped();
        blocked.add(rel.join('/'));
        _job.skipped++;
      }
    }
    for (final (rel, entry) in files) {
      _job.check();
      if (under(rel)) {
        _job.skipped++;
        _job.progressed(_job.bytes + (entry.size ?? 0));
        continue;
      }
      await file(_join(_src.style, from, rel), _join(_dst.style, root, rel), entry);
    }
  }

  static String _join(PathStyle style, String root, List<String> rel) => rel.fold(root, style.join);

  /// The source stream, stopping early on cancel — and on pause, but only where parking is legal: a file
  /// inside a directory copy ignores the pause token, so a directory is never half-parked.
  Stream<Uint8List> _until(Stream<Uint8List> data, {bool parkable = false}) async* {
    await for (final chunk in data) {
      if (_job.stop.isCancelled || (parkable && _job.pause.isCancelled)) return;
      yield chunk;
    }
  }
}

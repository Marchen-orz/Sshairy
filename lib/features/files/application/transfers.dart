import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../foundation/cancellation.dart';
import '../../../foundation/data_dir.dart';
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
  late final JsonFile _file = JsonFile('${ref.read(dataDirProvider)}/transfers.json');
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

  Transfer? byId(TransferId id) => state.where((t) => t.id == id).firstOrNull;

  /// Copies [paths] on [from] (null for this computer) into [targetDir] on [to]. One call is one batch.
  List<TransferId> enqueue({required Host? from, required List<String> paths, required Host? to, required String targetDir}) {
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

  void cancel(TransferId id) {
    final job = _jobs[id];
    if (job != null) {
      job.stop.cancel();
      return;
    }
    _update(id, (t) => t.state == TransferState.queued
        ? t.copyWith(state: TransferState.cancelled, finished: () => DateTime.now())
        : t);
  }

  /// From the start; MODULES §4 keeps resuming for M3.
  void retry(TransferId id) {
    if (_closing) return;
    _update(id, (t) => t.state.canRetry ? t.restart(newId()) : t);
    _pump();
  }

  void remove(TransferId id) => _set([for (final t in state) if (t.id != id || t.state.active) t]);

  void clearFinished() => _set([for (final t in state) if (t.state.active) t]);

  /// For the shutdown coordinator: stops taking work, cancels what runs and waits a little for it to clean up.
  Future<void> shutdown({Duration grace = const Duration(seconds: 3)}) async {
    _closing = true;
    for (final j in _jobs.values) {
      j.stop.cancel();
    }
    final running = [for (final j in _jobs.values) j.finished.future];
    await Future.wait(running).timeout(grace, onTimeout: () => const []);
    _flush();
    await _file.idle;
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
    final t = job.transfer;
    FsHandle? src, dst;
    final prompts = ui?.prompts ?? const NoPrompts();
    try {
      src = await _pool.acquire(t.source.host, prompts);
      job.check();
      dst = await _pool.acquire(t.target.host, prompts);
      job.check();
      // Started only now: connecting may wait on a password dialog for as long as the user likes.
      job.startWatchdog(_touch);
      final entry = await src.fs.stat(t.source.path);
      if (entry == null) throw const OpFailure('sourceMissing');
      final copy = _Copy(this, job, src.fs, dst.fs);
      if (entry.isDir) {
        await copy.directory(t.source.path, t.target.path);
      } else if (entry.kind == FileKind.file) {
        job.total = entry.size;
        job.totalFiles = 1;
        await copy.file(t.source.path, t.target.path, entry);
      } else {
        throw const OpFailure('unsupportedType');
      }
      _finish(job, TransferState.completed);
    } on _Stopped {
      _stopped(job);
    } on OpFailure catch (e) {
      job.stop.isCancelled ? _stopped(job) : _finish(job, TransferState.failed, error: e.code, detail: e.detail);
    } on FsError catch (e) {
      job.stop.isCancelled ? _stopped(job) : _finish(job, TransferState.failed, error: e.kind.name, detail: e.detail);
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

  void _stopped(_Job job) => job.stalled
      ? _finish(job, TransferState.failed, error: 'stalled')
      : _finish(job, TransferState.cancelled);

  void _finish(_Job job, TransferState s, {String? error, String detail = ''}) {
    job.state = s;
    job.phase = null;
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

  void _update(TransferId id, Transfer Function(Transfer) f) =>
      _set([for (final t in state) t.id == id ? f(t) : t]);

  void _set(List<Transfer> next) {
    state = next;
    _save();
  }

  void _save() {
    final kept = pruneHistory(state, DateTime.now());
    _file.write({
      'schemaVersion': 1,
      'transfers': [for (final t in kept) t.toJson()],
    });
  }
}

class _Stopped implements Exception {
  const _Stopped();
}

/// The mutable side of a running transfer; [snapshot] turns it into the immutable value listeners see.
class _Job {
  _Job(this.transfer)
      : state = transfer.state,
        total = transfer.total,
        totalFiles = transfer.totalFiles;

  final Transfer transfer;
  final stop = CancellationToken();
  final finished = Completer<void>();
  final _meter = SpeedMeter();
  TransferState state;
  TransferPhase? phase;
  int bytes = 0, files = 0, skipped = 0;
  int? total, totalFiles;
  Conflict? conflict;
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
    final base = _job.bytes;
    await writeVerified(
      _dst,
      path,
      _until(_src.read(from)),
      expectedSize: incoming.size,
      replacing: baseline,
      onProgress: (n) => _job.progressed(base + n),
      onPhase: (p) => _job.phase = p,
      cancel: _job.stop,
    );
    _job.check();
    _job.files++;
    _job.phase = TransferPhase.copying;
    _job.progressed();
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

  Stream<Uint8List> _until(Stream<Uint8List> data) async* {
    await for (final chunk in data) {
      if (_job.stop.isCancelled) return;
      yield chunk;
    }
  }
}

import '../../../foundation/file_system.dart';
import '../../../foundation/ids.dart';

/// [waiting] needs the user's answer to a conflict; [pausing] drains in-flight writes before [paused];
/// [interrupted] was unfinished when the app last quit. A paused transfer keeps its target locked but frees
/// its connection and its slot in the concurrency limit.
enum TransferState {
  queued,
  running,
  waiting,
  pausing,
  paused,
  completed,
  failed,
  cancelled,
  interrupted;

  bool get active => this == queued || this == running || this == waiting || this == pausing || this == paused;
  bool get canRetry => this == failed || this == cancelled || this == interrupted;
}

enum TransferPhase { scanning, copying, verifying, publishing }

/// A path on this computer (no host) or on a host. [label] is the host's name when queued, so the history still
/// reads well after the host is renamed or gone.
class FileEnd {
  const FileEnd(this.host, this.path, {this.label = ''});

  final HostId? host;
  final String path;
  final String label;

  bool get local => host == null;

  Map<String, Object?> toJson() => {if (host != null) 'host': host!.value, 'path': path, 'label': label};

  factory FileEnd.fromJson(Map<String, dynamic> j) => FileEnd(
    j['host'] == null ? null : HostId(j['host'] as String),
    j['path'] as String,
    label: j['label'] as String? ?? '',
  );
}

/// The hidden file a paused transfer stages in, beside its target (docs/SECURITY.md §5): the target's name and
/// this transfer's ID, so a restored history can never name some other file to touch.
final _safeTransferId = RegExp(r'^[A-Za-z0-9_-]{1,128}$');

bool _validTransferId(TransferId id) => _safeTransferId.hasMatch(id.value);

String partPathFor(PathStyle style, String target, TransferId id) {
  if (!_validTransferId(id)) throw const FormatException('invalid transfer id');
  return style.join(style.parent(target), '.${style.name(target)}.${id.value}.part');
}

Map<String, Object?> _entryJson(FileEntry e) => {
  'kind': e.kind.name,
  if (e.size != null) 'size': e.size,
  if (e.modified != null) 'modified': e.modified!.toIso8601String(),
};

FileEntry _entryFrom(Map<String, dynamic> j) => FileEntry(
  '',
  FileKind.values.byName(j['kind'] as String),
  size: j['size'] as int?,
  modified: j['modified'] == null ? null : DateTime.parse(j['modified'] as String),
);

/// Where a paused single-file transfer stopped (docs/TRANSFER_RESUME.md). Only a [settled] checkpoint — recorded
/// after the writes drained and the source and part were verified — may be resumed; an unsettled one only tells
/// the next start which part file to clean up.
class TransferCheckpoint {
  const TransferCheckpoint({
    required this.offset,
    required this.source,
    required this.target,
    required this.part,
    this.replacing,
    this.settled = false,
  });

  /// The stable length of the part file when the writes had drained.
  final int offset;

  /// The source as it was when the transfer paused; resuming requires it to be unchanged.
  final FileEntry source;

  /// The actual target, which a keep-both conflict may have renamed.
  final String target;

  /// Always [partPathFor] of [target] and the owning transfer's ID.
  final String part;

  /// What the target looked like before being replaced, to re-check at publish time.
  final FileEntry? replacing;

  final bool settled;

  TransferCheckpoint copyWith({int? offset, bool? settled}) => TransferCheckpoint(
    offset: offset ?? this.offset,
    source: source,
    target: target,
    part: part,
    replacing: replacing,
    settled: settled ?? this.settled,
  );

  Map<String, Object?> toJson() => {
    'offset': offset,
    'source': _entryJson(source),
    'target': target,
    'part': part,
    if (replacing != null) 'replacing': _entryJson(replacing!),
    'settled': settled,
  };

  factory TransferCheckpoint.fromJson(Map<String, dynamic> j) => TransferCheckpoint(
    offset: j['offset'] as int,
    source: _entryFrom((j['source'] as Map).cast()),
    target: j['target'] as String,
    part: j['part'] as String,
    replacing: j['replacing'] == null ? null : _entryFrom((j['replacing'] as Map).cast()),
    settled: j['settled'] as bool? ?? false,
  );
}

/// Why [cp] cannot be resumed for [t], or null when it can. Structural only: no file system is touched, so a
/// passing check still has to be followed by stats of the source and the part.
String? checkpointProblem(Transfer t, TransferCheckpoint cp, PathStyle style) {
  if (!cp.settled || cp.source.kind != FileKind.file) return 'partInvalid';
  if (!partDerived(t, cp, style)) return 'partInvalid';
  if (cp.offset < 0 || cp.source.size == null || cp.offset > cp.source.size!) return 'partInvalid';
  return null;
}

/// Whether the checkpoint's part is the one this transfer owns: beside a target that is either the original
/// path or a legal keep-both name of it. This is what gates cleanup, so restored JSON never deletes by path.
bool partDerived(Transfer t, TransferCheckpoint cp, PathStyle style) {
  if (!_validTransferId(t.id)) return false;
  final original = t.target.path;
  if (style.parent(cp.target) != style.parent(original)) return false;
  if (style.parent(cp.part) != style.parent(cp.target)) return false;
  if (cp.part != partPathFor(style, cp.target, t.id)) return false;
  final name = style.name(cp.target), originalName = style.name(original);
  if (name == originalName) return true;
  for (var n = 1; n < 1000; n++) {
    final candidate = keepBothName(originalName, n, directory: false);
    if (candidate == name) return true;
    if (candidate.length > name.length) return false;
  }
  return false;
}

/// One queued copy of a file or directory. [target] is the full path the item should get; keeping both copies
/// may give it another name at run time.
class Transfer {
  const Transfer({
    required this.id,
    required this.batch,
    required this.source,
    required this.target,
    required this.created,
    this.state = TransferState.queued,
    this.phase,
    this.bytes = 0,
    this.total,
    this.files = 0,
    this.totalFiles,
    this.skipped = 0,
    this.speed = 0,
    this.error,
    this.detail = '',
    this.finished,
    this.conflict,
    this.directory = false,
    this.checkpoint,
  });

  final TransferId id;

  /// Transfers queued together; "apply to all" answers hold within a batch only.
  final String batch;
  final FileEnd source, target;
  final DateTime created;
  final TransferState state;
  final TransferPhase? phase;
  final int bytes;
  final int? total;
  final int files;
  final int? totalFiles;

  /// Items left out: skipped conflicts, links and special files inside directories.
  final int skipped;

  /// Bytes per second over the last few seconds; not saved.
  final double speed;

  /// A stable code for the failure, such as `sizeMismatch` or `permission`.
  final String? error;
  final String detail;
  final DateTime? finished;

  /// What [waiting] waits for.
  final Conflict? conflict;

  /// Whether the source is a directory, known after the first stat; directories have no checkpoint.
  final bool directory;

  /// Where a paused or interrupted single-file transfer stopped.
  final TransferCheckpoint? checkpoint;

  bool get upload => source.local && !target.local;
  bool get download => !source.local && target.local;

  Transfer copyWith({
    String? batch,
    TransferState? state,
    TransferPhase? Function()? phase,
    int? bytes,
    int? Function()? total,
    int? files,
    int? Function()? totalFiles,
    int? skipped,
    double? speed,
    String? Function()? error,
    String? detail,
    DateTime? Function()? finished,
    Conflict? Function()? conflict,
    bool? directory,
    TransferCheckpoint? Function()? checkpoint,
  }) => Transfer(
    id: id,
    batch: batch ?? this.batch,
    source: source,
    target: target,
    created: created,
    state: state ?? this.state,
    phase: phase == null ? this.phase : phase(),
    bytes: bytes ?? this.bytes,
    total: total == null ? this.total : total(),
    files: files ?? this.files,
    totalFiles: totalFiles == null ? this.totalFiles : totalFiles(),
    skipped: skipped ?? this.skipped,
    speed: speed ?? this.speed,
    error: error == null ? this.error : error(),
    detail: detail ?? this.detail,
    finished: finished == null ? this.finished : finished(),
    conflict: conflict == null ? this.conflict : conflict(),
    directory: directory ?? this.directory,
    checkpoint: checkpoint == null ? this.checkpoint : checkpoint(),
  );

  /// A fresh attempt from the start, in a batch of its own so earlier "apply to all" answers do not carry over.
  Transfer restart(String batch) => Transfer(id: id, batch: batch, source: source, target: target, created: created);

  /// Only what history needs: no handles, no secrets, no conflict in progress.
  Map<String, Object?> toJson() => {
    'id': id.value,
    'batch': batch,
    'source': source.toJson(),
    'target': target.toJson(),
    'created': created.toIso8601String(),
    'state': state.name,
    'bytes': bytes,
    if (total != null) 'total': total,
    'files': files,
    if (totalFiles != null) 'totalFiles': totalFiles,
    if (skipped > 0) 'skipped': skipped,
    if (error != null) 'error': error,
    if (detail.isNotEmpty) 'detail': detail,
    if (finished != null) 'finished': finished!.toIso8601String(),
    if (directory) 'directory': true,
    if (checkpoint != null) 'checkpoint': checkpoint!.toJson(),
  };

  /// A transfer that was still active when saved did not finish: it comes back interrupted, never running.
  factory Transfer.fromJson(Map<String, dynamic> j) {
    final saved = TransferState.values.byName(j['state'] as String);
    final id = TransferId(j['id'] as String);
    if (!_validTransferId(id)) throw const FormatException('invalid transfer id');
    return Transfer(
      id: id,
      batch: j['batch'] as String,
      source: FileEnd.fromJson((j['source'] as Map).cast()),
      target: FileEnd.fromJson((j['target'] as Map).cast()),
      created: DateTime.parse(j['created'] as String),
      state: saved.active ? TransferState.interrupted : saved,
      bytes: j['bytes'] as int? ?? 0,
      total: j['total'] as int?,
      files: j['files'] as int? ?? 0,
      totalFiles: j['totalFiles'] as int?,
      skipped: j['skipped'] as int? ?? 0,
      error: j['error'] as String?,
      detail: j['detail'] as String? ?? '',
      finished: j['finished'] == null ? null : DateTime.parse(j['finished'] as String),
      directory: j['directory'] as bool? ?? false,
      checkpoint: j['checkpoint'] == null
          ? null
          : TransferCheckpoint.fromJson((j['checkpoint'] as Map).cast<String, dynamic>()),
    );
  }
}

/// [fileOnDir]: a file would land where a directory is, or the other way round; neither can replace the other.
enum ConflictKind { file, directory, fileOnDir }

enum ConflictChoice { replace, merge, keepBoth, skip, cancel }

class Conflict {
  const Conflict(this.kind, this.path, this.existing, this.incoming);

  final ConflictKind kind;
  final String path;
  final FileEntry existing, incoming;

  List<ConflictChoice> get choices => switch (kind) {
    ConflictKind.file => const [
      ConflictChoice.replace,
      ConflictChoice.keepBoth,
      ConflictChoice.skip,
      ConflictChoice.cancel,
    ],
    ConflictKind.directory => const [
      ConflictChoice.merge,
      ConflictChoice.keepBoth,
      ConflictChoice.skip,
      ConflictChoice.cancel,
    ],
    ConflictKind.fileOnDir => const [ConflictChoice.keepBoth, ConflictChoice.skip, ConflictChoice.cancel],
  };
}

class ConflictAnswer {
  const ConflictAnswer(this.choice, {this.all = false});

  final ConflictChoice choice;

  /// Use the same choice for this kind of conflict in the rest of the batch.
  final bool all;
}

/// `report (1).pdf` for files, `photos (1)` for directories and names without an extension.
String keepBothName(String name, int n, {required bool directory}) {
  final dot = name.lastIndexOf('.');
  if (directory || dot <= 0) return '$name ($n)';
  return '${name.substring(0, dot)} ($n)${name.substring(dot)}';
}

/// Every active transfer stays; finished ones are kept for [maxAge] and at most [max] of them, newest first.
/// A transfer with a checkpoint also stays: dropping it would strand its part file (docs/TRANSFER_RESUME.md).
List<Transfer> pruneHistory(
  List<Transfer> all,
  DateTime now, {
  int max = 200,
  Duration maxAge = const Duration(days: 30),
}) {
  final done = [
    for (final t in all)
      if (!t.state.active && t.checkpoint == null && now.difference(t.finished ?? t.created) <= maxAge) t,
  ]..sort((a, b) => (b.finished ?? b.created).compareTo(a.finished ?? a.created));
  final kept = {...done.take(max).map((t) => t.id)};
  return [
    for (final t in all)
      if (t.state.active || t.checkpoint != null || kept.contains(t.id)) t,
  ];
}

/// The queued transfers that may start now, oldest first: at most [global] running, [perHost] on any one host,
/// and never two writing the same target. A paused or interrupted transfer with a checkpoint keeps its target
/// locked until it is resumed, finished or explicitly cleaned up.
List<TransferId> runnable(List<Transfer> all, {required int global, int perHost = 2}) {
  bool holdsSlot(Transfer t) =>
      t.state == TransferState.running || t.state == TransferState.waiting || t.state == TransferState.pausing;
  bool holdsTarget(Transfer t) =>
      holdsSlot(t) || t.state == TransferState.paused || (t.state == TransferState.interrupted && t.checkpoint != null);
  Iterable<String> hosts(Transfer t) => {?t.source.host?.value, ?t.target.host?.value};
  String target(Transfer t) => '${t.target.host?.value ?? ''}\u0000${t.target.path}';

  var running = 0;
  final perHostCount = <String, int>{};
  final targets = <String>{};
  for (final t in all.where(holdsTarget)) {
    if (holdsSlot(t)) {
      running++;
      for (final h in hosts(t)) {
        perHostCount[h] = (perHostCount[h] ?? 0) + 1;
      }
    }
    targets.add(target(t));
  }
  final out = <TransferId>[];
  for (final t in all.where((t) => t.state == TransferState.queued)) {
    if (running >= global) break;
    if (hosts(t).any((h) => (perHostCount[h] ?? 0) >= perHost) || targets.contains(target(t))) continue;
    out.add(t.id);
    running++;
    for (final h in hosts(t)) {
      perHostCount[h] = (perHostCount[h] ?? 0) + 1;
    }
    targets.add(target(t));
  }
  return out;
}

/// Bytes per second over a sliding window, so one slow moment does not swing the figure.
class SpeedMeter {
  SpeedMeter({this.window = const Duration(seconds: 3)});

  final Duration window;
  final _samples = <(DateTime, int)>[];

  void add(DateTime at, int total) {
    _samples.add((at, total));
    while (_samples.length > 2 && at.difference(_samples.first.$1) > window) {
      _samples.removeAt(0);
    }
  }

  double get bytesPerSecond {
    if (_samples.length < 2) return 0;
    final (t0, b0) = _samples.first;
    final (t1, b1) = _samples.last;
    final ms = t1.difference(t0).inMilliseconds;
    return ms <= 0 ? 0 : (b1 - b0) * 1000 / ms;
  }
}

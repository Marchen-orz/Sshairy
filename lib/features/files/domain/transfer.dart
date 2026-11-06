import '../../../foundation/file_system.dart';
import '../../../foundation/ids.dart';

/// [waiting] needs the user's answer to a conflict; [interrupted] was unfinished when the app last quit.
enum TransferState {
  queued,
  running,
  waiting,
  completed,
  failed,
  cancelled,
  interrupted;

  bool get active => this == queued || this == running || this == waiting;
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

  factory FileEnd.fromJson(Map<String, dynamic> j) =>
      FileEnd(j['host'] == null ? null : HostId(j['host'] as String), j['path'] as String, label: j['label'] as String? ?? '');
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
  }) =>
      Transfer(
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
      };

  /// A transfer that was still active when saved did not finish: it comes back interrupted, never running.
  factory Transfer.fromJson(Map<String, dynamic> j) {
    final saved = TransferState.values.byName(j['state'] as String);
    return Transfer(
      id: TransferId(j['id'] as String),
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
        ConflictKind.file => const [ConflictChoice.replace, ConflictChoice.keepBoth, ConflictChoice.skip, ConflictChoice.cancel],
        ConflictKind.directory => const [ConflictChoice.merge, ConflictChoice.keepBoth, ConflictChoice.skip, ConflictChoice.cancel],
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
List<Transfer> pruneHistory(List<Transfer> all, DateTime now, {int max = 200, Duration maxAge = const Duration(days: 30)}) {
  final done = [
    for (final t in all)
      if (!t.state.active && now.difference(t.finished ?? t.created) <= maxAge) t,
  ]..sort((a, b) => (b.finished ?? b.created).compareTo(a.finished ?? a.created));
  final kept = {...done.take(max).map((t) => t.id)};
  return [for (final t in all) if (t.state.active || kept.contains(t.id)) t];
}

/// The queued transfers that may start now, oldest first: at most [global] running, [perHost] on any one host,
/// and never two writing the same target.
List<TransferId> runnable(List<Transfer> all, {required int global, int perHost = 2}) {
  bool busy(Transfer t) => t.state == TransferState.running || t.state == TransferState.waiting;
  Iterable<String> hosts(Transfer t) => {?t.source.host?.value, ?t.target.host?.value};
  String target(Transfer t) => '${t.target.host?.value ?? ''}\u0000${t.target.path}';

  var running = 0;
  final perHostCount = <String, int>{};
  final targets = <String>{};
  for (final t in all.where(busy)) {
    running++;
    for (final h in hosts(t)) {
      perHostCount[h] = (perHostCount[h] ?? 0) + 1;
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

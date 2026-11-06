import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// How the last [JsonFile.read] ended. [recovered] means the file was unreadable and an earlier snapshot took its
/// place; [lost] means it was unreadable and no snapshot could stand in.
enum JsonReadStatus { missing, ok, recovered, lost }

/// A JSON document on disk: writes are serialized, checked for readability, and replace the file atomically.
///
/// With [backups], the file being replaced is first copied to `backups/` next to it, at most once per [interval],
/// keeping the newest [keepSnapshots] copies of each file and [snapshotBytesCap] bytes in all. A failed copy never
/// blocks saving.
class JsonFile {
  JsonFile(
    this.path, {
    this.backups = false,
    this.interval = const Duration(minutes: 5),
    this.bytesCap = snapshotBytesCap,
  });

  static const keepSnapshots = 10;
  static const snapshotBytesCap = 50 << 20;

  final String path;
  final bool backups;
  final Duration interval;
  final int bytesCap;
  Future<void> _pending = Future.value();

  JsonReadStatus status = JsonReadStatus.missing;

  String get _name => _base(path);
  String get _dir => path.substring(0, path.length - _name.length);
  String get _backupDir => '${_dir}backups';

  /// Returns null when missing. An unreadable file is kept aside, never overwritten; the newest snapshot that reads
  /// takes its place, or the result is null and [status] says [JsonReadStatus.lost].
  Map<String, dynamic>? read() {
    final file = File(path);
    if (!file.existsSync()) {
      status = JsonReadStatus.missing;
      return null;
    }
    final data = _decode(file);
    if (data != null) {
      status = JsonReadStatus.ok;
      return data;
    }
    file.renameSync('$path.corrupt-${DateTime.now().millisecondsSinceEpoch}');
    for (final snapshot in snapshots()) {
      final earlier = _decode(snapshot);
      if (earlier == null) continue;
      snapshot.copySync(path);
      status = JsonReadStatus.recovered;
      return earlier;
    }
    status = JsonReadStatus.lost;
    return null;
  }

  /// Completes once every write issued so far has landed.
  Future<void> get idle => _pending;

  Future<void> write(Map<String, dynamic> data) {
    final next = _pending.then((_) async {
      final tmp = File('$path.tmp');
      await tmp.writeAsString(const JsonEncoder.withIndent('  ').convert(data), flush: true);
      // Replacing the file only after the new text is known to read back.
      jsonDecode(await tmp.readAsString());
      if (backups) await _snapshot();
      await tmp.rename(path);
    });
    _pending = next.catchError((_) {});
    return next;
  }

  /// The copies of this file, newest first.
  List<File> snapshots() {
    final dir = Directory(_backupDir);
    if (!dir.existsSync()) return const [];
    final found = [
      for (final e in dir.listSync())
        if (e is File && _parse(e)?.name == _name) e,
    ];
    return found..sort((a, b) => _parse(b)!.stamp.compareTo(_parse(a)!.stamp));
  }

  static Map<String, dynamic>? _decode(File file) {
    try {
      final data = jsonDecode(file.readAsStringSync());
      return data is Map<String, dynamic> ? data : null;
    } on FormatException {
      return null;
    }
  }

  static final _snapshotName = RegExp(r'^(.+)\.(\d+)\.bak$');

  static String _base(String path) => path.substring(path.lastIndexOf(RegExp(r'[/\\]')) + 1);

  /// The file a snapshot copies and when it was taken, from its name `<file>.<milliseconds>.bak`; null for others.
  static ({String name, int stamp})? _parse(File file) {
    final match = _snapshotName.firstMatch(_base(file.path));
    final stamp = int.tryParse(match?[2] ?? '');
    return stamp == null ? null : (name: match![1]!, stamp: stamp);
  }

  Future<void> _snapshot() async {
    try {
      final current = File(path);
      if (!await current.exists() || _decode(current) == null) return;
      final taken = snapshots();
      final now = DateTime.now().millisecondsSinceEpoch;
      final last = taken.isEmpty ? null : _parse(taken.first)!.stamp;
      if (last != null && now - last < interval.inMilliseconds) return;
      await Directory(_backupDir).create(recursive: true);
      await current.copy('$_backupDir/$_name.${last == null ? now : max(now, last + 1)}.bak');
      await _prune();
    } on FileSystemException {
      // A missing backup must not stop the configuration from being saved.
    }
  }

  /// Drops each file's copies beyond [keepSnapshots], then the oldest others while the folder is over the byte cap.
  Future<void> _prune() async {
    for (final old in snapshots().skip(keepSnapshots)) {
      await old.delete();
    }
    final all = [
      for (final e in Directory(_backupDir).listSync())
        if (e is File && _parse(e) != null) (file: e, size: e.lengthSync(), stamp: _parse(e)!.stamp),
    ]..sort((a, b) => a.stamp.compareTo(b.stamp));
    var total = all.fold(0, (sum, e) => sum + e.size);
    final newest = snapshots().firstOrNull?.path;
    for (final e in all) {
      if (total <= bytesCap) break;
      if (e.file.path == newest) continue;
      await e.file.delete();
      total -= e.size;
    }
  }
}

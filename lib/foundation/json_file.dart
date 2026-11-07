import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// A failed read never means an empty configuration.
enum JsonReadStatus { missing, ok, recovered, corrupt, unsupportedVersion, permissionDenied, ioError }

enum JsonFileFailure {
  corrupt,
  unsupportedVersion,
  migrationFailed,
  permissionDenied,
  diskFull,
  io,
  conflict,
  backupFailed,
}

typedef JsonMigration = Map<String, dynamic> Function(Map<String, dynamic> source);

class JsonSnapshot {
  const JsonSnapshot._(this.path, this.revision, this.created, this._bytes);
  final String path;
  final int revision;
  final DateTime created;
  final List<int> _bytes;
}

class JsonFileError implements Exception {
  const JsonFileError(this.kind, this.path, {this.expectedRevision, this.actualRevision, this.recovery});

  final JsonFileFailure kind;
  final String path;
  final JsonFile? recovery;
  final int? expectedRevision, actualRevision;

  @override
  String toString() => 'JsonFileError(${kind.name}, $path)';
}

/// Serialized configuration writes with revision checks and protected recovery.
/// [validate] must check the feature's structure; JSON syntax alone cannot justify restoring a backup.
class JsonFile {
  JsonFile(
    this.path, {
    this.backups = false,
    this.interval = const Duration(minutes: 5),
    this.bytesCap = snapshotBytesCap,
    this.schemaVersion = 1,
    this.migrations = const {},
    this.validate,
  });

  static const keepSnapshots = 10;
  static const snapshotBytesCap = 50 << 20;
  static final _writes = <String, Future<void>>{};
  static final _locked = <String>{};
  static var _serial = 0;

  final String path;
  final bool backups;
  final Duration interval;
  final int bytesCap, schemaVersion;
  final Map<int, JsonMigration> migrations;
  final void Function(Map<String, dynamic>)? validate;
  Future<void> _pending = Future.value();
  List<int>? _baseline;
  var _loaded = false;
  var _revision = 0;
  JsonFileError? _blocked;

  JsonReadStatus status = JsonReadStatus.missing;
  int get revision => _revision;

  String get _name => _base(path);
  String get _backupDir => '${path.substring(0, path.length - _name.length)}backups';
  String get _queueKey {
    final absolute = File(path).absolute.uri.normalizePath().toFilePath();
    return Platform.isWindows ? absolute.toLowerCase() : absolute;
  }

  /// Null means absent, exclusively. A damaged or unsupported document stays in place and locks ordinary writes.
  /// Recovery is allowed only with a feature validator and after a verified protection copy of the damaged file.
  Map<String, dynamic>? read() {
    try {
      final bytes = _readBytes();
      if (bytes == null) {
        if (_blocked case final error?) throw error;
        _accept(null);
        status = JsonReadStatus.missing;
        return null;
      }
      _Document document;
      try {
        document = _inspect(bytes);
      } on JsonFileError catch (error) {
        if (error.kind != JsonFileFailure.corrupt || !backups || validate == null) rethrow;
        final recovered = _recover(bytes);
        if (recovered == null) rethrow;
        _accept(recovered);
        status = JsonReadStatus.recovered;
        return recovered.data;
      }
      _accept(document);
      status = JsonReadStatus.ok;
      return document.data;
    } on JsonFileError catch (error) {
      if (error.kind != JsonFileFailure.conflict) _block(error);
      throw _withRecovery(error);
    } on FileSystemException catch (error) {
      final failure = _io(error);
      _block(failure);
      throw _withRecovery(failure);
    }
  }

  JsonFileError _withRecovery(JsonFileError error) => JsonFileError(
    error.kind,
    error.path,
    expectedRevision: error.expectedRevision,
    actualRevision: error.actualRevision,
    recovery: error.kind == JsonFileFailure.unsupportedVersion || validate == null ? null : this,
  );

  /// Includes the latest failure until a subsequent write succeeds; the internal scheduling queue still recovers.
  Future<void> get idle => _pending;

  /// Uses the revision last read by this instance unless [expectedRevision] is explicit. Concurrent calls on this
  /// instance commit in order; a different reader cannot overwrite a state that changed after its read.
  Future<void> write(Map<String, dynamic> data, {int? expectedRevision}) {
    String? payload;
    try {
      payload = jsonEncode(data);
    } on Object {
      // Report encoding failures through the same ordered future as file failures.
    }
    return _enqueue(() async {
      if (payload == null) throw JsonFileError(JsonFileFailure.corrupt, path);
      await _commit((jsonDecode(payload) as Map).cast<String, dynamic>(), expectedRevision);
    });
  }

  Future<void> _enqueue(Future<void> Function() operation) {
    final key = _queueKey;
    final next = (_writes[key] ?? Future<void>.value()).then((_) => operation());
    _pending = next;
    final tail = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    _writes[key] = tail;
    tail.then((_) {
      if (identical(_writes[key], tail)) _writes.remove(key);
    });
    return next;
  }

  Future<void> _commit(Map<String, dynamic> data, int? expectedRevision) async {
    File? tmp;
    RandomAccessFile? lock;
    try {
      if (_blocked case final error?) throw error;
      if (!_loaded) read();
      lock = _lock();
      final current = _current();
      if (expectedRevision != null && expectedRevision != _revision) {
        throw JsonFileError(
          JsonFileFailure.conflict,
          path,
          expectedRevision: expectedRevision,
          actualRevision: _revision,
        );
      }
      final bytes = utf8.encode(
        const JsonEncoder.withIndent('  ')
            .convert({...data, if (schemaVersion > 1) 'schemaVersion': schemaVersion, 'revision': _revision + 1}),
      );
      final prepared = _inspect(bytes);
      tmp = File(_temporary(path));
      await tmp.writeAsBytes(bytes, flush: true);
      final checked = await tmp.readAsBytes();
      if (!_same(bytes, checked)) throw JsonFileError(JsonFileFailure.io, path);
      _inspect(checked);
      _current();
      if (backups && current != null) await _snapshot(current);
      // Also reject an external edit that happened while the new file or backup was being prepared.
      _current();
      await tmp.rename(path);
      _accept(prepared);
      status = JsonReadStatus.ok;
    } on FileSystemException catch (error) {
      throw _io(error);
    } finally {
      try {
        if (tmp != null && await tmp.exists()) await tmp.delete();
      } on FileSystemException {
        // A leftover temporary file must not hide the actual save failure.
      }
      _release(lock);
    }
  }

  RandomAccessFile _lock() {
    if (!_locked.add(_queueKey)) throw JsonFileError(JsonFileFailure.conflict, path);
    RandomAccessFile? handle;
    try {
      handle = File('$path.lock').openSync(mode: FileMode.append);
      try {
        handle.lockSync(FileLock.exclusive, 0, 1);
      } on FileSystemException catch (error) {
        final failure = _io(error);
        if (failure.kind != JsonFileFailure.io) throw failure;
        throw JsonFileError(JsonFileFailure.conflict, path);
      }
      return handle;
    } on Object {
      handle?.closeSync();
      _locked.remove(_queueKey);
      rethrow;
    }
  }

  void _release(RandomAccessFile? handle) {
    if (handle == null) return;
    try {
      handle.closeSync();
    } finally {
      _locked.remove(_queueKey);
    }
  }

  _Document? _current() {
    try {
      final bytes = _readBytes();
      final document = bytes == null ? null : _inspect(bytes);
      if (!_same(bytes, _baseline)) {
        throw JsonFileError(
          JsonFileFailure.conflict,
          path,
          expectedRevision: _revision,
          actualRevision: document?.revision ?? 0,
        );
      }
      return document;
    } on JsonFileError catch (error) {
      if (error.kind != JsonFileFailure.conflict) _block(error);
      rethrow;
    }
  }

  void _accept(_Document? document) {
    _baseline = document?.bytes;
    _revision = document?.revision ?? 0;
    _loaded = true;
    _blocked = null;
  }

  void _block(JsonFileError error) {
    _blocked = error;
    status = switch (error.kind) {
      JsonFileFailure.corrupt => JsonReadStatus.corrupt,
      JsonFileFailure.unsupportedVersion => JsonReadStatus.unsupportedVersion,
      JsonFileFailure.permissionDenied => JsonReadStatus.permissionDenied,
      _ => JsonReadStatus.ioError,
    };
  }

  List<int>? _readBytes() {
    try {
      return File(path).readAsBytesSync();
    } on FileSystemException catch (error) {
      if (error.osError?.errorCode == 2 || (Platform.isWindows && error.osError?.errorCode == 3)) return null;
      throw _io(error);
    }
  }

  _Document _inspect(List<int> bytes) {
    try {
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map<String, dynamic>) throw const FormatException('object required');
      final version = decoded.containsKey('schemaVersion') ? decoded['schemaVersion'] : 1;
      if (version is! int || version < 1 || version > schemaVersion) {
        throw JsonFileError(JsonFileFailure.unsupportedVersion, path);
      }
      final revision = decoded.containsKey('revision') ? decoded['revision'] : 0;
      if (revision is! int || revision < 0) throw const FormatException('invalid revision');
      var data = decoded;
      for (var from = version; from < schemaVersion; from++) {
        final migrate = migrations[from];
        if (migrate == null) throw JsonFileError(JsonFileFailure.unsupportedVersion, path);
        try {
          data = {...migrate(data), 'schemaVersion': from + 1, 'revision': revision};
        } on Object {
          throw JsonFileError(JsonFileFailure.migrationFailed, path);
        }
      }
      try {
        validate?.call(data);
      } on Object {
        if (version < schemaVersion) throw JsonFileError(JsonFileFailure.migrationFailed, path);
        rethrow;
      }
      return _Document(bytes, data, revision);
    } on JsonFileError {
      rethrow;
    } on Object {
      throw JsonFileError(JsonFileFailure.corrupt, path);
    }
  }

  _Document? _recover(List<int> damaged) {
    _Document? candidate;
    for (final snapshot in snapshots()) {
      try {
        final document = _inspect(snapshot.readAsBytesSync());
        if (candidate == null || document.revision > candidate.revision) candidate = document;
      } on JsonFileError {
        continue;
      } on FileSystemException {
        continue;
      }
    }
    if (candidate == null) return null;
    final lock = _lock();
    try {
      _replaceProtected(candidate, damaged, 'corrupt');
      return candidate;
    } finally {
      _release(lock);
    }
  }

  /// Only snapshots that pass this configuration's schema and domain checks may be offered for recovery.
  List<JsonSnapshot> availableSnapshots() {
    if (validate == null) return const [];
    final valid = <JsonSnapshot>[];
    for (final file in snapshots()) {
      try {
        final document = _inspect(file.readAsBytesSync());
        valid.add(
          JsonSnapshot._(
            file.path,
            document.revision,
            DateTime.fromMillisecondsSinceEpoch(_parse(file)!.stamp),
            document.bytes,
          ),
        );
      } on JsonFileError {
        continue;
      } on FileSystemException {
        continue;
      }
    }
    return valid;
  }

  /// Explicit rollback still protects the current bytes and rejects a file changed while the user was choosing.
  Future<void> restore(JsonSnapshot snapshot) {
    final previous = _readBytes();
    return _enqueue(() async {
      RandomAccessFile? lock;
      try {
        lock = _lock();
        if (validate == null || !snapshots().any((file) => file.path == snapshot.path)) {
          throw JsonFileError(JsonFileFailure.corrupt, path);
        }
        if (!_same(previous, _readBytes())) throw JsonFileError(JsonFileFailure.conflict, path);
        var currentRevision = 0;
        if (previous != null) {
          try {
            currentRevision = _inspect(previous).revision;
          } on JsonFileError catch (error) {
            if (error.kind != JsonFileFailure.corrupt) rethrow;
          }
        }
        final candidate = _inspect(File(snapshot.path).readAsBytesSync());
        if (!_same(candidate.bytes, snapshot._bytes)) throw JsonFileError(JsonFileFailure.conflict, path);
        final restored = _inspect(
          utf8.encode(
            const JsonEncoder.withIndent('  ').convert({
              ...candidate.data,
              'schemaVersion': schemaVersion,
              'revision': max(currentRevision, candidate.revision) + 1,
            }),
          ),
        );
        _replaceProtected(restored, previous, 'before-restore');
        _accept(restored);
        status = JsonReadStatus.recovered;
      } on FileSystemException catch (error) {
        throw _io(error);
      } finally {
        _release(lock);
      }
    });
  }

  void _replaceProtected(_Document candidate, List<int>? previous, String reason) {
    if (!_same(_readBytes(), previous)) throw JsonFileError(JsonFileFailure.conflict, path);
    final tmp = File(_temporary(path));
    try {
      if (previous != null) {
        final protection = File('$path.$reason-${DateTime.now().microsecondsSinceEpoch}-${_serial++}');
        try {
          protection.writeAsBytesSync(previous, flush: true);
          if (!_same(protection.readAsBytesSync(), previous)) {
            throw const FileSystemException('protection copy differs');
          }
        } on FileSystemException {
          throw JsonFileError(JsonFileFailure.backupFailed, path);
        }
      }
      tmp.writeAsBytesSync(candidate.bytes, flush: true);
      final checked = tmp.readAsBytesSync();
      _inspect(checked);
      if (!_same(checked, candidate.bytes)) throw JsonFileError(JsonFileFailure.io, path);
      if (!_same(_readBytes(), previous)) throw JsonFileError(JsonFileFailure.conflict, path);
      tmp.renameSync(path);
    } finally {
      try {
        if (tmp.existsSync()) tmp.deleteSync();
      } on FileSystemException {
        // Preserve the original failure.
      }
    }
  }

  /// Newest snapshot slot first. Each slot is refreshed with the preceding valid revision on every write.
  List<File> snapshots() {
    final dir = Directory(_backupDir);
    if (!dir.existsSync()) return const [];
    final found = [
      for (final entry in dir.listSync())
        if (entry is File && _parse(entry)?.name == _name) entry,
    ];
    return found..sort((a, b) => _parse(b)!.stamp.compareTo(_parse(a)!.stamp));
  }

  Future<void> _snapshot(_Document current) async {
    File? tmp;
    try {
      final taken = snapshots();
      final now = DateTime.now().millisecondsSinceEpoch;
      final last = taken.isEmpty ? null : _parse(taken.first)!.stamp;
      await Directory(_backupDir).create(recursive: true);
      final target = last != null && now - last < interval.inMilliseconds
          ? taken.first.path
          : '$_backupDir/$_name.${last == null ? now : max(now, last + 1)}.bak';
      tmp = File(_temporary(target));
      await tmp.writeAsBytes(current.bytes, flush: true);
      final checked = await tmp.readAsBytes();
      _inspect(checked);
      if (!_same(checked, current.bytes)) throw JsonFileError(JsonFileFailure.backupFailed, path);
      await tmp.rename(target);
      await _prune();
    } on FileSystemException {
      throw JsonFileError(JsonFileFailure.backupFailed, path);
    } finally {
      try {
        if (tmp != null && await tmp.exists()) await tmp.delete();
      } on FileSystemException {
        // Preserve the backup failure.
      }
    }
  }

  Future<void> _prune() async {
    for (final old in snapshots().skip(keepSnapshots)) {
      await old.delete();
    }
    final all = [
      for (final entry in Directory(_backupDir).listSync())
        if (entry is File && _parse(entry) != null)
          (file: entry, size: entry.lengthSync(), stamp: _parse(entry)!.stamp),
    ]..sort((a, b) => a.stamp.compareTo(b.stamp));
    var total = all.fold(0, (sum, entry) => sum + entry.size);
    final newest = <String, String>{};
    for (final entry in all) {
      newest[_parse(entry.file)!.name] = entry.file.path;
    }
    for (final entry in all) {
      if (total <= bytesCap) break;
      // Each configuration retains a known-good predecessor, even if those minimum copies exceed the archive cap.
      if (newest[_parse(entry.file)!.name] == entry.file.path) continue;
      await entry.file.delete();
      total -= entry.size;
    }
  }

  JsonFileError _io(FileSystemException error) {
    final code = error.osError?.errorCode;
    return JsonFileError(switch (code) {
      5 when Platform.isWindows => JsonFileFailure.permissionDenied,
      13 || 1 when !Platform.isWindows => JsonFileFailure.permissionDenied,
      28 when !Platform.isWindows => JsonFileFailure.diskFull,
      39 || 112 when Platform.isWindows => JsonFileFailure.diskFull,
      _ => JsonFileFailure.io,
    }, path);
  }

  static String _temporary(String path) => '$path.$pid.${DateTime.now().microsecondsSinceEpoch}-${_serial++}.tmp';
  static String _base(String path) => path.substring(path.lastIndexOf(RegExp(r'[/\\]')) + 1);
  static final _snapshotName = RegExp(r'^(.+)\.(\d+)\.bak$');

  static ({String name, int stamp})? _parse(File file) {
    final match = _snapshotName.firstMatch(_base(file.path));
    final stamp = int.tryParse(match?[2] ?? '');
    return stamp == null ? null : (name: match![1]!, stamp: stamp);
  }

  static bool _same(List<int>? a, List<int>? b) {
    if (identical(a, b)) return true;
    if (a == null || b == null || a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

class _Document {
  const _Document(this.bytes, this.data, this.revision);
  final List<int> bytes;
  final Map<String, dynamic> data;
  final int revision;
}

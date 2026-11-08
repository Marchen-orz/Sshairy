import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

enum DiagnosticArea { application, connection, transfer, configuration }

enum DiagnosticAction { start, dial, copy, pause, cancel, read, write, recover, uncaught, shutdown }

enum DiagnosticOutcome { started, succeeded, failed, cancelled, interrupted }

final diagnosticLogProvider = Provider<DiagnosticLog>((_) => DiagnosticLog.disabled());

/// Only these typed fields can reach the viewer or clipboard.
class DiagnosticRecord {
  const DiagnosticRecord({
    required this.time,
    required this.area,
    required this.action,
    required this.outcome,
    this.elapsedMilliseconds,
    this.dropped = 0,
  });

  final DateTime time;
  final DiagnosticArea area;
  final DiagnosticAction action;
  final DiagnosticOutcome outcome;
  final int? elapsedMilliseconds;
  final int dropped;

  Map<String, Object> toJson() => {
    'time': time.toUtc().toIso8601String(),
    'area': area.name,
    'action': action.name,
    'outcome': outcome.name,
    'elapsedMs': ?elapsedMilliseconds,
    if (dropped > 0) 'dropped': dropped,
  };

  String get text => jsonEncode(toJson());

  static DiagnosticRecord? _parse(String line) {
    try {
      final value = jsonDecode(line);
      if (value is! Map<String, dynamic> ||
          value.keys.any((key) => !const {'time', 'area', 'action', 'outcome', 'elapsedMs', 'dropped'}.contains(key))) {
        return null;
      }
      final stamp = value['time'];
      final time = stamp is String && stamp.length <= 40 ? DateTime.tryParse(stamp) : null;
      final area = DiagnosticArea.values.asNameMap()[value['area']];
      final action = DiagnosticAction.values.asNameMap()[value['action']];
      final outcome = DiagnosticOutcome.values.asNameMap()[value['outcome']];
      final elapsed = value['elapsedMs'], dropped = value['dropped'];
      bool validInteger(Object? number) => number is int && number >= 0 && number <= 0x1fffffffffffff;
      if (time == null ||
          area == null ||
          action == null ||
          outcome == null ||
          (elapsed != null && !validInteger(elapsed)) ||
          (dropped != null && !validInteger(dropped))) {
        return null;
      }
      return DiagnosticRecord(
        time: time.toUtc(),
        area: area,
        action: action,
        outcome: outcome,
        elapsedMilliseconds: elapsed as int?,
        dropped: dropped as int? ?? 0,
      );
    } on Object {
      return null;
    }
  }
}

class DiagnosticSnapshot {
  const DiagnosticSnapshot(this.records, {this.skipped = 0});

  final List<DiagnosticRecord> records;
  final int skipped;
}

/// Deliberately carries no filesystem path or original error.
class DiagnosticReadFailure implements Exception {
  const DiagnosticReadFailure();
}

/// A structural projection: no API accepts error messages, arbitrary fields, paths, commands or secrets.
class DiagnosticLog {
  DiagnosticLog(String directory, {this.fileBytes = 2 << 20, this.fileCount = 5, this.maxPending = 256})
    : _directory = directory {
    if (fileBytes < 256 || fileCount < 1 || maxPending < 1) throw ArgumentError('invalid diagnostic limits');
  }

  DiagnosticLog.disabled() : _directory = null, fileBytes = 2 << 20, fileCount = 5, maxPending = 256;

  final String? _directory;
  final int fileBytes, fileCount, maxPending;
  Future<void> _tail = Future.value();
  var _pending = 0, _dropped = 0;
  var _failed = false, _closing = false;
  RandomAccessFile? _lock;
  final _changes = StreamController<void>.broadcast();

  bool get enabled => _directory != null && !_closing;
  Stream<void> get changes => _changes.stream;
  bool get failed => _failed;
  int get pending => _pending;
  Future<void> get idle => _tail;

  void record(DiagnosticArea area, DiagnosticAction action, DiagnosticOutcome outcome, {int? elapsedMilliseconds}) {
    if (_directory == null || _failed || _closing) return;
    if (_pending >= maxPending) {
      _dropped++;
      return;
    }
    final line = jsonEncode({
      'time': DateTime.now().toUtc().toIso8601String(),
      'area': area.name,
      'action': action.name,
      'outcome': outcome.name,
      if (elapsedMilliseconds != null && elapsedMilliseconds >= 0) 'elapsedMs': elapsedMilliseconds,
      if (_dropped > 0) 'dropped': _dropped,
    });
    _dropped = 0;
    _pending++;
    _tail = _tail.then((_) async {
      try {
        if (!_failed) await _append(utf8.encode('$line\n'));
      } on Object {
        // Diagnostics must never recursively report their own IO failure or fail a business operation.
        _failed = true;
      } finally {
        _pending--;
        if (!_changes.isClosed) _changes.add(null);
      }
    });
  }

  /// Serialized with writes, so the files cannot rotate halfway through a snapshot.
  Future<DiagnosticSnapshot> readRecent({int limit = 500}) {
    if (limit < 1 || limit > 500) throw RangeError.range(limit, 1, 500, 'limit');
    final result = Completer<DiagnosticSnapshot>();
    _tail = _tail.then((_) async {
      try {
        result.complete(await _readRecent(limit));
      } on Object {
        result.completeError(const DiagnosticReadFailure());
      }
    });
    return result.future;
  }

  Future<DiagnosticSnapshot> _readRecent(int limit) async {
    if (_directory == null) return const DiagnosticSnapshot([]);
    final type = await FileSystemEntity.type(_directory, followLinks: false);
    if (type == FileSystemEntityType.notFound) return const DiagnosticSnapshot([]);
    if (type != FileSystemEntityType.directory) throw const DiagnosticReadFailure();
    final records = <DiagnosticRecord>[];
    var skipped = 0;
    for (var index = 0; index < fileCount && records.length < limit; index++) {
      final path = '$_directory/diagnostic-$index.jsonl';
      final type = await FileSystemEntity.type(path, followLinks: false);
      if (type == FileSystemEntityType.notFound) continue;
      if (type != FileSystemEntityType.file) throw const DiagnosticReadFailure();
      final file = await File(path).open();
      late final List<int> bytes;
      try {
        final length = await file.length();
        if (length > fileBytes) throw const DiagnosticReadFailure();
        bytes = await file.read(length);
      } finally {
        await file.close();
      }
      final lines = const LineSplitter().convert(utf8.decode(bytes, allowMalformed: true));
      for (final line in lines.reversed) {
        if (line.trim().isEmpty) continue;
        final record = line.length <= 2048 ? DiagnosticRecord._parse(line) : null;
        if (record == null) {
          skipped++;
        } else {
          records.add(record);
          if (records.length == limit) break;
        }
      }
    }
    return DiagnosticSnapshot(List.unmodifiable(records), skipped: skipped);
  }

  Future<void> close() async {
    _closing = true;
    await _tail;
    final lock = _lock;
    _lock = null;
    await lock?.close();
    if (!_changes.isClosed) {
      _changes.add(null);
      unawaited(_changes.close());
    }
  }

  Future<void> _append(List<int> bytes) async {
    if (bytes.length > fileBytes) return;
    final directory = Directory(_directory!);
    var rootType = await FileSystemEntity.type(directory.path, followLinks: false);
    if (rootType == FileSystemEntityType.notFound) {
      await directory.create(recursive: true);
      rootType = await FileSystemEntity.type(directory.path, followLinks: false);
    }
    if (rootType != FileSystemEntityType.directory) throw const DiagnosticReadFailure();
    // Validate every rotation destination as well as the current file before moving or appending.
    for (final name in ['diagnostic.lock', for (var i = 0; i < fileCount; i++) 'diagnostic-$i.jsonl']) {
      final type = await FileSystemEntity.type('${directory.path}/$name', followLinks: false);
      if (type != FileSystemEntityType.notFound && type != FileSystemEntityType.file) {
        throw const DiagnosticReadFailure();
      }
    }
    if (_lock == null) {
      final lock = await File('${directory.path}/diagnostic.lock').open(mode: FileMode.append);
      try {
        await lock.lock(FileLock.exclusive);
        _lock = lock;
      } on Object {
        await lock.close();
        rethrow;
      }
    }
    File log(int index) => File('${directory.path}/diagnostic-$index.jsonl');
    final current = log(0);
    if (await current.exists() && await current.length() + bytes.length > fileBytes) {
      for (var i = fileCount - 1; i >= 0; i--) {
        final source = log(i);
        if (!await source.exists()) continue;
        if (i == fileCount - 1) {
          await source.delete();
        } else {
          await source.rename(log(i + 1).path);
        }
      }
    }
    await current.writeAsBytes(bytes, mode: FileMode.append, flush: true);
  }
}

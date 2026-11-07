import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

enum DiagnosticArea { application, connection, transfer, configuration }

enum DiagnosticAction { start, dial, copy, pause, cancel, read, write, recover, uncaught, shutdown }

enum DiagnosticOutcome { started, succeeded, failed, cancelled, interrupted }

final diagnosticLogProvider = Provider<DiagnosticLog>((_) => DiagnosticLog.disabled());

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
      }
    });
  }

  Future<void> close() async {
    _closing = true;
    await _tail;
    final lock = _lock;
    _lock = null;
    await lock?.close();
  }

  Future<void> _append(List<int> bytes) async {
    if (bytes.length > fileBytes) return;
    final directory = Directory(_directory!);
    await directory.create(recursive: true);
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

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/features/connections/api.dart';
import 'package:sshairy/features/files/api.dart' show NoPrompts;
import 'package:sshairy/features/hosts/api.dart';
import 'package:sshairy/foundation/diagnostics.dart';
import 'package:sshairy/foundation/ids.dart';

void main() {
  late Directory directory;
  setUp(() => directory = Directory.systemTemp.createTempSync('sshairy-diagnostics-'));
  tearDown(() => directory.deleteSync(recursive: true));

  List<File> logs() => directory.listSync().whereType<File>().where((file) => file.path.endsWith('.jsonl')).toList();
  List<Map<String, dynamic>> records() => [
    for (final file in logs())
      for (final line in file.readAsLinesSync()) (jsonDecode(line) as Map).cast<String, dynamic>(),
  ];

  test('rotation bounds disk use while retaining whole JSON records', () async {
    final log = DiagnosticLog(directory.path, fileBytes: 300, fileCount: 3);
    for (var i = 0; i < 20; i++) {
      log.record(DiagnosticArea.connection, DiagnosticAction.dial, DiagnosticOutcome.succeeded, elapsedMilliseconds: i);
    }
    await log.close();
    expect(log.failed, isFalse);
    expect(logs(), hasLength(3));
    expect(logs().map((file) => file.lengthSync()), everyElement(lessThanOrEqualTo(300)));
    expect(records().map((record) => record['elapsedMs']), contains(19));
    expect(records().length, lessThan(20));
  });

  test('a flood keeps pending writes bounded and reports dropped metadata', () async {
    final log = DiagnosticLog(directory.path, maxPending: 3);
    for (var i = 0; i < 1000; i++) {
      log.record(DiagnosticArea.application, DiagnosticAction.uncaught, DiagnosticOutcome.failed);
    }
    expect(log.pending, lessThanOrEqualTo(3));
    await log.idle;
    log.record(DiagnosticArea.application, DiagnosticAction.shutdown, DiagnosticOutcome.succeeded);
    await log.close();
    expect(records(), hasLength(4));
    expect(records().last['dropped'], 997);
  });

  test('unwritable diagnostics fail quietly and leave existing content intact', () async {
    final obstacle = File('${directory.path}/not-a-directory')..writeAsStringSync('keep');
    final log = DiagnosticLog(obstacle.path);
    log.record(DiagnosticArea.application, DiagnosticAction.start, DiagnosticOutcome.started);
    await log.idle;
    expect(log.failed, isTrue);
    log.record(DiagnosticArea.application, DiagnosticAction.uncaught, DiagnosticOutcome.failed);
    await log.close();
    expect(log.pending, 0);
    expect(obstacle.readAsStringSync(), 'keep');
  });

  test('recent history is newest first, bounded and immutable across rotations', () async {
    final log = DiagnosticLog(directory.path, fileBytes: 300, fileCount: 3);
    for (var i = 0; i < 20; i++) {
      log.record(DiagnosticArea.connection, DiagnosticAction.dial, DiagnosticOutcome.succeeded, elapsedMilliseconds: i);
    }
    final snapshot = await log.readRecent(limit: 2);
    expect(snapshot.records.map((record) => record.elapsedMilliseconds), [19, 18]);
    expect(() => snapshot.records.clear(), throwsUnsupportedError);
    expect(snapshot.skipped, 0);
    expect(() => log.readRecent(limit: 501), throwsRangeError);
    await log.close();
  });

  test('reader skips malformed, unknown, oversized and arbitrary-field records', () async {
    final valid = {
      'time': '2026-11-08T12:00:00.000Z',
      'area': 'connection',
      'action': 'dial',
      'outcome': 'failed',
      'elapsedMs': 42,
    };
    File('${directory.path}/diagnostic-0.jsonl').writeAsStringSync(
      [
        jsonEncode(valid),
        '{broken',
        jsonEncode({...valid, 'area': 'unknown'}),
        jsonEncode({...valid, 'secret': 'not-for-viewer'}),
        jsonEncode({...valid, 'elapsedMs': -1}),
        jsonEncode({...valid, 'dropped': 1.5}),
        'x' * 2049,
      ].join('\n'),
    );
    final log = DiagnosticLog(directory.path);
    final snapshot = await log.readRecent();
    expect(snapshot.records, hasLength(1));
    expect(snapshot.skipped, 6);
    expect(jsonDecode(snapshot.records.single.text), valid);
    expect(snapshot.records.single.text, isNot(contains('not-for-viewer')));
    await log.close();
  });

  test('snapshots and notifications do not duplicate or miss queued writes', () async {
    final log = DiagnosticLog(directory.path);
    var notices = 0;
    final subscription = log.changes.listen((_) => notices++);
    log.record(DiagnosticArea.application, DiagnosticAction.start, DiagnosticOutcome.started, elapsedMilliseconds: 1);
    final first = log.readRecent();
    log.record(DiagnosticArea.connection, DiagnosticAction.dial, DiagnosticOutcome.succeeded, elapsedMilliseconds: 2);
    expect((await first).records.map((record) => record.elapsedMilliseconds), [1]);
    final second = await log.readRecent();
    expect(second.records.map((record) => record.elapsedMilliseconds), [2, 1]);
    await Future<void>.delayed(Duration.zero);
    expect(notices, 2);
    await subscription.cancel();
    await log.close();
  });

  test('reader refuses oversized files without returning raw contents or paths', () async {
    File('${directory.path}/diagnostic-0.jsonl').writeAsStringSync('x' * 257);
    final log = DiagnosticLog(directory.path, fileBytes: 256);
    await expectLater(log.readRecent(), throwsA(isA<DiagnosticReadFailure>()));
    expect(const DiagnosticReadFailure().toString(), isNot(contains(directory.path)));
    await log.close();
  });

  test('reader and writer reject a non-file rotation destination', () async {
    Directory('${directory.path}/diagnostic-1.jsonl').createSync();
    final log = DiagnosticLog(directory.path);
    await expectLater(log.readRecent(), throwsA(isA<DiagnosticReadFailure>()));
    log.record(DiagnosticArea.application, DiagnosticAction.start, DiagnosticOutcome.started);
    await log.idle;
    expect(log.failed, isTrue);
    expect(File('${directory.path}/diagnostic-0.jsonl').existsSync(), isFalse);
    await log.close();
  });

  test('reader and writer refuse linked log files', () async {
    final outside = File('${directory.path}/outside')..writeAsStringSync('untouched');
    Link('${directory.path}/diagnostic-0.jsonl').createSync(outside.path);
    final log = DiagnosticLog(directory.path);
    await expectLater(log.readRecent(), throwsA(isA<DiagnosticReadFailure>()));
    log.record(DiagnosticArea.application, DiagnosticAction.start, DiagnosticOutcome.started);
    await log.idle;
    expect(log.failed, isTrue);
    expect(outside.readAsStringSync(), 'untouched');
    await log.close();
  }, skip: Platform.isWindows ? 'Windows symlink creation requires machine-specific privileges.' : false);

  test('disabled logger returns empty history without creating files', () async {
    final log = DiagnosticLog.disabled();
    expect((await log.readRecent()).records, isEmpty);
    log.record(DiagnosticArea.application, DiagnosticAction.start, DiagnosticOutcome.started);
    await log.close();
    expect(directory.listSync(), isEmpty);
  });

  test('connection failures never serialize secrets, target metadata or raw exceptions', () async {
    const sentinel = 'diagnostic-test-secret-not-for-output';
    final log = DiagnosticLog(directory.path);
    final manager = ConnectionManager(
      (_, _, _) async => throw const ConnectError(ConnectFailure.auth, sentinel),
      diagnostics: log,
    );
    const host = Host(id: HostId('private-id'), label: sentinel, address: 'private.example', username: 'private-user');
    await expectLater(manager.acquire(host, const NoPrompts()), throwsA(isA<ConnectError>()));
    await log.close();
    manager.closeAll();
    final content = logs().map((file) => file.readAsStringSync()).join();
    for (final sensitive in [sentinel, host.address, host.username, host.id.value, 'ConnectError']) {
      expect(content.contains(sensitive), isFalse);
    }
    expect(records().map((record) => record['outcome']), ['started', 'failed']);
    expect(records().expand((record) => record.keys).toSet(), {'time', 'area', 'action', 'outcome', 'elapsedMs'});
  });
}

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

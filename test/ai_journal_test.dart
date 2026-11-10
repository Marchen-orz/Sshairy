import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/features/ai/adapters/operation_journal.dart';
import 'package:sshairy/features/ai/domain/agent.dart';
import 'package:sshairy/foundation/ids.dart';
import 'package:sshairy/foundation/json_file.dart';

OperationRecord _record(String id, [OperationState state = OperationState.intent]) =>
    OperationRecord(OperationId(id), const HostId('host-1'), 'command.execute', DateTime.utc(2026, 11, 10), state);

Map<String, Object?> _encoded(String id, String state) => {
  'id': id,
  'hostId': 'host-1',
  'capability': 'command.execute',
  'at': '2026-11-10T00:00:00.000Z',
  'state': state,
};

void main() {
  late Directory directory;
  setUp(() => directory = Directory.systemTemp.createTempSync('sshairy-ai-journal-'));
  tearDown(() async => directory.delete(recursive: true));

  test('creation is lazy and records metadata only with serialized terminal updates', () async {
    final journal = JsonOperationJournal(directory.path);
    expect(directory.listSync(), isEmpty);
    expect(await journal.load(), isEmpty);
    expect(directory.listSync(), isEmpty);
    final intent = _record('operation-1');
    final first = journal.record(intent);
    final second = journal.record(intent.withState(OperationState.completed));
    await Future.wait([first, second]);
    await journal.saved;
    final document = jsonDecode(File('${directory.path}/ai_operations.json').readAsStringSync()) as Map;
    expect(document.keys.toSet(), {'schemaVersion', 'revision', 'operations'});
    expect(document['revision'], 2);
    final operations = document['operations'] as List;
    expect(operations, hasLength(1));
    expect(operations.single, _encoded('operation-1', 'completed'));
    expect((await journal.load()).single.state, OperationState.completed);
  });

  test('restart persists unknown outcomes and never turns old intent into a new execution', () async {
    final journal = JsonOperationJournal(directory.path);
    await journal.record(_record('unfinished'));
    final reopened = JsonOperationJournal(directory.path);
    final recovered = await reopened.load();
    expect(recovered.single.state, OperationState.outcomeUnknown);
    final document = jsonDecode(File('${directory.path}/ai_operations.json').readAsStringSync()) as Map;
    expect((document['operations'] as List).single['state'], 'outcomeUnknown');
    await expectLater(
      reopened.record(_record('unfinished')),
      throwsA(isA<AgentFailure>().having((e) => e.code, 'code', 'operationConflict')),
    );
    expect((await reopened.load()).single.state, OperationState.outcomeUnknown);
  });

  test('same operation cannot change target, action, timestamp or restart after completion', () async {
    final journal = JsonOperationJournal(directory.path);
    final record = _record('once');
    await journal.record(record);
    await journal.record(record.withState(OperationState.completed));
    final bytes = File('${directory.path}/ai_operations.json').readAsBytesSync();
    await journal.record(record.withState(OperationState.completed));
    expect(File('${directory.path}/ai_operations.json').readAsBytesSync(), bytes);
    for (final changed in [
      OperationRecord(record.id, const HostId('other'), record.capability, record.at, OperationState.failed),
      OperationRecord(record.id, record.host, 'diagnostics.collect', record.at, OperationState.failed),
      OperationRecord(
        record.id,
        record.host,
        record.capability,
        record.at.add(const Duration(seconds: 1)),
        OperationState.failed,
      ),
      record,
    ]) {
      await expectLater(
        journal.record(changed),
        throwsA(isA<AgentFailure>().having((e) => e.code, 'code', 'operationConflict')),
      );
    }
    await expectLater(
      journal.record(_record('no-intent', OperationState.completed)),
      throwsA(isA<AgentFailure>().having((e) => e.code, 'code', 'operationMissingIntent')),
    );
    expect(File('${directory.path}/ai_operations.json').readAsBytesSync(), bytes);
  });

  test('corrupt, future and invalid metadata are preserved and block new intents', () async {
    final file = File('${directory.path}/ai_operations.json');
    for (final content in [
      '{broken',
      jsonEncode({'schemaVersion': 2, 'revision': 1, 'operations': []}),
      jsonEncode({
        'schemaVersion': 1,
        'revision': 1,
        'operations': [
          {..._encoded('op', 'intent'), 'command': 'private'},
        ],
      }),
      jsonEncode({
        'schemaVersion': 1,
        'revision': 1,
        'operations': [_encoded('op', 'futureState')],
      }),
    ]) {
      await file.writeAsString(content);
      final journal = JsonOperationJournal(directory.path);
      await expectLater(journal.load(), throwsA(isA<JsonFileError>()));
      await expectLater(journal.record(_record('fresh')), throwsA(isA<JsonFileError>()));
      expect(file.readAsStringSync(), content);
    }
  });

  test('metadata validation rejects command-like IDs before writing', () async {
    final journal = JsonOperationJournal(directory.path);
    await expectLater(journal.record(_record('echo secret')), throwsA(isA<FormatException>()));
    expect(await journal.load(), isEmpty);
    expect(File('${directory.path}/ai_operations.json').existsSync(), isFalse);
  });

  test('capacity prunes completed records and preserves unknown operations', () async {
    final file = File('${directory.path}/ai_operations.json');
    await file.writeAsString(
      jsonEncode({
        'schemaVersion': 1,
        'revision': 1,
        'operations': [
          _encoded('unknown', 'outcomeUnknown'),
          for (var i = 1; i < JsonOperationJournal.maxRecords; i++) _encoded('done-$i', 'completed'),
        ],
      }),
    );
    final journal = JsonOperationJournal(directory.path);
    await journal.record(_record('new'));
    final records = await journal.load();
    expect(records, hasLength(JsonOperationJournal.maxRecords));
    expect(records.any((r) => r.id.value == 'unknown'), isTrue);
    expect(records.any((r) => r.id.value == 'done-1'), isFalse);
    expect(records.last.state, OperationState.intent);
  });

  test('capacity filled with unresolved outcomes refuses side effects without deleting records', () async {
    final file = File('${directory.path}/ai_operations.json');
    final content = jsonEncode({
      'schemaVersion': 1,
      'revision': 1,
      'operations': [
        for (var i = 0; i < JsonOperationJournal.maxRecords; i++) _encoded('unknown-$i', 'outcomeUnknown'),
      ],
    });
    await file.writeAsString(content);
    final journal = JsonOperationJournal(directory.path);
    await expectLater(
      journal.record(_record('new')),
      throwsA(isA<AgentFailure>().having((e) => e.code, 'code', 'operationCapacity')),
    );
    expect(file.readAsStringSync(), content);
  });

  test('conflicting writers cannot silently overwrite an intent', () async {
    final first = JsonOperationJournal(directory.path), stale = JsonOperationJournal(directory.path);
    await first.load();
    await stale.load();
    await first.record(_record('first'));
    await expectLater(
      stale.record(_record('second')),
      throwsA(isA<JsonFileError>().having((e) => e.kind, 'kind', JsonFileFailure.conflict)),
    );
    final records = await JsonOperationJournal(directory.path).load();
    expect(records.map((record) => record.id.value), ['first']);
    expect(records.single.state, OperationState.outcomeUnknown);
  });
}

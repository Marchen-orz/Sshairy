import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/features/ai/adapters/conversation_store.dart';
import 'package:sshairy/features/ai/domain/conversation.dart';
import 'package:sshairy/foundation/ids.dart';
import 'package:sshairy/foundation/json_file.dart';

const _destination = '["openAi","https://model.invalid/v1","test-model"]';
const _signature = '0123456789abcdef0123456789abcdef';

AgentConversationRecord _record(
  String id, {
  String title = 'A conversation',
  DateTime? updatedAt,
  List<ConversationEntry>? entries,
}) {
  final time = updatedAt ?? DateTime.now().toUtc();
  return AgentConversationRecord(
    id: id,
    title: title,
    createdAt: time.subtract(const Duration(minutes: 1)),
    updatedAt: time,
    destination: _destination,
    host: const HostId('host-1'),
    routeSignature: _signature,
    entries: entries ?? const [ConversationEntry(kind: ConversationEntryKind.user, text: 'Inspect disk usage')],
  );
}

Map<String, dynamic> _encodedRecord({String id = 'conversation-1', DateTime? updatedAt}) {
  final time = updatedAt ?? DateTime.now().toUtc();
  return {
    'id': id,
    'title': 'A conversation',
    'createdAt': time.subtract(const Duration(minutes: 1)).toIso8601String(),
    'updatedAt': time.toIso8601String(),
    'destination': _destination,
    'hostId': 'host-1',
    'routeSignature': _signature,
    'historyTruncated': false,
    'entries': [
      {'kind': 'user', 'text': 'Inspect disk usage', 'truncated': false},
    ],
  };
}

String _document(List<Map<String, dynamic>> records) =>
    jsonEncode({'schemaVersion': 1, 'revision': 1, 'conversations': records});

void main() {
  late Directory directory;
  late File file;
  setUp(() {
    directory = Directory.systemTemp.createTempSync('sshairy-ai-conversations-');
    file = File('${directory.path}/ai_conversations.json');
  });
  tearDown(() async => directory.delete(recursive: true));

  test('creation and missing history reads are lazy', () async {
    final store = JsonConversationStore(directory.path);
    expect(directory.listSync(), isEmpty);
    expect(await store.load(), isEmpty);
    expect(directory.listSync(), isEmpty);
  });

  test('queued saves survive restart as immutable readable projections', () async {
    final store = JsonConversationStore(directory.path);
    final now = DateTime.now().toUtc();
    final first = _record('first', updatedAt: now.subtract(const Duration(seconds: 1)));
    final second = _record(
      'second',
      updatedAt: now,
      entries: const [
        ConversationEntry(kind: ConversationEntryKind.user, text: 'Inspect memory'),
        ConversationEntry(
          kind: ConversationEntryKind.execution,
          text: 'User-shared summary',
          capability: 'diagnostics.collect',
          state: 'completed',
          exitCode: 0,
          truncated: true,
        ),
        ConversationEntry(kind: ConversationEntryKind.assistant, text: 'Memory usage is low.'),
      ],
    );
    await Future.wait([
      store.save([first]),
      store.save([first, second]),
    ]);
    await store.saved;
    final document = jsonDecode(file.readAsStringSync()) as Map;
    expect(document.keys.toSet(), {'schemaVersion', 'revision', 'conversations'});
    expect(document['revision'], 2);
    final records = await JsonConversationStore(directory.path).load();
    expect(records.map((record) => record.id), ['second', 'first']);
    final recovered = records.first;
    expect(recovered.destination, _destination);
    expect(recovered.host, const HostId('host-1'));
    expect(recovered.routeSignature, _signature);
    expect(recovered.entries[1].text, 'User-shared summary');
    expect(recovered.entries[1].capability, 'diagnostics.collect');
    expect(recovered.entries[1].state, 'completed');
    expect(recovered.entries[1].exitCode, 0);
    expect(recovered.entries[1].truncated, isTrue);
    expect(() => records.clear(), throwsUnsupportedError);
    expect(() => recovered.entries.clear(), throwsUnsupportedError);
  });

  test('record freezes the caller entry list', () {
    final entries = [const ConversationEntry(kind: ConversationEntryKind.user, text: 'Keep this')];
    final record = _record('immutable', entries: entries);
    entries.clear();
    expect(record.entries.single.text, 'Keep this');
  });

  test('common secret forms are redacted before title and entry persistence', () async {
    const text =
        'Bearer synthetic-token.value\n'
        'API_KEY="synthetic key with spaces" password=synthetic-password\n'
        'TOKEN: synthetic-token\n'
        '-----BEGIN OPENSSH PRIVATE KEY-----\n'
        'synthetic-private-material\n'
        '-----END OPENSSH PRIVATE KEY-----\n'
        'ordinary diagnostic text';
    final store = JsonConversationStore(directory.path);
    await store.save([
      _record(
        'redacted',
        title: 'API_KEY=synthetic-title',
        entries: const [ConversationEntry(kind: ConversationEntryKind.user, text: text)],
      ),
    ]);
    final content = file.readAsStringSync();
    for (final secret in [
      'synthetic-token.value',
      'synthetic key with spaces',
      'synthetic-password',
      'synthetic-token',
      'synthetic-private-material',
      'synthetic-title',
    ]) {
      expect(content, isNot(contains(secret)));
    }
    final loaded = (await JsonConversationStore(directory.path).load()).single;
    expect(loaded.title, contains('[redacted]'));
    expect(loaded.entries.single.text, contains('ordinary diagnostic text'));
    expect(sanitizeConversationText(loaded.entries.single.text), loaded.entries.single.text);
    expect(sanitizeConversationText('-----BEGIN PRIVATE KEY-----\nunfinished-material'), '[redacted private key]');
  });

  test('load removes expired records and sanitizes legacy readable text on disk', () async {
    final now = DateTime.now().toUtc();
    final live = _encodedRecord(id: 'live', updatedAt: now);
    live['entries'] = [
      {'kind': 'user', 'text': 'Bearer synthetic-legacy-token'},
    ];
    await file.writeAsString(
      _document([_encodedRecord(id: 'expired', updatedAt: now.subtract(const Duration(days: 31))), live]),
    );
    final loaded = await JsonConversationStore(directory.path).load();
    expect(loaded.map((record) => record.id), ['live']);
    expect(loaded.single.entries.single.text, 'Bearer [redacted]');
    expect(file.readAsStringSync(), isNot(contains('synthetic-legacy-token')));
    expect(file.readAsStringSync(), isNot(contains('expired')));
    expect((jsonDecode(file.readAsStringSync()) as Map)['revision'], 2);
  });

  test('corrupt, future-version and invalid documents preserve bytes and block saves', () async {
    for (final content in [
      '{broken',
      jsonEncode({'schemaVersion': 2, 'revision': 1, 'conversations': []}),
      jsonEncode({'schemaVersion': 1, 'revision': 'bad', 'conversations': []}),
      jsonEncode({'schemaVersion': 1, 'revision': 1, 'conversations': 'bad'}),
      _document([
        {..._encodedRecord(), 'routeSignature': 'ssh://account@address:22'},
      ]),
      _document([
        {
          ..._encodedRecord(),
          'entries': [
            {'kind': 'tool', 'text': 'bad'},
          ],
        },
      ]),
      _document([
        {
          ..._encodedRecord(),
          'entries': [
            {'kind': 'user', 'text': 'bad', 'exitCode': 0},
          ],
        },
      ]),
      _document([_encodedRecord(), _encodedRecord()]),
    ]) {
      await file.writeAsString(content);
      final store = JsonConversationStore(directory.path);
      await expectLater(store.load(), throwsA(isA<JsonFileError>()));
      await expectLater(store.save([_record('fresh')]), throwsA(isA<JsonFileError>()));
      await expectLater(store.saved, throwsA(isA<JsonFileError>()));
      expect(file.readAsStringSync(), content);
    }
  });

  test('unknown and sensitive fields at every document level are rejected', () async {
    for (final field in ['raw', 'stdout', 'stderr', 'command', 'cwd', 'target', 'approval', 'opaque', 'outputHandle']) {
      for (final level in ['document', 'record', 'entry']) {
        final record = _encodedRecord();
        final document = <String, dynamic>{
          'schemaVersion': 1,
          'revision': 1,
          'conversations': [record],
        };
        switch (level) {
          case 'document':
            document[field] = 'synthetic-private';
          case 'record':
            record[field] = 'synthetic-private';
          case 'entry':
            (record['entries'] as List).first[field] = 'synthetic-private';
        }
        final content = jsonEncode(document);
        await file.writeAsString(content);
        final store = JsonConversationStore(directory.path);
        await expectLater(store.load(), throwsA(isA<JsonFileError>()), reason: '$level.$field');
        await expectLater(store.save([]), throwsA(isA<JsonFileError>()), reason: '$level.$field');
        expect(file.readAsStringSync(), content);
      }
    }
  });

  test('persisted entry/count/text capacity violations are not silently repaired', () async {
    for (final records in [
      [for (var i = 0; i <= maxAgentConversations; i++) _encodedRecord(id: 'conversation-$i')],
      [
        {
          ..._encodedRecord(),
          'entries': [
            for (var i = 0; i <= maxConversationEntries; i++) {'kind': 'user', 'text': 'turn $i'},
          ],
        },
      ],
      [
        {
          ..._encodedRecord(),
          'entries': [
            {'kind': 'user', 'text': 'x' * maxConversationTextBytes},
          ],
        },
      ],
    ]) {
      final content = _document(records);
      await file.writeAsString(content);
      final store = JsonConversationStore(directory.path);
      await expectLater(store.load(), throwsA(isA<JsonFileError>()));
      await expectLater(store.save([]), throwsA(isA<JsonFileError>()));
      expect(file.readAsStringSync(), content);
    }
  });

  test('oversized files are rejected before parsing and cannot be overwritten', () async {
    final handle = file.openSync(mode: FileMode.write);
    handle.truncateSync(JsonConversationStore.maxFileBytes + 1);
    handle.closeSync();
    final store = JsonConversationStore(directory.path);
    await expectLater(store.load(), throwsA(isA<JsonFileError>()));
    await expectLater(store.save([]), throwsA(isA<JsonFileError>()));
    expect(file.lengthSync(), JsonConversationStore.maxFileBytes + 1);
  });

  test('retention keeps the newest 100 conversations with deterministic ordering', () {
    final now = DateTime.utc(2026, 11, 11);
    final kept = boundedConversationRecords([
      for (var i = 0; i <= maxAgentConversations; i++)
        _record('record-$i', updatedAt: now.subtract(Duration(seconds: i))),
      _record('expired', updatedAt: now.subtract(const Duration(days: 31))),
    ], now: now);
    expect(kept, hasLength(maxAgentConversations));
    expect(kept.first.id, 'record-0');
    expect(kept.last.id, 'record-99');
    final ties = boundedConversationRecords([_record('b', updatedAt: now), _record('a', updatedAt: now)], now: now);
    expect(ties.map((record) => record.id), ['a', 'b']);
    expect(() => kept.clear(), throwsUnsupportedError);
  });

  test('entry capacity drops whole oldest turns and persists the truncation marker', () async {
    final store = JsonConversationStore(directory.path);
    await store.save([
      _record(
        'many-turns',
        entries: [
          for (var i = 0; i <= maxConversationEntries ~/ 2; i++) ...[
            ConversationEntry(kind: ConversationEntryKind.user, text: 'user $i'),
            ConversationEntry(kind: ConversationEntryKind.assistant, text: 'assistant $i'),
          ],
        ],
      ),
    ]);
    final recovered = (await JsonConversationStore(directory.path).load()).single;
    expect(recovered.entries, hasLength(maxConversationEntries));
    expect(recovered.entries.first.kind, ConversationEntryKind.user);
    expect(recovered.entries.first.text, 'user 1');
    expect(recovered.entries.last.text, 'assistant 100');
    expect(recovered.historyTruncated, isTrue);
  });

  test('text capacity trims a whole old turn without shortening the latest user text', () {
    final now = DateTime.utc(2026, 11, 11);
    final latest = 'latest user text ' * 20;
    final record = boundedConversationRecords([
      _record(
        'large-old-turn',
        updatedAt: now,
        entries: [
          ConversationEntry(kind: ConversationEntryKind.user, text: 'x' * maxConversationTextBytes),
          const ConversationEntry(kind: ConversationEntryKind.assistant, text: 'old response'),
          ConversationEntry(kind: ConversationEntryKind.user, text: latest),
          const ConversationEntry(kind: ConversationEntryKind.assistant, text: 'new response'),
        ],
      ),
    ], now: now).single;
    expect(record.entries.map((entry) => entry.text), [latest, 'new response']);
    expect(record.historyTruncated, isTrue);
  });

  test('latest turn overflow fails explicitly and retains the accepted file and cache', () async {
    final store = JsonConversationStore(directory.path);
    await store.save([_record('accepted')]);
    final bytes = file.readAsBytesSync();
    for (final entries in [
      [ConversationEntry(kind: ConversationEntryKind.user, text: 'x' * maxConversationTextBytes)],
      [
        const ConversationEntry(kind: ConversationEntryKind.user, text: 'latest user'),
        for (var i = 0; i < maxConversationEntries; i++)
          const ConversationEntry(kind: ConversationEntryKind.assistant, text: 'response'),
      ],
    ]) {
      await expectLater(
        store.save([_record('too-large', entries: entries)]),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('latest conversation turn'))),
      );
      await expectLater(store.saved, throwsA(isA<FormatException>()));
      expect(file.readAsBytesSync(), bytes);
      expect((await store.load()).single.id, 'accepted');
    }
    await store.save([_record('retry')]);
    await store.saved;
    expect((await JsonConversationStore(directory.path).load()).single.id, 'retry');
  });

  test('total text capacity retains a newest prefix within 50 MiB', () {
    final now = DateTime.utc(2026, 11, 11);
    final large = 'x' * (maxConversationTextBytes - utf8.encode('A conversation').length);
    final records = boundedConversationRecords([
      for (var i = 0; i <= maxConversationHistoryBytes ~/ maxConversationTextBytes; i++)
        _record(
          'large-$i',
          updatedAt: now.subtract(Duration(seconds: i)),
          entries: [ConversationEntry(kind: ConversationEntryKind.user, text: large)],
        ),
    ], now: now);
    expect(records, hasLength(50));
    expect(records.first.id, 'large-0');
    expect(records.last.id, 'large-49');
  });

  test('invalid new metadata cannot overwrite accepted history', () async {
    final store = JsonConversationStore(directory.path);
    await store.save([_record('accepted')]);
    final bytes = file.readAsBytesSync();
    await expectLater(store.save([_record('echo private command')]), throwsA(isA<FormatException>()));
    expect(file.readAsBytesSync(), bytes);
    expect((await store.load()).single.id, 'accepted');
  });

  test('separate stale writer fails and keeps its accepted cache', () async {
    final first = JsonConversationStore(directory.path), stale = JsonConversationStore(directory.path);
    await first.load();
    await stale.load();
    await first.save([_record('first')]);
    final bytes = file.readAsBytesSync();
    await expectLater(
      stale.save([_record('second')]),
      throwsA(isA<JsonFileError>().having((e) => e.kind, 'kind', JsonFileFailure.conflict)),
    );
    await expectLater(stale.saved, throwsA(isA<JsonFileError>()));
    expect(await stale.load(), isEmpty);
    expect(file.readAsBytesSync(), bytes);
    expect((await JsonConversationStore(directory.path).load()).single.id, 'first');
  });

  test('deleting history creates no backup or protected content snapshots', () async {
    final store = JsonConversationStore(directory.path);
    await store.save([
      _record(
        'delete-me',
        entries: const [ConversationEntry(kind: ConversationEntryKind.user, text: 'private discussion')],
      ),
    ]);
    await store.save([]);
    expect(await JsonConversationStore(directory.path).load(), isEmpty);
    expect(file.readAsStringSync(), isNot(contains('private discussion')));
    expect(directory.listSync().map((entry) => entry.path.split(Platform.pathSeparator).last).toSet(), {
      'ai_conversations.json',
      'ai_conversations.json.lock',
    });
  });
}

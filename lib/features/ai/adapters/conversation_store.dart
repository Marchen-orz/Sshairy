import 'dart:convert';
import 'dart:io';

import '../../../foundation/ids.dart';
import '../../../foundation/json_file.dart';
import '../domain/conversation.dart';

const maxAgentConversations = 100;
const maxConversationEntries = 200;
const maxConversationTextBytes = 1 << 20;
const maxConversationHistoryBytes = 50 << 20;
const conversationHistoryAge = Duration(days: 30);

final _bearer = RegExp(
  r'\bBearer[ \t]+[A-Za-z0-9._~+/=\-]+',
  caseSensitive: false,
);
final _assignments = RegExp(
  r'''(\b[A-Za-z_][A-Za-z0-9_]*(?:KEY|TOKEN|SECRET|PASSWORD|PASSWD)\b|\b(?:key|token|secret|password|passwd)\b)(["']?[ \t]*[:=][ \t]*)(?:\[redacted\]|"[^"\r\n]*"|'[^'\r\n]*'|[^\s,;}\]]+)''',
  caseSensitive: false,
);
final _privateKey = RegExp(
  r'-----BEGIN ([A-Z0-9 ]*PRIVATE KEY)-----[\s\S]*?(?:-----END \1-----|$)',
);

/// Auxiliary filtering only: unknown secrets and business-sensitive text can still remain.
String sanitizeConversationText(String text) => text
    .replaceAll(_privateKey, '[redacted private key]')
    .replaceAll(_bearer, 'Bearer [redacted]')
    .replaceAllMapped(
      _assignments,
      (match) => '${match[1]}${match[2]}[redacted]',
    );

int _textBytes(AgentConversationRecord record) =>
    utf8.encode(record.title).length +
    record.entries.fold(
      0,
      (size, entry) => size + utf8.encode(entry.text).length,
    );

AgentConversationRecord _copy(
  AgentConversationRecord record,
  List<ConversationEntry> entries, {
  required bool truncated,
}) => AgentConversationRecord(
  id: record.id,
  title: sanitizeConversationText(record.title),
  createdAt: record.createdAt.toUtc(),
  updatedAt: record.updatedAt.toUtc(),
  destination: record.destination,
  host: record.host,
  routeSignature: record.routeSignature,
  entries: entries,
  historyTruncated: truncated,
);

/// Drops old whole turns and old conversations; the newest turn is never silently shortened.
List<AgentConversationRecord> boundedConversationRecords(
  Iterable<AgentConversationRecord> records, {
  DateTime? now,
}) {
  final cutoff = (now ?? DateTime.now()).toUtc().subtract(
    conversationHistoryAge,
  );
  final normalized = <AgentConversationRecord>[];
  final ids = <String>{};
  for (final record in records) {
    _validateRecord(_encode(record), bounded: false);
    if (!ids.add(record.id))
      throw const FormatException('duplicate conversation');
    if (record.updatedAt.isBefore(cutoff)) continue;
    var entries = [
      for (final entry in record.entries)
        ConversationEntry(
          kind: entry.kind,
          text: sanitizeConversationText(entry.text),
          capability: entry.capability,
          state: entry.state,
          exitCode: entry.exitCode,
          truncated: entry.truncated,
          retracted: entry.retracted,
          executionId: entry.executionId,
        ),
    ];
    var next = _copy(record, entries, truncated: record.historyTruncated);
    while (entries.length > maxConversationEntries ||
        _textBytes(next) > maxConversationTextBytes) {
      final nextTurn = entries.indexWhere(
        (entry) => entry.kind == ConversationEntryKind.user,
        1,
      );
      if (nextTurn < 0)
        throw const FormatException(
          'latest conversation turn exceeds history capacity',
        );
      entries = entries.sublist(nextTurn);
      next = _copy(record, entries, truncated: true);
    }
    _validateRecord(_encode(next));
    normalized.add(next);
  }
  normalized.sort((a, b) {
    final order = b.updatedAt.compareTo(a.updatedAt);
    return order == 0 ? a.id.compareTo(b.id) : order;
  });
  final kept = <AgentConversationRecord>[];
  var bytes = 0;
  for (final record in normalized) {
    final size = _textBytes(record);
    if (kept.length >= maxAgentConversations ||
        bytes + size > maxConversationHistoryBytes)
      break;
    kept.add(record);
    bytes += size;
  }
  return List.unmodifiable(kept);
}

/// History is a bounded text projection. No backups retain content after an explicit deletion.
class JsonConversationStore implements ConversationStore {
  JsonConversationStore(String directory)
    : path = '$directory/ai_conversations.json',
      _file = JsonFile(
        '$directory/ai_conversations.json',
        validate: _validateDocument,
      );

  static const maxFileBytes = 64 << 20;
  final String path;
  final JsonFile _file;
  List<AgentConversationRecord>? _records;
  Future<void> _queue = Future.value(), _saved = Future.value();

  @override
  Future<void> get saved => _saved;

  Future<T> _serial<T>(Future<T> Function() operation) {
    final next = _queue.then((_) => operation());
    _saved = next.then<void>((_) {});
    _queue = _saved.then<void>((_) {}, onError: (Object _) {});
    return next;
  }

  void _checkFileSize() {
    final file = File(path);
    if (file.existsSync() && file.lengthSync() > maxFileBytes) {
      throw JsonFileError(JsonFileFailure.corrupt, path);
    }
  }

  Future<void> _load() async {
    if (_records != null) return;
    _checkFileSize();
    final document = _file.read();
    final decoded = [
      for (final value in document?['conversations'] as List? ?? const [])
        _decode((value as Map).cast<String, dynamic>()),
    ];
    final next = boundedConversationRecords(decoded);
    if (document != null &&
        jsonEncode(decoded.map(_encode).toList()) !=
            jsonEncode(next.map(_encode).toList())) {
      await _write(next);
    }
    _records = next;
  }

  @override
  Future<List<AgentConversationRecord>> load() => _serial(() async {
    await _load();
    return List.unmodifiable(_records!);
  });

  @override
  Future<void> save(List<AgentConversationRecord> records) {
    final snapshot = List<AgentConversationRecord>.unmodifiable(records);
    return _serial(() async {
      await _load();
      final next = boundedConversationRecords(snapshot);
      await _write(next);
      _records = next;
    });
  }

  Future<void> _write(List<AgentConversationRecord> records) {
    _checkFileSize();
    final document = {
      'schemaVersion': 1,
      'conversations': [for (final record in records) _encode(record)],
    };
    final encoded = const JsonEncoder.withIndent('  ')
        .convert({...document, 'revision': _file.revision + 1});
    if (utf8.encode(encoded).length > maxFileBytes) {
      throw const FormatException('conversation document exceeds capacity');
    }
    return _file.write(document);
  }
}

final _id = RegExp(r'^[A-Za-z0-9_.:\-]{1,128}$');
final _signature = RegExp(r'^[A-Za-z0-9_\-]{16,128}$');
final _capability = RegExp(r'^[A-Za-z][A-Za-z0-9_.]{0,95}$');
const _executionStates = {
  'pending',
  'running',
  'completed',
  'failed',
  'cancelled',
  'interrupted',
  'outcomeUnknown',
};

void _validateDocument(Map<String, dynamic> document) {
  if (document.keys.any(
    (key) =>
        !const {'schemaVersion', 'revision', 'conversations'}.contains(key),
  )) {
    throw const FormatException('conversation document fields');
  }
  final records = document['conversations'];
  if (records is! List || records.length > maxAgentConversations)
    throw const FormatException('conversations');
  final ids = <String>{};
  var bytes = 0;
  for (final record in records) {
    if (record is! Map<String, dynamic>)
      throw const FormatException('conversation');
    _validateRecord(record);
    if (!ids.add(record['id'] as String))
      throw const FormatException('duplicate conversation');
    bytes += _textBytes(_decode(record));
  }
  if (bytes > maxConversationHistoryBytes)
    throw const FormatException('conversation history exceeds capacity');
}

void _validateRecord(Map<String, dynamic> record, {bool bounded = true}) {
  const required = {
    'id',
    'title',
    'createdAt',
    'updatedAt',
    'destination',
    'entries',
  };
  const allowed = {...required, 'hostId', 'routeSignature', 'historyTruncated'};
  if (!record.keys.toSet().containsAll(required) ||
      record.keys.any((key) => !allowed.contains(key))) {
    throw const FormatException('conversation fields');
  }
  if (record['id'] is! String || !_id.hasMatch(record['id'] as String)) {
    throw const FormatException('conversation id');
  }
  final title = record['title'], destination = record['destination'];
  if (title is! String ||
      title.isEmpty ||
      utf8.encode(title).length > 2048 ||
      title.contains('\u0000') ||
      destination is! String ||
      destination.isEmpty ||
      destination.length > 4096 ||
      RegExp(r'[\x00-\x1f\x7f-\x9f]').hasMatch(destination)) {
    throw const FormatException('conversation identity');
  }
  final created = record['createdAt'], updated = record['updatedAt'];
  if (created is! String ||
      updated is! String ||
      created.length > 40 ||
      updated.length > 40) {
    throw const FormatException('conversation dates');
  }
  final createdAt = DateTime.tryParse(created),
      updatedAt = DateTime.tryParse(updated);
  if (createdAt == null || updatedAt == null || updatedAt.isBefore(createdAt)) {
    throw const FormatException('conversation dates');
  }
  final host = record['hostId'], signature = record['routeSignature'];
  if (host != null && (host is! String || !_id.hasMatch(host)))
    throw const FormatException('conversation host');
  if (signature != null &&
      (signature is! String ||
          !_signature.hasMatch(signature) ||
          host == null)) {
    throw const FormatException('conversation route signature');
  }
  if (record.containsKey('historyTruncated') &&
      record['historyTruncated'] is! bool) {
    throw const FormatException('conversation truncation');
  }
  final entries = record['entries'];
  if (entries is! List ||
      (bounded && entries.length > maxConversationEntries)) {
    throw const FormatException('conversation entries');
  }
  final executionIds = <String>{};
  for (final entry in entries) {
    if (entry is! Map<String, dynamic>)
      throw const FormatException('conversation entry');
    _validateEntry(entry);
    final executionId = entry['executionId'] as String?;
    if (executionId != null && !executionIds.add(executionId)) {
      throw const FormatException('duplicate execution id');
    }
  }
  if (bounded && _textBytes(_decode(record)) > maxConversationTextBytes) {
    throw const FormatException('conversation text exceeds capacity');
  }
}

void _validateEntry(Map<String, dynamic> entry) {
  const allowed = {
    'kind',
    'text',
    'capability',
    'state',
    'exitCode',
    'truncated',
    'retracted',
    'executionId',
  };
  if (!entry.keys.toSet().containsAll(const {'kind', 'text'}) ||
      entry.keys.any((key) => !allowed.contains(key))) {
    throw const FormatException('conversation entry fields');
  }
  if (!ConversationEntryKind.values.any((kind) => kind.name == entry['kind']) ||
      entry['text'] is! String ||
      (entry['text'] as String).contains('\u0000') ||
      (entry.containsKey('truncated') && entry['truncated'] is! bool) ||
      (entry.containsKey('retracted') && entry['retracted'] is! bool)) {
    throw const FormatException('conversation entry value');
  }
  final capability = entry['capability'],
      state = entry['state'],
      exitCode = entry['exitCode'];
  final executionId = entry['executionId'];
  if (capability != null &&
          (capability is! String || !_capability.hasMatch(capability)) ||
      state != null &&
          (state is! String || !_executionStates.contains(state)) ||
      exitCode != null && exitCode is! int ||
      executionId != null &&
          (executionId is! String || !_id.hasMatch(executionId))) {
    throw const FormatException('conversation execution metadata');
  }
  if (entry['kind'] != ConversationEntryKind.execution.name &&
      (capability != null ||
          state != null ||
          exitCode != null ||
          executionId != null)) {
    throw const FormatException('conversation text metadata');
  }
}

Map<String, dynamic> _encode(AgentConversationRecord record) => {
  'id': record.id,
  'title': record.title,
  'createdAt': record.createdAt.toUtc().toIso8601String(),
  'updatedAt': record.updatedAt.toUtc().toIso8601String(),
  'destination': record.destination,
  'hostId': record.host?.value,
  'routeSignature': record.routeSignature,
  'historyTruncated': record.historyTruncated,
  'entries': [
    for (final entry in record.entries)
      {
        'kind': entry.kind.name,
        'text': entry.text,
        if (entry.capability != null) 'capability': entry.capability,
        if (entry.state != null) 'state': entry.state,
        if (entry.exitCode != null) 'exitCode': entry.exitCode,
        if (entry.executionId != null) 'executionId': entry.executionId,
        if (entry.retracted) 'retracted': true,
        'truncated': entry.truncated,
      },
  ],
};

AgentConversationRecord _decode(Map<String, dynamic> record) =>
    AgentConversationRecord(
      id: record['id'] as String,
      title: record['title'] as String,
      createdAt: DateTime.parse(record['createdAt'] as String).toUtc(),
      updatedAt: DateTime.parse(record['updatedAt'] as String).toUtc(),
      destination: record['destination'] as String,
      host: record['hostId'] == null
          ? null
          : HostId(record['hostId'] as String),
      routeSignature: record['routeSignature'] as String?,
      historyTruncated: record['historyTruncated'] as bool? ?? false,
      entries: [
        for (final entry in record['entries'] as List)
          ConversationEntry(
            kind: ConversationEntryKind.values.byName(entry['kind'] as String),
            text: entry['text'] as String,
            capability: entry['capability'] as String?,
            state: entry['state'] as String?,
            exitCode: entry['exitCode'] as int?,
            truncated: entry['truncated'] as bool? ?? false,
            retracted: entry['retracted'] as bool? ?? false,
            executionId: entry['executionId'] as String?,
          ),
      ],
    );

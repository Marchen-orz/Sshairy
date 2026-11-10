import '../../../foundation/ids.dart';
import '../../../foundation/json_file.dart';
import '../domain/agent.dart';

/// Durable operation metadata never includes commands, output, connection configuration or credentials.
class JsonOperationJournal implements OperationJournal {
  JsonOperationJournal(String directory) : _file = JsonFile('$directory/ai_operations.json', validate: _validate);

  static const maxRecords = 1000;
  final JsonFile _file;
  List<OperationRecord>? _records;
  Future<void> _queue = Future.value();
  Future<void> _saved = Future.value();

  @override
  Future<void> get saved => _saved;

  Future<T> _serial<T>(Future<T> Function() operation) {
    final next = _queue.then((_) => operation());
    final saved = next.then<void>((_) {});
    _saved = saved;
    _queue = saved.then<void>((_) {}, onError: (Object _) {});
    return next;
  }

  @override
  Future<List<OperationRecord>> load() => _serial(() async {
    await _load();
    return List.unmodifiable(_records!);
  });

  Future<void> _load() async {
    if (_records != null) return;
    final document = _file.read();
    final records = [
      for (final value in document?['operations'] as List? ?? const []) _decode((value as Map).cast<String, dynamic>()),
    ];
    final recovered = [
      for (final record in records)
        record.state == OperationState.intent ? record.withState(OperationState.outcomeUnknown) : record,
    ];
    if (records.any((record) => record.state == OperationState.intent)) {
      await _write(recovered);
    }
    _records = recovered;
  }

  @override
  Future<void> record(OperationRecord record) => _serial(() async {
    await _load();
    _validateRecord(_encode(record));
    final next = List<OperationRecord>.of(_records!);
    final existing = next.indexWhere((entry) => entry.id == record.id);
    if (existing >= 0) {
      final old = next[existing];
      if (old.host != record.host || old.capability != record.capability || old.at.toUtc() != record.at.toUtc()) {
        throw const AgentFailure('operationConflict');
      }
      if (old.state == record.state) return;
      if (old.state != OperationState.intent && old.state != OperationState.outcomeUnknown) {
        throw const AgentFailure('operationConflict');
      }
      if (record.state == OperationState.intent) throw const AgentFailure('operationConflict');
      next[existing] = record;
    } else {
      if (record.state != OperationState.intent) throw const AgentFailure('operationMissingIntent');
      while (next.length >= maxRecords) {
        final removable = next.indexWhere(
          (entry) => entry.state == OperationState.completed || entry.state == OperationState.failed,
        );
        if (removable < 0) throw const AgentFailure('operationCapacity');
        next.removeAt(removable);
      }
      next.add(record);
    }
    await _write(next);
    _records = next;
  });

  Future<void> _write(List<OperationRecord> records) => _file.write({
    'schemaVersion': 1,
    'operations': [for (final record in records) _encode(record)],
  });

  static final _id = RegExp(r'^[A-Za-z0-9_.:\-]{1,128}$');
  static final _capability = RegExp(r'^[A-Za-z][A-Za-z0-9_.]{0,95}$');

  static void _validate(Map<String, dynamic> document) {
    if (document.keys.any((key) => !const {'schemaVersion', 'revision', 'operations'}.contains(key))) {
      throw const FormatException('operation document');
    }
    final records = document['operations'];
    if (records is! List || records.length > maxRecords) throw const FormatException('operations');
    final ids = <String>{};
    for (final record in records) {
      if (record is! Map<String, dynamic>) throw const FormatException('operation');
      _validateRecord(record);
      if (!ids.add(record['id'] as String)) throw const FormatException('duplicate operation');
    }
  }

  static void _validateRecord(Map<String, dynamic> record) {
    if (record.length != 5 || !record.keys.toSet().containsAll(const {'id', 'hostId', 'capability', 'at', 'state'})) {
      throw const FormatException('operation fields');
    }
    if (record['id'] is! String ||
        !_id.hasMatch(record['id'] as String) ||
        record['hostId'] is! String ||
        !_id.hasMatch(record['hostId'] as String) ||
        record['capability'] is! String ||
        !_capability.hasMatch(record['capability'] as String) ||
        record['at'] is! String ||
        DateTime.tryParse(record['at'] as String) == null ||
        !OperationState.values.any((state) => state.name == record['state'])) {
      throw const FormatException('operation metadata');
    }
  }

  static Map<String, dynamic> _encode(OperationRecord record) => {
    'id': record.id.value,
    'hostId': record.host.value,
    'capability': record.capability,
    'at': record.at.toUtc().toIso8601String(),
    'state': record.state.name,
  };

  static OperationRecord _decode(Map<String, dynamic> record) => OperationRecord(
    OperationId(record['id'] as String),
    HostId(record['hostId'] as String),
    record['capability'] as String,
    DateTime.parse(record['at'] as String).toUtc(),
    OperationState.values.byName(record['state'] as String),
  );
}

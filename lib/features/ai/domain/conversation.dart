import '../../../foundation/ids.dart';
import 'attachment.dart';

enum ConversationEntryKind { user, assistant, execution }

/// A readable history projection, never a protocol message, approval or raw execution buffer.
class ConversationEntry {
  const ConversationEntry({
    required this.kind,
    required this.text,
    this.capability,
    this.state,
    this.exitCode,
    this.truncated = false,
    this.retracted = false,
    this.executionId,
    this.attachments = const [],
  });

  final ConversationEntryKind kind;
  final String text;
  final String? capability, state, executionId;
  final int? exitCode;
  final bool truncated, retracted;
  final List<AgentAttachment> attachments;
}

class AgentConversationRecord {
  AgentConversationRecord({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    required this.destination,
    required Iterable<ConversationEntry> entries,
    this.host,
    this.routeSignature,
    this.historyTruncated = false,
  }) : entries = List.unmodifiable(entries);

  final String id, title, destination;
  final DateTime createdAt, updatedAt;
  final HostId? host;
  final String? routeSignature;
  final List<ConversationEntry> entries;
  final bool historyTruncated;
}

abstract interface class ConversationStore {
  Future<List<AgentConversationRecord>> load();
  Future<void> save(List<AgentConversationRecord> records);
  Future<void> get saved;
}

import 'dart:convert';

import '../../../foundation/cancellation.dart';
import 'model_profile.dart';
import 'attachment.dart';

export 'attachment.dart';

export 'model_profile.dart';

class ModelTool {
  const ModelTool(this.name, this.description, this.schema);
  final String name;
  final String description;
  final Map<String, Object?> schema;
}

class ModelCall {
  ModelCall(this.id, this.name, Map<String, Object?> arguments) : arguments = Map.unmodifiable(arguments);
  final String id;
  final String name;
  final Map<String, Object?> arguments;
}

enum ModelRole { user, assistant, tool }

class ModelMessage {
  ModelMessage(
    this.role, {
    this.text = '',
    List<ModelCall> calls = const [],
    this.toolCallId,
    this.isError = false,
    this.opaque,
    Iterable<AgentAttachment> attachments = const [],
  }) : calls = List.unmodifiable(calls),
       attachments = checkedAgentAttachments(attachments);

  final ModelRole role;
  final String text;
  final List<ModelCall> calls;
  final List<AgentAttachment> attachments;
  final String? toolCallId;
  final bool isError;

  /// Provider-owned active continuation. Never render, serialize or use it as approval evidence.
  final Object? opaque;
}

class ModelRequest {
  ModelRequest({
    required this.profile,
    required this.system,
    required List<ModelMessage> messages,
    List<ModelTool> tools = const [],
  }) : messages = List.unmodifiable(messages),
       tools = List.unmodifiable(tools);

  final ModelProfile profile;
  final String system;
  final List<ModelMessage> messages;
  final List<ModelTool> tools;
}

/// Context uses two text bytes per token; encoded image data has a separate wire limit.
class ModelInputBudget {
  static const maxMessageBytes = 2 << 20;
  static const maxWireBytes = 32 << 20;

  static int availableBytes(ModelProfile profile) =>
      (profile.contextWindow - profile.maxOutputTokens - 2048).clamp(0, profile.contextWindow) * 2;

  static int imageBytes(AgentAttachment attachment) {
    if (!attachment.isImage) return 0;
    // Attachments are validated PNGs; the first 24 bytes contain both dimensions.
    final header = base64Decode(attachment.content.substring(0, 32));
    int dimension(int offset) =>
        (header[offset] << 24) | (header[offset + 1] << 16) | (header[offset + 2] << 8) | header[offset + 3];
    final width = dimension(16), height = dimension(20);
    // shortcut: conservative high-detail patches, replace when model token metadata is available.
    return (1024 + ((width + 31) ~/ 32) * ((height + 31) ~/ 32) * 4) * 2;
  }
}

abstract interface class ModelProvider {
  Stream<ModelEvent> stream(ModelRequest request, CancellationToken cancel);
  void close();
}

sealed class ModelEvent {
  const ModelEvent();
}

class ModelTextDelta extends ModelEvent {
  const ModelTextDelta(this.text);
  final String text;
}

/// Actual provider reasoning activity. Text is a provider-returned summary, never opaque continuation.
class ModelReasoningDelta extends ModelEvent {
  const ModelReasoningDelta([this.summary = '']);
  final String summary;
}

class ModelMessageComplete extends ModelEvent {
  const ModelMessageComplete(this.message);
  final ModelMessage message;
}

class ModelUsage extends ModelEvent {
  const ModelUsage({this.inputTokens, this.outputTokens});
  final int? inputTokens;
  final int? outputTokens;
}

class ModelFailure implements Exception {
  const ModelFailure(this.code, {this.statusCode, this.retryAfter});
  final String code;
  final int? statusCode;
  final Duration? retryAfter;

  @override
  String toString() => 'ModelFailure($code)';
}

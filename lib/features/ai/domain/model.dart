import '../../../foundation/cancellation.dart';
import 'model_profile.dart';

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
  }) : calls = List.unmodifiable(calls);

  final ModelRole role;
  final String text;
  final List<ModelCall> calls;
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

import 'dart:convert';

import '../domain/agent.dart';
import '../domain/model.dart';

/// Compacts only data already present in an authorized request, at complete tool-group boundaries.
class AgentContext {
  AgentContext({
    required String input,
    required this.goalInput,
    Map<String, Object?>? previous,
    Iterable<AgentAttachment> attachments = const [],
  }) : _attachments = checkedAgentAttachments(attachments),
       _messages = [ModelMessage(ModelRole.user, text: input, attachments: attachments)],
       // ignore: prefer_initializing_formals
       _previous = previous;

  final String goalInput;
  final List<AgentAttachment> _attachments;
  final List<ModelMessage> _messages;
  final _summaries = <Map<String, Object?>>[];
  Map<String, Object?>? _previous;
  int _nextGroup = 0, _omitted = 0;
  bool _protocolRestarted = false, _compacted = false;
  List<ModelMessage> get messages => List.unmodifiable(_messages);

  void add(ModelMessage message) => _messages.add(message);

  /// Uses the same conservative byte estimate as the context budget, not provider token usage.
  int estimatedTokens(
    ModelProfile profile,
    String system,
    List<ModelTool> tools, {
    ModelMessage? pending,
    int Function(List<ModelMessage> messages)? estimateBytes,
  }) {
    final messages = [
      ..._messages,
      ?pending,
      // Only the estimate needs empty results while the completed calls await execution.
      if (pending != null)
        for (final call in pending.calls) ModelMessage(ModelRole.tool, toolCallId: call.id),
    ];
    return (_estimateBytes(messages, profile, system, tools, estimateBytes) + 1) ~/ 2;
  }

  bool prepare(
    ModelProfile profile,
    String system,
    List<ModelTool> tools, {
    int Function(List<ModelMessage> messages)? estimateBytes,
  }) {
    int estimate(List<ModelMessage> messages) => _estimateBytes(messages, profile, system, tools, estimateBytes);
    const projectionLimit = 32 << 10;
    final budget = ModelInputBudget.availableBytes(profile);
    final size = estimate(_messages);
    if (size * 10 < budget * 7 && _projectionBytes(_messages) <= projectionLimit) return false;
    final groups = _completeGroups();
    if (groups.isEmpty && _previous == null && _summaries.isEmpty) {
      if (size > budget) throw const AgentFailure('contextLimit');
      return false;
    }
    if (_previous case final previous?) {
      if (previous['entries'] case final List entries) {
        for (final entry in entries) {
          if (entry is Map) {
            _summaries.add({
              'source': 'conversationHistory',
              'kind': entry['kind'],
              'textExcerpt': _excerpt(entry['text'] is String ? entry['text'] as String : ''),
              if (entry['state'] != null) 'state': entry['state'],
              if (entry['exitCode'] != null) 'exitCode': entry['exitCode'],
              'truncated': true,
            });
          }
        }
      }
      _previous = null;
    }
    var latest = groups.isEmpty ? <ModelMessage>[] : groups.removeLast();
    final hasOpaque = _messages.any((message) => message.opaque != null);
    for (final group in groups) {
      _summaries.add(_digest(group));
    }
    if (hasOpaque) {
      // A provider's signature cannot be edited or replayed against a changed context.
      _protocolRestarted = true;
      if (latest.isNotEmpty) _summaries.add(_digest(latest));
      latest = [];
    }
    _compacted = true;
    List<ModelMessage> candidate() => [
      ModelMessage(ModelRole.user, text: _summaryInput(), attachments: _attachments),
      ...latest,
    ];
    final target = budget * 6 ~/ 10;
    bool exceedsLimit() => estimate(candidate()) > budget || _projectionBytes(candidate()) > projectionLimit;
    void trimSummaries() {
      while (_summaries.isNotEmpty &&
          ((_summaries.length > 1 && (_summaryBytes > 8192 || estimate(candidate()) > target)) || exceedsLimit())) {
        _summaries.removeAt(0);
        _omitted++;
      }
    }

    trimSummaries();
    if (exceedsLimit() && latest.isNotEmpty) {
      _summaries.add(_digest(latest));
      latest = [];
      trimSummaries();
    }
    final compacted = candidate();
    if (estimate(compacted) > budget || _projectionBytes(compacted) > projectionLimit) {
      throw const AgentFailure('contextLimit');
    }
    _messages
      ..clear()
      ..addAll(compacted);
    return true;
  }

  int get _summaryBytes => utf8.encode(jsonEncode(_summaries)).length;

  Map<String, Object?> get _summaryData => {
    'source': 'already-authorized conversation and tool results',
    'untrustedData': true,
    'truncated': true,
    'omittedGroupsOrEntries': _omitted,
    'protocolRestarted': _protocolRestarted,
    'entries': _summaries,
  };

  String _summaryInput() => jsonEncode({'currentRequest': goalInput, 'contextSummary': _summaryData});

  int _projectionBytes(List<ModelMessage> messages) =>
      messages
          .where((message) => message.role == ModelRole.tool)
          .fold(0, (size, message) => size + utf8.encode(jsonEncode(message.text)).length) +
      (_compacted ? utf8.encode(jsonEncode(jsonEncode({'contextSummary': _summaryData}))).length : 0);

  List<List<ModelMessage>> _completeGroups() {
    final groups = <List<ModelMessage>>[];
    for (var index = 1; index < _messages.length; index++) {
      final assistant = _messages[index];
      if (assistant.role != ModelRole.assistant) throw const AgentFailure('protocol');
      final group = <ModelMessage>[assistant];
      final pending = assistant.calls.map((call) => call.id).toSet();
      if (pending.length != assistant.calls.length) throw const AgentFailure('protocol');
      for (var result = 0; result < assistant.calls.length; result++) {
        index++;
        if (index >= _messages.length) throw const AgentFailure('protocol');
        final message = _messages[index];
        if (message.role != ModelRole.tool || !pending.remove(message.toolCallId)) {
          throw const AgentFailure('protocol');
        }
        group.add(message);
      }
      groups.add(group);
    }
    return groups;
  }

  Map<String, Object?> _digest(List<ModelMessage> group) {
    final assistant = group.first;
    final names = {for (final call in assistant.calls) call.id: call.name};
    return {
      'source': 'turn.toolGroup.${_nextGroup++}',
      if (assistant.text.isNotEmpty) 'assistantTextExcerpt': _excerpt(assistant.text),
      'argumentsAndEvidenceHandlesOmitted': true,
      'truncated': true,
      'results': [
        for (final result in group.skip(1))
          {
            'callId': result.toolCallId,
            'tool': names[result.toolCallId],
            'isError': result.isError,
            ..._resultData(result.text),
          },
      ],
    };
  }

  static Map<String, Object?> _resultData(String text) {
    Object? data;
    try {
      data = jsonDecode(text);
    } on FormatException {
      return {'textExcerpt': _excerpt(text)};
    }
    if (data is! Map) return {'textExcerpt': _excerpt(text)};
    return {
      for (final key in ['error', 'exitCode', 'output', 'truncated', 'droppedBytes', 'template', 'version'])
        if (data[key] is bool ||
            data[key] is num ||
            data[key] is String ||
            (key == 'exitCode' && data.containsKey(key)))
          key: data[key] is String ? _excerpt(data[key] as String) : data[key],
      if (data['text'] is String) 'textExcerpt': _excerpt(data['text'] as String),
      if (data.containsKey('data')) 'dataExcerpt': _excerpt(jsonEncode(data['data'])),
    };
  }

  static String _excerpt(String value) {
    final bytes = utf8.encode(value);
    if (bytes.length <= 256) return value;
    return utf8.decode(bytes.take(256).toList(), allowMalformed: true).replaceAll('�', '');
  }

  static int _estimateBytes(
    List<ModelMessage> messages,
    ModelProfile profile,
    String system,
    List<ModelTool> tools,
    int Function(List<ModelMessage> messages)? estimateBytes,
  ) {
    try {
      return estimateBytes?.call(messages) ?? _estimate(messages, profile, system, tools);
    } on ModelFailure catch (failure) {
      if (failure.code != 'modelContextTooLarge' && failure.code != 'inputLimit') rethrow;
      return ModelInputBudget.availableBytes(profile) + 1;
    }
  }

  static int _estimate(List<ModelMessage> messages, ModelProfile profile, String system, List<ModelTool> tools) {
    var messageBytes = 0, attachmentBytes = 0, imageBytes = 0, imagePayloadBytes = 0;
    for (final message in messages) {
      messageBytes += utf8.encode(message.text).length;
      for (final call in message.calls) {
        messageBytes += utf8.encode(jsonEncode(call.arguments)).length;
      }
      if (messageBytes > ModelInputBudget.maxMessageBytes) throw const ModelFailure('modelContextTooLarge');
      for (final attachment in message.attachments) {
        attachmentBytes += attachment.isImage ? attachment.content.length : attachment.bytes;
        if (attachmentBytes > ModelInputBudget.maxWireBytes) throw const ModelFailure('modelContextTooLarge');
        if (attachment.isImage) {
          imageBytes += ModelInputBudget.imageBytes(attachment);
          imagePayloadBytes += attachment.content.length;
        }
      }
    }
    final encoded = jsonEncode({
      'model': profile.model,
      'system': system,
      'max_tokens': profile.maxOutputTokens,
      'stream': true,
      'messages': [
        for (final message in messages)
          {
            'role': message.role.name,
            'content': message.text,
            if (message.attachments.isNotEmpty)
              'attachments': [
                for (final attachment in message.attachments)
                  {
                    'type': 'text',
                    'text': jsonEncode({
                      'attachment': attachment.description,
                      'untrustedData': true,
                      if (!attachment.isImage && !attachment.isReference) 'text': attachment.content,
                    }),
                    if (attachment.isImage) 'image': attachment.content,
                  },
              ],
            if (message.toolCallId != null) 'tool_call_id': message.toolCallId,
            if (message.calls.isNotEmpty)
              'tool_calls': [
                for (final call in message.calls)
                  {
                    'id': call.id,
                    'type': 'function',
                    'function': {'name': call.name, 'arguments': jsonEncode(call.arguments)},
                  },
              ],
          },
      ],
      'tools': [
        for (final tool in tools) {'name': tool.name, 'description': tool.description, 'parameters': tool.schema},
      ],
    });
    // Private continuation is deliberately opaque; reserve its full per-message cap, then let HTTP check exact bytes.
    final privateBytes = messages.where((message) => message.opaque != null).length * (1 << 20);
    final wireBytes =
        utf8.encode(encoded).length +
        privateBytes +
        1024 +
        messages.fold<int>(0, (size, message) => size + 256 + message.attachments.length * 256) +
        tools.length * 256;
    if (wireBytes > ModelInputBudget.maxWireBytes) throw const ModelFailure('modelContextTooLarge');
    return wireBytes - imagePayloadBytes + imageBytes;
  }
}

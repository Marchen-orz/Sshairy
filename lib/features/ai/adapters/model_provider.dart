import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../../foundation/cancellation.dart';
import '../../../foundation/secret.dart';
import '../domain/model.dart';
import 'sse.dart';

const _messageLimit = 1024 * 1024;
const _argumentLimit = 64 * 1024;
final _toolName = RegExp(r'^[A-Za-z0-9_-]{1,64}$');
final _callId = RegExp(r'^[A-Za-z0-9_-]{1,256}$');

/// Owns only model HTTP requests. Construction does not open a connection or read a key.
class HttpModelProvider implements ModelProvider {
  HttpModelProvider({
    required this.readKey,
    HttpClient Function()? clientFactory,
    this.idleTimeout = const Duration(seconds: 120),
  }) : _clientFactory = clientFactory ?? HttpClient.new;

  final Future<Secret?> Function(String identity) readKey;
  final HttpClient Function() _clientFactory;
  final Duration idleTimeout;
  final _active = <_RequestLife>{};
  var _closed = false;

  @override
  Stream<ModelEvent> stream(ModelRequest request, CancellationToken cancel) async* {
    if (_closed || cancel.isCancelled) throw const ModelFailure('cancelled');
    final body = utf8.encode(jsonEncode(encodeModelRequest(request)));
    final inputBytes = ((request.profile.contextWindow - request.profile.maxOutputTokens - 2048) * 2).clamp(0, 2 << 20);
    if (body.length > inputBytes) throw const ModelFailure('inputLimit');
    final life = _RequestLife(cancel, idleTimeout);
    var complete = false;
    _active.add(life);
    try {
      final key = await life.wait(readKey(request.profile.identity));
      life.check();
      final value = key?.reveal();
      if (value != null &&
          (value.trim().isEmpty || value.length > 8192 || RegExp(r'[\x00-\x20\x7f-\x9f]').hasMatch(value))) {
        throw const ModelFailure('invalidModelKey');
      }
      final client = _clientFactory();
      life.client = client;
      client.connectionTimeout = idleTimeout;
      final outgoing = await life.wait(client.postUrl(request.profile.requestUri));
      life.check();
      outgoing.followRedirects = false;
      outgoing.maxRedirects = 0;
      outgoing.headers.contentType = ContentType.json;
      outgoing.headers.set(HttpHeaders.acceptHeader, 'text/event-stream');
      if (request.profile.protocol == ModelProtocol.anthropic) {
        outgoing.headers.set('anthropic-version', '2023-06-01');
        if (value != null) outgoing.headers.set('x-api-key', value);
      } else if (value != null) {
        outgoing.headers.set(HttpHeaders.authorizationHeader, 'Bearer $value');
      }
      outgoing.contentLength = body.length;
      outgoing.add(body);
      final response = await life.wait(outgoing.close());
      life.check();
      if (response.statusCode != HttpStatus.ok) {
        throw ModelFailure(
          'modelHttpError',
          statusCode: response.statusCode,
          retryAfter: _retryAfter(response.headers),
        );
      }
      if (response.headers.contentType?.mimeType.toLowerCase() != 'text/event-stream') {
        throw const ModelFailure('invalidModelContentType');
      }
      final allowedTools = {for (final tool in request.tools) tool.name};
      await for (final event in decodeModelStream(request.profile, life.watch(response))) {
        life.check();
        if (event is ModelMessageComplete && event.message.calls.any((call) => !allowedTools.contains(call.name))) {
          throw const ModelFailure('unrequestedModelTool');
        }
        if (event is ModelMessageComplete) complete = true;
        yield event;
      }
    } on ModelFailure {
      life.check();
      rethrow;
    } on Object {
      life.check();
      throw const ModelFailure('modelNetworkError');
    } finally {
      if (!complete) life.abort('cancelled');
      life.dispose();
      _active.remove(life);
    }
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    for (final life in _active.toList()) {
      life.abort('cancelled');
    }
  }

  static Duration? _retryAfter(HttpHeaders headers) {
    final raw = headers.value(HttpHeaders.retryAfterHeader);
    if (raw == null || raw.length > 128) return null;
    final seconds = int.tryParse(raw);
    if (seconds != null) return Duration(seconds: seconds.clamp(0, 86400));
    try {
      final duration = HttpDate.parse(raw).difference(DateTime.now().toUtc());
      return Duration(seconds: duration.inSeconds.clamp(0, 86400));
    } on Object {
      return null;
    }
  }
}

class _CancelWatch {
  void Function()? action;
  void fire() => action?.call();
}

class _RequestLife {
  _RequestLife(CancellationToken cancel, this.timeout) {
    final watch = _watch;
    watch.action = () => abort('cancelled');
    unawaited(cancel.whenCancelled.then((_) => watch.fire()));
    touch();
    if (cancel.isCancelled) abort('cancelled');
  }

  final Duration timeout;
  final _watch = _CancelWatch();
  final _aborted = Completer<void>();
  HttpClient? client;
  Timer? _timer;
  String? _failure;

  void touch() {
    _timer?.cancel();
    _timer = Timer(timeout, () => abort('modelTimedOut'));
  }

  void abort(String code) {
    if (_failure != null) return;
    _failure = code;
    _timer?.cancel();
    client?.close(force: true);
    _aborted.complete();
  }

  void check() {
    if (_failure case final failure?) throw ModelFailure(failure);
  }

  Future<T> wait<T>(Future<T> pending) async {
    check();
    late final T value;
    try {
      value = await Future.any<T>([
        pending,
        _aborted.future.then<T>((_) => throw ModelFailure(_failure ?? 'cancelled')),
      ]);
    } on Object {
      check();
      rethrow;
    }
    check();
    touch();
    return value;
  }

  Stream<List<int>> watch(Stream<List<int>> incoming) {
    late StreamController<List<int>> controller;
    StreamSubscription<List<int>>? subscription;
    var finished = false;
    void finish([Object? error, StackTrace? stack]) {
      if (finished) return;
      finished = true;
      if (error != null) controller.addError(error, stack);
      unawaited(controller.close());
      unawaited(subscription?.cancel());
    }

    controller = StreamController<List<int>>(
      sync: true,
      onListen: () {
        subscription = incoming.listen(
          (bytes) {
            if (finished) return;
            touch();
            controller.add(bytes);
          },
          onError: (Object error, StackTrace stack) => finish(error, stack),
          onDone: () => finish(),
        );
        unawaited(_aborted.future.then((_) => finish(ModelFailure(_failure ?? 'cancelled'))));
      },
      onPause: () => subscription?.pause(),
      onResume: () => subscription?.resume(),
      onCancel: () {
        finished = true;
        return subscription?.cancel();
      },
    );
    return controller.stream;
  }

  void dispose() {
    _watch.action = null;
    _timer?.cancel();
    client?.close(force: true);
    client = null;
  }
}

/// Kept in the adapter: callers cannot fabricate or inspect protocol continuation.
class _AnthropicContinuation {
  _AnthropicContinuation(this.identity, this.blocks, String text, List<ModelCall> calls)
    : fingerprint = jsonEncode([
        text,
        for (final call in calls) [call.id, call.name, call.arguments],
      ]);
  final String identity;
  final List<Map<String, Object?>> blocks;
  final String fingerprint;

  bool matches(ModelMessage message) =>
      fingerprint ==
      jsonEncode([
        message.text,
        for (final call in message.calls) [call.id, call.name, call.arguments],
      ]);
}

int estimateModelRequestBytes(ModelRequest request) {
  try {
    return utf8.encode(jsonEncode(encodeModelRequest(request))).length;
  } on ModelFailure catch (error) {
    if (error.code == 'modelContextTooLarge') return (2 << 20) + 1;
    rethrow;
  }
}

Map<String, Object?> encodeModelRequest(ModelRequest request) {
  if (request.messages.isEmpty ||
      request.messages.length > 200 ||
      request.tools.length > 64 ||
      (!request.profile.tools && request.tools.isNotEmpty)) {
    throw const ModelFailure('invalidModelRequest');
  }
  final names = <String>{};
  for (final tool in request.tools) {
    if (!_toolName.hasMatch(tool.name) ||
        !names.add(tool.name) ||
        tool.description.length > 4096 ||
        utf8.encode(jsonEncode(tool.schema)).length > _argumentLimit) {
      throw const ModelFailure('invalidModelRequest');
    }
  }
  _validateMessages(request.messages, request.profile);
  return switch (request.profile.protocol) {
    ModelProtocol.anthropic => {
      'model': request.profile.model,
      'system': request.system,
      'max_tokens': request.profile.maxOutputTokens,
      'stream': true,
      'messages': _anthropicMessages(request.messages, request.profile),
      if (request.tools.isNotEmpty)
        'tools': [
          for (final tool in request.tools)
            {'name': tool.name, 'description': tool.description, 'input_schema': tool.schema},
        ],
    },
    ModelProtocol.openai => {
      'model': request.profile.model,
      'max_tokens': request.profile.maxOutputTokens,
      'stream': true,
      'messages': [
        if (request.system.isNotEmpty) {'role': 'system', 'content': request.system},
        for (final message in request.messages)
          {
            'role': message.role.name,
            'content': message.text,
            if (message.role == ModelRole.tool) 'tool_call_id': message.toolCallId,
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
      if (request.tools.isNotEmpty)
        'tools': [
          for (final tool in request.tools)
            {
              'type': 'function',
              'function': {'name': tool.name, 'description': tool.description, 'parameters': tool.schema},
            },
        ],
    },
  };
}

void _validateMessages(List<ModelMessage> messages, ModelProfile profile) {
  final pending = <String>{};
  final seen = <String>{};
  var bytes = 0;
  for (final message in messages) {
    bytes += utf8.encode(message.text).length;
    if (message.calls.length > 8 ||
        (message.calls.isNotEmpty && message.role != ModelRole.assistant) ||
        (message.role != ModelRole.tool && message.toolCallId != null)) {
      throw const ModelFailure('invalidModelRequest');
    }
    if (message.opaque case final continuation?) {
      if (message.role != ModelRole.assistant ||
          profile.protocol != ModelProtocol.anthropic ||
          continuation is! _AnthropicContinuation ||
          continuation.identity != profile.identity ||
          !continuation.matches(message)) {
        throw const ModelFailure('invalidModelContinuation');
      }
      bytes += utf8.encode(jsonEncode(continuation.blocks)).length;
    }
    if (message.role == ModelRole.tool) {
      if (!pending.remove(message.toolCallId)) throw const ModelFailure('invalidToolPairing');
    } else if (pending.isNotEmpty) {
      throw const ModelFailure('invalidToolPairing');
    }
    for (final call in message.calls) {
      final argumentBytes = utf8.encode(jsonEncode(call.arguments)).length;
      if (!_callId.hasMatch(call.id) ||
          !_toolName.hasMatch(call.name) ||
          !seen.add(call.id) ||
          argumentBytes > _argumentLimit) {
        throw const ModelFailure('invalidModelRequest');
      }
      pending.add(call.id);
      bytes += argumentBytes;
    }
    if (bytes > 2 << 20) throw const ModelFailure('modelContextTooLarge');
  }
  if (pending.isNotEmpty) throw const ModelFailure('invalidToolPairing');
}

List<Map<String, Object?>> _anthropicMessages(List<ModelMessage> messages, ModelProfile profile) {
  final encoded = <Map<String, Object?>>[];
  for (final message in messages) {
    if (message.role == ModelRole.tool) {
      final result = <String, Object?>{
        'type': 'tool_result',
        'tool_use_id': message.toolCallId,
        'content': message.text,
        'is_error': message.isError,
      };
      if (encoded.lastOrNull?['role'] == 'user' &&
          (encoded.last['content'] as List).firstOrNull is Map &&
          ((encoded.last['content'] as List).first as Map)['type'] == 'tool_result') {
        (encoded.last['content'] as List).add(result);
      } else {
        encoded.add({
          'role': 'user',
          'content': [result],
        });
      }
      continue;
    }
    final continuation = message.opaque;
    final content = continuation is _AnthropicContinuation
        ? continuation.blocks
        : <Map<String, Object?>>[
            if (message.text.isNotEmpty) {'type': 'text', 'text': message.text},
            for (final call in message.calls)
              {'type': 'tool_use', 'id': call.id, 'name': call.name, 'input': call.arguments},
          ];
    encoded.add({'role': message.role.name, 'content': content});
  }
  return encoded;
}

Stream<ModelEvent> decodeModelStream(ModelProfile profile, Stream<List<int>> bytes) async* {
  final parser = profile.protocol == ModelProtocol.anthropic ? _AnthropicParser(profile.identity) : _OpenAiParser();
  try {
    await for (final event in decodeSse(bytes)) {
      for (final result in parser.add(event)) {
        yield result;
      }
      if (parser.complete) return;
    }
    throw const ModelFailure('incompleteModelStream');
  } on ModelFailure {
    rethrow;
  } on Object {
    throw const ModelFailure('invalidModelStream');
  }
}

abstract class _ProtocolParser {
  var complete = false;
  var bytes = 0;
  Iterable<ModelEvent> add(SseEvent event);
  void count(Object? value) {
    bytes += utf8.encode(value is String ? value : jsonEncode(value)).length;
    if (bytes > _messageLimit) throw const ModelFailure('modelMessageTooLarge');
  }

  Map<String, Object?> object(String value) {
    final decoded = jsonDecode(value);
    if (decoded is! Map<String, dynamic>) throw const ModelFailure('invalidModelStream');
    return decoded;
  }
}

class _AnthropicBlock {
  _AnthropicBlock(this.value);
  final Map<String, Object?> value;
  final arguments = StringBuffer();
  var closed = false;
  var argumentBytes = 0;
}

class _AnthropicParser extends _ProtocolParser {
  _AnthropicParser(this.identity);
  final String identity;
  final blocks = <_AnthropicBlock>[];
  var started = false;
  String? reason;

  @override
  Iterable<ModelEvent> add(SseEvent event) sync* {
    if (event.event == 'ping') return;
    if (event.event == 'error') throw const ModelFailure('modelStreamError');
    final value = object(event.data);
    final type = value['type'];
    if (event.event != null && event.event != type) throw const ModelFailure('invalidModelStream');
    if (type == 'message_start') {
      final message = value['message'];
      if (started ||
          message is! Map ||
          message['role'] != 'assistant' ||
          message['content'] is! List ||
          (message['content'] as List).isNotEmpty) {
        throw const ModelFailure('invalidModelStream');
      }
      started = true;
      final usage = message['usage'];
      if (usage is Map) yield _usage(usage, anthropic: true);
      return;
    }
    if (!started || complete) throw const ModelFailure('invalidModelStream');
    if (type == 'content_block_start') {
      final index = value['index'];
      final block = value['content_block'];
      if (reason != null || index != blocks.length || block is! Map<String, dynamic> || blocks.length >= 64) {
        throw const ModelFailure('invalidModelStream');
      }
      final copy = Map<String, Object?>.from(block);
      switch (copy['type']) {
        case 'text':
          if (copy['text'] is! String) throw const ModelFailure('invalidModelStream');
          if ((copy['text'] as String).isNotEmpty) yield ModelTextDelta(copy['text'] as String);
        case 'tool_use':
          if (copy['id'] is! String ||
              !_callId.hasMatch(copy['id'] as String) ||
              copy['name'] is! String ||
              !_toolName.hasMatch(copy['name'] as String) ||
              copy['input'] is! Map) {
            throw const ModelFailure('invalidModelStream');
          }
        case 'thinking':
          if (copy['thinking'] is! String || copy['signature'] is! String) {
            throw const ModelFailure('invalidModelStream');
          }
        case 'redacted_thinking':
          if (copy['data'] is! String) throw const ModelFailure('invalidModelStream');
        default:
          throw const ModelFailure('unsupportedModelContent');
      }
      count(copy);
      blocks.add(_AnthropicBlock(copy));
      return;
    }
    if (type == 'content_block_delta' || type == 'content_block_stop') {
      final index = value['index'];
      if (reason != null || index is! int || index < 0 || index >= blocks.length || blocks[index].closed) {
        throw const ModelFailure('invalidModelStream');
      }
      final block = blocks[index];
      if (type == 'content_block_stop') {
        block.closed = true;
        if (block.value['type'] == 'tool_use') {
          if (block.arguments.isNotEmpty) {
            if ((block.value['input'] as Map).isNotEmpty) throw const ModelFailure('invalidModelStream');
            block.value['input'] = _arguments(block.arguments.toString());
          } else {
            block.value['input'] = _arguments(jsonEncode(block.value['input']));
          }
        }
        if (block.value['type'] == 'thinking' && (block.value['signature'] as String).isEmpty) {
          throw const ModelFailure('invalidModelContinuation');
        }
        return;
      }
      final delta = value['delta'];
      if (delta is! Map) throw const ModelFailure('invalidModelStream');
      final (field, expected) = switch (delta['type']) {
        'text_delta' => ('text', 'text'),
        'thinking_delta' => ('thinking', 'thinking'),
        'signature_delta' => ('signature', 'thinking'),
        'input_json_delta' => ('partial_json', 'tool_use'),
        _ => throw const ModelFailure('unsupportedModelContent'),
      };
      final fragment = delta[field];
      if (block.value['type'] != expected || fragment is! String) throw const ModelFailure('invalidModelStream');
      count(fragment);
      if (field == 'partial_json') {
        block.argumentBytes += utf8.encode(fragment).length;
        if (block.argumentBytes > _argumentLimit) throw const ModelFailure('modelArgumentsTooLarge');
        block.arguments.write(fragment);
      } else {
        block.value[field] = '${block.value[field]}$fragment';
        if (field == 'text') yield ModelTextDelta(fragment);
      }
      return;
    }
    if (type == 'message_delta') {
      final delta = value['delta'];
      if (reason != null || blocks.any((block) => !block.closed) || delta is! Map || delta['stop_reason'] is! String) {
        throw const ModelFailure('invalidModelStream');
      }
      reason = delta['stop_reason'] as String;
      if (!{'end_turn', 'stop_sequence', 'tool_use'}.contains(reason)) {
        throw ModelFailure(reason == 'max_tokens' ? 'modelTruncated' : 'unsupportedModelStop');
      }
      final usage = value['usage'];
      if (usage is Map) yield _usage(usage, anthropic: true);
      return;
    }
    if (type == 'message_stop') {
      if (reason == null || blocks.any((block) => !block.closed)) throw const ModelFailure('incompleteModelStream');
      final calls = <ModelCall>[];
      final text = StringBuffer();
      for (final block in blocks) {
        if (block.value['type'] == 'text') text.write(block.value['text']);
        if (block.value['type'] == 'tool_use') {
          final input = block.value['input'];
          if (input is! Map<String, dynamic> && input is! Map<String, Object?>) {
            throw const ModelFailure('invalidModelStream');
          }
          calls.add(
            ModelCall(
              block.value['id'] as String,
              block.value['name'] as String,
              Map<String, Object?>.from(input as Map),
            ),
          );
        }
      }
      _validateCalls(calls, reason == 'tool_use');
      complete = true;
      yield ModelMessageComplete(
        ModelMessage(
          ModelRole.assistant,
          text: text.toString(),
          calls: calls,
          opaque: _AnthropicContinuation(
            identity,
            [for (final block in blocks) Map.unmodifiable(block.value)],
            text.toString(),
            calls,
          ),
        ),
      );
      return;
    }
    throw const ModelFailure('unsupportedModelEvent');
  }
}

class _OpenAiCall {
  String? id;
  final name = StringBuffer();
  final arguments = StringBuffer();
  var argumentBytes = 0;
}

class _OpenAiParser extends _ProtocolParser {
  final text = StringBuffer();
  final calls = <int, _OpenAiCall>{};
  String? reason;
  String? messageId;
  var started = false;

  @override
  Iterable<ModelEvent> add(SseEvent event) sync* {
    if (event.data == '[DONE]') {
      if (!started || reason == null) throw const ModelFailure('incompleteModelStream');
      final sorted = calls.keys.toList()..sort();
      if (sorted.indexed.any((item) => item.$1 != item.$2)) throw const ModelFailure('invalidModelStream');
      final completedCalls = [
        for (final index in sorted)
          ModelCall(
            calls[index]!.id ?? '',
            calls[index]!.name.toString(),
            _arguments(calls[index]!.arguments.toString()),
          ),
      ];
      _validateCalls(completedCalls, reason == 'tool_calls');
      complete = true;
      yield ModelMessageComplete(ModelMessage(ModelRole.assistant, text: text.toString(), calls: completedCalls));
      return;
    }
    final value = object(event.data);
    if (value.containsKey('error')) throw const ModelFailure('modelStreamError');
    final id = value['id'];
    if (id != null && (id is! String || id.length > 256 || (messageId != null && id != messageId))) {
      throw const ModelFailure('invalidModelStream');
    }
    messageId ??= id as String?;
    final usage = value['usage'];
    if (usage is Map) yield _usage(usage, anthropic: false);
    final choices = value['choices'];
    if (choices is! List || choices.length > 1) throw const ModelFailure('invalidModelStream');
    if (choices.isEmpty) return;
    final choice = choices.single;
    if (choice is! Map || choice['index'] != 0 || reason != null) throw const ModelFailure('invalidModelStream');
    final delta = choice['delta'];
    if (delta is! Map ||
        (delta['role'] != null && delta['role'] != 'assistant') ||
        delta.containsKey('function_call')) {
      throw const ModelFailure('invalidModelStream');
    }
    started = true;
    final content = delta['content'];
    if (content != null && content is! String) throw const ModelFailure('unsupportedModelContent');
    if (content is String) {
      count(content);
      text.write(content);
      if (content.isNotEmpty) yield ModelTextDelta(content);
    }
    if (delta['refusal'] != null) throw const ModelFailure('modelRefused');
    // Compatible providers may send internal reasoning deltas. They consume the message budget, never UI text.
    if (delta['reasoning_content'] != null) count(delta['reasoning_content']);
    final toolCalls = delta['tool_calls'];
    if (toolCalls != null) {
      if (toolCalls is! List || toolCalls.length > 8) throw const ModelFailure('invalidModelStream');
      for (final fragment in toolCalls) {
        if (fragment is! Map ||
            fragment['index'] is! int ||
            (fragment['index'] as int) < 0 ||
            (fragment['index'] as int) >= 8 ||
            (fragment['type'] != null && fragment['type'] != 'function')) {
          throw const ModelFailure('invalidModelStream');
        }
        final call = calls.putIfAbsent(fragment['index'] as int, _OpenAiCall.new);
        final id = fragment['id'];
        if (id != null) {
          if (id is! String || !_callId.hasMatch(id) || (call.id != null && call.id != id)) {
            throw const ModelFailure('invalidModelStream');
          }
          if (call.id == null) count(id);
          call.id = id;
        }
        final function = fragment['function'];
        if (function != null) {
          if (function is! Map) throw const ModelFailure('invalidModelStream');
          final name = function['name'];
          if (name != null) {
            if (name is! String || call.name.length + name.length > 64) throw const ModelFailure('invalidModelStream');
            call.name.write(name);
            count(name);
          }
          final arguments = function['arguments'];
          if (arguments != null) {
            if (arguments is! String) throw const ModelFailure('invalidModelStream');
            call.argumentBytes += utf8.encode(arguments).length;
            if (call.argumentBytes > _argumentLimit) throw const ModelFailure('modelArgumentsTooLarge');
            call.arguments.write(arguments);
            count(arguments);
          }
        }
      }
    }
    final finished = choice['finish_reason'];
    if (finished != null) {
      if (finished is! String || !{'stop', 'tool_calls'}.contains(finished)) {
        throw ModelFailure(finished == 'length' ? 'modelTruncated' : 'unsupportedModelStop');
      }
      reason = finished;
    }
  }
}

Map<String, Object?> _arguments(String encoded) {
  if (utf8.encode(encoded).length > _argumentLimit) throw const ModelFailure('modelArgumentsTooLarge');
  final value = jsonDecode(encoded);
  if (value is! Map<String, dynamic>) throw const ModelFailure('invalidModelArguments');
  final pending = <(Object?, int)>[(value, 0)];
  while (pending.isNotEmpty) {
    final (node, depth) = pending.removeLast();
    if (depth > 32) throw const ModelFailure('invalidModelArguments');
    if (node is Map) {
      pending.addAll(node.values.map((value) => (value, depth + 1)));
    } else if (node is List) {
      pending.addAll(node.map((value) => (value, depth + 1)));
    }
  }
  return value;
}

void _validateCalls(List<ModelCall> calls, bool toolReason) {
  if (calls.length > 8 ||
      calls.isNotEmpty != toolReason ||
      calls.map((call) => call.id).toSet().length != calls.length ||
      calls.any((call) => !_callId.hasMatch(call.id) || !_toolName.hasMatch(call.name))) {
    throw const ModelFailure('invalidModelStream');
  }
}

ModelUsage _usage(Map usage, {required bool anthropic}) {
  final input = usage[anthropic ? 'input_tokens' : 'prompt_tokens'];
  final output = usage[anthropic ? 'output_tokens' : 'completion_tokens'];
  if ((input != null && (input is! int || input < 0)) || (output != null && (output is! int || output < 0))) {
    throw const ModelFailure('invalidModelStream');
  }
  return ModelUsage(inputTokens: input as int?, outputTokens: output as int?);
}

import 'dart:convert';

/// Each protocol has its own request and continuation format.
enum ModelProtocol { anthropic, openai, responses }

/// [off] sends the protocol's explicit "no thinking" request; [modelDefault] sends nothing.
enum ReasoningEffort { modelDefault, off, low, medium, high }

String? terminalModelDestination(ModelProfile? profile, String? inlineModel, String? completionModel) {
  if (profile == null) return null;
  final inline = profile.withModel(inlineModel ?? profile.model).identity;
  final completion = profile.withModel(completionModel ?? profile.model).identity;
  return inline == profile.identity && completion == profile.identity
      ? profile.identity
      : jsonEncode([profile.identity, inline, completion]);
}

class ModelProfile {
  ModelProfile({
    required this.protocol,
    required String endpoint,
    required this.model,
    this.tools = true,
    this.maxOutputTokens = 4096,
    this.contextWindow = 1000000,
    this.reasoningEffort = ReasoningEffort.modelDefault,
  }) : endpoint = normalizeEndpoint(endpoint) {
    if (model.trim().isEmpty ||
        model != model.trim() ||
        model.length > 256 ||
        _controls.hasMatch(model) ||
        maxOutputTokens < 1 ||
        maxOutputTokens > 65536 ||
        contextWindow < 1024 ||
        contextWindow > 2000000 ||
        maxOutputTokens >= contextWindow) {
      throw const FormatException('invalidModelProfile');
    }
  }

  final ModelProtocol protocol;
  final String endpoint;
  final String model;
  final bool tools;
  final int maxOutputTokens;
  final int contextWindow;
  final ReasoningEffort reasoningEffort;

  ModelProfile withModel(String model, {bool? tools, ReasoningEffort? reasoningEffort}) => ModelProfile(
    protocol: protocol,
    endpoint: endpoint,
    model: model,
    tools: tools ?? this.tools,
    maxOutputTokens: maxOutputTokens,
    contextWindow: contextWindow,
    reasoningEffort: reasoningEffort ?? this.reasoningEffort,
  );

  /// Credentials and active continuation are tied to this exact destination.
  String get identity => jsonEncode([protocol.name, endpoint, model]);

  Uri get requestUri => Uri.parse(
    '$endpoint/${switch (protocol) {
      ModelProtocol.anthropic => 'messages',
      ModelProtocol.openai => 'chat/completions',
      ModelProtocol.responses => 'responses',
    }}',
  );

  Map<String, Object?> toJson() => {
    'protocol': protocol.name,
    'endpoint': endpoint,
    'model': model,
    'tools': tools,
    'maxOutputTokens': maxOutputTokens,
    'contextWindow': contextWindow,
    if (reasoningEffort != ReasoningEffort.modelDefault) 'reasoningEffort': reasoningEffort.name,
  };

  factory ModelProfile.fromJson(Map<String, Object?> json) {
    const keys = {'protocol', 'endpoint', 'model', 'tools', 'maxOutputTokens', 'contextWindow', 'reasoningEffort'};
    if (json.keys.any((key) => !keys.contains(key)) ||
        json['protocol'] is! String ||
        json['endpoint'] is! String ||
        json['model'] is! String ||
        (json.containsKey('tools') && json['tools'] is! bool) ||
        (json.containsKey('maxOutputTokens') && json['maxOutputTokens'] is! int) ||
        (json.containsKey('contextWindow') && json['contextWindow'] is! int) ||
        (json.containsKey('reasoningEffort') &&
            !ReasoningEffort.values.any((effort) => effort.name == json['reasoningEffort']))) {
      throw const FormatException('invalidModelProfile');
    }
    final protocol = ModelProtocol.values.asNameMap()[json['protocol']];
    if (protocol == null) throw const FormatException('invalidModelProfile');
    return ModelProfile(
      protocol: protocol,
      endpoint: json['endpoint'] as String,
      model: json['model'] as String,
      tools: json['tools'] as bool? ?? true,
      maxOutputTokens: json['maxOutputTokens'] as int? ?? 4096,
      contextWindow: json['contextWindow'] as int? ?? 1000000,
      reasoningEffort: ReasoningEffort.values.asNameMap()[json['reasoningEffort']] ?? ReasoningEffort.modelDefault,
    );
  }

  static final _controls = RegExp(r'[\x00-\x20\x7f-\x9f]');

  static String normalizeEndpoint(String value) {
    if (value.isEmpty || value.length > 2048 || _controls.hasMatch(value) || value.contains('\\')) {
      throw const FormatException('invalidModelEndpoint');
    }
    // Uri.parse normalizes literal dot segments, so inspect the supplied path first.
    final authority = value.indexOf('://');
    final pathStart = authority < 0 ? -1 : value.indexOf('/', authority + 3);
    if (pathStart >= 0) {
      try {
        final rawPath = value.substring(pathStart).split(RegExp(r'[?#]')).first;
        for (final segment in rawPath.split('/')) {
          final decoded = Uri.decodeComponent(segment);
          if (decoded == '.' ||
              decoded == '..' ||
              decoded.contains('/') ||
              decoded.contains('\\') ||
              _controls.hasMatch(decoded)) {
            throw const FormatException('invalidModelEndpoint');
          }
        }
      } on FormatException {
        throw const FormatException('invalidModelEndpoint');
      }
    }
    final uri = Uri.tryParse(value);
    if (uri == null ||
        !uri.hasAuthority ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        !{'https', 'http'}.contains(uri.scheme) ||
        uri.port < 1 ||
        uri.port > 65535 ||
        (uri.scheme == 'http' && !{'localhost', '127.0.0.1', '::1', '[::1]'}.contains(uri.host))) {
      throw const FormatException('invalidModelEndpoint');
    }
    if (uri.pathSegments.any((segment) => segment == '.' || segment == '..' || _controls.hasMatch(segment))) {
      throw const FormatException('invalidModelEndpoint');
    }
    var path = uri.path;
    while (path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    return uri.replace(path: path).toString();
  }
}

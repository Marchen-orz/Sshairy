import 'dart:convert';

/// Each protocol has its own request and continuation format.
enum ModelProtocol { anthropic, openai }

class ModelProfile {
  ModelProfile({
    required this.protocol,
    required String endpoint,
    required this.model,
    this.tools = false,
    this.maxOutputTokens = 4096,
    this.contextWindow = 32768,
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

  /// Credentials and active continuation are tied to this exact destination.
  String get identity => jsonEncode([protocol.name, endpoint, model]);

  Uri get requestUri => Uri.parse('$endpoint/${protocol == ModelProtocol.anthropic ? 'messages' : 'chat/completions'}');

  Map<String, Object?> toJson() => {
    'protocol': protocol.name,
    'endpoint': endpoint,
    'model': model,
    'tools': tools,
    'maxOutputTokens': maxOutputTokens,
    'contextWindow': contextWindow,
  };

  factory ModelProfile.fromJson(Map<String, Object?> json) {
    const keys = {'protocol', 'endpoint', 'model', 'tools', 'maxOutputTokens', 'contextWindow'};
    if (json.keys.any((key) => !keys.contains(key)) ||
        json['protocol'] is! String ||
        json['endpoint'] is! String ||
        json['model'] is! String ||
        (json.containsKey('tools') && json['tools'] is! bool) ||
        (json.containsKey('maxOutputTokens') && json['maxOutputTokens'] is! int) ||
        (json.containsKey('contextWindow') && json['contextWindow'] is! int)) {
      throw const FormatException('invalidModelProfile');
    }
    final protocol = ModelProtocol.values.asNameMap()[json['protocol']];
    if (protocol == null) throw const FormatException('invalidModelProfile');
    return ModelProfile(
      protocol: protocol,
      endpoint: json['endpoint'] as String,
      model: json['model'] as String,
      tools: json['tools'] as bool? ?? false,
      maxOutputTokens: json['maxOutputTokens'] as int? ?? 4096,
      contextWindow: json['contextWindow'] as int? ?? 32768,
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

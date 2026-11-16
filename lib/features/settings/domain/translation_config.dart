enum TranslationProvider { myMemory, deepL, google, microsoft, openAi }

/// Nonsecret translation settings; credentials live only in secure storage.
class TranslationConfig {
  const TranslationConfig({
    this.provider = TranslationProvider.myMemory,
    this.endpoint = '',
    this.model = '',
    this.region = '',
    this.deepLFree = true,
    this.myMemoryEmail = '',
  });

  final TranslationProvider provider;
  final String endpoint, model, region, myMemoryEmail;
  final bool deepLFree;

  static final _model = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:/-]{0,127}$');
  static final _region = RegExp(r'^[a-z0-9][a-z0-9-]{0,63}$');
  static final _unsafeUrl = RegExp(r'[\s\x00-\x1f\x7f-\x9f\\]');
  static bool _hasUnsafeUrl(String value) =>
      _unsafeUrl.hasMatch(value) ||
      value.runes.any(
        (code) =>
            (code >= 0x200b && code <= 0x200f) ||
            (code >= 0x202a && code <= 0x202e) ||
            (code >= 0x2060 && code <= 0x206f) ||
            code == 0xfeff,
      );
  static const _keys = {'provider', 'endpoint', 'model', 'region', 'deepLFree'};
  static final _emailLocal = RegExp(r"^[A-Za-z0-9!#$%&'*+/=?^_`{|}~.-]+$");
  static final _emailLabel = RegExp(r'^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?$');

  static bool validMyMemoryEmail(String value) {
    if (value.isEmpty) return true;
    if (value.length > 254 || value.codeUnits.any((code) => code < 33 || code > 126)) return false;
    final parts = value.split('@');
    if (parts.length != 2) return false;
    final local = parts[0], domain = parts[1];
    if (local.isEmpty ||
        local.length > 64 ||
        _emailLocal.stringMatch(local) != local ||
        local.startsWith('.') ||
        local.endsWith('.') ||
        local.contains('..')) {
      return false;
    }
    final labels = domain.split('.');
    return labels.length >= 2 && labels.every((label) => _emailLabel.stringMatch(label) == label);
  }

  static bool validModel(String value) => _model.stringMatch(value) == value;
  static bool validRegion(String value) => value.isEmpty || _region.stringMatch(value) == value;

  static bool validEndpoint(String value) {
    if (value.isEmpty ||
        value.length > 2048 ||
        _hasUnsafeUrl(value) ||
        RegExp(r'%(?![0-9A-Fa-f]{2})').hasMatch(value)) {
      return false;
    }
    try {
      final authority = RegExp(r'^[A-Za-z][A-Za-z0-9+.-]*://([^/?#]*)').firstMatch(value)?.group(1);
      if (authority == null || authority.contains('@')) return false;
      final uri = Uri.tryParse(value);
      if (uri != null && _hasUnsafeUrl(Uri.decodeComponent(uri.toString()))) return false;
      if (uri == null ||
          !uri.hasAuthority ||
          uri.host.isEmpty ||
          uri.authority.contains('@') ||
          uri.hasQuery ||
          uri.hasFragment ||
          (uri.hasPort && (uri.port < 1 || uri.port > 65535))) {
        return false;
      }
      final host = uri.host.toLowerCase().replaceAll('[', '').replaceAll(']', '');
      final secure =
          uri.scheme == 'https' || (uri.scheme == 'http' && {'localhost', '127.0.0.1', '::1'}.contains(host));
      return secure && 'openAi:${_canonicalEndpoint(uri)}'.length <= 2048;
    } on FormatException {
      return false;
    } on ArgumentError {
      return false;
    }
  }

  bool get isValid =>
      (provider == TranslationProvider.myMemory ? validMyMemoryEmail(myMemoryEmail) : myMemoryEmail.isEmpty) &&
      switch (provider) {
        TranslationProvider.openAi => validEndpoint(endpoint) && validModel(model) && region.isEmpty,
        TranslationProvider.microsoft => endpoint.isEmpty && model.isEmpty && validRegion(region),
        _ => endpoint.isEmpty && model.isEmpty && region.isEmpty,
      };

  /// The API base URL, including its path (/v1 when unversioned); the router adds /chat/completions.
  String get canonicalEndpoint => validEndpoint(endpoint) ? _canonicalEndpoint(Uri.parse(endpoint)) : '';

  static String _canonicalEndpoint(Uri value) {
    final uri = value.normalizePath();
    final port = uri.hasPort && uri.port != (uri.scheme == 'https' ? 443 : 80) ? uri.port : null;
    final path = uri.path.replaceFirst(RegExp(r'/+$'), '');
    // A base URL without a version segment such as v1 or v1beta gets the common /v1.
    final versioned = uri.pathSegments.any(RegExp(r'^v\d').hasMatch);
    return Uri(
      scheme: uri.scheme.toLowerCase(),
      host: uri.host.toLowerCase(),
      port: port,
      path: versioned ? path : '$path/v1',
    ).toString();
  }

  /// Endpoint changes must never silently reuse a key saved for another destination.
  String get credentialId => switch (provider) {
    TranslationProvider.myMemory => 'myMemory',
    TranslationProvider.deepL => deepLFree ? 'deepL:free' : 'deepL:pro',
    TranslationProvider.google => 'google',
    TranslationProvider.microsoft => 'microsoft:$region',
    TranslationProvider.openAi => 'openAi:$canonicalEndpoint',
  };

  factory TranslationConfig.fromJson(Object? json) {
    if (json is! Map ||
        (json.length != _keys.length && json.length != _keys.length + 1) ||
        !_keys.every(json.containsKey) ||
        !json.keys.every((key) => _keys.contains(key) || key == 'myMemoryEmail') ||
        (json.containsKey('myMemoryEmail') && json['myMemoryEmail'] is! String) ||
        json['provider'] is! String ||
        json['endpoint'] is! String ||
        json['model'] is! String ||
        json['region'] is! String ||
        json['deepLFree'] is! bool) {
      throw const FormatException('invalid translation config');
    }
    final provider = TranslationProvider.values.where((value) => value.name == json['provider']).firstOrNull;
    if (provider == null) throw const FormatException('invalid translation provider');
    final config = TranslationConfig(
      provider: provider,
      endpoint: json['endpoint'] as String,
      model: json['model'] as String,
      region: json['region'] as String,
      deepLFree: json['deepLFree'] as bool,
      myMemoryEmail: json['myMemoryEmail'] as String? ?? '',
    );
    if (!config.isValid) throw const FormatException('invalid translation config');
    return config;
  }

  Map<String, Object?> toJson() => {
    'provider': provider.name,
    'endpoint': endpoint,
    'model': model,
    'region': region,
    'deepLFree': deepLFree,
    'myMemoryEmail': myMemoryEmail,
  };
}

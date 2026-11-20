import '../../../foundation/ids.dart';
import '../../../foundation/json_file.dart';
import '../domain/model_profile.dart';

/// Only nonsecret user configuration lives here. A damaged file is never an empty profile.
class AiConfigStore {
  AiConfigStore(this.path) : _file = _open(path);

  final String path;
  JsonFile _file;

  static JsonFile _open(String path) =>
      JsonFile(path, backups: true, schemaVersion: 2, migrations: {1: _migrate}, validate: _validate);

  static const _keys = {
    'schemaVersion',
    'revision',
    'enabled',
    'profile',
    'inlineEnabled',
    'completionEnabled',
    'predictionEnabled',
    'inlineModel',
    'completionModel',
    'reviewModel',
  };
  static const _legacyKeys = {'completionHistory', 'completionPosix', 'completionHosts', 'terminalDestination'};
  static final _hostControls = RegExp(r'[\x00-\x20\x7f-\x9f]');

  static bool _validHost(Object? id) =>
      id is String && id.isNotEmpty && id.length <= 128 && !_hostControls.hasMatch(id);

  static ModelProfile? _validateProfile(Map<String, dynamic> json) {
    if (json['enabled'] is! bool || !json.containsKey('profile')) {
      throw const FormatException('invalid AI configuration');
    }
    final raw = json['profile'];
    ModelProfile? profile;
    if (raw != null) {
      if (raw is! Map<String, dynamic>) throw const FormatException('invalid AI profile');
      profile = ModelProfile.fromJson(raw);
    } else if (json['enabled'] == true) {
      throw const FormatException('AI profile required');
    }
    for (final key in ['inlineEnabled', 'completionEnabled', 'predictionEnabled']) {
      if (json.containsKey(key) && json[key] is! bool) throw const FormatException('invalid AI terminal setting');
    }
    for (final key in ['inlineModel', 'completionModel', 'reviewModel']) {
      final model = json[key];
      if (model != null) {
        if (model is! String || profile == null) throw const FormatException('invalid AI role model');
        profile.withModel(model);
      }
    }
    return profile;
  }

  static Map<String, dynamic> _migrate(Map<String, dynamic> json) {
    if (!json.keys.every({..._keys, ..._legacyKeys}.contains)) {
      throw const FormatException('invalid legacy AI configuration');
    }
    final profile = _validateProfile(json);
    for (final key in ['completionHistory', 'completionPosix']) {
      if (json.containsKey(key) && json[key] is! bool) throw const FormatException('invalid AI terminal policy');
    }
    final expectedDestination = terminalModelDestination(
      profile,
      json['inlineModel'] as String?,
      json['completionModel'] as String?,
    );
    final destination = json['terminalDestination'];
    if (destination != null && (destination is! String || destination != expectedDestination)) {
      throw const FormatException('AI terminal destination changed');
    }
    final hosts = json['completionHosts'];
    if (hosts != null) {
      if (hosts is! Map<String, dynamic> || hosts.length > 100) {
        throw const FormatException('invalid AI host grants');
      }
      for (final entry in hosts.entries) {
        if (!_validHost(entry.key) ||
            entry.value is! String ||
            (entry.value as String).isEmpty ||
            (entry.value as String).length > 32768 ||
            RegExp(r'[\x00-\x1f\x7f-\x9f]').hasMatch(entry.value as String)) {
          throw const FormatException('invalid AI host grant');
        }
      }
    }
    if ((json['inlineEnabled'] == true || json['completionEnabled'] == true) &&
        (profile == null || destination != expectedDestination)) {
      throw const FormatException('AI terminal destination required');
    }
    return {
      for (final entry in json.entries)
        if (!_legacyKeys.contains(entry.key)) entry.key: entry.value,
      'inlineEnabled': true,
      'completionEnabled': true,
      'inlineExcludedHosts': <String>[],
      'completionExcludedHosts': <String>[],
    };
  }

  static void _validate(Map<String, dynamic> json) {
    if (!json.keys.every({..._keys, 'inlineExcludedHosts', 'completionExcludedHosts'}.contains)) {
      throw const FormatException('invalid AI configuration');
    }
    _validateProfile(json);
    for (final key in ['inlineExcludedHosts', 'completionExcludedHosts']) {
      if (!json.containsKey(key)) continue;
      final hosts = json[key];
      if (hosts is! List || hosts.length > 10000 || !hosts.every(_validHost) || hosts.toSet().length != hosts.length) {
        throw const FormatException('invalid AI host exclusions');
      }
    }
  }

  ({
    bool enabled,
    ModelProfile? profile,
    int revision,
    bool inlineEnabled,
    bool completionEnabled,
    bool predictionEnabled,
    Set<HostId> inlineExcludedHosts,
    Set<HostId> completionExcludedHosts,
    String? inlineModel,
    String? completionModel,
    String? reviewModel,
  })
  read({bool reload = false}) {
    if (reload) _file = _open(path);
    final json = _file.read();
    final profile = json?['profile'] == null ? null : ModelProfile.fromJson(json!['profile'] as Map<String, dynamic>);
    return (
      enabled: json?['enabled'] as bool? ?? false,
      profile: profile,
      revision: _file.revision,
      inlineEnabled: json?['inlineEnabled'] as bool? ?? true,
      completionEnabled: json?['completionEnabled'] as bool? ?? true,
      predictionEnabled: json?['predictionEnabled'] as bool? ?? false,
      inlineExcludedHosts: Set<HostId>.unmodifiable({
        for (final id in json?['inlineExcludedHosts'] as List? ?? const []) HostId(id as String),
      }),
      completionExcludedHosts: Set<HostId>.unmodifiable({
        for (final id in json?['completionExcludedHosts'] as List? ?? const []) HostId(id as String),
      }),
      inlineModel: json?['inlineModel'] as String? ?? profile?.model,
      completionModel: json?['completionModel'] as String? ?? profile?.model,
      reviewModel: json?['reviewModel'] as String?,
    );
  }

  Future<void> write({
    required bool enabled,
    required ModelProfile? profile,
    required int expectedRevision,
    bool inlineEnabled = true,
    bool completionEnabled = true,
    bool predictionEnabled = false,
    Set<HostId> inlineExcludedHosts = const {},
    Set<HostId> completionExcludedHosts = const {},
    String? inlineModel,
    String? completionModel,
    String? reviewModel,
  }) => _file.write({
    'schemaVersion': 2,
    'enabled': enabled,
    'profile': profile?.toJson(),
    'inlineEnabled': inlineEnabled,
    'completionEnabled': completionEnabled,
    'predictionEnabled': predictionEnabled,
    'inlineExcludedHosts': [for (final id in inlineExcludedHosts) id.value]..sort(),
    'completionExcludedHosts': [for (final id in completionExcludedHosts) id.value]..sort(),
    'inlineModel': inlineModel,
    'completionModel': completionModel,
    'reviewModel': reviewModel,
  }, expectedRevision: expectedRevision);

  int get revision => _file.revision;
  Future<void> get saved => _file.idle;
}

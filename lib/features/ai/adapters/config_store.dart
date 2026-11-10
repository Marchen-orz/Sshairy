import '../../../foundation/ids.dart';
import '../../../foundation/json_file.dart';
import '../domain/model_profile.dart';

/// Only nonsecret user configuration lives here. A damaged file is never an empty profile.
class AiConfigStore {
  AiConfigStore(this.path) : _file = _open(path);

  final String path;
  JsonFile _file;

  static JsonFile _open(String path) => JsonFile(path, backups: true, validate: _validate);

  static void _validate(Map<String, dynamic> json) {
    const keys = {
      'schemaVersion',
      'revision',
      'enabled',
      'profile',
      'inlineEnabled',
      'completionEnabled',
      'completionHistory',
      'completionPosix',
      'completionHosts',
      'terminalDestination',
    };
    if (!json.keys.every(keys.contains) || json['enabled'] is! bool || !json.containsKey('profile')) {
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
    for (final key in ['inlineEnabled', 'completionEnabled', 'completionHistory', 'completionPosix']) {
      if (json.containsKey(key) && json[key] is! bool) throw const FormatException('invalid AI terminal policy');
    }
    final destination = json['terminalDestination'];
    if (destination != null && (destination is! String || destination != profile?.identity)) {
      throw const FormatException('AI terminal destination changed');
    }
    final hosts = json['completionHosts'];
    if (hosts != null) {
      if (hosts is! Map<String, dynamic> || hosts.length > 100) {
        throw const FormatException('invalid AI host grants');
      }
      for (final entry in hosts.entries) {
        if (entry.key.isEmpty ||
            entry.key.length > 128 ||
            RegExp(r'[\x00-\x20\x7f-\x9f]').hasMatch(entry.key) ||
            entry.value is! String ||
            (entry.value as String).isEmpty ||
            (entry.value as String).length > 32768 ||
            RegExp(r'[\x00-\x1f\x7f-\x9f]').hasMatch(entry.value as String)) {
          throw const FormatException('invalid AI host grant');
        }
      }
    }
    if ((json['inlineEnabled'] == true || json['completionEnabled'] == true) && destination != profile?.identity) {
      throw const FormatException('AI terminal destination required');
    }
  }

  ({
    bool enabled,
    ModelProfile? profile,
    int revision,
    bool inlineEnabled,
    bool completionEnabled,
    bool completionHistory,
    bool completionPosix,
    Map<HostId, String> completionHosts,
    String? terminalDestination,
  })
  read({bool reload = false}) {
    if (reload) _file = _open(path);
    final json = _file.read();
    return (
      enabled: json?['enabled'] as bool? ?? false,
      profile: json?['profile'] == null ? null : ModelProfile.fromJson(json!['profile'] as Map<String, dynamic>),
      revision: _file.revision,
      inlineEnabled: json?['inlineEnabled'] as bool? ?? false,
      completionEnabled: json?['completionEnabled'] as bool? ?? false,
      completionHistory: json?['completionHistory'] as bool? ?? false,
      completionPosix: json?['completionPosix'] as bool? ?? false,
      completionHosts: Map<HostId, String>.unmodifiable({
        for (final entry in (json?['completionHosts'] as Map<String, dynamic>? ?? const {}).entries)
          HostId(entry.key): entry.value as String,
      }),
      terminalDestination: json?['terminalDestination'] as String?,
    );
  }

  Future<void> write({
    required bool enabled,
    required ModelProfile? profile,
    required int expectedRevision,
    bool inlineEnabled = false,
    bool completionEnabled = false,
    bool completionHistory = false,
    bool completionPosix = false,
    Map<HostId, String> completionHosts = const {},
    String? terminalDestination,
  }) => _file.write({
    'schemaVersion': 1,
    'enabled': enabled,
    'profile': profile?.toJson(),
    'inlineEnabled': inlineEnabled,
    'completionEnabled': completionEnabled,
    'completionHistory': completionHistory,
    'completionPosix': completionPosix,
    'completionHosts': {for (final entry in completionHosts.entries) entry.key.value: entry.value},
    'terminalDestination': terminalDestination,
  }, expectedRevision: expectedRevision);

  int get revision => _file.revision;
  Future<void> get saved => _file.idle;
}

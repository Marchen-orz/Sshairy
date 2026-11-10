import '../../../foundation/json_file.dart';
import '../domain/model_profile.dart';

/// Only nonsecret user configuration lives here. A damaged file is never an empty profile.
class AiConfigStore {
  AiConfigStore(this.path) : _file = _open(path);

  final String path;
  JsonFile _file;

  static JsonFile _open(String path) => JsonFile(path, backups: true, validate: _validate);

  static void _validate(Map<String, dynamic> json) {
    if (!json.keys.every(const {'schemaVersion', 'revision', 'enabled', 'profile'}.contains) ||
        json['enabled'] is! bool ||
        !json.containsKey('profile')) {
      throw const FormatException('invalid AI configuration');
    }
    final raw = json['profile'];
    if (raw != null) {
      if (raw is! Map<String, dynamic>) throw const FormatException('invalid AI profile');
      ModelProfile.fromJson(raw);
    } else if (json['enabled'] == true) {
      throw const FormatException('AI profile required');
    }
  }

  ({bool enabled, ModelProfile? profile, int revision}) read({bool reload = false}) {
    if (reload) _file = _open(path);
    final json = _file.read();
    return (
      enabled: json?['enabled'] as bool? ?? false,
      profile: json?['profile'] == null ? null : ModelProfile.fromJson(json!['profile'] as Map<String, dynamic>),
      revision: _file.revision,
    );
  }

  Future<void> write({required bool enabled, required ModelProfile? profile, required int expectedRevision}) =>
      _file.write({
        'schemaVersion': 1,
        'enabled': enabled,
        'profile': profile?.toJson(),
      }, expectedRevision: expectedRevision);

  int get revision => _file.revision;
  Future<void> get saved => _file.idle;
}

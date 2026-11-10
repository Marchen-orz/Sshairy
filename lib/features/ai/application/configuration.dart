import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../foundation/data_dir.dart';
import '../../../foundation/json_file.dart';
import '../adapters/config_store.dart';
import '../domain/model_profile.dart';

class AiConfiguration {
  const AiConfiguration({this.enabled = false, this.profile, this.revision = 0, this.loadFailed = false});

  final bool enabled, loadFailed;
  final ModelProfile? profile;
  final int revision;
}

final aiConfigurationProvider = NotifierProvider<AiConfigurationController, AiConfiguration>(
  AiConfigurationController.new,
);

class AiConfigurationController extends Notifier<AiConfiguration> {
  late final _store = AiConfigStore('${ref.read(dataDirProvider)}/ai.json');
  JsonFileError? _loadError;
  Future<void> _pending = Future.value(), _lastSave = Future.value();

  @override
  AiConfiguration build() => _read();

  AiConfiguration _read({bool reload = false}) {
    try {
      final value = _store.read(reload: reload);
      _loadError = null;
      return AiConfiguration(enabled: value.enabled, profile: value.profile, revision: value.revision);
    } on JsonFileError catch (error) {
      _loadError = error;
      return const AiConfiguration(loadFailed: true);
    }
  }

  void reload() => state = _read(reload: true);

  Future<void> get saved => _lastSave.then((_) => _store.saved);

  Future<void> save({required bool enabled, required ModelProfile? profile, int? expectedRevision}) {
    final next = _pending.then((_) async {
      if (_loadError case final error?) throw error;
      if (enabled && profile == null) throw ArgumentError('AI profile required');
      final checked = profile == null ? null : ModelProfile.fromJson(profile.toJson());
      await _store.write(enabled: enabled, profile: checked, expectedRevision: expectedRevision ?? state.revision);
      state = AiConfiguration(enabled: enabled, profile: checked, revision: _store.revision);
    });
    _lastSave = next;
    _pending = next.then<void>((_) {}, onError: (Object _) {});
    return next;
  }
}

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../foundation/data_dir.dart';
import '../../../foundation/ids.dart';
import '../../../foundation/json_file.dart';
import '../adapters/config_store.dart';
import '../domain/model_profile.dart';

class AiTerminalHost {
  const AiTerminalHost(this.id, this.label, this.signature);
  final HostId id;
  final String label, signature;
}

/// The app supplies effective nonsecret hosts; changes cancel affected terminal requests.
final aiTerminalHostsProvider = Provider<List<AiTerminalHost>>((_) => const []);

class AiConfiguration {
  const AiConfiguration({
    this.enabled = false,
    this.profile,
    this.revision = 0,
    this.loadFailed = false,
    this.inlineEnabled = true,
    this.completionEnabled = true,
    this.inlineExcludedHosts = const {},
    this.completionExcludedHosts = const {},
    this.inlineModel,
    this.completionModel,
    this.reviewModel,
  });

  final bool enabled, loadFailed;
  final ModelProfile? profile;
  final int revision;
  final bool inlineEnabled, completionEnabled;
  final Set<HostId> inlineExcludedHosts, completionExcludedHosts;
  final String? inlineModel, completionModel, reviewModel;

  ModelProfile? get profileForReview => reviewModel == null
      ? null
      : profile?.withModel(reviewModel!, tools: false, reasoningEffort: ReasoningEffort.modelDefault);
  ModelProfile? get profileForInline =>
      profile?.withModel(inlineModel ?? profile!.model, tools: false, reasoningEffort: ReasoningEffort.off);
  ModelProfile? get profileForCompletion =>
      profile?.withModel(completionModel ?? profile!.model, tools: false, reasoningEffort: ReasoningEffort.off);
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
      return AiConfiguration(
        enabled: value.enabled,
        profile: value.profile,
        revision: value.revision,
        inlineEnabled: value.inlineEnabled,
        completionEnabled: value.completionEnabled,
        inlineExcludedHosts: value.inlineExcludedHosts,
        completionExcludedHosts: value.completionExcludedHosts,
        inlineModel: value.inlineModel,
        completionModel: value.completionModel,
        reviewModel: value.reviewModel,
      );
    } on JsonFileError catch (error) {
      _loadError = error;
      return const AiConfiguration(loadFailed: true);
    }
  }

  void reload() => state = _read(reload: true);

  Future<void> get saved => _lastSave.then((_) => _store.saved);

  Future<void> save({
    required bool enabled,
    required ModelProfile? profile,
    int? expectedRevision,
    bool? inlineEnabled,
    bool? completionEnabled,
    Set<HostId>? inlineExcludedHosts,
    Set<HostId>? completionExcludedHosts,
    String? inlineModel,
    String? completionModel,
    String? reviewModel,
  }) {
    final inlineExcluded = inlineExcludedHosts == null ? null : Set<HostId>.unmodifiable(inlineExcludedHosts);
    final completionExcluded = completionExcludedHosts == null
        ? null
        : Set<HostId>.unmodifiable(completionExcludedHosts);
    final next = _pending.then((_) async {
      if (_loadError case final error?) throw error;
      if (enabled && profile == null) throw ArgumentError('AI profile required');
      final checked = profile == null ? null : ModelProfile.fromJson(profile.toJson());
      final sameProvider = checked?.protocol == state.profile?.protocol && checked?.endpoint == state.profile?.endpoint;
      final selectedInline = checked == null
          ? null
          : inlineModel ?? (sameProvider ? state.inlineModel : null) ?? checked.model;
      final selectedCompletion = checked == null
          ? null
          : completionModel ?? (sameProvider ? state.completionModel : null) ?? checked.model;
      final selectedReview = checked == null ? null : reviewModel ?? (sameProvider ? state.reviewModel : null);
      await _store.write(
        enabled: enabled,
        profile: checked,
        expectedRevision: expectedRevision ?? state.revision,
        inlineEnabled: inlineEnabled ?? state.inlineEnabled,
        completionEnabled: completionEnabled ?? state.completionEnabled,
        inlineExcludedHosts: inlineExcluded ?? state.inlineExcludedHosts,
        completionExcludedHosts: completionExcluded ?? state.completionExcludedHosts,
        inlineModel: selectedInline,
        completionModel: selectedCompletion,
        reviewModel: selectedReview,
      );
      state = _read();
    });
    _lastSave = next;
    _pending = next.then<void>((_) {}, onError: (Object _) {});
    return next;
  }
}

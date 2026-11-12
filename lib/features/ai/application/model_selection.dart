import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../settings/api.dart';
import '../domain/model_profile.dart';
import 'configuration.dart';

/// The panel remembers the last model for the same protocol and endpoint; other destinations use their default.
final selectedAgentModelProvider = NotifierProvider<SelectedAgentModel, String?>(SelectedAgentModel.new);

class SelectedAgentModel extends Notifier<String?> {
  /// Keeps the pick while the saved write is in flight, so a configuration revision cannot revert it.
  String? _chosen;
  String? _chosenDestination;

  @override
  String? build() {
    final profile = ref.watch(aiConfigurationProvider).profile;
    if (profile == null) return null;
    final destination = destinationOf(profile);
    if (_chosenDestination == destination) return _chosen;
    final settings = ref.read(settingsProvider);
    final model = settings.get(SettingKeys.agentModel);
    if (model == null || model.isEmpty) return null;
    return settings.get(SettingKeys.agentModelEndpoint) == destination ? model : null;
  }

  void select(String model) {
    _chosen = model;
    state = model;
    final profile = ref.read(aiConfigurationProvider).profile;
    if (profile == null) return;
    _chosenDestination = destinationOf(profile);
    ref.read(settingsProvider.notifier).patch({
      SettingKeys.agentModel.key: model,
      SettingKeys.agentModelEndpoint.key: _chosenDestination!,
    }).ignore();
  }

  static String destinationOf(ModelProfile profile) => '${profile.protocol.name} ${profile.endpoint}';
}

/// Separates the selection guard from the runtime's dependency on the selected profile.
final agentTurnActiveProvider = NotifierProvider<AgentTurnActive, bool>(AgentTurnActive.new);

class AgentTurnActive extends Notifier<bool> {
  @override
  bool build() => false;

  void update(bool active) {
    if (state != active) state = active;
  }
}

/// A conversation-local override; null follows the saved default.
final selectedAgentReasoningProvider = NotifierProvider<SelectedAgentReasoning, ReasoningEffort?>(
  SelectedAgentReasoning.new,
);

class SelectedAgentReasoning extends Notifier<ReasoningEffort?> {
  @override
  ReasoningEffort? build() {
    ref.watch(aiConfigurationProvider);
    return null;
  }

  void select(ReasoningEffort effort) {
    if (!ref.read(agentTurnActiveProvider)) state = effort;
  }

  void reset() {
    if (!ref.read(agentTurnActiveProvider)) state = null;
  }
}

final effectiveAgentProfileProvider = Provider<ModelProfile?>((ref) {
  final profile = ref.watch(aiConfigurationProvider).profile;
  final selected = ref.watch(selectedAgentModelProvider);
  final reasoning = ref.watch(selectedAgentReasoningProvider);
  return profile?.withModel(selected ?? profile.model, tools: true, reasoningEffort: reasoning);
});

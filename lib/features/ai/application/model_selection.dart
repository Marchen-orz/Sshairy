import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/model_profile.dart';
import 'configuration.dart';

/// A window-local choice leaves the saved default and terminal suggestions alone.
final selectedAgentModelProvider = NotifierProvider<SelectedAgentModel, String?>(SelectedAgentModel.new);

class SelectedAgentModel extends Notifier<String?> {
  @override
  String? build() {
    ref.listen(aiConfigurationProvider.select((value) => value.profile), (_, _) => state = null);
    return null;
  }

  void select(String model) => state = model;
}

final effectiveAgentProfileProvider = Provider<ModelProfile?>((ref) {
  final profile = ref.watch(aiConfigurationProvider).profile;
  final selected = ref.watch(selectedAgentModelProvider);
  return profile?.withModel(selected ?? profile.model, tools: true);
});

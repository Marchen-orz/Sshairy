import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/agent.dart';
import 'providers.dart';

/// A user-only, window-local choice; a running turn keeps its captured policy.
final selectedAgentPermissionModeProvider = NotifierProvider<SelectedAgentPermissionMode, AgentPermissionMode>(
  SelectedAgentPermissionMode.new,
);

class SelectedAgentPermissionMode extends Notifier<AgentPermissionMode> {
  @override
  AgentPermissionMode build() => AgentPermissionMode.confirm;

  void select(AgentPermissionMode mode) {
    if (!ref.read(agentRuntimeProvider).busy) state = mode;
  }
}

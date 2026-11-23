import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/agent.dart';
import 'providers.dart';

/// A user-only, window-local choice that a running turn applies to its remaining decisions.
final selectedAgentPermissionModeProvider = NotifierProvider<SelectedAgentPermissionMode, AgentPermissionMode>(
  SelectedAgentPermissionMode.new,
);

class SelectedAgentPermissionMode extends Notifier<AgentPermissionMode> {
  @override
  AgentPermissionMode build() => AgentPermissionMode.confirm;

  void select(AgentPermissionMode mode) {
    if (state == mode) return;
    state = mode;
    ref.read(agentRuntimeProvider).setPermissionMode(mode);
  }

  /// Every new conversation starts from the safe default.
  void reset() {
    if (state == AgentPermissionMode.confirm) return;
    state = AgentPermissionMode.confirm;
    ref.read(agentRuntimeProvider).setPermissionMode(AgentPermissionMode.confirm);
  }
}

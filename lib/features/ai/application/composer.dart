import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../foundation/ids.dart';
import '../domain/attachment.dart';

class AgentComposerState {
  const AgentComposerState({this.goal = '', this.host, this.attachments = const []});

  final String goal;
  final HostId? host;
  final List<AgentAttachment> attachments;
}

/// Window-local drafts survive the panel closing; they never enter configuration or model requests by themselves.
final agentComposerProvider = NotifierProvider<AgentComposer, AgentComposerState>(AgentComposer.new);

class AgentComposer extends Notifier<AgentComposerState> {
  @override
  AgentComposerState build() => const AgentComposerState();

  void setGoal(String value) {
    if (value == state.goal) return;
    state = AgentComposerState(goal: value, host: state.host, attachments: state.attachments);
  }

  void selectHost(HostId? value) {
    if (value == state.host) return;
    state = AgentComposerState(goal: state.goal, host: value, attachments: state.attachments);
  }

  void setAttachments(Iterable<AgentAttachment> attachments) =>
      state = AgentComposerState(goal: state.goal, host: state.host, attachments: checkedAgentAttachments(attachments));

  void restore(AgentComposerState draft) => state = AgentComposerState(
    goal: draft.goal,
    host: draft.host,
    attachments: checkedAgentAttachments(draft.attachments),
  );

  void newTask() => state = AgentComposerState(host: state.host);
}

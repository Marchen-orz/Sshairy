import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../foundation/ids.dart';
import 'providers.dart';
import 'runtime.dart';

class AgentComposerState {
  const AgentComposerState({this.goal = '', this.host, this.outputRequest, this.outputEdit});

  final String goal;
  final HostId? host;
  final AgentDataRequest? outputRequest;
  final String? outputEdit;

  String outputText(AgentDataRequest request) =>
      identical(outputRequest, request) ? outputEdit ?? request.suggested : request.suggested;
}

/// Window-local drafts survive the panel closing; they never enter configuration or model requests by themselves.
final agentComposerProvider = NotifierProvider<AgentComposer, AgentComposerState>(AgentComposer.new);

class AgentComposer extends Notifier<AgentComposerState> {
  @override
  AgentComposerState build() {
    final runtime = ref.read(agentRuntimeProvider);
    void discardExpiredOutput() {
      final request = state.outputRequest;
      if (request != null && !identical(runtime.dataRequest, request)) clearOutput(request);
    }

    runtime.addListener(discardExpiredOutput);
    ref.onDispose(() => runtime.removeListener(discardExpiredOutput));
    return const AgentComposerState();
  }

  void setGoal(String value) {
    if (value == state.goal) return;
    state = AgentComposerState(
      goal: value,
      host: state.host,
      outputRequest: state.outputRequest,
      outputEdit: state.outputEdit,
    );
  }

  void selectHost(HostId? value) {
    if (value == state.host) return;
    state = AgentComposerState(
      goal: state.goal,
      host: value,
      outputRequest: state.outputRequest,
      outputEdit: state.outputEdit,
    );
  }

  void editOutput(AgentDataRequest request, String value) {
    state = AgentComposerState(goal: state.goal, host: state.host, outputRequest: request, outputEdit: value);
  }

  void clearOutput(AgentDataRequest request) {
    if (!identical(state.outputRequest, request)) return;
    state = AgentComposerState(goal: state.goal, host: state.host);
  }

  void newTask() => state = AgentComposerState(host: state.host);
}

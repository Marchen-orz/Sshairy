import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../design/select.dart';
import '../../../design/theme.dart';
import '../../../foundation/ids.dart';
import '../../../l10n/app_localizations.dart';
import '../../settings/api.dart';
import '../application/configuration.dart';
import '../application/providers.dart';
import '../application/runtime.dart';
import '../domain/agent.dart';

class AgentPanel extends ConsumerStatefulWidget {
  const AgentPanel({super.key});

  @override
  ConsumerState<AgentPanel> createState() => _AgentPanelState();
}

class _AgentPanelState extends ConsumerState<AgentPanel> {
  final _goal = TextEditingController();
  AgentMode _mode = AgentMode.explain;
  HostId? _host;
  bool _startFailed = false;

  @override
  void dispose() {
    _goal.dispose();
    super.dispose();
  }

  Future<void> _send(AgentRuntime runtime, AgentMode mode, HostId? host) async {
    final goal = _goal.text.trim();
    if (runtime.busy || goal.isEmpty || (mode != AgentMode.explain && host == null)) return;
    setState(() => _startFailed = false);
    _goal.clear();
    try {
      await runtime.start(goal, AgentScope(mode: mode, hosts: mode == AgentMode.explain ? const [] : [host!]));
    } on Object {
      if (!mounted) return;
      if (_goal.text.isEmpty) _goal.text = goal;
      setState(() => _startFailed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final configuration = ref.watch(aiConfigurationProvider);
    final runtime = ref.watch(agentRuntimeProvider);
    final hosts = ref.watch(agentBackendProvider).hosts;
    final enabled = configuration.enabled && configuration.profile != null && !configuration.loadFailed;
    final tools = configuration.profile?.tools ?? false;
    final selectedMode = tools ? _mode : AgentMode.explain;
    final selectedHost = hosts.any((host) => host.id == _host) ? _host : null;
    final theme = Theme.of(context);

    return ListenableBuilder(
      listenable: runtime,
      builder: (context, _) => Padding(
        padding: const EdgeInsets.all(Space.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(child: Text(l.aiAgentTitle, style: theme.textTheme.titleSmall)),
                IconButton(
                  tooltip: l.aiAgentClear,
                  onPressed: runtime.busy ? null : runtime.clear,
                  icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                ),
                IconButton(
                  tooltip: l.settings,
                  onPressed: () => showSettingsDialog(context),
                  icon: const Icon(Icons.settings_outlined, size: 18),
                ),
              ],
            ),
            if (!enabled) ...[
              Padding(
                padding: const EdgeInsets.symmetric(vertical: Space.sm),
                child: Text(
                  configuration.loadFailed ? l.aiAgentConfigurationFailed : l.aiAgentConfigure,
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(onPressed: () => showSettingsDialog(context), child: Text(l.settings)),
              ),
            ],
            AppSelect<AgentMode>(
              key: const ValueKey('ai-agent-mode'),
              value: selectedMode,
              options: [
                AppOption(AgentMode.explain, l.aiAgentExplain),
                if (tools) ...[
                  AppOption(AgentMode.diagnose, l.aiAgentDiagnose),
                  AppOption(AgentMode.execute, l.aiAgentExecute),
                ],
              ],
              onChanged: !enabled || runtime.busy ? null : (value) => setState(() => _mode = value),
            ),
            if (selectedMode != AgentMode.explain) ...[
              const SizedBox(height: Space.sm),
              AppSelect<HostId?>(
                key: const ValueKey('ai-agent-host'),
                value: selectedHost,
                options: [
                  AppOption(null, l.aiAgentChooseHost),
                  for (final host in hosts) AppOption(host.id, host.label),
                ],
                searchable: hosts.length > 8,
                searchHint: l.aiAgentChooseHost,
                onChanged: !enabled || runtime.busy ? null : (value) => setState(() => _host = value),
              ),
            ],
            if (selectedMode != AgentMode.explain) ...[
              const SizedBox(height: Space.sm),
              Text(l.aiAgentDiagnosticScope, style: theme.textTheme.bodySmall),
            ],
            const SizedBox(height: Space.sm),
            Row(
              children: [
                if (runtime.busy) ...[
                  const SizedBox(width: Space.md, height: Space.md, child: CircularProgressIndicator(strokeWidth: 2)),
                  const SizedBox(width: Space.sm),
                ],
                Expanded(child: Text(_phase(l, runtime.phase), style: theme.textTheme.bodySmall)),
              ],
            ),
            if (runtime.error != null || _startFailed)
              Padding(
                padding: const EdgeInsets.only(top: Space.sm),
                child: Text(
                  l.aiAgentFailed,
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
                ),
              ),
            const SizedBox(height: Space.sm),
            Expanded(child: _Conversation(runtime: runtime)),
            const SizedBox(height: Space.sm),
            TextField(
              key: const ValueKey('ai-agent-goal'),
              controller: _goal,
              enabled: enabled && !runtime.busy,
              minLines: 2,
              maxLines: 5,
              maxLength: 4096,
              decoration: InputDecoration(hintText: l.aiAgentGoal, counterText: ''),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: Space.sm),
            Align(
              alignment: Alignment.centerRight,
              child: runtime.busy
                  ? OutlinedButton.icon(
                      key: const ValueKey('ai-agent-stop'),
                      onPressed: runtime.stop,
                      icon: const Icon(Icons.stop, size: 16),
                      label: Text(l.stop),
                    )
                  : FilledButton.icon(
                      key: const ValueKey('ai-agent-send'),
                      onPressed:
                          !enabled ||
                              _goal.text.trim().isEmpty ||
                              (selectedMode != AgentMode.explain && selectedHost == null)
                          ? null
                          : () => _send(runtime, selectedMode, selectedHost),
                      icon: const Icon(Icons.arrow_upward, size: 16),
                      label: Text(l.aiAgentSend),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Conversation extends StatelessWidget {
  const _Conversation({required this.runtime});
  final AgentRuntime runtime;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final messages = runtime.messages;
    final executions = runtime.executions;
    final messageStart = max(0, messages.length - 200);
    final executionStart = max(0, executions.length - 64);
    final messageCount = messages.length - messageStart;
    final executionCount = executions.length - executionStart;
    final approval = runtime.approval;
    final data = runtime.dataRequest;
    final count = messageCount + executionCount + (approval == null ? 0 : 1) + (data == null ? 0 : 1);
    if (count == 0) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(Space.lg),
          child: Text(l.aiAgentEmpty, style: Theme.of(context).textTheme.bodySmall, textAlign: TextAlign.center),
        ),
      );
    }
    return SelectionArea(
      child: ListView.builder(
        key: const PageStorageKey('ai-agent-conversation'),
        reverse: true,
        itemCount: count,
        itemBuilder: (context, index) {
          index = count - index - 1;
          if (index < messageCount) {
            final message = messages[messageStart + index];
            final user = message.role == 'user';
            return Padding(
              padding: const EdgeInsets.only(bottom: Space.md),
              child: _AgentCard(
                emphasized: user,
                child: Text(message.text, style: Theme.of(context).textTheme.bodyMedium),
              ),
            );
          }
          index -= messageCount;
          if (index < executionCount) {
            final execution = executions[executionStart + index];
            return _ExecutionCard(key: ValueKey(execution.id), execution: execution);
          }
          index -= executionCount;
          if (approval != null) {
            if (index == 0) {
              return _ApprovalCard(
                approval: approval,
                onApprove: () => runtime.approve(true, expected: approval),
                onReject: () => runtime.approve(false, expected: approval),
              );
            }
            index--;
          }
          return _OutputApproval(
            key: ObjectKey(data),
            request: data!,
            onShare: (text) => runtime.shareOutput(text, expected: data),
          );
        },
      ),
    );
  }
}

class _ExecutionCard extends StatefulWidget {
  const _ExecutionCard({super.key, required this.execution});
  final AgentExecution execution;

  @override
  State<_ExecutionCard> createState() => _ExecutionCardState();
}

class _ExecutionCardState extends State<_ExecutionCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final execution = widget.execution;
    final output = execution.output;
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.sm),
      child: _AgentCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(execution.target, style: theme.textTheme.labelLarge),
            const SizedBox(height: Space.xs),
            Text(
              execution.command.isEmpty ? l.aiAgentDiagnostics : execution.command,
              style: mono(context, theme.textTheme.bodySmall),
              maxLines: 5,
              overflow: TextOverflow.ellipsis,
            ),
            if (execution.cwd.isNotEmpty) Text(execution.cwd, style: mono(context, theme.textTheme.bodySmall)),
            const SizedBox(height: Space.xs),
            Text(_executionState(l, execution.state), style: theme.textTheme.bodySmall),
            if (execution.exitCode case final code?) Text(l.aiAgentExitCode(code), style: theme.textTheme.bodySmall),
            if (output?.truncated ?? false) Text(l.aiAgentTruncated, style: theme.textTheme.bodySmall),
            if (output != null) ...[
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: () => setState(() => _expanded = !_expanded),
                  child: Text(_expanded ? l.aiAgentHideOutput : l.aiAgentShowOutput),
                ),
              ),
              if (_expanded) Text(output.excerpt, style: mono(context, theme.textTheme.bodySmall)),
            ],
          ],
        ),
      ),
    );
  }
}

class _ApprovalCard extends StatelessWidget {
  const _ApprovalCard({required this.approval, required this.onApprove, required this.onReject});
  final AgentApproval approval;
  final VoidCallback onApprove, onReject;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.sm),
      child: _AgentCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(approval.target, style: theme.textTheme.labelLarge),
            const SizedBox(height: Space.sm),
            Text(approval.cwd, style: mono(context, theme.textTheme.bodySmall)),
            const SizedBox(height: Space.sm),
            Text(approval.command, style: mono(context, theme.textTheme.bodyMedium)),
            const SizedBox(height: Space.sm),
            Text(l.aiAgentShellPermission, style: theme.textTheme.bodySmall),
            const SizedBox(height: Space.sm),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: Space.sm,
              runSpacing: Space.sm,
              children: [
                TextButton(onPressed: onReject, child: Text(l.aiAgentReject)),
                FilledButton.tonal(onPressed: onApprove, child: Text(l.aiAgentApprove)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _OutputApproval extends StatefulWidget {
  const _OutputApproval({super.key, required this.request, required this.onShare});
  final AgentDataRequest request;
  final ValueChanged<String?> onShare;

  @override
  State<_OutputApproval> createState() => _OutputApprovalState();
}

class _OutputApprovalState extends State<_OutputApproval> {
  late final _text = TextEditingController(text: widget.request.suggested);

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final valid = utf8.encode(jsonEncode(_text.text)).length <= 7000;
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.sm),
      child: _AgentCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(l.aiAgentSharePreview, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: Space.sm),
            TextField(
              key: const ValueKey('ai-agent-output-projection'),
              controller: _text,
              minLines: 3,
              maxLines: 8,
              maxLength: 8192,
              style: mono(context, Theme.of(context).textTheme.bodySmall),
              decoration: InputDecoration(errorText: valid ? null : l.aiAgentProjectionTooLarge, counterText: ''),
              onChanged: (_) => setState(() {}),
            ),
            if (widget.request.output.truncated)
              Padding(
                padding: const EdgeInsets.only(top: Space.sm),
                child: Text(l.aiAgentTruncated, style: Theme.of(context).textTheme.bodySmall),
              ),
            const SizedBox(height: Space.sm),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: Space.sm,
              runSpacing: Space.sm,
              children: [
                TextButton(onPressed: () => widget.onShare(null), child: Text(l.aiAgentKeepLocal)),
                FilledButton.tonal(
                  key: const ValueKey('ai-agent-share-output'),
                  onPressed: valid ? () => widget.onShare(_text.text) : null,
                  child: Text(l.aiAgentShare),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _AgentCard extends StatelessWidget {
  const _AgentCard({required this.child, this.emphasized = false});
  final Widget child;
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(Space.md),
      decoration: BoxDecoration(
        color: emphasized ? scheme.surfaceContainerHigh : scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(Radii.card),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: child,
    );
  }
}

String _phase(AppLocalizations l, AgentPhase phase) => switch (phase) {
  AgentPhase.idle => l.aiAgentIdle,
  AgentPhase.preparing => l.aiAgentPreparing,
  AgentPhase.streaming => l.aiAgentStreaming,
  AgentPhase.awaitingApproval => l.aiAgentAwaitingApproval,
  AgentPhase.executing => l.aiAgentExecuting,
  AgentPhase.awaitingData => l.aiAgentAwaitingData,
  AgentPhase.completed => l.aiAgentCompleted,
  AgentPhase.stopping => l.aiAgentStopping,
  AgentPhase.cancelled => l.aiAgentCancelled,
  AgentPhase.failed => l.aiAgentFailed,
  AgentPhase.outcomeUnknown => l.aiAgentOutcomeUnknown,
};

String _executionState(AppLocalizations l, String state) => switch (state) {
  'pending' || 'intent' || 'preparing' => l.aiAgentPreparing,
  'executing' || 'running' => l.aiAgentExecuting,
  'completed' => l.aiAgentCompleted,
  'failed' => l.aiAgentFailed,
  'cancelled' => l.aiAgentCancelled,
  'outcomeUnknown' || 'unknown' => l.aiAgentOutcomeUnknown,
  _ => l.aiAgentPreparing,
};

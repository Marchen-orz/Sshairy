import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../design/brand.dart';
import '../../../design/dialog.dart';
import '../../../design/popup.dart';
import '../../../design/select.dart';
import '../../../design/theme.dart';
import '../../../foundation/ids.dart';
import '../../../l10n/app_localizations.dart';
import '../../settings/api.dart';
import '../application/composer.dart';
import '../application/conversations.dart';
import '../application/configuration.dart';
import '../application/providers.dart';
import '../application/model_selection.dart';
import '../adapters/markdown_view.dart';
import 'model_picker.dart';
import '../application/runtime.dart';
import '../domain/agent.dart';

class AgentPanel extends ConsumerStatefulWidget {
  const AgentPanel({super.key, this.onClose});
  final VoidCallback? onClose;

  @override
  ConsumerState<AgentPanel> createState() => _AgentPanelState();
}

class _AgentPanelState extends ConsumerState<AgentPanel> {
  late final _goal = TextEditingController(text: ref.read(agentComposerProvider).goal);
  bool _scopeDetails = false;
  bool _startFailed = false, _confirming = false;

  void _resetConversationUi() => setState(() {
    _startFailed = false;
    _scopeDetails = false;
  });

  Future<void> _history(BuildContext anchorContext) async {
    final conversations = ref.read(agentConversationsProvider);
    final choice = await showAnchoredPopup<(String, bool)>(
      context: context,
      anchor: anchorOf(anchorContext),
      width: WorkspaceSize.toolPanel,
      builder: (context) => _History(conversations: conversations),
    );
    if (!mounted || choice == null) return;
    if (choice.$2) {
      final l = AppLocalizations.of(context);
      final confirmed = await showAppDialog<bool>(
        context: context,
        builder: (context) => AppDialog(
          content: Text(l.aiAgentHistoryDeleteConfirm),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: Text(l.cancel)),
            TextButton(onPressed: () => Navigator.pop(context, true), child: Text(l.aiAgentHistoryDelete)),
          ],
        ),
      );
      if (!mounted || confirmed != true) return;
      await conversations.delete(choice.$1);
    } else {
      conversations.select(choice.$1);
    }
    if (mounted) _resetConversationUi();
  }

  @override
  void dispose() {
    _goal.dispose();
    super.dispose();
  }

  void _goalChanged() => ref.read(agentComposerProvider.notifier).setGoal(_goal.text);

  void _replaceGoal(String value) {
    _goal.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
    _goalChanged();
  }

  Future<void> _send(AgentRuntime runtime, HostId? host) async {
    final goal = _goal.text.trim();
    final conversations = ref.read(agentConversationsProvider);
    if (runtime.busy || conversations.loading || _confirming || goal.isEmpty || !_goal.value.composing.isCollapsed) {
      return;
    }
    setState(() => _startFailed = false);
    var continueHistory = false;
    if (conversations.hasHistory) {
      final l = AppLocalizations.of(context);
      final canContinue = conversations.canContinue(host);
      final configuration = ref.read(aiConfigurationProvider);
      final profile = ref.read(effectiveAgentProfileProvider);
      final hostName =
          ref.read(agentBackendProvider).hosts.where((entry) => entry.id == host).firstOrNull?.label ?? l.aiAgentNoHost;
      final selectedId = conversations.selectedId;
      _confirming = true;
      final accepted = await showAppDialog<bool>(
        context: context,
        builder: (context) => AppDialog(
          content: SingleChildScrollView(
            child: Text(
              canContinue
                  ? l.aiAgentHistoryContinueNotice('${profile?.endpoint ?? ''} · ${profile?.model ?? ''}', hostName)
                  : l.aiAgentHistoryTargetChanged,
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: Text(l.cancel)),
            FilledButton.tonal(
              onPressed: () => Navigator.pop(context, true),
              child: Text(canContinue ? l.aiAgentContinueConversation : l.aiAgentNewTask),
            ),
          ],
        ),
      );
      _confirming = false;
      if (!mounted ||
          accepted != true ||
          runtime.busy ||
          selectedId != conversations.selectedId ||
          _goal.text.trim() != goal ||
          ref.read(aiConfigurationProvider) != configuration ||
          ref.read(effectiveAgentProfileProvider)?.identity != profile?.identity ||
          ref.read(agentComposerProvider).host != host && (profile?.tools ?? false)) {
        return;
      }
      if (canContinue && !conversations.canContinue(host)) return;
      continueHistory = canContinue;
    }
    try {
      await conversations.send(goal, host, continueHistory: continueHistory);
      if (mounted && runtime.error == 'notConfigured' && _goal.text.isEmpty) _replaceGoal(goal);
    } on Object {
      if (!mounted) return;
      if (_goal.text.isEmpty) _replaceGoal(goal);
      setState(() => _startFailed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final configuration = ref.watch(aiConfigurationProvider);
    final runtime = ref.watch(agentRuntimeProvider);
    final conversations = ref.watch(agentConversationsProvider);
    final draft = ref.watch(agentComposerProvider);
    if (_goal.text != draft.goal) {
      _goal.value = TextEditingValue(
        text: draft.goal,
        selection: TextSelection.collapsed(offset: draft.goal.length),
      );
    }
    final hosts = ref.watch(agentBackendProvider).hosts;
    final enabled = configuration.enabled && configuration.profile != null && !configuration.loadFailed;
    final profile = ref.watch(effectiveAgentProfileProvider);
    final tools = profile?.tools ?? false;
    final selectedHost = tools && hosts.any((host) => host.id == draft.host) ? draft.host : null;
    final theme = Theme.of(context);

    return ListenableBuilder(
      listenable: Listenable.merge([runtime, conversations]),
      builder: (context, _) => LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxHeight < 440;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(Space.md, Space.sm, Space.xs, Space.sm),
                child: Row(
                  children: [
                    Icon(Icons.auto_awesome_outlined, size: 18, color: theme.colorScheme.primary),
                    const SizedBox(width: Space.xs),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(l.aiAgentTitle, style: theme.textTheme.titleSmall),
                          if (runtime.phase != AgentPhase.idle)
                            Text(
                              _phase(l, runtime.phase),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                            ),
                        ],
                      ),
                    ),
                    Builder(
                      builder: (anchorContext) => IconButton(
                        key: const ValueKey('ai-agent-history'),
                        tooltip: l.aiAgentHistory,
                        onPressed: () => _history(anchorContext),
                        icon: const Icon(Icons.history_rounded, size: 17),
                      ),
                    ),
                    IconButton(
                      key: const ValueKey('ai-agent-new-task'),
                      tooltip: l.aiAgentNewTask,
                      onPressed: runtime.busy || conversations.loading
                          ? null
                          : () {
                              if (conversations.newConversation()) _resetConversationUi();
                            },
                      icon: const Icon(Icons.add_comment_outlined, size: 17),
                    ),
                    IconButton(
                      tooltip: l.settings,
                      onPressed: () => showSettingsDialog(context, section: SettingsSectionId.ai),
                      icon: const Icon(Icons.tune_outlined, size: 17),
                    ),
                    if (widget.onClose != null)
                      IconButton(tooltip: l.close, onPressed: widget.onClose, icon: const Icon(Icons.close, size: 17)),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: runtime.timeline.isEmpty && !runtime.busy
                    ? _Welcome(
                        enabled: enabled,
                        failed: configuration.loadFailed,
                        compact: compact,
                        onExample: _replaceGoal,
                      )
                    : _Conversation(runtime: runtime, conversationId: conversations.selectedId),
              ),
              if (runtime.error != null || _startFailed)
                Padding(
                  padding: const EdgeInsets.fromLTRB(Space.md, Space.xs, Space.md, 0),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.info_outline_rounded, size: 16, color: theme.colorScheme.error),
                      const SizedBox(width: Space.sm),
                      Expanded(
                        child: Text(
                          _error(l, runtime.error),
                          maxLines: compact ? 2 : 4,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
                        ),
                      ),
                    ],
                  ),
                ),
              Padding(
                padding: const EdgeInsets.all(Space.sm),
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: max(112, constraints.maxHeight * (compact ? .58 : .46))),
                  child: SingleChildScrollView(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surfaceContainerLow,
                        border: Border.all(color: theme.colorScheme.outlineVariant),
                        borderRadius: BorderRadius.circular(Radii.card),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(Space.sm),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (conversations.loadFailed || conversations.saveFailed)
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      conversations.loadFailed
                                          ? l.aiAgentHistoryLoadFailed
                                          : l.aiAgentHistorySaveFailed,
                                      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
                                    ),
                                  ),
                                  TextButton(
                                    onPressed: () =>
                                        conversations.loadFailed ? conversations.reload() : conversations.retrySave(),
                                    child: Text(l.aiAgentHistoryRetry),
                                  ),
                                ],
                              ),
                            if (conversations.current?.historyTruncated ?? false)
                              Text(l.aiAgentHistoryTruncated, style: theme.textTheme.bodySmall),
                            if (runtime.contextCompacted)
                              Text(l.aiAgentContextCompacted, style: theme.textTheme.bodySmall),
                            Focus(
                              onKeyEvent: (_, event) {
                                if (event is! KeyDownEvent ||
                                    event.logicalKey != LogicalKeyboardKey.enter ||
                                    !(HardwareKeyboard.instance.isControlPressed ||
                                        HardwareKeyboard.instance.isMetaPressed) ||
                                    !_goal.value.composing.isCollapsed) {
                                  return KeyEventResult.ignored;
                                }
                                if (enabled &&
                                    !runtime.busy &&
                                    !conversations.loading &&
                                    _goal.text.trim().isNotEmpty) {
                                  unawaited(_send(runtime, selectedHost));
                                }
                                return KeyEventResult.handled;
                              },
                              child: TextField(
                                key: const ValueKey('ai-agent-goal'),
                                controller: _goal,
                                enabled: enabled,
                                minLines: 1,
                                maxLines: compact ? 2 : 4,
                                maxLength: 4096,
                                decoration: InputDecoration(
                                  hintText: l.aiAgentGoal,
                                  counterText: '',
                                  border: InputBorder.none,
                                  enabledBorder: InputBorder.none,
                                  focusedBorder: InputBorder.none,
                                  disabledBorder: InputBorder.none,
                                  filled: false,
                                  isDense: true,
                                  contentPadding: const EdgeInsets.symmetric(vertical: Space.sm, horizontal: Space.xs),
                                ),
                                onChanged: (_) => _goalChanged(),
                              ),
                            ),
                            const SizedBox(height: Space.xs),
                            Row(
                              children: [
                                Expanded(
                                  child: profile == null
                                      ? Text(l.aiAgentConfigureAction, style: theme.textTheme.bodySmall)
                                      : AiModelPicker(
                                          key: const ValueKey('ai-agent-model'),
                                          value: profile.model,
                                          protocol: profile.protocol,
                                          endpoint: profile.endpoint,
                                          credentialIdentity: configuration.profile?.identity,
                                          compact: true,
                                          onChanged: runtime.busy
                                              ? null
                                              : ref.read(selectedAgentModelProvider.notifier).select,
                                        ),
                                ),
                                if (!tools) Text(l.aiAgentTextOnly, style: theme.textTheme.bodySmall),
                              ],
                            ),
                            const SizedBox(height: Space.sm),
                            Row(
                              children: [
                                Expanded(
                                  child: tools
                                      ? AppSelect<HostId?>(
                                          key: const ValueKey('ai-agent-host'),
                                          value: selectedHost,
                                          options: [
                                            AppOption(null, l.aiAgentNoHost, icon: Icons.chat_bubble_outline_rounded),
                                            for (final host in hosts)
                                              AppOption(host.id, host.label, icon: Icons.dns_outlined),
                                          ],
                                          searchable: hosts.length > 8,
                                          searchHint: l.aiAgentChooseHost,
                                          onChanged: !enabled || runtime.busy
                                              ? null
                                              : ref.read(agentComposerProvider.notifier).selectHost,
                                        )
                                      : const SizedBox.shrink(),
                                ),
                                if (tools && selectedHost != null)
                                  IconButton(
                                    key: const ValueKey('ai-agent-scope-details'),
                                    tooltip: l.aiAgentScopeDetails,
                                    isSelected: _scopeDetails,
                                    onPressed: () => setState(() => _scopeDetails = !_scopeDetails),
                                    icon: const Icon(Icons.shield_outlined, size: 17),
                                  ),
                                const SizedBox(width: Space.sm),
                                runtime.busy
                                    ? IconButton.filledTonal(
                                        key: const ValueKey('ai-agent-stop'),
                                        tooltip: l.stop,
                                        onPressed: runtime.stop,
                                        icon: const Icon(Icons.stop_rounded, size: 18),
                                      )
                                    : IconButton.filled(
                                        key: const ValueKey('ai-agent-send'),
                                        tooltip: l.aiAgentSendShortcut,
                                        onPressed: !enabled || conversations.loading || draft.goal.trim().isEmpty
                                            ? null
                                            : () => _send(runtime, selectedHost),
                                        icon: const Icon(Icons.arrow_upward_rounded, size: 18),
                                      ),
                              ],
                            ),
                            if (tools && selectedHost != null && _scopeDetails) ...[
                              const SizedBox(height: Space.sm),
                              Text(l.aiAgentDiagnosticScope, style: theme.textTheme.bodySmall),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _History extends StatelessWidget {
  const _History({required this.conversations});
  final AgentConversations conversations;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final style = Theme.of(context).textTheme.bodySmall;
    return PopupSurface(
      padding: const EdgeInsets.symmetric(vertical: Space.sm),
      child: PopupKeys(
        child: ListenableBuilder(
          listenable: conversations,
          builder: (context, _) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: Space.md, vertical: Space.xs),
                child: Text(l.aiAgentHistoryLocalNotice, style: style),
              ),
              if (conversations.runtime.busy)
                Padding(
                  padding: const EdgeInsets.all(Space.md),
                  child: Text(l.aiAgentHistoryBusy, style: style),
                ),
              if (conversations.loading) const LinearProgressIndicator(),
              Flexible(
                child: conversations.records.isEmpty
                    ? Padding(padding: const EdgeInsets.all(Space.lg), child: Text(l.aiAgentHistoryEmpty))
                    : ListView.builder(
                        shrinkWrap: true,
                        itemCount: conversations.records.length,
                        itemBuilder: (context, index) {
                          final record = conversations.records[index];
                          final enabled = !conversations.runtime.busy && !conversations.loading;
                          return Row(
                            children: [
                              Expanded(
                                child: PopupRow(
                                  key: ValueKey('ai-conversation-${record.id}'),
                                  selected: record.id == conversations.selectedId,
                                  onTap: enabled ? () => Navigator.pop(context, (record.id, false)) : null,
                                  child: Text(record.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                                ),
                              ),
                              IconButton(
                                key: ValueKey('ai-conversation-delete-${record.id}'),
                                tooltip: l.aiAgentHistoryDelete,
                                onPressed: enabled ? () => Navigator.pop(context, (record.id, true)) : null,
                                icon: const Icon(Icons.delete_outline_rounded, size: 17),
                              ),
                            ],
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Welcome extends StatelessWidget {
  const _Welcome({required this.enabled, required this.failed, required this.compact, required this.onExample});
  final bool enabled, failed, compact;
  final ValueChanged<String> onExample;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            BrandIllustration(pose: BrandPose.thinkingAi, size: compact ? 96 : 144),
            const SizedBox(height: Space.md),
            Text(
              enabled ? l.aiAgentWelcome : l.aiAgentSetupTitle,
              style: theme.textTheme.titleSmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: Space.sm),
            Text(
              failed
                  ? l.aiAgentConfigurationFailed
                  : enabled
                  ? l.aiAgentWelcomeHint
                  : l.aiAgentConfigure,
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: Space.lg),
            if (!enabled)
              FilledButton.tonal(
                onPressed: () => showSettingsDialog(context, section: SettingsSectionId.ai),
                child: Text(l.aiAgentConfigureAction),
              )
            else
              Wrap(
                alignment: WrapAlignment.center,
                spacing: Space.sm,
                runSpacing: Space.sm,
                children: [
                  OutlinedButton(
                    onPressed: () => onExample(l.aiAgentExampleExplainGoal),
                    child: Text(l.aiAgentExampleExplain),
                  ),
                  OutlinedButton(
                    onPressed: () => onExample(l.aiAgentExampleDiagnoseGoal),
                    child: Text(l.aiAgentExampleDiagnose),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _Conversation extends StatelessWidget {
  const _Conversation({required this.runtime, required this.conversationId});
  final AgentRuntime runtime;
  final String conversationId;

  @override
  Widget build(BuildContext context) {
    final entries = runtime.timeline.where((entry) => entry is! AgentChatEntry || entry.text.isNotEmpty).toList();
    final approval = runtime.approval;
    final data = runtime.dataRequest;
    final count = entries.length + (approval == null ? 0 : 1) + (data == null ? 0 : 1);
    return SelectionArea(
      child: ListView.builder(
        key: PageStorageKey('ai-agent-conversation-$conversationId'),
        padding: const EdgeInsets.all(Space.md),
        reverse: true,
        itemCount: count,
        itemBuilder: (context, index) {
          index = count - index - 1;
          if (index < entries.length) {
            final entry = entries[index];
            if (entry is AgentExecution) return _ExecutionCard(key: ValueKey(entry.id), execution: entry);
            final message = entry as AgentChatEntry;
            final user = message.role == 'user';
            final theme = Theme.of(context);
            return Padding(
              key: ObjectKey(message),
              padding: const EdgeInsets.only(bottom: Space.md),
              child: Align(
                alignment: user ? Alignment.centerRight : Alignment.centerLeft,
                child: Container(
                  padding: user ? const EdgeInsets.all(Space.md) : const EdgeInsets.symmetric(vertical: Space.xs),
                  decoration: user
                      ? BoxDecoration(
                          color: theme.colorScheme.surfaceContainerHigh,
                          borderRadius: BorderRadius.circular(Radii.card),
                        )
                      : null,
                  child: user ? Text(message.text, style: theme.textTheme.bodyMedium) : AiMarkdown(data: message.text),
                ),
              ),
            );
          }
          index -= entries.length;
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
          return _OutputApproval(key: ObjectKey(data), request: data!, runtime: runtime);
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
    final failed = execution.state == 'failed' || (execution.exitCode != null && execution.exitCode != 0);
    final unknown = execution.state == 'outcomeUnknown';
    final running = execution.state == 'running';
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.md),
      child: _AgentCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: _expanded ? l.aiAgentHideOutput : l.aiAgentShowOutput,
                  onPressed: () => setState(() => _expanded = !_expanded),
                  icon: Icon(_expanded ? Icons.expand_less_rounded : Icons.chevron_right_rounded, size: 17),
                ),
                Expanded(
                  child: Text(
                    execution.archived
                        ? (execution.capability == 'agent.diagnose' ? l.aiAgentDiagnostics : l.aiAgentHistory)
                        : execution.capability == 'agent.diagnose'
                        ? l.aiAgentDiagnostics
                        : execution.command,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: mono(context, theme.textTheme.bodySmall),
                  ),
                ),
                const SizedBox(width: Space.sm),
                Tooltip(
                  message: _executionState(l, execution.state),
                  child: Icon(
                    unknown
                        ? Icons.help_outline_rounded
                        : failed
                        ? Icons.error_outline_rounded
                        : running
                        ? Icons.more_horiz_rounded
                        : Icons.check_circle_outline_rounded,
                    size: 16,
                    color: failed || unknown ? theme.colorScheme.error : theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            if (_expanded) ...[
              if (!execution.archived && execution.target.isNotEmpty)
                Text(execution.target, style: theme.textTheme.labelMedium),
              const SizedBox(height: Space.sm),
              Wrap(
                spacing: Space.md,
                runSpacing: Space.xs,
                children: [
                  Text(
                    failed ? l.aiAgentExecutionFailed : _executionState(l, execution.state),
                    style: theme.textTheme.bodySmall,
                  ),
                  if (execution.exitCode case final code?)
                    Text(l.aiAgentExitCode(code), style: theme.textTheme.bodySmall),
                  if (execution.historyTruncated || (output?.truncated ?? false))
                    Text(l.aiAgentTruncated, style: theme.textTheme.bodySmall),
                ],
              ),
              if (execution.archived) ...[
                const SizedBox(height: Space.sm),
                Text(l.aiAgentHistoryOutputUnavailable, style: theme.textTheme.bodySmall),
                if (execution.sharedText?.isNotEmpty ?? false) ...[
                  const SizedBox(height: Space.sm),
                  Text(execution.sharedText!, style: mono(context, theme.textTheme.bodySmall)),
                ],
              ],
              if (!execution.archived && execution.cwd.isNotEmpty) ...[
                const SizedBox(height: Space.sm),
                Text(execution.cwd, style: mono(context, theme.textTheme.bodySmall)),
              ],
              if (!execution.archived && output != null && output.length > 0) ...[
                const SizedBox(height: Space.sm),
                const Divider(height: 1),
                const SizedBox(height: Space.sm),
                Text(output.excerpt, style: mono(context, theme.textTheme.bodySmall)),
              ],
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
      padding: const EdgeInsets.only(bottom: Space.md),
      child: _AgentCard(
        emphasized: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _CardTitle(icon: Icons.terminal_rounded, label: l.aiAgentApproveTitle),
            const SizedBox(height: Space.md),
            Text(approval.target, style: theme.textTheme.labelLarge),
            const SizedBox(height: Space.xs),
            Text(approval.cwd, style: mono(context, theme.textTheme.bodySmall)),
            const SizedBox(height: Space.md),
            Text(approval.command, style: mono(context, theme.textTheme.bodyMedium)),
            const SizedBox(height: Space.md),
            Text(l.aiAgentShellPermission, style: theme.textTheme.bodySmall),
            const SizedBox(height: Space.md),
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

class _OutputApproval extends ConsumerStatefulWidget {
  const _OutputApproval({super.key, required this.request, required this.runtime});
  final AgentDataRequest request;
  final AgentRuntime runtime;

  @override
  ConsumerState<_OutputApproval> createState() => _OutputApprovalState();
}

class _OutputApprovalState extends ConsumerState<_OutputApproval> {
  late final _text = TextEditingController(text: ref.read(agentComposerProvider).outputText(widget.request));

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _share(String? text) {
    widget.runtime.shareOutput(text, expected: widget.request);
    ref.read(agentComposerProvider.notifier).clearOutput(widget.request);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final valid = utf8.encode(jsonEncode(_text.text)).length <= 7000;
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.md),
      child: _AgentCard(
        emphasized: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _CardTitle(icon: Icons.outbox_outlined, label: l.aiAgentShareTitle),
            const SizedBox(height: Space.md),
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
              onChanged: (value) {
                ref.read(agentComposerProvider.notifier).editOutput(widget.request, value);
                setState(() {});
              },
            ),
            if (widget.request.output.truncated) ...[
              const SizedBox(height: Space.sm),
              Text(l.aiAgentTruncated, style: Theme.of(context).textTheme.bodySmall),
            ],
            const SizedBox(height: Space.md),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: Space.sm,
              runSpacing: Space.sm,
              children: [
                TextButton(onPressed: () => _share(null), child: Text(l.aiAgentKeepLocal)),
                FilledButton.tonal(
                  key: const ValueKey('ai-agent-share-output'),
                  onPressed: valid ? () => _share(_text.text) : null,
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

class _CardTitle extends StatelessWidget {
  const _CardTitle({required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Icon(icon, size: 16, color: Theme.of(context).colorScheme.primary),
      const SizedBox(width: Space.sm),
      Expanded(child: Text(label, style: Theme.of(context).textTheme.labelLarge)),
    ],
  );
}

class _AgentCard extends StatelessWidget {
  const _AgentCard({required this.child, this.emphasized = false});
  final Widget child;
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: EdgeInsets.all(emphasized ? Space.md : Space.sm),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(Radii.card),
        border: Border.all(color: emphasized ? scheme.primary.withValues(alpha: .45) : scheme.outlineVariant),
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

String _error(AppLocalizations l, String? code) => switch (code) {
  'notConfigured' || 'invalidModelKey' || 'invalidModelRequest' => l.aiAgentErrorConfiguration,
  'modelNetworkError' => l.aiAgentErrorNetwork,
  'modelHttpError' || 'modelStreamError' || 'modelRefused' => l.aiAgentErrorHttp,
  'deadline' || 'modelTimedOut' => l.aiAgentErrorTimeout,
  'contextLimit' ||
  'messageLimit' ||
  'toolLimit' ||
  'stepLimit' ||
  'outputLimit' ||
  'inputLimit' ||
  'modelContextTooLarge' ||
  'modelMessageTooLarge' ||
  'modelEventTooLarge' ||
  'modelArgumentsTooLarge' => l.aiAgentErrorLimit,
  'scopeChanged' => l.aiAgentErrorScope,
  'hostTrustRequired' => l.aiAgentErrorHostTrust,
  'authenticationRequired' => l.aiAgentErrorAuthentication,
  'hostUnavailable' => l.aiAgentErrorHostUnavailable,
  'connectionFailed' => l.aiAgentErrorConnection,
  'executionFailed' => l.aiAgentErrorExecution,
  'journalFailed' || 'operationConflict' || 'operationMissingIntent' || 'operationCapacity' => l.aiAgentErrorJournal,
  'outcomeUnknown' => l.aiAgentOutcomeUnknown,
  'cancelled' => l.aiAgentCancelled,
  'unsupported' => l.aiAgentErrorUnsupported,
  'protocol' ||
  'incomplete' ||
  'unexpectedTool' ||
  'incompleteModelStream' ||
  'invalidModelStream' ||
  'invalidModelContentType' ||
  'unrequestedModelTool' ||
  'unsupportedModelContent' ||
  'invalidModelContinuation' ||
  'invalidToolPairing' ||
  'unsupportedModelEvent' ||
  'invalidModelArguments' => l.aiAgentErrorProtocol,
  _ => l.aiAgentFailed,
};

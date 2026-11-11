import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../design/brand.dart';
import '../../../design/dialog.dart';
import '../../../design/popup.dart';
import '../../../design/theme.dart';
import '../../../foundation/ids.dart';
import '../../../l10n/app_localizations.dart';
import '../../settings/api.dart';
import '../application/composer.dart';
import '../application/conversations.dart';
import '../application/configuration.dart';
import '../application/providers.dart';
import '../application/model_selection.dart';
import '../application/target.dart';
import '../application/permission_mode.dart';
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
  late final _goal = TextEditingController(
    text: ref.read(agentComposerProvider).goal,
  );
  bool _startFailed = false, _historyExpanded = false;

  void _resetConversationUi() => setState(() {
    _startFailed = false;
  });

  Future<void> _history(String id, bool delete) async {
    final conversations = ref.read(agentConversationsProvider);
    if (conversations.runtime.busy || conversations.loading) return;
    if (delete) {
      final l = AppLocalizations.of(context);
      final confirmed = await showAppDialog<bool>(
        context: context,
        builder: (context) => AppDialog(
          content: Text(l.aiAgentHistoryDeleteConfirm),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(l.cancel),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(l.aiAgentHistoryDelete),
            ),
          ],
        ),
      );
      if (!mounted || confirmed != true) return;
      await conversations.delete(id);
    } else {
      conversations.select(id);
      if (mounted) setState(() => _historyExpanded = false);
    }
    if (mounted) _resetConversationUi();
  }

  @override
  void dispose() {
    _goal.dispose();
    super.dispose();
  }

  void _goalChanged() =>
      ref.read(agentComposerProvider.notifier).setGoal(_goal.text);

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
    if (runtime.busy ||
        conversations.loading ||
        goal.isEmpty ||
        !_goal.value.composing.isCollapsed) {
      return;
    }
    if (conversations.hasHistory && !conversations.canContinue(host)) return;
    setState(() => _startFailed = false);
    try {
      await conversations.send(goal, host, continueHistory: true);
      if (mounted && runtime.error == 'notConfigured' && _goal.text.isEmpty) {
        _replaceGoal(goal);
      }
    } on Object {
      if (!mounted) return;
      if (_goal.text.isEmpty) _replaceGoal(goal);
      setState(() => _startFailed = true);
    }
  }

  Future<void> _regenerate(HostId? host) async {
    setState(() => _startFailed = false);
    try {
      await ref.read(agentConversationsProvider).regenerate(host);
    } on Object {
      if (mounted) setState(() => _startFailed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final configuration = ref.watch(aiConfigurationProvider);
    final runtime = ref.watch(agentRuntimeProvider);
    final conversations = ref.watch(agentConversationsProvider);
    final draft = ref.watch(agentComposerProvider);
    final permissionMode = ref.watch(selectedAgentPermissionModeProvider);
    if (_goal.text != draft.goal) {
      _goal.value = TextEditingValue(
        text: draft.goal,
        selection: TextSelection.collapsed(offset: draft.goal.length),
      );
    }
    final hosts = ref.watch(agentBackendProvider).hosts;
    final enabled =
        configuration.enabled &&
        configuration.profile != null &&
        !configuration.loadFailed;
    final profile = ref.watch(effectiveAgentProfileProvider);
    final tools = profile?.tools ?? false;
    final focusedHost = ref.watch(agentFocusedHostProvider);
    final selectedHost = tools && hosts.any((host) => host.id == focusedHost)
        ? focusedHost
        : null;
    final theme = Theme.of(context);

    return ListenableBuilder(
      listenable: Listenable.merge([runtime, conversations]),
      builder: (context, _) => LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxHeight < 440;
          final targetHost = runtime.busy ? runtime.resolvedHost : selectedHost;
          final targetLabel =
              hosts.where((host) => host.id == targetHost).firstOrNull?.label ??
              l.aiAgentAutoTarget;
          final changedBinding =
              conversations.hasHistory &&
              !conversations.canContinue(selectedHost);
          return IconButtonTheme(
            data: IconButtonThemeData(
              style: IconButton.styleFrom(
                minimumSize: const Size(
                  WorkspaceSize.control,
                  WorkspaceSize.control,
                ),
                padding: const EdgeInsets.all(Space.xs),
                visualDensity: VisualDensity.compact,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    Space.md,
                    Space.sm,
                    Space.sm,
                    Space.sm,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.auto_awesome_outlined,
                        size: 18,
                        color: theme.colorScheme.primary,
                      ),
                      const SizedBox(width: Space.xs),
                      Text(l.aiAgentTitle, style: theme.textTheme.titleSmall),
                      const SizedBox(width: Space.sm),
                      Expanded(
                        child: Tooltip(
                          message: targetLabel,
                          child: Text(
                            targetLabel,
                            key: const ValueKey('ai-agent-target'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurface.withValues(
                                alpha: .55,
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: Space.sm),
                      Semantics(
                        expanded: _historyExpanded,
                        child: IconButton(
                          key: const ValueKey('ai-agent-history'),
                          tooltip: l.aiAgentHistory,
                          onPressed: () => setState(
                            () => _historyExpanded = !_historyExpanded,
                          ),
                          icon: const Icon(Icons.history_rounded, size: 17),
                        ),
                      ),
                      IconButton(
                        key: const ValueKey('ai-agent-new-task'),
                        tooltip: l.aiAgentNewTask,
                        onPressed: runtime.busy || conversations.loading
                            ? null
                            : () {
                                if (conversations.newConversation()) {
                                  _resetConversationUi();
                                }
                              },
                        icon: const Icon(Icons.add_comment_outlined, size: 17),
                      ),
                      IconButton(
                        tooltip: l.settings,
                        onPressed: () => showSettingsDialog(
                          context,
                          section: SettingsSectionId.ai,
                        ),
                        icon: const Icon(Icons.tune_outlined, size: 17),
                      ),
                      if (widget.onClose != null)
                        IconButton(
                          tooltip: l.close,
                          onPressed: widget.onClose,
                          icon: const Icon(Icons.close, size: 17),
                        ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                if (_historyExpanded)
                  ConstrainedBox(
                    key: const ValueKey('ai-agent-history-list'),
                    constraints: BoxConstraints(
                      maxHeight: min(240, constraints.maxHeight * .32),
                    ),
                    child: _History(
                      conversations: conversations,
                      onChoice: _history,
                    ),
                  ),
                Expanded(
                  child: runtime.timeline.isEmpty && !runtime.busy
                      ? _Welcome(
                          enabled: enabled,
                          failed: configuration.loadFailed,
                          compact: compact,
                          onExample: _replaceGoal,
                        )
                      : _Conversation(
                          key: ValueKey(conversations.selectedId),
                          runtime: runtime,
                          conversationId: conversations.selectedId,
                          canRegenerate:
                              enabled &&
                              !changedBinding &&
                              conversations.canRegenerate,
                          canWithdraw: conversations.canWithdraw,
                          onRegenerate: () => _regenerate(selectedHost),
                          onWithdraw: () {
                            if (conversations.withdrawLastTurn()) {
                              _resetConversationUi();
                            }
                          },
                        ),
                ),
                if (runtime.error != null || _startFailed)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      Space.md,
                      Space.xs,
                      Space.md,
                      0,
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.info_outline_rounded,
                          size: 16,
                          color: theme.colorScheme.error,
                        ),
                        const SizedBox(width: Space.sm),
                        Expanded(
                          child: Text(
                            _error(l, runtime.error),
                            maxLines: compact ? 2 : 4,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.error,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                const Divider(
                  key: ValueKey('ai-agent-composer-divider'),
                  height: 1,
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: Space.md,
                    vertical: Space.sm,
                  ),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: max(
                        112,
                        constraints.maxHeight * (compact ? .58 : .46),
                      ),
                    ),
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (changedBinding && !runtime.busy)
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    l.aiAgentHistoryTargetChanged,
                                    style: theme.textTheme.bodySmall,
                                  ),
                                ),
                                TextButton(
                                  key: const ValueKey('ai-agent-new-target'),
                                  onPressed: conversations.loading
                                      ? null
                                      : () {
                                          final goal = _goal.text;
                                          if (!conversations
                                              .newConversation()) {
                                            return;
                                          }
                                          _replaceGoal(goal);
                                          _resetConversationUi();
                                        },
                                  child: Text(l.aiAgentNewTask),
                                ),
                              ],
                            ),
                          if (conversations.loadFailed ||
                              conversations.saveFailed)
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    conversations.loadFailed
                                        ? l.aiAgentHistoryLoadFailed
                                        : l.aiAgentHistorySaveFailed,
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: theme.colorScheme.error,
                                    ),
                                  ),
                                ),
                                TextButton(
                                  onPressed: () => conversations.loadFailed
                                      ? conversations.reload()
                                      : conversations.retrySave(),
                                  child: Text(l.aiAgentHistoryRetry),
                                ),
                              ],
                            ),
                          if (conversations.current?.historyTruncated ?? false)
                            Text(
                              l.aiAgentHistoryTruncated,
                              style: theme.textTheme.bodySmall,
                            ),
                          if (runtime.contextCompacted)
                            Text(
                              l.aiAgentContextCompacted,
                              style: theme.textTheme.bodySmall,
                            ),
                          Focus(
                            onKeyEvent: (_, event) {
                              if (event is! KeyDownEvent ||
                                  event.logicalKey !=
                                      LogicalKeyboardKey.enter ||
                                  !(HardwareKeyboard
                                          .instance
                                          .isControlPressed ||
                                      HardwareKeyboard
                                          .instance
                                          .isMetaPressed) ||
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
                              minLines: compact ? 2 : 3,
                              maxLines: compact ? 3 : 6,
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
                                contentPadding: const EdgeInsets.symmetric(
                                  vertical: Space.sm,
                                  horizontal: Space.xs,
                                ),
                              ),
                              onChanged: (_) => _goalChanged(),
                            ),
                          ),
                          const SizedBox(height: Space.sm),
                          LayoutBuilder(
                            builder: (context, toolbar) {
                              final model = profile == null
                                  ? Text(
                                      l.aiAgentConfigureAction,
                                      style: theme.textTheme.bodySmall,
                                    )
                                  : AiModelPicker(
                                      key: const ValueKey('ai-agent-model'),
                                      value: profile.model,
                                      protocol: profile.protocol,
                                      endpoint: profile.endpoint,
                                      credentialIdentity:
                                          configuration.profile?.identity,
                                      compact: true,
                                      onChanged: runtime.busy
                                          ? null
                                          : ref
                                                .read(
                                                  selectedAgentModelProvider
                                                      .notifier,
                                                )
                                                .select,
                                    );
                              final usage = _ContextUsage(
                                runtime: runtime,
                                window: profile?.contextWindow ?? 0,
                              );
                              final permission = _PermissionPicker(
                                mode: runtime.busy
                                    ? runtime.permissionMode
                                    : permissionMode,
                                onChanged: !enabled || runtime.busy
                                    ? null
                                    : ref
                                          .read(
                                            selectedAgentPermissionModeProvider
                                                .notifier,
                                          )
                                          .select,
                              );
                              final actionStyle = IconButton.styleFrom(
                                minimumSize: const Size.square(
                                  WorkspaceSize.tabHeight,
                                ),
                                fixedSize: const Size.square(
                                  WorkspaceSize.tabHeight,
                                ),
                                padding: EdgeInsets.zero,
                                visualDensity: VisualDensity.standard,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(
                                    Radii.control,
                                  ),
                                ),
                              );
                              final action = runtime.busy
                                  ? IconButton.filledTonal(
                                      key: const ValueKey('ai-agent-stop'),
                                      tooltip: l.stop,
                                      onPressed: runtime.stop,
                                      style: actionStyle,
                                      icon: const Icon(
                                        Icons.stop_rounded,
                                        size: 16,
                                      ),
                                    )
                                  : IconButton.filled(
                                      key: const ValueKey('ai-agent-send'),
                                      tooltip: l.aiAgentSendShortcut,
                                      onPressed:
                                          !enabled ||
                                              conversations.loading ||
                                              draft.goal.trim().isEmpty
                                          ? null
                                          : () => _send(runtime, selectedHost),
                                      style: actionStyle.merge(
                                        IconButton.styleFrom(
                                          foregroundColor:
                                              theme.colorScheme.onPrimary,
                                        ),
                                      ),
                                      icon: const Icon(
                                        Icons.arrow_upward_rounded,
                                        size: 16,
                                      ),
                                    );
                              if (toolbar.maxWidth <
                                  280 *
                                      MediaQuery.textScalerOf(context)
                                          .scale(1)) {
                                return Column(
                                  children: [
                                    Row(
                                      children: [
                                        Expanded(child: model),
                                        const SizedBox(width: Space.sm),
                                        usage,
                                      ],
                                    ),
                                    const SizedBox(height: Space.sm),
                                    Row(
                                      children: [
                                        permission,
                                        const Spacer(),
                                        action,
                                      ],
                                    ),
                                  ],
                                );
                              }
                              return Row(
                                children: [
                                  Expanded(child: model),
                                  const SizedBox(width: Space.sm),
                                  usage,
                                  const SizedBox(width: Space.sm),
                                  permission,
                                  const SizedBox(width: Space.sm),
                                  action,
                                ],
                              );
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _History extends StatelessWidget {
  const _History({required this.conversations, required this.onChoice});
  final AgentConversations conversations;
  final void Function(String id, bool delete) onChoice;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final style = Theme.of(context).textTheme.bodySmall;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (conversations.runtime.busy)
          Padding(
            padding: const EdgeInsets.all(Space.sm),
            child: Text(l.aiAgentHistoryBusy, style: style),
          ),
        if (conversations.loading) const LinearProgressIndicator(),
        Flexible(
          child: conversations.records.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(Space.md),
                  child: Text(l.aiAgentHistoryEmpty),
                )
              : ListView.builder(
                  shrinkWrap: true,
                  itemCount: conversations.records.length,
                  itemBuilder: (context, index) {
                    final record = conversations.records[index];
                    final enabled =
                        !conversations.runtime.busy && !conversations.loading;
                    return Row(
                      children: [
                        Expanded(
                          child: PopupRow(
                            key: ValueKey('ai-conversation-${record.id}'),
                            selected: record.id == conversations.selectedId,
                            onTap: enabled
                                ? () => onChoice(record.id, false)
                                : null,
                            child: Text(
                              record.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                        IconButton(
                          key: ValueKey('ai-conversation-delete-${record.id}'),
                          tooltip: l.aiAgentHistoryDelete,
                          onPressed: enabled
                              ? () => onChoice(record.id, true)
                              : null,
                          icon: const Icon(
                            Icons.delete_outline_rounded,
                            size: 17,
                          ),
                        ),
                      ],
                    );
                  },
                ),
        ),
        const Divider(height: 1),
      ],
    );
  }
}

class _ContextUsage extends StatelessWidget {
  const _ContextUsage({required this.runtime, required this.window});
  final AgentRuntime runtime;
  final int window;

  @override
  Widget build(BuildContext context) {
    final total = runtime.contextWindow > 0 ? runtime.contextWindow : window;
    final used = runtime.contextUsedTokens;
    final ratio = total > 0 ? (used / total).clamp(0.0, 1.0) : 0.0;
    final percent = (ratio * 100).ceil();
    final l = AppLocalizations.of(context);
    return Tooltip(
      message: l.aiAgentContextUsage(percent, used, total),
      child: Semantics(
        label: l.aiAgentContextUsage(percent, used, total),
        child: Row(
          key: const ValueKey('ai-agent-context-usage'),
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                value: ratio,
                strokeWidth: 2,
                backgroundColor: Theme.of(context).colorScheme.outlineVariant,
              ),
            ),
            const SizedBox(width: Space.xs),
            Text('$percent%', style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}

IconData _permissionIcon(AgentPermissionMode mode) => switch (mode) {
  AgentPermissionMode.auto => Icons.bolt_outlined,
  AgentPermissionMode.confirm => Icons.verified_user_outlined,
  AgentPermissionMode.observe => Icons.visibility_outlined,
};

String _permissionLabel(AppLocalizations l, AgentPermissionMode mode) =>
    switch (mode) {
      AgentPermissionMode.auto => l.aiAgentPermissionAuto,
      AgentPermissionMode.confirm => l.aiAgentPermissionConfirm,
      AgentPermissionMode.observe => l.aiAgentPermissionObserve,
    };

class _PermissionPicker extends StatelessWidget {
  const _PermissionPicker({required this.mode, required this.onChanged});
  final AgentPermissionMode mode;
  final ValueChanged<AgentPermissionMode>? onChanged;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Builder(
      builder: (anchorContext) => TextButton(
        key: const ValueKey('ai-agent-permission'),
        onPressed: onChanged == null
            ? null
            : () async {
                final picked = await showAnchoredPopup<AgentPermissionMode>(
                  context: context,
                  anchor: anchorOf(anchorContext),
                  width: 180,
                  builder: (context) => PopupSurface(
                    padding: const EdgeInsets.symmetric(vertical: Space.xs),
                    child: PopupKeys(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (final option in [
                            AgentPermissionMode.auto,
                            AgentPermissionMode.confirm,
                            AgentPermissionMode.observe,
                          ])
                            PopupRow(
                              key: ValueKey(
                                'ai-agent-permission-${option.name}',
                              ),
                              selected: option == mode,
                              onTap: () => Navigator.pop(context, option),
                              child: Tooltip(
                                message: switch (option) {
                                  AgentPermissionMode.auto =>
                                    l.aiAgentPermissionAutoHint,
                                  AgentPermissionMode.confirm =>
                                    l.aiAgentPermissionConfirmHint,
                                  AgentPermissionMode.observe =>
                                    l.aiAgentPermissionObserveHint,
                                },
                                child: Row(
                                  children: [
                                    Icon(_permissionIcon(option), size: 16),
                                    const SizedBox(width: Space.sm),
                                    Expanded(
                                      child: Text(_permissionLabel(l, option)),
                                    ),
                                    if (option == mode)
                                      const Icon(Icons.check_rounded, size: 16),
                                  ],
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                );
                if (picked != null) onChanged?.call(picked);
              },
        style: TextButton.styleFrom(
          minimumSize: const Size(0, WorkspaceSize.tabHeight),
          padding: const EdgeInsets.symmetric(horizontal: Space.xs),
          foregroundColor: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(_permissionIcon(mode), size: 16),
            const SizedBox(width: Space.xs),
            Text(_permissionLabel(l, mode)),
            const Icon(Icons.keyboard_arrow_down_rounded, size: 16),
          ],
        ),
      ),
    );
  }
}

class _Welcome extends StatelessWidget {
  const _Welcome({
    required this.enabled,
    required this.failed,
    required this.compact,
    required this.onExample,
  });
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
            BrandIllustration(
              pose: BrandPose.thinkingAi,
              size: compact ? 96 : 144,
            ),
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
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: Space.lg),
            if (!enabled)
              FilledButton.tonal(
                onPressed: () =>
                    showSettingsDialog(context, section: SettingsSectionId.ai),
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

class _Conversation extends StatefulWidget {
  const _Conversation({
    super.key,
    required this.runtime,
    required this.conversationId,
    required this.canRegenerate,
    required this.canWithdraw,
    required this.onRegenerate,
    required this.onWithdraw,
  });
  final AgentRuntime runtime;
  final String conversationId;
  final bool canRegenerate, canWithdraw;
  final VoidCallback onRegenerate, onWithdraw;

  @override
  State<_Conversation> createState() => _ConversationState();
}

class _ConversationState extends State<_Conversation> {
  final _scroll = ScrollController();
  final _keys = <AgentTimelineEntry, GlobalKey>{};
  String? _highlighted;
  int _navigation = 0, _revealVersion = 0;

  List<AgentTimelineEntry> get _entries => widget.runtime.timeline
      .where(
        (entry) =>
            entry is! AgentChatEntry ||
            (!entry.retracted && entry.text.isNotEmpty),
      )
      .toList();

  @override
  void dispose() {
    _navigation++;
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _reveal(String id) async {
    final navigation = ++_navigation;
    final disableAnimations = MediaQuery.disableAnimationsOf(context);
    setState(() {
      _highlighted = id;
      _revealVersion++;
    });
    await WidgetsBinding.instance.endOfFrame;
    for (
      var attempt = 0;
      mounted && navigation == _navigation && attempt < 64;
      attempt++
    ) {
      final entries = _entries;
      final index = entries.indexWhere(
        (entry) => entry is AgentExecution && entry.id == id,
      );
      if (index < 0 || !_scroll.hasClients) return;
      final target = _keys[entries[index]]?.currentContext;
      if (target != null) {
        if (!target.mounted) return;
        await Scrollable.ensureVisible(
          target,
          alignment: .2,
          duration: disableAnimations ? Duration.zero : Motion.normal,
        );
        return;
      }
      final position = _scroll.position;
      double offset;
      if (attempt == 0) {
        offset =
            position.maxScrollExtent *
            (entries.length - index - 1) /
            max(1, entries.length - 1);
      } else {
        final visible = [
          for (var i = 0; i < entries.length; i++)
            if (_keys[entries[i]]?.currentContext != null) i,
        ];
        if (visible.isEmpty) return;
        offset =
            position.pixels +
            (index < visible.first ? 1 : -1) * position.viewportDimension * .8;
      }
      offset = offset.clamp(0, position.maxScrollExtent);
      if (attempt > 0 && (offset - position.pixels).abs() < 1) return;
      _scroll.jumpTo(offset);
      await WidgetsBinding.instance.endOfFrame;
    }
  }

  Future<void> _copy(String text) async {
    final l = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    var message = l.aiAgentCopied;
    try {
      await Clipboard.setData(ClipboardData(text: text));
    } on Object {
      message = l.aiAgentCopyFailed;
    }
    if (mounted) messenger.showSnackBar(SnackBar(content: Text(message)));
  }

  Widget _actions(AgentChatEntry message, int index, {required bool latest}) {
    final l = AppLocalizations.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          key: ValueKey('ai-agent-copy-$index'),
          tooltip: l.copy,
          onPressed: () => _copy(message.text),
          icon: const Icon(Icons.copy_outlined, size: 14),
        ),
        if (latest) ...[
          Tooltip(
            message: l.aiAgentRegenerateHint,
            child: IconButton(
              key: const ValueKey('ai-agent-regenerate'),
              tooltip: l.aiAgentRegenerate,
              onPressed: widget.canRegenerate ? widget.onRegenerate : null,
              icon: const Icon(Icons.refresh_rounded, size: 16),
            ),
          ),
          Tooltip(
            message: l.aiAgentWithdrawHint,
            child: IconButton(
              key: const ValueKey('ai-agent-withdraw'),
              tooltip: l.aiAgentWithdraw,
              onPressed: widget.canWithdraw ? widget.onWithdraw : null,
              icon: const Icon(Icons.undo_rounded, size: 16),
            ),
          ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final entries = _entries;
    final current = entries.toSet();
    _keys.removeWhere((entry, _) => !current.contains(entry));
    final references = <String, String>{};
    final ambiguous = <String>{};
    for (final execution in entries.whereType<AgentExecution>()) {
      for (final id in [
        execution.id,
        if (execution.output != null) execution.output!.id,
      ]) {
        if (ambiguous.contains(id)) continue;
        if (references.containsKey(id) && references[id] != execution.id) {
          references.remove(id);
          ambiguous.add(id);
        } else {
          references[id] = execution.id;
        }
      }
    }
    final lastUser = entries.lastIndexWhere(
      (entry) => entry is AgentChatEntry && entry.role == 'user',
    );
    final lastAssistant = entries.lastIndexWhere(
      (entry) => entry is AgentChatEntry && entry.role == 'assistant',
    );
    final approval = widget.runtime.approval;
    final data = widget.runtime.dataRequest;
    final thinking = widget.runtime.busy && approval == null && data == null;
    final count =
        entries.length +
        (approval == null ? 0 : 1) +
        (data == null ? 0 : 1) +
        (thinking ? 1 : 0);
    return SelectionArea(
      child: ListView.builder(
        key: PageStorageKey('ai-agent-conversation-${widget.conversationId}'),
        controller: _scroll,
        padding: const EdgeInsets.symmetric(
          horizontal: Space.md,
          vertical: Space.sm,
        ),
        reverse: true,
        itemCount: count,
        itemBuilder: (context, index) {
          index = count - index - 1;
          if (index < entries.length) {
            final entry = entries[index];
            Widget row;
            if (entry is AgentExecution) {
              row = _ExecutionCard(
                key: ValueKey(entry.id),
                execution: entry,
                revealVersion: _highlighted == entry.id ? _revealVersion : 0,
              );
            } else {
              final message = entry as AgentChatEntry;
              final user = message.role == 'user';
              final theme = Theme.of(context);
              row = Padding(
                padding: const EdgeInsets.only(bottom: Space.sm),
                child: Column(
                  crossAxisAlignment: user
                      ? CrossAxisAlignment.end
                      : CrossAxisAlignment.start,
                  children: [
                    if (user)
                      LayoutBuilder(
                        builder: (context, constraints) => Align(
                          alignment: Alignment.centerRight,
                          child: Container(
                            key: const ValueKey('ai-agent-user-message'),
                            constraints: BoxConstraints(
                              maxWidth: constraints.maxWidth * .94,
                            ),
                            padding: const EdgeInsets.symmetric(
                              horizontal: Space.md,
                              vertical: Space.sm,
                            ),
                            decoration: BoxDecoration(
                              border: Border.all(
                                color: theme.colorScheme.outlineVariant,
                              ),
                              borderRadius: BorderRadius.circular(
                                Radii.control,
                              ),
                            ),
                            child: Text(
                              message.text,
                              style: theme.textTheme.bodyMedium,
                            ),
                          ),
                        ),
                      )
                    else ...[
                      AiMarkdown(
                        data: message.text,
                        executionReferences: references,
                        onExecution: _reveal,
                      ),
                      _actions(
                        message,
                        index,
                        latest: index == lastAssistant && index > lastUser,
                      ),
                    ],
                    if (user &&
                        index == lastUser &&
                        lastAssistant < lastUser &&
                        widget.canWithdraw)
                      IconButton(
                        key: const ValueKey('ai-agent-withdraw'),
                        tooltip: AppLocalizations.of(context)
                            .aiAgentWithdrawHint,
                        onPressed: widget.onWithdraw,
                        icon: const Icon(Icons.undo_rounded, size: 16),
                      ),
                  ],
                ),
              );
            }
            return KeyedSubtree(
              key: _keys.putIfAbsent(entry, GlobalKey.new),
              child: row,
            );
          }
          index -= entries.length;
          if (approval != null) {
            if (index == 0) {
              return _ApprovalCard(
                approval: approval,
                onApprove: () =>
                    widget.runtime.approve(true, expected: approval),
                onReject: () =>
                    widget.runtime.approve(false, expected: approval),
              );
            }
            index--;
          }
          if (data != null) {
            if (index == 0) {
              return _OutputApproval(
                key: ObjectKey(data),
                request: data,
                runtime: widget.runtime,
              );
            }
            index--;
          }
          return const _ThinkingDots();
        },
      ),
    );
  }
}

class _ThinkingDots extends StatefulWidget {
  const _ThinkingDots();

  @override
  State<_ThinkingDots> createState() => _ThinkingDotsState();
}

class _ThinkingDotsState extends State<_ThinkingDots> {
  Timer? _timer;
  int _step = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _timer?.cancel();
    if (!MediaQuery.disableAnimationsOf(context)) {
      _timer = Timer.periodic(
        const Duration(milliseconds: 400),
        (_) => setState(() => _step = (_step + 1) % 3),
      );
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
    label: AppLocalizations.of(context).aiAgentStreaming,
    child: Padding(
      key: const ValueKey('ai-agent-thinking'),
      padding: const EdgeInsets.symmetric(vertical: Space.sm),
      child: Row(
        children: [
          for (var i = 0; i < 3; i++)
            Padding(
              padding: const EdgeInsets.only(right: Space.xs),
              child: AnimatedOpacity(
                opacity: _timer == null || i == _step ? .9 : .3,
                duration: MediaQuery.disableAnimationsOf(context)
                    ? Duration.zero
                    : Motion.quick,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    shape: BoxShape.circle,
                  ),
                  child: const SizedBox.square(dimension: Space.xs),
                ),
              ),
            ),
        ],
      ),
    ),
  );
}

class _ExecutionCard extends StatefulWidget {
  const _ExecutionCard({
    super.key,
    required this.execution,
    this.revealVersion = 0,
  });
  final AgentExecution execution;
  final int revealVersion;

  @override
  State<_ExecutionCard> createState() => _ExecutionCardState();
}

class _ExecutionCardState extends State<_ExecutionCard> {
  bool _expanded = false;

  @override
  void didUpdateWidget(_ExecutionCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.revealVersion != 0 &&
        widget.revealVersion != oldWidget.revealVersion) {
      _expanded = true;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final execution = widget.execution;
    final output = execution.output;
    final failed =
        execution.state == 'failed' ||
        (execution.exitCode != null && execution.exitCode != 0);
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
                  tooltip: _expanded
                      ? l.aiAgentHideOutput
                      : l.aiAgentShowOutput,
                  onPressed: () => setState(() => _expanded = !_expanded),
                  icon: Icon(
                    _expanded
                        ? Icons.expand_less_rounded
                        : Icons.chevron_right_rounded,
                    size: 17,
                  ),
                ),
                Expanded(
                  child: Text(
                    execution.archived
                        ? (execution.capability == 'agent.diagnose'
                              ? l.aiAgentDiagnostics
                              : l.aiAgentHistory)
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
                    color: failed || unknown
                        ? theme.colorScheme.error
                        : theme.colorScheme.onSurfaceVariant,
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
                    failed
                        ? l.aiAgentExecutionFailed
                        : _executionState(l, execution.state),
                    style: theme.textTheme.bodySmall,
                  ),
                  if (execution.exitCode case final code?)
                    Text(
                      l.aiAgentExitCode(code),
                      style: theme.textTheme.bodySmall,
                    ),
                  if (execution.historyTruncated ||
                      (output?.truncated ?? false))
                    Text(l.aiAgentTruncated, style: theme.textTheme.bodySmall),
                ],
              ),
              if (execution.archived) ...[
                const SizedBox(height: Space.sm),
                Text(
                  l.aiAgentHistoryOutputUnavailable,
                  style: theme.textTheme.bodySmall,
                ),
                if (execution.sharedText?.isNotEmpty ?? false) ...[
                  const SizedBox(height: Space.sm),
                  Text(
                    execution.sharedText!,
                    style: mono(context, theme.textTheme.bodySmall),
                  ),
                ],
              ],
              if (!execution.archived && execution.cwd.isNotEmpty) ...[
                const SizedBox(height: Space.sm),
                Text(
                  execution.cwd,
                  style: mono(context, theme.textTheme.bodySmall),
                ),
              ],
              if (!execution.archived &&
                  output != null &&
                  output.length > 0) ...[
                const SizedBox(height: Space.sm),
                const Divider(height: 1),
                const SizedBox(height: Space.sm),
                Text(
                  output.excerpt,
                  style: mono(context, theme.textTheme.bodySmall),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

class _ApprovalCard extends StatelessWidget {
  const _ApprovalCard({
    required this.approval,
    required this.onApprove,
    required this.onReject,
  });
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
            _CardTitle(
              icon: Icons.terminal_rounded,
              label: l.aiAgentApproveTitle,
            ),
            const SizedBox(height: Space.md),
            Text(approval.target, style: theme.textTheme.labelLarge),
            const SizedBox(height: Space.xs),
            Text(approval.cwd, style: mono(context, theme.textTheme.bodySmall)),
            const SizedBox(height: Space.md),
            Text(
              approval.command,
              style: mono(context, theme.textTheme.bodyMedium),
            ),
            const SizedBox(height: Space.md),
            Text(l.aiAgentShellPermission, style: theme.textTheme.bodySmall),
            const SizedBox(height: Space.md),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: Space.sm,
              runSpacing: Space.sm,
              children: [
                TextButton(onPressed: onReject, child: Text(l.aiAgentReject)),
                FilledButton.tonal(
                  onPressed: onApprove,
                  child: Text(l.aiAgentApprove),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _OutputApproval extends ConsumerStatefulWidget {
  const _OutputApproval({
    super.key,
    required this.request,
    required this.runtime,
  });
  final AgentDataRequest request;
  final AgentRuntime runtime;

  @override
  ConsumerState<_OutputApproval> createState() => _OutputApprovalState();
}

class _OutputApprovalState extends ConsumerState<_OutputApproval> {
  late final _text = TextEditingController(
    text: ref.read(agentComposerProvider).outputText(widget.request),
  );

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
            Text(
              l.aiAgentSharePreview,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: Space.sm),
            TextField(
              key: const ValueKey('ai-agent-output-projection'),
              controller: _text,
              minLines: 3,
              maxLines: 8,
              maxLength: 8192,
              style: mono(context, Theme.of(context).textTheme.bodySmall),
              decoration: InputDecoration(
                errorText: valid ? null : l.aiAgentProjectionTooLarge,
                counterText: '',
              ),
              onChanged: (value) {
                ref
                    .read(agentComposerProvider.notifier)
                    .editOutput(widget.request, value);
                setState(() {});
              },
            ),
            if (widget.request.output.truncated) ...[
              const SizedBox(height: Space.sm),
              Text(
                l.aiAgentTruncated,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: Space.md),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: Space.sm,
              runSpacing: Space.sm,
              children: [
                TextButton(
                  onPressed: () => _share(null),
                  child: Text(l.aiAgentKeepLocal),
                ),
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
      Expanded(
        child: Text(label, style: Theme.of(context).textTheme.labelLarge),
      ),
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
        border: Border.all(
          color: emphasized
              ? scheme.primary.withValues(alpha: .45)
              : scheme.outlineVariant,
        ),
      ),
      child: child,
    );
  }
}

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
  'notConfigured' ||
  'invalidModelKey' ||
  'invalidModelRequest' => l.aiAgentErrorConfiguration,
  'modelNetworkError' => l.aiAgentErrorNetwork,
  'modelHttpError' ||
  'modelStreamError' ||
  'modelRefused' => l.aiAgentErrorHttp,
  'deadline' || 'modelTimedOut' => l.aiAgentErrorTimeout,
  'contextLimit' ||
  'scopeLimit' ||
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
  'journalFailed' ||
  'operationConflict' ||
  'operationMissingIntent' ||
  'operationCapacity' => l.aiAgentErrorJournal,
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

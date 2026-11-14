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
import '../adapters/attachments.dart';
import '../adapters/attachment_drop.dart';
import '../domain/attachment.dart';
import 'model_picker.dart';
import '../application/runtime.dart';
import '../domain/agent.dart';
import '../domain/model_profile.dart';

class AgentPanel extends ConsumerStatefulWidget {
  const AgentPanel({super.key, this.onClose});
  final VoidCallback? onClose;

  @override
  ConsumerState<AgentPanel> createState() => _AgentPanelState();
}

class _AgentPanelState extends ConsumerState<AgentPanel> {
  late final _goal = TextEditingController(text: ref.read(agentComposerProvider).goal);
  bool _startFailed = false, _historyExpanded = false, _pickingAttachment = false, _dropHover = false;
  FormatException? _attachmentError;
  final _conversationKey = GlobalKey<_ConversationState>();

  void _resetConversationUi() => setState(() {
    _startFailed = false;
    _attachmentError = null;
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
            TextButton(onPressed: () => Navigator.pop(context, false), child: Text(l.cancel)),
            TextButton(onPressed: () => Navigator.pop(context, true), child: Text(l.aiAgentHistoryDelete)),
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

  void _goalChanged() => ref.read(agentComposerProvider.notifier).setGoal(_goal.text);

  void _replaceGoal(String value) {
    _goal.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
    _goalChanged();
  }

  bool get _attachmentEnabled {
    final configuration = ref.read(aiConfigurationProvider);
    final conversations = ref.read(agentConversationsProvider);
    return configuration.enabled &&
        configuration.profile != null &&
        !configuration.loadFailed &&
        !conversations.loading &&
        !conversations.runtime.busy;
  }

  Future<void> _paste(VoidCallback pasteText) async {
    if (_pickingAttachment) return;
    if (!_attachmentEnabled) {
      pasteText();
      return;
    }
    await _attach(clipboard: true, pasteText: pasteText);
  }

  Future<void> _attach({List<String>? paths, bool clipboard = false, VoidCallback? pasteText}) async {
    if (_pickingAttachment || !_attachmentEnabled) return;
    final conversations = ref.read(agentConversationsProvider);
    final selected = conversations.selectedId;
    final draft = ref.read(agentComposerProvider);
    final configuration = ref.read(aiConfigurationProvider);
    final textValue = _goal.value;
    final picker = ref.read(agentAttachmentPickerProvider);
    var invalidated = false;
    bool current() =>
        mounted &&
        !invalidated &&
        selected == conversations.selectedId &&
        _attachmentEnabled &&
        identical(ref.read(aiConfigurationProvider), configuration) &&
        identical(ref.read(agentComposerProvider).attachments, draft.attachments);
    void checkCurrent() {
      if (!current()) invalidated = true;
    }

    conversations.addListener(checkCurrent);
    conversations.runtime.addListener(checkCurrent);
    setState(() {
      _pickingAttachment = true;
      _dropHover = false;
      _attachmentError = null;
    });
    try {
      if (clipboard) {
        paths = await picker.clipboardFiles();
        if (!current()) return;
        if (paths.isEmpty) {
          if (_goal.value == textValue) pasteText?.call();
          return;
        }
      }
      final attachments = paths == null
          ? await picker.choose(draft.attachments)
          : await picker.importFiles(paths, draft.attachments);
      if (current()) ref.read(agentComposerProvider.notifier).setAttachments(attachments);
    } on FormatException catch (error) {
      if (current()) setState(() => _attachmentError = error);
    } on Object {
      if (current()) setState(() => _attachmentError = const FormatException('attachmentUnreadable'));
    } finally {
      conversations.removeListener(checkCurrent);
      conversations.runtime.removeListener(checkCurrent);
      if (mounted) setState(() => _pickingAttachment = false);
    }
  }

  String _attachmentMessage(AppLocalizations l) {
    final message = switch (_attachmentError?.message) {
      'attachmentTooMany' => l.aiAgentAttachmentTooMany(AgentAttachmentLimits.count),
      'attachmentTotalTooLarge' => l.aiAgentAttachmentTotalTooLarge(AgentAttachmentLimits.totalBytes >> 20),
      'attachmentImageTooLarge' => l.aiAgentAttachmentImageTooLarge,
      'attachmentTooLarge' => l.aiAgentAttachmentTooLarge,
      'attachmentUnsupported' => l.aiAgentAttachmentUnsupported,
      _ => l.aiAgentAttachmentUnreadable,
    };
    if (_attachmentError case AttachmentImportFailure(:final fileName)) {
      return l.aiAgentAttachmentFileError(fileName, message);
    }
    return message;
  }

  Future<void> _send(AgentRuntime runtime, HostId? host) async {
    final goal = _goal.text.trim();
    final conversations = ref.read(agentConversationsProvider);
    final draft = ref.read(agentComposerProvider);
    if (runtime.busy ||
        conversations.loading ||
        _pickingAttachment ||
        (goal.isEmpty && draft.attachments.isEmpty) ||
        !_goal.value.composing.isCollapsed) {
      return;
    }
    if (conversations.hasHistory && !conversations.canContinue(host)) return;
    setState(() => _startFailed = false);
    try {
      final sending = conversations.send(goal, host, continueHistory: true);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _conversationKey.currentState?.scrollToBottom();
      });
      await sending;
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
    final enabled = configuration.enabled && configuration.profile != null && !configuration.loadFailed;
    final profile = ref.watch(effectiveAgentProfileProvider);
    final tools = profile?.tools ?? false;
    final focusedHost = ref.watch(agentFocusedHostProvider);
    final selectedHost = tools && hosts.any((host) => host.id == focusedHost) ? focusedHost : null;
    final theme = Theme.of(context);

    return ListenableBuilder(
      listenable: Listenable.merge([runtime, conversations]),
      builder: (context, _) => LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxHeight < 440;
          final targetHost = runtime.busy ? runtime.resolvedHost : selectedHost;
          final targetLabel = hosts.where((host) => host.id == targetHost).firstOrNull?.label ?? l.aiAgentAutoTarget;
          final changedBinding = conversations.hasHistory && !conversations.canContinue(selectedHost);
          return IconButtonTheme(
            data: IconButtonThemeData(
              style: IconButton.styleFrom(
                minimumSize: const Size(WorkspaceSize.control, WorkspaceSize.control),
                padding: const EdgeInsets.all(Space.xs),
                visualDensity: VisualDensity.compact,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
            child: AgentAttachmentDropZone(
              key: const ValueKey('ai-agent-file-drop'),
              enabled: _attachmentEnabled && !_pickingAttachment,
              onHover: (value) {
                if (mounted && _dropHover != value) setState(() => _dropHover = value);
              },
              onDrop: (paths) => unawaited(_attach(paths: paths)),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: _dropHover && _attachmentEnabled && !_pickingAttachment
                      ? Border.all(color: theme.colorScheme.primary)
                      : null,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(Space.md, Space.sm, Space.sm, Space.sm),
                      child: Row(
                        children: [
                          Icon(Icons.auto_awesome_outlined, size: 18, color: theme.colorScheme.primary),
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
                                  color: theme.colorScheme.onSurface.withValues(alpha: .55),
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
                              onPressed: () => setState(() => _historyExpanded = !_historyExpanded),
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
                            onPressed: () => showSettingsDialog(context, section: SettingsSectionId.ai),
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
                        constraints: BoxConstraints(maxHeight: min(240, constraints.maxHeight * .32)),
                        child: _History(conversations: conversations, onChoice: _history),
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
                              key: _conversationKey,
                              runtime: runtime,
                              conversationId: conversations.selectedId,
                              historyTruncated: conversations.current?.historyTruncated ?? false,
                              canRegenerate: enabled && !changedBinding && conversations.canRegenerate,
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
                    const Divider(key: ValueKey('ai-agent-composer-divider'), height: 1),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: Space.md, vertical: Space.sm),
                      child: ConstrainedBox(
                        constraints: BoxConstraints(maxHeight: max(112, constraints.maxHeight * (compact ? .58 : .46))),
                        child: SingleChildScrollView(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (changedBinding && !runtime.busy)
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(l.aiAgentHistoryTargetChanged, style: theme.textTheme.bodySmall),
                                    ),
                                    TextButton(
                                      key: const ValueKey('ai-agent-new-target'),
                                      onPressed: conversations.loading
                                          ? null
                                          : () {
                                              final goal = _goal.text;
                                              if (!conversations.newConversation()) {
                                                return;
                                              }
                                              _replaceGoal(goal);
                                              _resetConversationUi();
                                            },
                                      child: Text(l.aiAgentNewTask),
                                    ),
                                  ],
                                ),
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
                              if (_attachmentError != null)
                                Text(
                                  _attachmentMessage(l),
                                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
                                ),
                              if (draft.attachments.isNotEmpty)
                                _AttachmentList(
                                  attachments: draft.attachments,
                                  onRemove: runtime.busy
                                      ? null
                                      : (attachment) {
                                          ref
                                              .read(agentComposerProvider.notifier)
                                              .setAttachments(
                                                draft.attachments.where((value) => value.id != attachment.id),
                                              );
                                        },
                                ),
                              Focus(
                                onKeyEvent: (_, event) {
                                  final keys = HardwareKeyboard.instance;
                                  final enter =
                                      event.logicalKey == LogicalKeyboardKey.enter ||
                                      event.logicalKey == LogicalKeyboardKey.numpadEnter;
                                  if (event is! KeyDownEvent ||
                                      !enter ||
                                      keys.isShiftPressed ||
                                      keys.isControlPressed ||
                                      keys.isAltPressed ||
                                      keys.isMetaPressed ||
                                      !_goal.value.composing.isCollapsed) {
                                    return KeyEventResult.ignored;
                                  }
                                  if (enabled &&
                                      !runtime.busy &&
                                      !conversations.loading &&
                                      (_goal.text.trim().isNotEmpty || draft.attachments.isNotEmpty)) {
                                    unawaited(_send(runtime, selectedHost));
                                  }
                                  return KeyEventResult.handled;
                                },
                                child: Actions(
                                  actions: {PasteTextIntent: _AttachmentPasteAction(_paste)},
                                  child: TextField(
                                    key: const ValueKey('ai-agent-goal'),
                                    controller: _goal,
                                    enabled: enabled,
                                    minLines: compact ? 2 : 3,
                                    maxLines: compact ? 3 : 6,
                                    maxLength: 4096,
                                    contextMenuBuilder: (context, editable) {
                                      final paste = ContextMenuButtonItem(
                                        type: ContextMenuButtonType.paste,
                                        onPressed: () {
                                          editable.hideToolbar();
                                          unawaited(_paste(() => editable.pasteText(SelectionChangedCause.toolbar)));
                                        },
                                      );
                                      final items = [
                                        for (final item in editable.contextMenuButtonItems)
                                          item.type == ContextMenuButtonType.paste ? paste : item,
                                      ];
                                      if (!items.any((item) => item.type == ContextMenuButtonType.paste)) {
                                        items.add(paste);
                                      }
                                      return AdaptiveTextSelectionToolbar.buttonItems(
                                        anchors: editable.contextMenuAnchors,
                                        buttonItems: items,
                                      );
                                    },
                                    decoration: const InputDecoration(
                                      counterText: '',
                                      border: InputBorder.none,
                                      enabledBorder: InputBorder.none,
                                      focusedBorder: InputBorder.none,
                                      disabledBorder: InputBorder.none,
                                      filled: false,
                                      isDense: true,
                                      contentPadding: EdgeInsets.symmetric(vertical: Space.sm, horizontal: Space.xs),
                                    ),
                                    onChanged: (_) => _goalChanged(),
                                  ),
                                ),
                              ),
                              const SizedBox(height: Space.sm),
                              LayoutBuilder(
                                builder: (context, toolbar) {
                                  final model = profile == null
                                      ? Text(
                                          l.aiAgentConfigureAction,
                                          style: theme.textTheme.bodySmall,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        )
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
                                          footer: (_) => const _ReasoningOptions(),
                                        );
                                  final usage = _ContextUsage(runtime: runtime, window: profile?.contextWindow ?? 0);
                                  final permission = _PermissionPicker(
                                    compact: toolbar.maxWidth < 480 * MediaQuery.textScalerOf(context).scale(1),
                                    mode: runtime.busy ? runtime.permissionMode : permissionMode,
                                    onChanged: !enabled || runtime.busy
                                        ? null
                                        : ref.read(selectedAgentPermissionModeProvider.notifier).select,
                                  );
                                  final actionStyle = IconButton.styleFrom(
                                    minimumSize: const Size.square(WorkspaceSize.tabHeight),
                                    fixedSize: const Size.square(WorkspaceSize.tabHeight),
                                    padding: EdgeInsets.zero,
                                    visualDensity: VisualDensity.standard,
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.control)),
                                  );
                                  final action = runtime.busy
                                      ? IconButton.filledTonal(
                                          key: const ValueKey('ai-agent-stop'),
                                          tooltip: l.stop,
                                          onPressed: runtime.stop,
                                          style: actionStyle,
                                          icon: const Icon(Icons.stop_rounded, size: 16),
                                        )
                                      : IconButton.filled(
                                          key: const ValueKey('ai-agent-send'),
                                          tooltip: l.aiAgentSendShortcut,
                                          onPressed:
                                              !enabled ||
                                                  conversations.loading ||
                                                  _pickingAttachment ||
                                                  (draft.goal.trim().isEmpty && draft.attachments.isEmpty)
                                              ? null
                                              : () => _send(runtime, selectedHost),
                                          style: actionStyle.merge(
                                            IconButton.styleFrom(foregroundColor: theme.colorScheme.onPrimary),
                                          ),
                                          icon: const Icon(Icons.arrow_upward_rounded, size: 16),
                                        );
                                  return Row(
                                    children: [
                                      IconButton(
                                        key: const ValueKey('ai-agent-attach'),
                                        tooltip: l.aiAgentAttach,
                                        onPressed: !enabled || runtime.busy || _pickingAttachment ? null : _attach,
                                        style: actionStyle,
                                        icon: const Icon(Icons.attach_file_rounded, size: 17),
                                      ),
                                      Expanded(child: model),
                                      const SizedBox(width: Space.xs),
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
              ),
            ),
          );
        },
      ),
    );
  }
}

class _AttachmentPasteAction extends Action<PasteTextIntent> {
  _AttachmentPasteAction(this.paste);
  final Future<void> Function(VoidCallback) paste;

  @override
  Object? invoke(PasteTextIntent intent) {
    final fallback = callingAction;
    unawaited(paste(() => fallback?.invoke(intent)));
    return null;
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
              ? Padding(padding: const EdgeInsets.all(Space.md), child: Text(l.aiAgentHistoryEmpty))
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
                            onTap: enabled ? () => onChoice(record.id, false) : null,
                            child: Text(record.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                          ),
                        ),
                        IconButton(
                          key: ValueKey('ai-conversation-delete-${record.id}'),
                          tooltip: l.aiAgentHistoryDelete,
                          onPressed: enabled ? () => onChoice(record.id, true) : null,
                          icon: const Icon(Icons.delete_outline_rounded, size: 17),
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

String _reasoningLabel(AppLocalizations l, ReasoningEffort effort) => switch (effort) {
  ReasoningEffort.modelDefault => l.aiReasoningDefault,
  ReasoningEffort.off => l.aiReasoningOff,
  ReasoningEffort.low => l.aiReasoningLow,
  ReasoningEffort.medium => l.aiReasoningMedium,
  ReasoningEffort.high => l.aiReasoningHigh,
};

/// Lives in the model popup: the effort belongs to the chosen model and applies to the next turn.
class _ReasoningOptions extends ConsumerWidget {
  const _ReasoningOptions();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final effort = ref.watch(effectiveAgentProfileProvider)?.reasoningEffort ?? ReasoningEffort.modelDefault;
    final locked = ref.watch(agentTurnActiveProvider);
    return Row(
      children: [
        Tooltip(
          message: l.aiReasoningEffort,
          child: const Padding(
            padding: EdgeInsets.symmetric(horizontal: Space.sm),
            child: Icon(Icons.psychology_outlined, size: 16),
          ),
        ),
        Expanded(
          // One row at any width: the options shrink together instead of wrapping.
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final option in ReasoningEffort.values) ...[
                  if (option != ReasoningEffort.values.first) const SizedBox(width: Space.xs),
                  ChoiceChip(
                    key: ValueKey('ai-agent-reasoning-${option.name}'),
                    label: Text(_reasoningLabel(l, option)),
                    labelPadding: const EdgeInsets.symmetric(horizontal: Space.xs),
                    selected: option == effort,
                    showCheckmark: false,
                    visualDensity: VisualDensity.compact,
                    onSelected: locked ? null : (_) => ref.read(selectedAgentReasoningProvider.notifier).select(option),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

IconData _permissionIcon(AgentPermissionMode mode) => switch (mode) {
  AgentPermissionMode.auto => Icons.bolt_outlined,
  AgentPermissionMode.review => Icons.auto_awesome_outlined,
  AgentPermissionMode.confirm => Icons.verified_user_outlined,
  AgentPermissionMode.observe => Icons.visibility_outlined,
};

String _permissionLabel(AppLocalizations l, AgentPermissionMode mode) => switch (mode) {
  AgentPermissionMode.auto => l.aiAgentPermissionAuto,
  AgentPermissionMode.review => l.aiAgentPermissionReview,
  AgentPermissionMode.confirm => l.aiAgentPermissionConfirm,
  AgentPermissionMode.observe => l.aiAgentPermissionObserve,
};

String _permissionHint(AppLocalizations l, AgentPermissionMode mode) => switch (mode) {
  AgentPermissionMode.auto => l.aiAgentPermissionAutoHint,
  AgentPermissionMode.review => l.aiAgentPermissionReviewHint,
  AgentPermissionMode.confirm => l.aiAgentPermissionConfirmHint,
  AgentPermissionMode.observe => l.aiAgentPermissionObserveHint,
};

class _PermissionPicker extends StatelessWidget {
  const _PermissionPicker({required this.mode, required this.onChanged, this.compact = false});
  final bool compact;
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
                  width: WorkspaceSize.toolPanelMin,
                  builder: (context) => PopupSurface(
                    padding: const EdgeInsets.symmetric(vertical: Space.xs),
                    child: PopupKeys(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (final option in [
                            AgentPermissionMode.observe,
                            AgentPermissionMode.confirm,
                            AgentPermissionMode.review,
                            AgentPermissionMode.auto,
                          ])
                            PopupRow(
                              key: ValueKey('ai-agent-permission-${option.name}'),
                              selected: option == mode,
                              onTap: () => Navigator.pop(context, option),
                              child: Tooltip(
                                message: _permissionHint(l, option),
                                child: Row(
                                  children: [
                                    Icon(_permissionIcon(option), size: 16),
                                    const SizedBox(width: Space.sm),
                                    Flexible(
                                      child: Text(
                                        _permissionLabel(l, option),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    const SizedBox(width: Space.sm),
                                    Expanded(
                                      child: Text(
                                        _permissionHint(l, option),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: Theme.of(context).textTheme.bodySmall
                                            ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
                                      ),
                                    ),
                                    const SizedBox(width: Space.sm),
                                    SizedBox(
                                      width: 16,
                                      child: option == mode ? const Icon(Icons.check_rounded, size: 16) : null,
                                    ),
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
          visualDensity: VisualDensity.standard,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          foregroundColor: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        child: Tooltip(
          message: _permissionLabel(l, mode),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(_permissionIcon(mode), size: 16),
              if (!compact) ...[const SizedBox(width: Space.xs), Text(_permissionLabel(l, mode))],
              const SizedBox(width: Space.xs),
              const Icon(Icons.keyboard_arrow_down_rounded, size: 16),
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

class _AttachmentList extends StatelessWidget {
  const _AttachmentList({required this.attachments, this.onRemove});
  final List<AgentAttachment> attachments;
  final ValueChanged<AgentAttachment>? onRemove;

  Future<void> _preview(BuildContext context, AgentAttachment attachment) => showAppDialog<void>(
    context: context,
    builder: (context) => AppDialog(
      title: Text(attachment.name, overflow: TextOverflow.ellipsis),
      width: 640,
      content: SingleChildScrollView(
        child: attachment.isImage
            ? Image.memory(
                base64Decode(attachment.content),
                fit: BoxFit.contain,
                errorBuilder: (_, _, _) => const Icon(Icons.broken_image_outlined),
              )
            : SelectableText(attachment.content),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(AppLocalizations.of(context).close))],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Wrap(
      spacing: Space.sm,
      runSpacing: Space.xs,
      children: [
        for (final attachment in attachments)
          Container(
            constraints: const BoxConstraints(maxWidth: 240),
            decoration: BoxDecoration(
              border: Border.all(color: theme.colorScheme.outlineVariant),
              borderRadius: BorderRadius.circular(Radii.control),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: TextButton(
                    key: ValueKey('ai-attachment-preview-${attachment.id}'),
                    onPressed: () => _preview(context, attachment),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (attachment.isImage)
                          Image.memory(
                            base64Decode(attachment.content),
                            width: 24,
                            height: 24,
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) => const Icon(Icons.broken_image_outlined, size: 17),
                          )
                        else
                          const Icon(Icons.description_outlined, size: 17),
                        const SizedBox(width: Space.xs),
                        Flexible(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(attachment.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                              Text(l.aiAgentAttachmentBytes(attachment.bytes), style: theme.textTheme.bodySmall),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (onRemove != null)
                  IconButton(
                    key: ValueKey('ai-attachment-remove-${attachment.id}'),
                    tooltip: l.remove,
                    onPressed: () => onRemove!(attachment),
                    icon: const Icon(Icons.close_rounded, size: 14),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

class _Conversation extends StatefulWidget {
  const _Conversation({
    super.key,
    required this.runtime,
    required this.conversationId,
    this.historyTruncated = false,
    required this.canRegenerate,
    required this.canWithdraw,
    required this.onRegenerate,
    required this.onWithdraw,
  });
  final AgentRuntime runtime;
  final String conversationId;
  final bool historyTruncated;
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

  List<AgentTimelineEntry> get _entries {
    final timeline = widget.runtime.timeline;
    // Keep a running reply before its first token; actions remain hidden until the turn ends.
    final streaming = widget.runtime.busy
        ? timeline.lastIndexWhere((entry) => entry is AgentChatEntry && entry.role == 'assistant')
        : -1;
    return [
      for (final (index, entry) in timeline.indexed)
        if (entry is! AgentChatEntry ||
            (!entry.retracted &&
                (entry.text.isNotEmpty ||
                    entry.attachments.isNotEmpty ||
                    entry.reasoningReceived ||
                    index == streaming)))
          entry,
    ];
  }

  @override
  void dispose() {
    _navigation++;
    _scroll.dispose();
    super.dispose();
  }

  void scrollToBottom() {
    _navigation++;
    if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.minScrollExtent);
  }

  @override
  void didUpdateWidget(_Conversation oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.conversationId != widget.conversationId) {
      _keys.clear();
      _highlighted = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) scrollToBottom();
      });
    }
  }

  Future<void> _reveal(String id) async {
    final navigation = ++_navigation;
    final disableAnimations = MediaQuery.disableAnimationsOf(context);
    setState(() {
      _highlighted = id;
      _revealVersion++;
    });
    await WidgetsBinding.instance.endOfFrame;
    for (var attempt = 0; mounted && navigation == _navigation && attempt < 64; attempt++) {
      final entries = _entries;
      final index = entries.indexWhere((entry) => entry is AgentExecution && entry.id == id);
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
        offset = position.maxScrollExtent * (entries.length - index - 1) / max(1, entries.length - 1);
      } else {
        final visible = [
          for (var i = 0; i < entries.length; i++)
            if (_keys[entries[i]]?.currentContext != null) i,
        ];
        if (visible.isEmpty) return;
        offset = position.pixels + (index < visible.first ? 1 : -1) * position.viewportDimension * .8;
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
    if (widget.runtime.busy) return const SizedBox.shrink();
    final l = AppLocalizations.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          key: ValueKey('ai-agent-copy-$index'),
          tooltip: l.copy,
          onPressed: message.text.isEmpty ? null : () => _copy(message.text),
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
      for (final id in [execution.id, if (execution.output != null) execution.output!.id]) {
        if (ambiguous.contains(id)) continue;
        if (references.containsKey(id) && references[id] != execution.id) {
          references.remove(id);
          ambiguous.add(id);
        } else {
          references[id] = execution.id;
        }
      }
    }
    final lastUser = entries.lastIndexWhere((entry) => entry is AgentChatEntry && entry.role == 'user');
    final lastAssistant = entries.lastIndexWhere((entry) => entry is AgentChatEntry && entry.role == 'assistant');
    // Only the last assistant text of each user round carries actions, never intermediate steps.
    final finalAssistants = <AgentChatEntry>{};
    AgentChatEntry? roundAssistant;
    for (final entry in entries) {
      if (entry is AgentChatEntry && entry.role == 'user') {
        if (roundAssistant != null) finalAssistants.add(roundAssistant);
        roundAssistant = null;
      } else if (entry is AgentChatEntry && entry.role == 'assistant' && entry.text.isNotEmpty) {
        roundAssistant = entry;
      }
    }
    if (roundAssistant != null) finalAssistants.add(roundAssistant);

    // Consecutive commands and their reasoning form one collapsible run until the next assistant text.
    final items = <Object>[];
    final activity = <AgentTimelineEntry>[];
    void flushActivity() {
      if (activity.whereType<AgentExecution>().length >= 2) {
        items.add(_ActivityGroup(List.of(activity)));
      } else {
        items.addAll(activity);
      }
      activity.clear();
    }

    for (final entry in entries) {
      if (entry is AgentExecution && entry.capability == 'agent.execute') {
        activity.add(entry);
        continue;
      }
      // An assistant placeholder or reasoning-only step does not split a command run.
      if (entry is AgentChatEntry && entry.role == 'assistant' && entry.text.isEmpty) {
        if (entry.reasoningReceived) activity.add(entry);
        continue;
      }
      flushActivity();
      items.add(entry);
    }
    flushActivity();

    final approval = widget.runtime.approval;
    final thinking = widget.runtime.busy && approval == null;
    final count = items.length + (widget.historyTruncated ? 1 : 0) + (approval == null ? 0 : 1) + (thinking ? 1 : 0);
    return SelectionArea(
      child: ListView.builder(
        key: PageStorageKey('ai-agent-conversation-${widget.conversationId}'),
        controller: _scroll,
        padding: const EdgeInsets.symmetric(horizontal: Space.md, vertical: Space.sm),
        reverse: true,
        itemCount: count,
        itemBuilder: (context, index) {
          index = count - index - 1;
          if (widget.historyTruncated) {
            if (index == 0) {
              return Padding(
                key: const ValueKey('ai-agent-history-trimmed'),
                padding: const EdgeInsets.only(bottom: Space.sm),
                child: Text(
                  AppLocalizations.of(context).aiAgentHistoryTruncated,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              );
            }
            index--;
          }
          if (index < items.length) {
            final item = items[index];
            if (item is _ActivityGroup) {
              final executions = item.steps.whereType<AgentExecution>().toList();
              return _ThinkingFlow(
                key: ValueKey('ai-agent-flow-${executions.first.id}'),
                steps: item.steps,
                highlightedId: _highlighted,
                stepBuilder: (step) => KeyedSubtree(
                  key: _keys.putIfAbsent(step, GlobalKey.new),
                  child: step is AgentExecution
                      ? _ExecutionCard(
                          key: ValueKey(step.id),
                          execution: step,
                          revealVersion: _highlighted == step.id ? _revealVersion : 0,
                        )
                      : _ReasoningSummary(message: step as AgentChatEntry),
                ),
              );
            }
            final entry = item as AgentTimelineEntry;
            final entryIndex = entries.indexOf(entry);
            Widget row;
            if (entry is AgentExecution) {
              row = _ExecutionCard(
                key: ValueKey(entry.id),
                execution: entry,
                revealVersion: _highlighted == entry.id ? _revealVersion : 0,
              );
            } else if (entry is AgentContextNotice) {
              row = Padding(
                key: const ValueKey('ai-agent-context-compacted'),
                padding: const EdgeInsets.only(bottom: Space.sm),
                child: Text(
                  AppLocalizations.of(context).aiAgentContextCompacted,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              );
            } else {
              final message = entry as AgentChatEntry;
              final user = message.role == 'user';
              final theme = Theme.of(context);
              row = Padding(
                padding: const EdgeInsets.only(bottom: Space.sm),
                child: Column(
                  crossAxisAlignment: user ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                  children: [
                    if (user)
                      LayoutBuilder(
                        builder: (context, constraints) => Align(
                          alignment: Alignment.centerRight,
                          child: Container(
                            key: const ValueKey('ai-agent-user-message'),
                            constraints: BoxConstraints(maxWidth: constraints.maxWidth * .94),
                            padding: const EdgeInsets.symmetric(horizontal: Space.md, vertical: Space.sm),
                            decoration: BoxDecoration(
                              border: Border.all(color: theme.colorScheme.outlineVariant),
                              borderRadius: BorderRadius.circular(Radii.control),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (message.text.isNotEmpty) Text(message.text, style: theme.textTheme.bodyMedium),
                                if (message.attachments.isNotEmpty) _AttachmentList(attachments: message.attachments),
                              ],
                            ),
                          ),
                        ),
                      )
                    else ...[
                      if (message.reasoningReceived) _ReasoningSummary(message: message),
                      AiMarkdown(data: message.text, executionReferences: references, onExecution: _reveal),
                      if (finalAssistants.contains(message))
                        _actions(message, entryIndex, latest: entryIndex == lastAssistant && entryIndex > lastUser),
                    ],
                    if (user && entryIndex == lastUser && lastAssistant < lastUser && widget.canWithdraw)
                      IconButton(
                        key: const ValueKey('ai-agent-withdraw'),
                        tooltip: AppLocalizations.of(context).aiAgentWithdrawHint,
                        onPressed: widget.onWithdraw,
                        icon: const Icon(Icons.undo_rounded, size: 16),
                      ),
                  ],
                ),
              );
            }
            return KeyedSubtree(key: _keys.putIfAbsent(entry, GlobalKey.new), child: row);
          }
          index -= items.length;
          if (approval != null) {
            if (index == 0) {
              return _ApprovalCard(
                approval: approval,
                onApprove: () => widget.runtime.approve(true, expected: approval),
                onReject: () => widget.runtime.approve(false, expected: approval),
              );
            }
            index--;
          }
          return widget.runtime.reviewing
              ? Padding(
                  padding: const EdgeInsets.symmetric(vertical: Space.sm),
                  child: Row(
                    children: [
                      const SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                      const SizedBox(width: Space.sm),
                      Expanded(
                        child: Text(
                          AppLocalizations.of(context).aiAgentReviewing,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    ],
                  ),
                )
              : const _ThinkingDots();
        },
      ),
    );
  }
}

class _ReasoningSummary extends StatefulWidget {
  const _ReasoningSummary({required this.message});
  final AgentChatEntry message;

  @override
  State<_ReasoningSummary> createState() => _ReasoningSummaryState();
}

class _ReasoningSummaryState extends State<_ReasoningSummary> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final message = widget.message;
    final summary = message.reasoningSummary;
    final label = message.reasoningActive
        ? l.aiReasoningActive
        : summary.isEmpty
        ? l.aiReasoningCompleted
        : l.aiReasoningSummary;
    final style = Theme.of(context).textTheme.bodySmall
        ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant);
    return Padding(
      key: const ValueKey('ai-agent-reasoning-status'),
      padding: const EdgeInsets.only(bottom: Space.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (summary.isEmpty)
            Text(label, style: style)
          else ...[
            TextButton(
              key: const ValueKey('ai-agent-reasoning-summary-toggle'),
              onPressed: () => setState(() => _expanded = !_expanded),
              style: TextButton.styleFrom(padding: EdgeInsets.zero, alignment: Alignment.centerLeft),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(label, style: style),
                  const SizedBox(width: Space.xs),
                  Icon(_expanded ? Icons.expand_less : Icons.expand_more, size: 14),
                ],
              ),
            ),
            Text(
              summary,
              key: const ValueKey('ai-agent-reasoning-summary'),
              maxLines: _expanded ? null : 2,
              overflow: _expanded ? TextOverflow.visible : TextOverflow.ellipsis,
              style: style,
            ),
          ],
        ],
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
      _timer = Timer.periodic(const Duration(milliseconds: 400), (_) => setState(() => _step = (_step + 1) % 3));
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
                duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : Motion.quick,
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

class _ActivityGroup {
  _ActivityGroup(this.steps);
  final List<AgentTimelineEntry> steps;
}

/// Consecutive command executions and their reasoning collapse into one disclosure until assistant text.
class _ThinkingFlow extends StatefulWidget {
  const _ThinkingFlow({super.key, required this.steps, required this.stepBuilder, this.highlightedId});
  final List<AgentTimelineEntry> steps;
  final Widget Function(AgentTimelineEntry step) stepBuilder;
  final String? highlightedId;

  @override
  State<_ThinkingFlow> createState() => _ThinkingFlowState();
}

class _ThinkingFlowState extends State<_ThinkingFlow> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final executions = widget.steps.whereType<AgentExecution>().toList();
    final latest = executions.last;
    final reveal =
        widget.highlightedId != null &&
        widget.steps.any((entry) => entry is AgentExecution && entry.id == widget.highlightedId);
    final expanded = _expanded || reveal;
    final failed = executions.any(
      (entry) => entry.state == 'failed' || (entry.exitCode != null && entry.exitCode != 0),
    );
    final unknown = executions.any((entry) => entry.state == 'outcomeUnknown' || entry.state == 'interrupted');
    final running = executions.any((entry) => entry.state == 'running' || entry.state == 'pending');
    final summary = latest.purpose.trim().isNotEmpty ? latest.purpose.trim() : latest.command;
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.md),
      child: _AgentCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InkWell(
              key: const ValueKey('ai-agent-thinking-flow-toggle'),
              borderRadius: BorderRadius.circular(Radii.control),
              onTap: () => setState(() => _expanded = !_expanded),
              child: Row(
                children: [
                  Icon(expanded ? Icons.expand_less_rounded : Icons.chevron_right_rounded, size: 17),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${l.aiAgentThinkingFlow} · ${executions.length}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall,
                        ),
                        if (summary.isNotEmpty)
                          Text(
                            summary,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: Space.sm),
                  Icon(
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
                ],
              ),
            ),
            if (expanded) ...[
              const SizedBox(height: Space.sm),
              for (final step in widget.steps) widget.stepBuilder(step),
            ],
          ],
        ),
      ),
    );
  }
}

class _ExecutionCard extends StatefulWidget {
  const _ExecutionCard({super.key, required this.execution, this.revealVersion = 0});
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
    if (widget.revealVersion != 0 && widget.revealVersion != oldWidget.revealVersion) {
      _expanded = true;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final execution = widget.execution;
    final output = execution.output;
    final failed = execution.state == 'failed' || (execution.exitCode != null && execution.exitCode != 0);
    final unknown = execution.state == 'outcomeUnknown' || execution.state == 'interrupted';
    final running = execution.state == 'running' || execution.state == 'pending';
    final compact = execution.capability != 'agent.execute' && execution.capability != 'agent.diagnose';
    final (title, description) = switch (execution.capability) {
      'agent.hosts' => (l.aiAgentToolHosts, l.aiAgentToolHostsHint),
      'agent.terminals' => (l.aiAgentToolTerminals, l.aiAgentToolTerminalsHint),
      'agent.terminalHistory' => (l.aiAgentToolTerminalHistory, l.aiAgentToolTerminalHistoryHint),
      'agent.terminalScreen' => (l.aiAgentToolTerminalScreen, l.aiAgentToolTerminalScreenHint),
      'file.list' => (l.aiAgentToolFilesList, l.aiAgentToolFilesHint),
      'file.stat' => (l.aiAgentToolFilesStat, l.aiAgentToolFilesHint),
      'file.read' => (l.aiAgentToolFilesRead, l.aiAgentToolFilesHint),
      'file.write' => (l.aiAgentToolFilesWrite, l.aiAgentToolFilesHint),
      'file.mkdir' => (l.aiAgentToolFilesMkdir, l.aiAgentToolFilesHint),
      'file.rename' => (l.aiAgentToolFilesRename, l.aiAgentToolFilesHint),
      'file.delete' => (l.aiAgentToolFilesDelete, l.aiAgentToolFilesHint),
      'transfer.list' => (l.aiAgentToolTransferList, l.aiAgentToolTransferHint),
      'transfer.enqueue' => (l.aiAgentToolTransferEnqueue, l.aiAgentToolTransferHint),
      'transfer.cancel' => (l.aiAgentToolTransferCancel, l.aiAgentToolTransferHint),
      'session.open' => (l.aiAgentToolSessionOpen, l.aiAgentToolSessionHint),
      'session.close' => (l.aiAgentToolSessionClose, l.aiAgentToolSessionHint),
      'session.reconnect' => (l.aiAgentToolSessionReconnect, l.aiAgentToolSessionHint),
      'workspace.focus' => (l.aiAgentToolWorkspaceFocus, l.aiAgentToolWorkspaceHint),
      'workspace.split' => (l.aiAgentToolWorkspaceSplit, l.aiAgentToolWorkspaceHint),
      'workspace.renameTab' => (l.aiAgentToolWorkspaceRename, l.aiAgentToolWorkspaceHint),
      'workspace.closeTabs' => (l.aiAgentToolWorkspaceCloseTabs, l.aiAgentToolWorkspaceHint),
      'settings.get' => (l.aiAgentToolSettingsGet, l.aiAgentToolSettingsHint),
      'settings.patch' => (l.aiAgentToolSettingsPatch, l.aiAgentToolSettingsHint),
      'host.create' => (l.aiAgentToolHostCreate, l.aiAgentToolHostHint),
      'host.update' => (l.aiAgentToolHostUpdate, l.aiAgentToolHostHint),
      'host.move' => (l.aiAgentToolHostMove, l.aiAgentToolHostHint),
      'host.delete' => (l.aiAgentToolHostDelete, l.aiAgentToolHostHint),
      'forward.list' => (l.aiAgentToolForwardList, l.aiAgentToolForwardHint),
      'forward.save' => (l.aiAgentToolForwardSave, l.aiAgentToolForwardHint),
      'forward.delete' => (l.aiAgentToolForwardDelete, l.aiAgentToolForwardHint),
      'forward.start' => (l.aiAgentToolForwardStart, l.aiAgentToolForwardHint),
      'forward.stop' => (l.aiAgentToolForwardStop, l.aiAgentToolForwardHint),
      'agent.jobs.start' => (l.aiAgentToolJobStart, l.aiAgentToolJobHint),
      'agent.jobs.read' => (l.aiAgentToolJobRead, l.aiAgentToolJobHint),
      'agent.jobs.status' => (l.aiAgentToolJobStatus, l.aiAgentToolJobHint),
      'agent.jobs.stop' => (l.aiAgentToolJobStop, l.aiAgentToolJobHint),
      'agent.diagnose' => (l.aiAgentToolDiagnostics, l.aiAgentToolDiagnosticsHint),
      'agent.execute' => (l.aiAgentToolExecute, l.aiAgentToolExecuteHint),
      'agent.output' => (l.aiAgentToolOutput, l.aiAgentToolOutputHint),
      _ => (l.aiAgentExecutionRecord, l.aiAgentExecutionRecord),
    };
    final purpose = execution.purpose.trim();
    final label = execution.capability != 'agent.execute' || execution.archived || execution.command.isEmpty
        ? title
        : purpose.isNotEmpty
        ? purpose
        : '$title · ${execution.command}';
    final status = failed
        ? compact || execution.command.isEmpty
              ? l.aiAgentFailed
              : l.aiAgentExecutionFailed
        : _executionState(l, execution.state);
    final failure = execution.failure == null ? null : _error(l, execution.failure);
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
                  child: Tooltip(
                    message: '$label\n$description',
                    child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall),
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
                        : execution.state == 'cancelled'
                        ? Icons.stop_circle_outlined
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
                  Text(status, style: theme.textTheme.bodySmall),
                  if (failure != null && failure != status) Text(failure, style: theme.textTheme.bodySmall),
                  if (execution.exitCode case final code?)
                    Text(l.aiAgentExitCode(code), style: theme.textTheme.bodySmall),
                  if (execution.historyTruncated || (output?.truncated ?? false))
                    Text(l.aiAgentTruncated, style: theme.textTheme.bodySmall),
                ],
              ),
              if (execution.archived && !compact) ...[
                const SizedBox(height: Space.sm),
                Text(l.aiAgentHistoryOutputUnavailable, style: theme.textTheme.bodySmall),
                if (execution.sharedText?.isNotEmpty ?? false) ...[
                  const SizedBox(height: Space.sm),
                  Text(execution.sharedText!, style: mono(context, theme.textTheme.bodySmall)),
                ],
              ],
              if (!execution.archived && execution.capability == 'agent.execute' && execution.command.isNotEmpty) ...[
                const SizedBox(height: Space.sm),
                Text(execution.command, style: mono(context, theme.textTheme.bodySmall)),
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

String _templateLabel(AppLocalizations l, String template) => switch (template) {
  'systemSummary' => l.aiAgentDiagnosticSystem,
  'storageCapacity' => l.aiAgentDiagnosticStorage,
  'processSummary' => l.aiAgentDiagnosticProcesses,
  'listeningPorts' => l.aiAgentDiagnosticPorts,
  'serviceStates' => l.aiAgentDiagnosticServices,
  _ => l.aiAgentToolDiagnostics,
};

class _ApprovalCard extends StatelessWidget {
  const _ApprovalCard({required this.approval, required this.onApprove, required this.onReject});
  final AgentApproval approval;
  final VoidCallback onApprove, onReject;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final terminalHistory = approval.capability == 'agent.terminalHistory';
    final terminalScreen = approval.capability == 'agent.terminalScreen';
    final contentRead = const {
      'file.list',
      'file.stat',
      'file.read',
      'agent.jobs.read',
      'agent.jobs.status',
    }.contains(approval.capability);
    final shell = const {'agent.execute', 'agent.jobs.start', 'agent.diagnose'}.contains(approval.capability);
    final reading = terminalHistory || terminalScreen || contentRead || approval.template != null;
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.md),
      child: _AgentCard(
        emphasized: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _CardTitle(
              icon: reading ? Icons.visibility_outlined : Icons.terminal_rounded,
              label: reading
                  ? l.aiAgentReadApproveTitle
                  : shell
                  ? l.aiAgentApproveTitle
                  : l.aiAgentActionApproveTitle,
            ),
            const SizedBox(height: Space.md),
            Text(approval.target, style: theme.textTheme.labelLarge),
            if (approval.template != null) ...[
              const SizedBox(height: Space.xs),
              Text(_templateLabel(l, approval.template!), style: theme.textTheme.labelLarge),
            ],
            if (approval.cwd.isNotEmpty) ...[
              const SizedBox(height: Space.xs),
              Text(approval.cwd, style: mono(context, theme.textTheme.bodySmall)),
            ],
            if (approval.command.isNotEmpty) ...[
              const SizedBox(height: Space.md),
              Text(approval.command, style: mono(context, theme.textTheme.bodyMedium)),
            ],
            if (approval.timeoutSeconds != null) ...[
              const SizedBox(height: Space.xs),
              Text(l.aiAgentExecutionTimeout(approval.timeoutSeconds!), style: theme.textTheme.bodySmall),
            ],
            const SizedBox(height: Space.md),
            Text(
              terminalScreen
                  ? l.aiAgentTerminalScreenApproveHint
                  : terminalHistory
                  ? l.aiAgentTerminalApproveHint
                  : contentRead
                  ? l.aiAgentContentApproveHint
                  : approval.template != null
                  ? l.aiAgentReadApproveHint
                  : shell
                  ? l.aiAgentShellPermission
                  : l.aiAgentActionApproveHint,
              style: theme.textTheme.bodySmall,
            ),
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

String _executionState(AppLocalizations l, String state) => switch (state) {
  'pending' || 'intent' || 'preparing' => l.aiAgentPreparing,
  'executing' || 'running' => l.aiAgentExecuting,
  'completed' => l.aiAgentCompleted,
  'failed' => l.aiAgentFailed,
  'cancelled' => l.aiAgentCancelled,
  'interrupted' => l.tsInterrupted,
  'outcomeUnknown' || 'unknown' => l.aiAgentOutcomeUnknown,
  _ => l.aiAgentPreparing,
};

String _error(AppLocalizations l, String? code) => switch (code) {
  'notConfigured' || 'invalidModelRequest' => l.aiAgentErrorModelConfig,
  'invalidModelKey' => l.aiAgentErrorConfiguration,
  'invalidSchema' => l.aiAgentErrorToolDefinition,
  'unsupportedReasoning' => l.aiReasoningUnsupported,
  'modelNetworkError' => l.aiAgentErrorNetwork,
  'modelHttpError' || 'modelStreamError' || 'modelRefused' => l.aiAgentErrorHttp,
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
  'invalidModelArguments' => '${l.aiAgentErrorProtocol} ($code)',
  _ => l.aiAgentFailed,
};

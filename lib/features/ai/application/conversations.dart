import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../foundation/data_dir.dart';
import '../../../foundation/ids.dart';
import '../adapters/conversation_store.dart';
import '../domain/conversation.dart';
import '../domain/agent.dart';
import '../domain/model_profile.dart';
import 'composer.dart';
import 'providers.dart';
import 'model_selection.dart';
import 'permission_mode.dart';
import 'runtime.dart';

export 'providers.dart' show agentConversationRoutesProvider;

final agentConversationStoreProvider = Provider<ConversationStore>(
  (ref) => JsonConversationStore(ref.read(dataDirProvider)),
);
final agentConversationsProvider = Provider<AgentConversations>((ref) {
  final controller = AgentConversations(
    runtime: ref.read(agentRuntimeProvider),
    store: ref.read(agentConversationStoreProvider),
    composer: ref.read(agentComposerProvider.notifier),
    draft: () => ref.read(agentComposerProvider),
    destination: () => ref.read(effectiveAgentProfileProvider)?.identity,
    toolsEnabled: () => ref.read(effectiveAgentProfileProvider)?.tools ?? false,
    routes: () => ref.read(agentConversationRoutesProvider)(),
    permissionMode: () => ref.read(selectedAgentPermissionModeProvider),
    resetPermission: () {
      ref.read(selectedAgentPermissionModeProvider.notifier).reset();
      ref.read(selectedAgentReasoningProvider.notifier).reset();
    },
  );
  ref.onDispose(controller.dispose);
  return controller;
});

class AgentConversations extends ChangeNotifier {
  AgentConversations({
    required this.runtime,
    required this.store,
    required this.composer,
    required this.draft,
    required this.destination,
    required this.toolsEnabled,
    required this.routes,
    this.permissionMode = _confirmMode,
    this.resetPermission = _noop,
  }) {
    runtime.addListener(_runtimeChanged);
    ready = reload();
  }

  final AgentRuntime runtime;
  final ConversationStore store;
  final AgentComposer composer;
  final AgentComposerState Function() draft;
  final String? Function() destination;
  final bool Function() toolsEnabled;
  final Map<HostId, String> Function() routes;
  final AgentPermissionMode Function() permissionMode;
  final VoidCallback resetPermission;
  static AgentPermissionMode _confirmMode() => AgentPermissionMode.confirm;
  static void _noop() {}
  final _drafts = <String, AgentComposerState>{};
  List<AgentConversationRecord> _records = [];
  String _selected = newId();
  bool _disposed = false, _changing = false, _wasBusy = false;
  bool loading = true, loadFailed = false, saveFailed = false;
  Future<void> _pending = Future.value();
  late final Future<void> ready;
  int _saveGeneration = 0;
  String? _turnConversation;

  String get selectedId => _selected;
  AgentConversationRecord? get current => _records.where((entry) => entry.id == _selected).firstOrNull;
  List<AgentConversationRecord> get records =>
      List.unmodifiable([..._records]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt)));
  Future<void> get saved => _pending;
  bool get hasHistory => current?.entries.isNotEmpty ?? false;
  bool get canWithdraw =>
      !runtime.busy &&
      !_changing &&
      !loading &&
      draft().goal.trim().isEmpty &&
      draft().attachments.isEmpty &&
      _lastUserIndex >= 0;
  bool get canRegenerate => !runtime.busy && !_changing && !loading && _lastAssistantIndex >= 0;

  int get _lastUserIndex =>
      current?.entries.lastIndexWhere((entry) => entry.kind == ConversationEntryKind.user && !entry.retracted) ?? -1;

  int get _lastAssistantIndex {
    final user = _lastUserIndex;
    if (user < 0) return -1;
    final index = current!.entries.lastIndexWhere(
      (entry) => entry.kind == ConversationEntryKind.assistant && !entry.retracted && entry.text.isNotEmpty,
    );
    return index > user ? index : -1;
  }

  void _emit() {
    if (!_disposed) notifyListeners();
  }

  Future<void> reload() async {
    if (!loading && !loadFailed) return;
    loading = true;
    _emit();
    try {
      final loaded = await store.load();
      if (_disposed) return;
      // A retry never discards unsaved in-memory conversations.
      final merged = {for (final entry in loaded) entry.id: entry, for (final entry in _records) entry.id: entry};
      _records = merged.values.toList();
      loadFailed = false;
    } on Object {
      if (!_disposed) loadFailed = true;
    } finally {
      if (!_disposed) {
        loading = false;
        _emit();
      }
    }
  }

  bool canContinue(HostId? host) {
    final record = current;
    if (record == null) return false;
    final service = _service(record.destination);
    return service != null && service == _service(destination());
  }

  // Legacy records include the model; only readable history can cross models within the same service.
  static (ModelProtocol, String)? _service(String? identity) {
    if (identity == null) return null;
    try {
      final parts = jsonDecode(identity);
      if (parts is! List || parts.length != 3) return null;
      final profile = ModelProfile.fromJson({'protocol': parts[0], 'endpoint': parts[1], 'model': parts[2]});
      return (profile.protocol, profile.endpoint);
    } on FormatException {
      return null;
    }
  }

  List<ConversationEntry> _snapshot() => [
    for (final entry in runtime.timeline)
      if (entry is AgentChatEntry && (entry.text.isNotEmpty || entry.attachments.isNotEmpty))
        ConversationEntry(
          kind: entry.role == 'user' ? ConversationEntryKind.user : ConversationEntryKind.assistant,
          text: sanitizeConversationText(entry.text),
          retracted: entry.retracted,
          attachments: entry.attachments,
        )
      else if (entry is AgentExecution)
        ConversationEntry(
          kind: ConversationEntryKind.execution,
          text: sanitizeConversationText(entry.sharedText ?? ''),
          capability: entry.capability,
          state: AgentExecution.restoredState(entry.capability, entry.state),
          exitCode: entry.exitCode,
          truncated: entry.historyTruncated || (entry.output?.truncated ?? false),
          retracted: entry.retracted,
          executionId: entry.id,
        ),
  ];

  static bool _sameEntries(List<ConversationEntry> a, List<ConversationEntry> b) {
    if (a.length != b.length) return false;
    for (var index = 0; index < a.length; index++) {
      final left = a[index], right = b[index];
      if (left.kind != right.kind ||
          left.text != right.text ||
          left.capability != right.capability ||
          left.state != right.state ||
          left.exitCode != right.exitCode ||
          left.truncated != right.truncated ||
          left.retracted != right.retracted ||
          left.executionId != right.executionId ||
          !listEquals(left.attachments, right.attachments)) {
        return false;
      }
    }
    return true;
  }

  void _capture() {
    final record = current;
    if (record == null ||
        _turnConversation == record.id && (runtime.error == 'notConfigured' || runtime.error == 'scopeLimit')) {
      return;
    }
    final entries = _snapshot();
    if (entries.isEmpty || _sameEntries(record.entries, entries)) return;
    final index = _records.indexOf(record);
    _records[index] = AgentConversationRecord(
      id: record.id,
      title: record.title,
      createdAt: record.createdAt,
      updatedAt: DateTime.now().toUtc(),
      destination: record.destination,
      host: record.host,
      routeSignature: record.routeSignature,
      entries: entries,
      historyTruncated: record.historyTruncated,
    );
  }

  void _runtimeChanged() {
    if (_changing || _disposed) return;
    final busy = runtime.busy;
    if (_wasBusy && !busy) {
      _capture();
      unawaited(_persist());
    }
    _wasBusy = busy;
    _emit();
  }

  Future<void> _persist() {
    if (loading || loadFailed || _disposed) return Future.value();
    final generation = ++_saveGeneration;
    late final List<AgentConversationRecord> snapshot;
    try {
      _records = boundedConversationRecords(_records).toList();
      snapshot = _records.where((entry) => entry.entries.isNotEmpty).toList();
      final kept = _records.map((entry) => entry.id).toSet();
      _drafts.removeWhere((id, _) => !kept.contains(id) && id != _selected);
      runtime.retainConversations({...kept, _selected});
    } on Object {
      saveFailed = true;
      _emit();
      return Future.value();
    }
    final next = _pending.then<void>((_) {}, onError: (Object _) {}).then((_) async {
      try {
        await store.save(snapshot);
        if (!_disposed && generation == _saveGeneration) saveFailed = false;
      } on Object {
        if (!_disposed && generation == _saveGeneration) saveFailed = true;
      }
      _emit();
    });
    _pending = next;
    return next;
  }

  Future<void> retrySave() => _persist();

  void _rememberDraft() {
    final value = draft();
    _drafts[_selected] = AgentComposerState(goal: value.goal, host: value.host, attachments: value.attachments);
    if (current == null && (value.goal.trim().isNotEmpty || value.attachments.isNotEmpty) && destination() != null) {
      _records.add(
        _newRecord(value.goal.isEmpty ? value.attachments.first.name : value.goal, toolsEnabled() ? value.host : null),
      );
    }
  }

  AgentConversationRecord _newRecord(String goal, HostId? host) {
    final title = sanitizeConversationText(goal).replaceAll(RegExp(r'\s+'), ' ').trim();
    final now = DateTime.now().toUtc();
    return AgentConversationRecord(
      id: _selected,
      title: title.length > 80 ? String.fromCharCodes(title.runes.take(80)) : title,
      createdAt: now,
      updatedAt: now,
      destination: destination() ?? '',
      host: host,
      routeSignature: host == null ? null : routes()[host],
      entries: const [],
    );
  }

  bool newConversation({bool keepDraft = false}) {
    if (runtime.busy || loading) return false;
    _changing = true;
    _capture();
    _rememberDraft();
    final previous = draft();
    _selected = newId();
    runtime.clear();
    resetPermission();
    composer.restore(keepDraft ? previous : AgentComposerState(host: previous.host));
    _wasBusy = false;
    _changing = false;
    unawaited(_persist());
    _emit();
    return true;
  }

  bool select(String id) {
    if (runtime.busy || loading || id == _selected) return false;
    final selected = _records.where((entry) => entry.id == id).firstOrNull;
    if (selected == null) return false;
    _changing = true;
    _capture();
    _rememberDraft();
    _selected = id;
    runtime.restoreConversation(selected.entries);
    resetPermission();
    composer.restore(_drafts[id] ?? AgentComposerState(host: selected.host));
    _wasBusy = false;
    _changing = false;
    unawaited(_persist());
    _emit();
    return true;
  }

  Future<void> delete(String id) async {
    if (runtime.busy || loading) return;
    _records.removeWhere((entry) => entry.id == id);
    _drafts.remove(id);
    runtime.forgetConversation(id);
    if (_selected == id) {
      _changing = true;
      _selected = newId();
      runtime.clear();
      resetPermission();
      composer.restore(const AgentComposerState());
      _changing = false;
    }
    _emit();
    await _persist();
  }

  Future<void> send(String goal, HostId? host, {bool continueHistory = false}) async {
    final sendingDraft = draft();
    final attachments = sendingDraft.attachments;
    if (runtime.busy || loading || (goal.trim().isEmpty && attachments.isEmpty) || destination() == null) return;
    host = toolsEnabled() ? host : null;
    final matches = hasHistory && canContinue(host);
    final continuing = matches && continueHistory;
    if (hasHistory && !continuing) {
      // Sending history to another protocol or endpoint remains an explicit boundary.
      if (continueHistory) return;
      newConversation(keepDraft: true);
    }
    final history = continuing ? current!.entries : const <ConversationEntry>[];
    if (current?.entries.isEmpty ?? true) {
      _records.removeWhere((entry) => entry.id == _selected);
      _records.add(_newRecord(goal.isEmpty ? attachments.first.name : goal, host));
    }
    final sendingId = _selected;
    _turnConversation = sendingId;
    composer.restore(AgentComposerState(host: sendingDraft.host));
    final work = runtime.startConversation(
      goal,
      AgentScope(
        hosts: [?host],
        discoverHosts: host == null && toolsEnabled(),
        permissionMode: permissionMode(),
        conversationId: sendingId,
        defaultHost: current!.host,
        defaultHostRoute: current!.routeSignature,
      ),
      history,
      attachments: attachments,
    );
    _wasBusy = runtime.busy;
    if (!runtime.busy && (runtime.error == 'notConfigured' || runtime.error == 'scopeLimit')) {
      if (draft().goal.isEmpty && draft().attachments.isEmpty) composer.restore(sendingDraft);
      _emit();
      return;
    }
    _capture();
    unawaited(_persist());
    await work;
    if (_disposed || _selected != sendingId) return;
    _capture();
    await _persist();
    if (runtime.error == 'notConfigured' && draft().goal.isEmpty && draft().attachments.isEmpty) {
      composer.restore(sendingDraft);
    }
    _emit();
  }

  AgentConversationRecord _withEntries(AgentConversationRecord record, List<ConversationEntry> entries) =>
      AgentConversationRecord(
        id: record.id,
        title: record.title,
        createdAt: record.createdAt,
        updatedAt: DateTime.now().toUtc(),
        destination: record.destination,
        host: record.host,
        routeSignature: record.routeSignature,
        entries: entries,
        historyTruncated: record.historyTruncated,
      );

  ConversationEntry _retract(ConversationEntry entry) => ConversationEntry(
    kind: entry.kind,
    text: entry.text,
    capability: entry.capability,
    state: entry.state,
    exitCode: entry.exitCode,
    truncated: entry.truncated,
    retracted: true,
    executionId: entry.executionId,
    attachments: entry.attachments,
  );

  void _replaceRecord(AgentConversationRecord record, List<ConversationEntry> entries) {
    final index = _records.indexWhere((entry) => entry.id == record.id);
    if (index >= 0) _records[index] = _withEntries(_records[index], entries);
  }

  /// Retracts the last turn from model context only; executed operations are not undone.
  bool withdrawLastTurn() {
    final record = current;
    final index = _lastUserIndex;
    if (record == null || !canWithdraw || index < 0) return false;
    final host = draft().host;
    final question = record.entries[index].text;
    final entries = [
      for (var i = 0; i < record.entries.length; i++) i < index ? record.entries[i] : _retract(record.entries[i]),
    ];
    _records[_records.indexOf(record)] = _withEntries(record, entries);
    runtime.restoreConversation(entries);
    composer.restore(AgentComposerState(goal: question, host: host, attachments: record.entries[index].attachments));
    unawaited(_persist());
    _emit();
    return true;
  }

  /// Produces a new answer without tools, private outputs, approvals or remote work.
  Future<bool> regenerate(HostId? host) async {
    final record = current;
    if (record == null || !canRegenerate) return false;
    host = toolsEnabled() ? host : null;
    if (!canContinue(host)) return false;
    final assistant = _lastAssistantIndex;
    if (assistant < 0) return false;
    final previous = record.entries;
    final question = previous[_lastUserIndex];
    _records[_records.indexOf(record)] = _withEntries(record, [...previous]..removeAt(assistant));
    runtime.discardLastAnswer();
    final sendingId = record.id;
    _turnConversation = sendingId;
    final work = runtime.startConversation(
      question.text,
      AgentScope(
        hosts: [?host],
        discoverHosts: false,
        permissionMode: permissionMode(),
        conversationId: sendingId,
        defaultHost: record.host,
        defaultHostRoute: record.routeSignature,
      ),
      previous.sublist(0, assistant),
      answerOnly: true,
      appendGoal: false,
      attachments: question.attachments,
    );
    _wasBusy = runtime.busy;
    if (!runtime.busy) {
      _replaceRecord(record, previous);
      runtime.restoreConversation(previous, failure: runtime.error);
      await _persist();
      _emit();
      return false;
    }
    await work;
    if (_disposed) return false;
    if (runtime.error != null) {
      _replaceRecord(record, previous);
      runtime.restoreConversation(previous, failure: runtime.error);
      await _persist();
      _emit();
      return false;
    }
    _capture();
    await _persist();
    _emit();
    return true;
  }

  Future<void> flush() async {
    await ready;
    if (!runtime.busy) _capture();
    await _persist();
    await store.saved;
    if (saveFailed || loadFailed) throw StateError('conversationSaveFailed');
  }

  @override
  void dispose() {
    _disposed = true;
    runtime.removeListener(_runtimeChanged);
    super.dispose();
  }
}

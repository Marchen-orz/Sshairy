import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/design/brand.dart';
import 'package:sshairy/design/popup.dart';
import 'package:sshairy/design/theme.dart';
import 'package:sshairy/features/ai/application/composer.dart';
import 'package:sshairy/features/ai/application/configuration.dart';
import 'package:sshairy/features/ai/application/conversations.dart';
import 'package:sshairy/features/ai/application/output_store.dart';
import 'package:sshairy/features/ai/application/model_catalog.dart';
import 'package:sshairy/features/ai/application/model_selection.dart';
import 'package:sshairy/features/ai/application/providers.dart';
import 'package:sshairy/features/ai/application/target.dart';
import 'package:sshairy/features/ai/application/permission_mode.dart';
import 'package:sshairy/features/ai/application/runtime.dart';
import 'package:sshairy/features/ai/domain/agent.dart';
import 'package:sshairy/features/ai/domain/model.dart';
import 'package:sshairy/features/ai/domain/conversation.dart';
import 'package:sshairy/features/ai/domain/model_catalog.dart';
import 'package:sshairy/features/ai/presentation/agent_panel.dart';
import 'package:sshairy/features/capabilities/api.dart';
import 'package:sshairy/features/settings/api.dart';
import 'package:sshairy/foundation/data_dir.dart';
import 'package:sshairy/foundation/cancellation.dart';
import 'package:sshairy/foundation/ids.dart';
import 'package:sshairy/foundation/secret.dart';
import 'package:sshairy/l10n/app_localizations.dart';

final _profile = ModelProfile(
  protocol: ModelProtocol.openai,
  endpoint: 'https://model.example/v1',
  model: 'a-long-configured-model-name-for-the-composer',
  tools: true,
);

class _Configuration extends AiConfigurationController {
  _Configuration(this.enabled, this.tools);
  final bool enabled, tools;
  @override
  AiConfiguration build() => AiConfiguration(
    enabled: enabled,
    profile: tools
        ? _profile
        : ModelProfile(protocol: _profile.protocol, endpoint: _profile.endpoint, model: _profile.model, tools: false),
    inlineModel: 'inline-model',
    completionModel: 'completion-model',
  );
}

class _Backend implements AgentBackend {
  @override
  List<AgentHost> get hosts => const [AgentHost(HostId('web'), 'Production web')];
  @override
  Future<AgentTarget> prepare(HostId host, CancellationToken cancel) => throw StateError('No UI-driven connection');
}

class _Journal implements OperationJournal {
  @override
  Future<List<OperationRecord>> load() async => const [];
  @override
  Future<void> record(OperationRecord record) async {}
  @override
  Future<void> get saved async {}
}

class _Model implements ModelProvider {
  @override
  Stream<ModelEvent> stream(ModelRequest request, CancellationToken cancel) => throw StateError('No UI-driven HTTP');
  @override
  void close() {}
}

class _Catalog implements ModelCatalog {
  @override
  Future<List<String>> list({
    required ModelProtocol protocol,
    required String endpoint,
    required CancellationToken cancel,
    String? credentialIdentity,
    Secret? draftKey,
  }) async => const ['alternate-model', 'other-model'];
  @override
  void cancelAll() {}
  @override
  void close() {}
}

class _ConversationStore implements ConversationStore {
  _ConversationStore([Iterable<AgentConversationRecord> initial = const []]) : records = [...initial];
  List<AgentConversationRecord> records;

  @override
  Future<List<AgentConversationRecord>> load() async => [...records];
  @override
  Future<void> save(List<AgentConversationRecord> value) async {
    records = [...value];
  }

  @override
  Future<void> get saved async {}
}

class _Settings extends SettingsNotifier {
  @override
  Settings build() => const Settings();
}

AgentConversationRecord _conversation(String id, {String? destination, List<ConversationEntry>? entries}) {
  final now = DateTime.now().toUtc();
  return AgentConversationRecord(
    id: id,
    title: 'Conversation $id',
    createdAt: now,
    updatedAt: now,
    destination: destination ?? _profile.identity,
    entries: entries ?? [ConversationEntry(kind: ConversationEntryKind.user, text: 'Previous $id')],
  );
}

class _Runtime extends AgentRuntime {
  _Runtime()
    : super(
        model: _Model(),
        backend: _Backend(),
        journal: _Journal(),
        dispatcher: CapabilityDispatcher(const []),
        configuration: () => (enabled: true, profile: _profile, revision: 0),
      );
  bool active = false;
  int estimatedUsed = 0, estimatedWindow = 0;
  @override
  int get contextUsedTokens => estimatedUsed;
  @override
  int get contextWindow => estimatedWindow;
  @override
  AgentPermissionMode get permissionMode => sentScope?.permissionMode ?? AgentPermissionMode.confirm;
  String? goal;
  AgentScope? sentScope;
  bool? approved;
  bool dataAnswered = false;
  String? shared;
  List<ConversationEntry> sentHistory = const [];
  final entries = <AgentTimelineEntry>[];
  void refresh() => notifyListeners();
  @override
  bool get busy => active;
  @override
  List<AgentTimelineEntry> get timeline => List.unmodifiable(entries);
  @override
  Future<void> startConversation(String goal, AgentScope scope, List<ConversationEntry> history) {
    sentHistory = List.unmodifiable(history);
    restoreConversation(history);
    return super.startConversation(goal, scope, history);
  }

  @override
  void restoreConversation(List<ConversationEntry> history) {
    if (active) return;
    super.restoreConversation(history);
    entries
      ..clear()
      ..addAll(super.timeline);
    notifyListeners();
  }

  @override
  Future<void> start(String value, AgentScope scope) async {
    goal = value;
    sentScope = scope;
    active = true;
    phase = AgentPhase.streaming;
    entries.add(AgentChatEntry('user', value));
    notifyListeners();
  }

  @override
  void clear() {
    if (active) return;
    entries.clear();
    super.clear();
  }

  @override
  void stop() {
    active = false;
    phase = AgentPhase.cancelled;
    notifyListeners();
  }

  @override
  void approve(bool value, {required AgentApproval expected}) {
    if (!identical(approval, expected)) return;
    approved = value;
    approval = null;
    notifyListeners();
  }

  @override
  void shareOutput(String? text, {required AgentDataRequest expected}) {
    if (!identical(dataRequest, expected)) return;
    dataAnswered = true;
    shared = text;
    dataRequest = null;
    notifyListeners();
  }
}

class _Assets extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async => key == 'AssetManifest.bin'
      ? const StandardMessageCodec().encodeMessage(<String, Object?>{})!
      : ByteData.sublistView(File(key).readAsBytesSync());
}

Widget _app(ProviderContainer container, {bool visible = true, double textScale = 1}) => UncontrolledProviderScope(
  container: container,
  child: DefaultAssetBundle(
    bundle: _Assets(),
    child: MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: buildTheme(Brightness.light).copyWith(splashFactory: NoSplash.splashFactory),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Scaffold(body: visible ? AgentPanel(onClose: () {}) : const SizedBox.shrink()),
    ),
  ),
);

Future<ProviderContainer> _panel(
  WidgetTester tester,
  _Runtime runtime, {
  bool enabled = true,
  bool tools = true,
  Size size = const Size(440, 1000),
  double textScale = 1,
  _ConversationStore? store,
  HostId? focusedHost,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final container = ProviderContainer(
    overrides: [
      aiConfigurationProvider.overrideWith(() => _Configuration(enabled, tools)),
      agentBackendProvider.overrideWithValue(_Backend()),
      agentFocusedHostProvider.overrideWithValue(focusedHost),
      aiModelCatalogProvider.overrideWithValue(_Catalog()),
      agentRuntimeProvider.overrideWithValue(runtime),
      agentConversationStoreProvider.overrideWithValue(store ?? _ConversationStore()),
      agentConversationRoutesProvider.overrideWithValue(() => const {HostId('web'): '0123456789abcdef'}),
      settingsProvider.overrideWith(_Settings.new),
      dataDirProvider.overrideWithValue('memory-only-ai-panel-tests'),
      systemFontsProvider.overrideWith((_) async => []),
      settingsSectionsProvider.overrideWithValue([
        SettingsSection(
          (l) => l.aiConfigTitle,
          (_) => const SizedBox(
            height: 600,
            child: Text('AI settings destination', key: ValueKey('ai-settings-destination')),
          ),
          id: SettingsSectionId.ai,
        ),
      ]),
    ],
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
    runtime.dispose();
  });
  await tester.pumpWidget(_app(container, textScale: textScale));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 250));
  return container;
}

void main() {
  testWidgets('disabled AI has a brand welcome and no request or mode selector', (tester) async {
    final runtime = _Runtime();
    await _panel(tester, runtime, enabled: false);
    expect(find.byType(BrandIllustration), findsOneWidget);
    expect(find.text('Configure a model and enable AI in Settings to begin.'), findsOneWidget);
    expect(find.byKey(const ValueKey('ai-agent-mode')), findsNothing);
    expect(tester.widget<IconButton>(find.byKey(const ValueKey('ai-agent-send'))).onPressed, isNull);
    expect(runtime.goal, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('examples fill only the draft and a unified Agent can send without a server', (tester) async {
    final runtime = _Runtime();
    await _panel(tester, runtime);
    await tester.tap(find.text('Explain a command'));
    await tester.pump();
    expect(runtime.goal, isNull);
    final goal = tester.widget<TextField>(find.byKey(const ValueKey('ai-agent-goal')));
    expect(goal.controller!.text, isNotEmpty);
    await tester.tap(find.byKey(const ValueKey('ai-agent-send')));
    await tester.pump();
    expect(runtime.sentScope!.hosts, isEmpty);
    expect(runtime.sentScope!.discoverHosts, isTrue);
    expect(runtime.busy, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('focused server is used automatically and a busy local draft survives Stop', (tester) async {
    final runtime = _Runtime();
    final container = await _panel(tester, runtime, focusedHost: const HostId('web'));
    expect(find.byKey(const ValueKey('ai-agent-host')), findsNothing);
    expect(find.byKey(const ValueKey('ai-agent-target')), findsOneWidget);
    expect(find.text('Production web'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('ai-agent-goal')), 'Check the server');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('ai-agent-send')));
    await tester.pump();
    expect(runtime.goal, 'Check the server');
    expect(runtime.sentScope!.hosts, {const HostId('web')});
    await tester.enterText(find.byKey(const ValueKey('ai-agent-goal')), 'My next task');
    await tester.tap(find.byKey(const ValueKey('ai-agent-stop')));
    await tester.pump();
    expect(runtime.busy, isFalse);
    expect(container.read(agentComposerProvider).goal, 'My next task');
    expect(tester.widget<TextField>(find.byKey(const ValueKey('ai-agent-goal'))).controller!.text, 'My next task');
    expect(tester.takeException(), isNull);
  });

  testWidgets('closing and reopening preserves unsent input and shows current focus', (tester) async {
    final runtime = _Runtime();
    final container = await _panel(tester, runtime, focusedHost: const HostId('web'));
    await tester.enterText(find.byKey(const ValueKey('ai-agent-goal')), 'Keep this local');
    await tester.pumpWidget(_app(container, visible: false));
    await tester.pump();
    await tester.pumpWidget(_app(container));
    await tester.pump();
    expect(tester.widget<TextField>(find.byKey(const ValueKey('ai-agent-goal'))).controller!.text, 'Keep this local');
    expect(find.text('Production web'), findsOneWidget);
    expect(runtime.goal, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Ctrl Enter sends after composition is committed and normal Enter keeps a multiline draft', (
    tester,
  ) async {
    final runtime = _Runtime();
    await _panel(tester, runtime);
    final goal = find.byKey(const ValueKey('ai-agent-goal'));
    await tester.enterText(goal, 'Explain pipes');
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'Explain pipes',
        selection: TextSelection.collapsed(offset: 13),
        composing: TextRange(start: 8, end: 13),
      ),
    );
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(runtime.goal, isNull);
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(text: 'Explain pipes', selection: TextSelection.collapsed(offset: 13)),
    );
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(runtime.goal, 'Explain pipes');
    expect(tester.takeException(), isNull);
  });

  testWidgets('messages and execution remain in the real task order', (tester) async {
    final runtime = _Runtime();
    runtime.entries.addAll([
      AgentChatEntry('user', 'Check storage'),
      AgentChatEntry('assistant', 'I will collect disk capacity.'),
      AgentExecution('exec-1', 'agent.diagnose', 'user@web.example', 'df -Pk', '/')..state = 'completed',
      AgentChatEntry('assistant', 'The disk still has space.'),
    ]);
    await _panel(tester, runtime);
    await tester.tap(find.byTooltip('Show local output'));
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(find.text('Check storage')).dy,
      lessThan(tester.getTopLeft(find.text('I will collect disk capacity.', findRichText: true)).dy),
    );
    expect(
      tester.getTopLeft(find.text('I will collect disk capacity.', findRichText: true)).dy,
      lessThan(tester.getTopLeft(find.text('user@web.example')).dy),
    );
    expect(
      tester.getTopLeft(find.text('user@web.example')).dy,
      lessThan(tester.getTopLeft(find.text('The disk still has space.', findRichText: true)).dy),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('approval shows the exact command and output sharing enforces the byte budget', (tester) async {
    final runtime = _Runtime()
      ..active = true
      ..phase = AgentPhase.awaitingApproval
      ..approval = AgentApproval('user@web.example', 'printf approved', '/srv/app', 'agent.execute');
    await _panel(tester, runtime);
    expect(find.text('user@web.example'), findsOneWidget);
    expect(find.text('/srv/app'), findsOneWidget);
    expect(find.text('printf approved'), findsOneWidget);
    await tester.tap(find.text('Approve once'));
    await tester.pump();
    expect(runtime.approved, isTrue);

    final output = OutputStore().create('owner', const HostId('web'), _profile.identity, 0);
    runtime.dataRequest = AgentDataRequest(output);
    runtime.phase = AgentPhase.awaitingData;
    runtime.refresh();
    await tester.pump();
    final projection = find.byKey(const ValueKey('ai-agent-output-projection'));
    await tester.enterText(projection, List.filled(4097, '界').join());
    await tester.pump();
    expect(
      tester.widget<TextField>(projection).decoration!.errorText,
      AppLocalizations.of(tester.element(projection)).aiAgentProjectionTooLarge,
    );
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('ai-agent-share-output'))).onPressed, isNull);
    await tester.tap(find.text('Keep local'));
    await tester.pump();
    expect(runtime.dataAnswered, isTrue);
    expect(runtime.shared, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('edited output survives hiding only for the exact pending request', (tester) async {
    final store = OutputStore();
    final first = AgentDataRequest(store.create('owner', const HostId('web'), _profile.identity, 0));
    final runtime = _Runtime()
      ..active = true
      ..dataRequest = first
      ..phase = AgentPhase.awaitingData;
    final container = await _panel(tester, runtime);
    final projection = find.byKey(const ValueKey('ai-agent-output-projection'));
    await tester.enterText(projection, 'redacted text');
    await tester.pumpWidget(_app(container, visible: false));
    await tester.pump();
    await tester.pumpWidget(_app(container));
    await tester.pump();
    expect(tester.widget<TextField>(projection).controller!.text, 'redacted text');
    final second = AgentDataRequest(store.create('owner', const HostId('web'), _profile.identity, 0));
    runtime.dataRequest = second;
    runtime.refresh();
    await tester.pump();
    expect(tester.widget<TextField>(projection).controller!.text, second.suggested);
    expect(container.read(agentComposerProvider).outputRequest, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('legacy tools-off profiles use automatic targets and errors use a safe actionable message', (
    tester,
  ) async {
    final runtime = _Runtime()..error = 'scopeChanged';
    await _panel(tester, runtime, tools: false);
    expect(find.text('Text only'), findsNothing);
    expect(find.byKey(const ValueKey('ai-agent-host')), findsNothing);
    expect(find.byKey(const ValueKey('ai-agent-target')), findsOneWidget);
    expect(find.textContaining('Start a new task to authorize the current target.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('chat model selection changes only this window and leaves defaults and lightweight models intact', (
    tester,
  ) async {
    final runtime = _Runtime();
    final container = await _panel(tester, runtime);
    final initial = container.read(aiConfigurationProvider);
    await tester.tap(
      find.descendant(of: find.byKey(const ValueKey('ai-agent-model')), matching: find.byType(TextButton)),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('ai-model-search')), 'alternate');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('ai-model-option-alternate-model')), findsOneWidget);
    expect(find.byKey(const ValueKey('ai-model-option-other-model')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('ai-model-option-alternate-model')));
    await tester.pumpAndSettle();
    expect(container.read(selectedAgentModelProvider), 'alternate-model');
    expect(container.read(effectiveAgentProfileProvider)!.model, 'alternate-model');
    final saved = container.read(aiConfigurationProvider);
    expect(saved, same(initial));
    expect(saved.profile!.model, _profile.model);
    expect(saved.profileForInline!.model, 'inline-model');
    expect(saved.profileForCompletion!.model, 'completion-model');
    expect(runtime.goal, isNull);
    await tester.pumpWidget(_app(container, visible: false));
    await tester.pump();
    await tester.pumpWidget(_app(container));
    await tester.pump();
    expect(container.read(effectiveAgentProfileProvider)!.model, 'alternate-model');
    expect(tester.takeException(), isNull);
  });

  testWidgets('composer shows mode, model and estimated context with host above and send at bottom right', (
    tester,
  ) async {
    final runtime = _Runtime();
    await _panel(tester, runtime, focusedHost: const HostId('web'));
    final host = tester.getRect(find.byKey(const ValueKey('ai-agent-target')));
    final goal = tester.getRect(find.byKey(const ValueKey('ai-agent-goal')));
    final send = tester.getRect(find.byKey(const ValueKey('ai-agent-send')));
    final model = tester.getRect(find.byKey(const ValueKey('ai-agent-model')));
    expect(host.bottom, lessThan(goal.top));
    expect(send.right, greaterThan(model.right));
    expect(send.bottom, greaterThanOrEqualTo(model.bottom));
    expect(find.text('0%'), findsOneWidget);
    runtime.estimatedUsed = 32000;
    runtime.estimatedWindow = 128000;
    runtime.refresh();
    await tester.pump();
    expect(find.text('25%'), findsOneWidget);
    final usage = tester.widget<Tooltip>(
      find.ancestor(of: find.byKey(const ValueKey('ai-agent-context-usage')), matching: find.byType(Tooltip)).first,
    );
    expect(usage.message, 'Estimated context: 25% · 32000 / 128000 tokens');
    expect(tester.takeException(), isNull);
  });

  testWidgets('permission selection applies to send and is disabled during a turn', (tester) async {
    final runtime = _Runtime();
    final container = await _panel(tester, runtime);
    expect(container.read(selectedAgentPermissionModeProvider), AgentPermissionMode.confirm);
    await tester.tap(find.byKey(const ValueKey('ai-agent-permission')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('ai-agent-permission-auto')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('ai-agent-permission-observe')));
    await tester.pumpAndSettle();
    expect(container.read(selectedAgentPermissionModeProvider), AgentPermissionMode.observe);
    await tester.enterText(find.byKey(const ValueKey('ai-agent-goal')), 'Observe the server');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('ai-agent-send')));
    await tester.pump();
    expect(runtime.sentScope!.permissionMode, AgentPermissionMode.observe);
    expect(tester.widget<TextButton>(find.byKey(const ValueKey('ai-agent-permission'))).onPressed, isNull);
    container.read(selectedAgentPermissionModeProvider.notifier).select(AgentPermissionMode.auto);
    expect(container.read(selectedAgentPermissionModeProvider), AgentPermissionMode.observe);
    await tester.tap(find.byKey(const ValueKey('ai-agent-stop')));
    await tester.pump();
    expect(tester.widget<TextButton>(find.byKey(const ValueKey('ai-agent-permission'))).onPressed, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('history expands inside the sidebar and toggles without an overlay', (tester) async {
    await _panel(tester, _Runtime(), store: _ConversationStore([_conversation('a')]));
    expect(find.byKey(const ValueKey('ai-agent-history-list')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('ai-agent-history')));
    await tester.pumpAndSettle();
    final history = find.byKey(const ValueKey('ai-agent-history-list'));
    expect(history, findsOneWidget);
    expect(
      find.descendant(of: find.byType(AgentPanel), matching: find.byKey(const ValueKey('ai-conversation-a'))),
      findsOneWidget,
    );
    expect(find.byType(PopupSurface), findsNothing);
    expect(
      tester.getRect(history).top,
      greaterThan(tester.getRect(find.byKey(const ValueKey('ai-agent-history'))).bottom),
    );
    await tester.tap(find.byKey(const ValueKey('ai-agent-history')));
    await tester.pumpAndSettle();
    expect(history, findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('history switches local drafts while target keeps following current focus', (tester) async {
    final runtime = _Runtime();
    final store = _ConversationStore([_conversation('a'), _conversation('b')]);
    final container = await _panel(tester, runtime, store: store, focusedHost: const HostId('web'));
    final conversations = container.read(agentConversationsProvider);
    final goal = find.byKey(const ValueKey('ai-agent-goal'));

    Future<void> select(String id) async {
      await tester.tap(find.byKey(const ValueKey('ai-agent-history')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('ai-conversation-$id')));
      await tester.pumpAndSettle();
    }

    await select('a');
    expect(find.text('Previous a'), findsOneWidget);
    await tester.enterText(goal, 'Only draft A');
    await select('b');
    expect(find.text('Previous a'), findsNothing);
    expect(find.text('Previous b'), findsOneWidget);
    expect(tester.widget<TextField>(goal).controller!.text, isEmpty);
    expect(container.read(agentComposerProvider).host, isNull);
    await tester.enterText(goal, 'Only draft B');
    await select('a');
    expect(conversations.selectedId, 'a');
    expect(tester.widget<TextField>(goal).controller!.text, 'Only draft A');
    expect(find.text('Production web'), findsOneWidget);
    await select('b');
    expect(tester.widget<TextField>(goal).controller!.text, 'Only draft B');
    expect(container.read(agentComposerProvider).host, isNull);
    await conversations.saved;
    expect(
      store.records.expand((record) => record.entries).map((entry) => entry.text),
      isNot(anyElement(contains('Only draft'))),
    );
    expect(runtime.goal, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('busy history stays visible while switching, deletion and new conversation are disabled', (tester) async {
    final runtime = _Runtime();
    final container = await _panel(tester, runtime, store: _ConversationStore([_conversation('a')]));
    await tester.enterText(find.byKey(const ValueKey('ai-agent-goal')), 'Current task');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('ai-agent-send')));
    await tester.pump();
    expect(runtime.busy, isTrue);
    expect(tester.widget<IconButton>(find.byKey(const ValueKey('ai-agent-new-task'))).onPressed, isNull);
    final selected = container.read(agentConversationsProvider).selectedId;
    await tester.tap(find.byKey(const ValueKey('ai-agent-history')));
    await tester.pumpAndSettle();
    expect(find.text('Stop the current task or wait for it to finish before switching conversations.'), findsOneWidget);
    expect(tester.widget<PopupRow>(find.byKey(const ValueKey('ai-conversation-a'))).onTap, isNull);
    expect(tester.widget<IconButton>(find.byKey(const ValueKey('ai-conversation-delete-a'))).onPressed, isNull);
    expect(container.read(agentConversationsProvider).selectedId, selected);
    expect(runtime.busy, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('ai-agent-stop')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('ai-agent-stop')));
    await tester.pump();
    expect(runtime.busy, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('restored history sends only after explicit Continue confirmation', (tester) async {
    final runtime = _Runtime();
    await _panel(tester, runtime, store: _ConversationStore([_conversation('a')]));
    await tester.tap(find.byKey(const ValueKey('ai-agent-history')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('ai-conversation-a')));
    await tester.pumpAndSettle();
    expect(find.text('Previous a'), findsOneWidget);
    expect(runtime.goal, isNull);
    final goal = find.byKey(const ValueKey('ai-agent-goal'));
    await tester.enterText(goal, 'Follow up');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('ai-agent-send')));
    await tester.pumpAndSettle();
    expect(find.text('Continue conversation'), findsOneWidget);
    expect(find.textContaining('Continuing resends this conversation'), findsOneWidget);
    expect(runtime.goal, isNull);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(runtime.goal, isNull);
    expect(tester.widget<TextField>(goal).controller!.text, 'Follow up');
    await tester.tap(find.byKey(const ValueKey('ai-agent-send')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue conversation'));
    await tester.pumpAndSettle();
    expect(runtime.goal, 'Follow up');
    expect(runtime.sentHistory.map((entry) => entry.text), ['Previous a']);
    expect(runtime.sentScope!.hosts, isEmpty);
    expect(runtime.sentScope!.discoverHosts, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('changed destination starts a new conversation without resending prior history', (tester) async {
    final runtime = _Runtime();
    final container = await _panel(
      tester,
      runtime,
      store: _ConversationStore([_conversation('a', destination: 'previous-model-destination')]),
    );
    await tester.tap(find.byKey(const ValueKey('ai-agent-history')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('ai-conversation-a')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('ai-agent-goal')), 'Fresh question');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('ai-agent-send')));
    await tester.pumpAndSettle();
    expect(find.text('The server or model destination changed. Start a new conversation.'), findsOneWidget);
    expect(runtime.goal, isNull);
    await tester.tap(find.widgetWithText(FilledButton, 'New conversation'));
    await tester.pumpAndSettle();
    expect(runtime.goal, 'Fresh question');
    expect(runtime.sentHistory, isEmpty);
    expect(container.read(agentConversationsProvider).selectedId, isNot('a'));
    expect(find.text('Previous a'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('restored executions show shared text without command, raw output or old approvals', (tester) async {
    final runtime = _Runtime();
    final store = _ConversationStore([
      _conversation(
        'a',
        entries: const [
          ConversationEntry(kind: ConversationEntryKind.user, text: 'Prior task'),
          ConversationEntry(
            kind: ConversationEntryKind.execution,
            capability: 'agent.execute',
            state: 'completed',
            exitCode: 0,
            text: 'Only approved shared output',
          ),
        ],
      ),
    ]);
    await _panel(tester, runtime, store: store);
    runtime.approval = AgentApproval(
      'old-user@old.example',
      'printf old-secret-command',
      '/private/old',
      'agent.execute',
    );
    final rawStore = OutputStore();
    final raw = rawStore.create('old-owner', const HostId('web'), _profile.identity, 0);
    rawStore.append(raw, false, Uint8List.fromList([82, 65, 87]));
    runtime.dataRequest = AgentDataRequest(raw);
    await tester.tap(find.byKey(const ValueKey('ai-agent-history')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('ai-conversation-a')));
    await tester.pumpAndSettle();
    expect(runtime.approval, isNull);
    expect(runtime.dataRequest, isNull);
    final execution = runtime.timeline.whereType<AgentExecution>().single;
    expect(execution.archived, isTrue);
    expect(execution.command, isEmpty);
    expect(execution.cwd, isEmpty);
    expect(execution.target, isEmpty);
    expect(execution.output, isNull);
    await tester.tap(find.byTooltip('Show local output'));
    await tester.pumpAndSettle();
    expect(find.text('Only approved shared output'), findsOneWidget);
    expect(find.text('Raw tool output is not saved in history.'), findsOneWidget);
    expect(find.text('printf old-secret-command'), findsNothing);
    expect(find.text('old-user@old.example'), findsNothing);
    expect(find.text('/private/old'), findsNothing);
    expect(find.text('RAW'), findsNothing);
    expect(find.text('Approve once'), findsNothing);
    expect(find.byKey(const ValueKey('ai-agent-share-output')), findsNothing);
    expect(runtime.goal, isNull);
    expect(tester.takeException(), isNull);
  });

  for (final welcome in [false, true]) {
    testWidgets('${welcome ? 'welcome' : 'toolbar'} configuration opens the AI settings category', (tester) async {
      await _panel(tester, _Runtime(), enabled: !welcome, size: const Size(1200, 1000));
      await tester.tap(welcome ? find.widgetWithText(FilledButton, 'Configure AI') : find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsPanel), findsOneWidget);
      final marker = find.byKey(const ValueKey('ai-settings-destination'));
      expect(marker, findsOneWidget);
      final content = tester.getRect(find.byKey(const ValueKey('settings-content')));
      final target = tester.getRect(marker);
      expect(target.top, inInclusiveRange(content.top - 1, content.bottom - 1));
      expect(tester.widget<SettingsPanel>(find.byType(SettingsPanel)).initialSection, SettingsSectionId.ai);
      expect(tester.takeException(), isNull);
    });
  }

  for (final width in [300.0, 560.0]) {
    testWidgets('Agent remains usable at width $width with a short scaled viewport', (tester) async {
      final runtime = _Runtime();
      await _panel(
        tester,
        runtime,
        size: Size(width, 420),
        textScale: 1.5,
        store: _ConversationStore([_conversation('a'), _conversation('b')]),
      );
      await tester.tap(find.byKey(const ValueKey('ai-agent-history')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('ai-conversation-a')), findsOneWidget);
      expect(find.byKey(const ValueKey('ai-conversation-b')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const ValueKey('ai-conversation-a')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('ai-agent-new-task')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('ai-agent-goal')), 'A short task');
      await tester.pump();
      await tester.ensureVisible(find.byKey(const ValueKey('ai-agent-send')));
      await tester.tap(find.byKey(const ValueKey('ai-agent-send')));
      await tester.pump();
      expect(runtime.goal, 'A short task');
      expect(tester.takeException(), isNull);
    });
  }
}

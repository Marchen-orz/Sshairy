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
  List<ConversationEntry> sentHistory = const [];
  bool sentAnswerOnly = false, appendGoal = true;
  final entries = <AgentTimelineEntry>[];
  void refresh() => notifyListeners();
  @override
  bool get busy => active;
  @override
  List<AgentTimelineEntry> get timeline => List.unmodifiable(entries);
  @override
  Future<void> startConversation(
    String goal,
    AgentScope scope,
    List<ConversationEntry> history, {
    bool answerOnly = false,
    bool appendGoal = true,
  }) {
    sentHistory = List.unmodifiable(history);
    sentAnswerOnly = answerOnly;
    this.appendGoal = appendGoal;
    restoreConversation(history);
    return super.startConversation(goal, scope, history, answerOnly: answerOnly, appendGoal: appendGoal);
  }

  @override
  void restoreConversation(List<ConversationEntry> history, {String? failure}) {
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
    if (appendGoal) entries.add(AgentChatEntry('user', value));
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
}

class _Assets extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async => key == 'AssetManifest.bin'
      ? const StandardMessageCodec().encodeMessage(<String, Object?>{})!
      : ByteData.sublistView(File(key).readAsBytesSync());
}

Widget _app(
  ProviderContainer container, {
  bool visible = true,
  double textScale = 1,
  Locale locale = const Locale('en'),
}) => UncontrolledProviderScope(
  container: container,
  child: DefaultAssetBundle(
    bundle: _Assets(),
    child: MaterialApp(
      locale: locale,
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
  Locale locale = const Locale('en'),
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
  await tester.pumpWidget(_app(container, textScale: textScale, locale: locale));
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

  testWidgets('Enter sends, Shift Enter keeps the draft, and Enter waits for composition', (tester) async {
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
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(runtime.goal, isNull);
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(text: 'Explain pipes', selection: TextSelection.collapsed(offset: 13)),
    );
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(runtime.goal, isNull);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
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

  for (final locale in [const Locale('en'), const Locale('zh')]) {
    testWidgets('tool cards use localized names and purpose hints in $locale', (tester) async {
      final runtime = _Runtime();
      runtime.entries.addAll([
        AgentChatEntry('user', 'Check tools'),
        AgentExecution('list', 'agent.hosts', '', '', '')..state = 'completed',
        AgentExecution('diagnose', 'agent.diagnose', 'target', 'fixed diagnostic', '/')..state = 'completed',
        AgentExecution('execute', 'agent.execute', 'target', 'printf checked', '/')..state = 'failed',
        AgentExecution('read', 'agent.output', '', '', '')..state = 'cancelled',
        AgentExecution('unknown', 'agent.unknown', '', '', '')..state = 'failed',
      ]);
      await _panel(tester, runtime, locale: locale);
      final l = AppLocalizations.of(tester.element(find.byType(AgentPanel)));
      expect(find.text(l.aiAgentToolHosts), findsOneWidget);
      expect(find.text(l.aiAgentToolDiagnostics), findsOneWidget);
      expect(find.text('${l.aiAgentToolExecute} · printf checked'), findsOneWidget);
      expect(find.text(l.aiAgentToolOutput), findsOneWidget);
      expect(find.text(l.aiAgentExecutionRecord), findsOneWidget);
      for (final raw in ['host_list', 'diagnostics_collect', 'command_execute', 'output_read']) {
        expect(find.textContaining(raw), findsNothing);
      }
      for (final (name, hint) in [
        (l.aiAgentToolHosts, l.aiAgentToolHostsHint),
        (l.aiAgentToolDiagnostics, l.aiAgentToolDiagnosticsHint),
        ('${l.aiAgentToolExecute} · printf checked', l.aiAgentToolExecuteHint),
        (l.aiAgentToolOutput, l.aiAgentToolOutputHint),
      ]) {
        expect(find.byTooltip('$name\n$hint'), findsOneWidget);
      }
      expect(find.byTooltip(l.aiAgentCancelled), findsOneWidget);
      expect(
        tester.getTopLeft(find.text(l.aiAgentToolHosts)).dy,
        lessThan(tester.getTopLeft(find.text(l.aiAgentToolDiagnostics)).dy),
      );
      expect(find.byTooltip(l.aiAgentShowOutput), findsNWidgets(5));
      final executeCard = find.byKey(const ValueKey('execute'));
      await tester.tap(find.descendant(of: executeCard, matching: find.byTooltip(l.aiAgentShowOutput)));
      await tester.pumpAndSettle();
      expect(find.text('printf checked'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('restored ordinary tools stay compact and show interrupted reads without output notices', (tester) async {
    final runtime = _Runtime();
    runtime.restoreConversation(const [
      ConversationEntry(kind: ConversationEntryKind.user, text: 'Read tools'),
      ConversationEntry(kind: ConversationEntryKind.execution, text: '', capability: 'agent.hosts', state: 'completed'),
      ConversationEntry(kind: ConversationEntryKind.execution, text: '', capability: 'agent.execute', state: 'failed'),
      ConversationEntry(
        kind: ConversationEntryKind.execution,
        text: '',
        capability: 'agent.diagnose',
        state: 'completed',
      ),
      ConversationEntry(kind: ConversationEntryKind.execution, text: '', capability: 'agent.output', state: 'running'),
    ]);
    final container = await _panel(tester, runtime);
    expect(find.text('List hosts'), findsOneWidget);
    expect(find.text('Execute command'), findsOneWidget);
    expect(find.text('Collect diagnostics'), findsOneWidget);
    expect(find.text('Read output'), findsOneWidget);
    expect(find.byTooltip('Interrupted'), findsOneWidget);
    final readCard = find.byKey(ValueKey(runtime.timeline.whereType<AgentExecution>().last.id));
    await tester.tap(find.descendant(of: readCard, matching: find.byTooltip('Show local output')));
    await tester.pumpAndSettle();
    expect(find.text('Interrupted'), findsOneWidget);
    expect(find.text('Raw tool output is not saved in history.'), findsNothing);
    await tester.pumpWidget(_app(container, locale: const Locale('zh')));
    await tester.pumpAndSettle();
    expect(find.text('查看主机列表'), findsOneWidget);
    expect(find.text('执行命令'), findsOneWidget);
    expect(find.text('收集诊断'), findsOneWidget);
    expect(find.text('读取输出'), findsOneWidget);
    expect(runtime.goal, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('approval shows the exact command without a second output-sharing form', (tester) async {
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
    expect(find.byKey(const ValueKey('ai-agent-output-projection')), findsNothing);
    expect(find.byKey(const ValueKey('ai-agent-share-output')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('read approval includes its bounded diagnostic result without another decision', (tester) async {
    final runtime = _Runtime()
      ..active = true
      ..approval = AgentApproval(
        'Production web',
        'fixed read command',
        '/',
        'agent.diagnose',
        template: 'listeningPorts',
      );
    await _panel(tester, runtime);
    final l = AppLocalizations.of(tester.element(find.byType(AgentPanel)));
    expect(find.text(l.aiAgentReadApproveTitle), findsOneWidget);
    expect(find.text(l.aiAgentDiagnosticPorts), findsOneWidget);
    expect(find.text(l.aiAgentReadApproveHint), findsOneWidget);
    await tester.tap(find.text(l.aiAgentApprove));
    await tester.pump();
    expect(runtime.approved, isTrue);
    expect(find.byKey(const ValueKey('ai-agent-output-projection')), findsNothing);
    expect(find.byKey(const ValueKey('ai-agent-share-output')), findsNothing);
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

  testWidgets('host shares the title row and composer controls align with a small square send button', (tester) async {
    final runtime = _Runtime();
    await _panel(tester, runtime, focusedHost: const HostId('web'), size: const Size(360, 800));
    final host = tester.getRect(find.byKey(const ValueKey('ai-agent-target')));
    final title = tester.getRect(find.text('Airy'));
    final history = tester.getRect(find.byKey(const ValueKey('ai-agent-history')));
    final send = tester.getRect(find.byKey(const ValueKey('ai-agent-send')));
    final model = tester.getRect(find.byKey(const ValueKey('ai-agent-model')));
    final context = tester.getRect(find.byKey(const ValueKey('ai-agent-context-usage')));
    final permission = tester.getRect(find.byKey(const ValueKey('ai-agent-permission')));
    expect(host.center.dy, closeTo(title.center.dy, 1));
    expect(host.left, greaterThan(title.right));
    expect(host.right, lessThan(history.left));
    expect(send.size, const Size.square(WorkspaceSize.tabHeight));
    final button = tester.widget<IconButton>(find.byKey(const ValueKey('ai-agent-send')));
    expect(button.style!.shape!.resolve({}), isA<RoundedRectangleBorder>());
    expect(context.center.dy, closeTo(model.center.dy, 1));
    expect(permission.center.dy, closeTo(model.center.dy, 1));
    expect(send.center.dy, closeTo(model.center.dy, 1));
    expect(context.left - model.right, closeTo(Space.sm, 1));
    expect(permission.left - context.right, closeTo(Space.sm, 1));
    expect(send.left - permission.right, closeTo(Space.sm, 1));
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

  for (final locale in [const Locale('en'), const Locale('zh')]) {
    for (final scale in [1.0, 1.5]) {
      testWidgets('composer stays in one row while resizing in $locale at text scale $scale', (tester) async {
        final runtime = _Runtime()
          ..estimatedUsed = 128000
          ..estimatedWindow = 128000;
        await _panel(tester, runtime, size: const Size(560, 800), textScale: scale, locale: locale);
        await tester.enterText(find.byKey(const ValueKey('ai-agent-goal')), 'Keep this task while resizing');

        void expectToolbar() {
          final controls = [
            find.byKey(const ValueKey('ai-agent-model')),
            find.byKey(const ValueKey('ai-agent-context-usage')),
            find.byKey(const ValueKey('ai-agent-permission')),
            find.byKey(ValueKey(runtime.busy ? 'ai-agent-stop' : 'ai-agent-send')),
          ].map(tester.getRect).toList();
          final panel = tester.getRect(find.byType(AgentPanel));
          for (final rect in controls) {
            expect(rect.center.dy, closeTo(controls.first.center.dy, 1));
            expect(rect.left, greaterThanOrEqualTo(panel.left));
            expect(rect.right, lessThanOrEqualTo(panel.right));
          }
          for (var i = 1; i < controls.length; i++) {
            expect(controls[i].left, greaterThan(controls[i - 1].right));
          }
          expect(controls.first.width, greaterThan(48));
          expect(controls.last.size, const Size.square(WorkspaceSize.tabHeight));
          expect(tester.takeException(), isNull);
        }

        for (final width in [560.0, 360.0, 300.0, 560.0, 300.0]) {
          tester.view.physicalSize = Size(width, 800);
          await tester.pumpAndSettle();
          expectToolbar();
          expect(
            tester.widget<TextField>(find.byKey(const ValueKey('ai-agent-goal'))).controller!.text,
            'Keep this task while resizing',
          );
        }
        final permission = find.byKey(const ValueKey('ai-agent-permission'));
        final l = AppLocalizations.of(tester.element(find.byType(AgentPanel)));
        expect(
          tester.widget<Tooltip>(find.descendant(of: permission, matching: find.byType(Tooltip))).message,
          l.aiAgentPermissionConfirm,
        );
        expect(
          tester
              .widget<Tooltip>(
                find.descendant(of: find.byKey(const ValueKey('ai-agent-model')), matching: find.byType(Tooltip)),
              )
              .message,
          _profile.model,
        );
        await tester.tap(permission);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('ai-agent-permission-observe')));
        await tester.pumpAndSettle();
        await tester.tap(
          find.descendant(of: find.byKey(const ValueKey('ai-agent-model')), matching: find.byType(TextButton)),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('ai-model-option-alternate-model')));
        await tester.pumpAndSettle();
        expectToolbar();
        await tester.tap(find.byKey(const ValueKey('ai-agent-send')));
        await tester.pump();
        expect(runtime.goal, 'Keep this task while resizing');
        expect(runtime.sentScope!.permissionMode, AgentPermissionMode.observe);
        expectToolbar();
        await tester.tap(find.byKey(const ValueKey('ai-agent-stop')));
        await tester.pumpAndSettle();
        expectToolbar();
      });
    }
  }

  for (final width in [300.0, 560.0]) {
    testWidgets('permission descriptions stay in the dropdown at width $width', (tester) async {
      await _panel(tester, _Runtime(), size: Size(width, 420), textScale: 1.5);
      final l = AppLocalizations.of(tester.element(find.byType(AgentPanel)));
      final hints = [
        l.aiAgentPermissionObserveHint,
        l.aiAgentPermissionConfirmHint,
        l.aiAgentPermissionReviewHint,
        l.aiAgentPermissionAutoHint,
      ];
      for (final hint in hints) {
        expect(find.text(hint), findsNothing);
      }
      final permission = find.byKey(const ValueKey('ai-agent-permission'));
      final before = tester.getSize(permission);
      await tester.tap(permission);
      await tester.pumpAndSettle();
      for (final (index, mode) in [
        AgentPermissionMode.observe,
        AgentPermissionMode.confirm,
        AgentPermissionMode.review,
        AgentPermissionMode.auto,
      ].indexed) {
        final row = find.byKey(ValueKey('ai-agent-permission-${mode.name}'));
        final hint = find.descendant(of: row, matching: find.text(hints[index]));
        expect(hint, findsOneWidget);
        expect(tester.widget<Text>(hint).maxLines, 1);
        expect(tester.getRect(hint).center.dy, closeTo(tester.getRect(row).center.dy, 1));
      }
      await tester.tap(find.byKey(const ValueKey('ai-agent-permission-auto')));
      await tester.pumpAndSettle();
      for (final hint in hints) {
        expect(find.text(hint), findsNothing);
      }
      expect(tester.getSize(permission).height, before.height);
      expect(tester.takeException(), isNull);
    });
  }

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
    await tester.tap(find.byKey(const ValueKey('ai-agent-new-task')));
    await tester.pumpAndSettle();
    expect(
      container.read(selectedAgentPermissionModeProvider),
      AgentPermissionMode.confirm,
      reason: 'every new conversation starts in confirm mode',
    );
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

  testWidgets('restored history continues directly in the same binding without a modal', (tester) async {
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
    await tester.pump();
    expect(find.text('Continue conversation'), findsNothing);
    expect(runtime.goal, 'Follow up');
    expect(runtime.sentHistory.map((entry) => entry.text), ['Previous a']);
    expect(runtime.sentScope!.hosts, isEmpty);
    expect(runtime.sentScope!.discoverHosts, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('changing the selected model keeps the conversation, history, draft and permission mode', (tester) async {
    final runtime = _Runtime();
    final container = await _panel(tester, runtime, store: _ConversationStore([_conversation('a')]));
    await tester.tap(find.byKey(const ValueKey('ai-agent-history')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('ai-conversation-a')));
    await tester.pumpAndSettle();
    final goal = find.byKey(const ValueKey('ai-agent-goal'));
    await tester.enterText(goal, 'Follow up with a new model');
    container.read(selectedAgentPermissionModeProvider.notifier).select(AgentPermissionMode.observe);
    await tester.tap(
      find.descendant(of: find.byKey(const ValueKey('ai-agent-model')), matching: find.byType(TextButton)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('ai-model-option-alternate-model')));
    await tester.pumpAndSettle();
    expect(container.read(effectiveAgentProfileProvider)!.model, 'alternate-model');
    expect(container.read(agentConversationsProvider).selectedId, 'a');
    expect(find.byKey(const ValueKey('ai-agent-new-target')), findsNothing);
    expect(find.text('Previous a'), findsOneWidget);
    expect(tester.widget<TextField>(goal).controller!.text, 'Follow up with a new model');
    expect(container.read(selectedAgentPermissionModeProvider), AgentPermissionMode.observe);
    expect(runtime.goal, isNull);
    await tester.tap(find.byKey(const ValueKey('ai-agent-send')));
    await tester.pump();
    expect(runtime.goal, 'Follow up with a new model');
    expect(runtime.sentHistory.map((entry) => entry.text), ['Previous a']);
    expect(runtime.sentScope!.conversationId, 'a');
    expect(runtime.sentScope!.permissionMode, AgentPermissionMode.observe);
    expect(container.read(agentConversationsProvider).selectedId, 'a');
    expect(tester.takeException(), isNull);
  });

  testWidgets('changed binding keeps the draft and starts a new conversation only on request', (tester) async {
    final runtime = _Runtime();
    final container = await _panel(
      tester,
      runtime,
      store: _ConversationStore([
        _conversation(
          'a',
          destination: ModelProfile(
            protocol: _profile.protocol,
            endpoint: 'https://previous-model.example/v1',
            model: _profile.model,
          ).identity,
        ),
      ]),
    );
    await tester.tap(find.byKey(const ValueKey('ai-agent-history')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('ai-conversation-a')));
    await tester.pumpAndSettle();
    final goal = find.byKey(const ValueKey('ai-agent-goal'));
    await tester.enterText(goal, 'Fresh question');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('ai-agent-send')));
    await tester.pump();
    expect(find.text('The model destination changed. Start a new conversation.'), findsOneWidget);
    expect(runtime.goal, isNull);
    expect(tester.widget<TextField>(goal).controller!.text, 'Fresh question');
    await tester.tap(find.byKey(const ValueKey('ai-agent-new-target')));
    await tester.pump();
    expect(tester.widget<TextField>(goal).controller!.text, 'Fresh question');
    expect(container.read(agentConversationsProvider).selectedId, isNot('a'));
    expect(find.text('Previous a'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('ai-agent-send')));
    await tester.pump();
    expect(runtime.goal, 'Fresh question');
    expect(runtime.sentHistory, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('assistant reply actions copy, regenerate without tools and withdraw the turn', (tester) async {
    final runtime = _Runtime();
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String?;
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    final store = _ConversationStore([
      _conversation(
        'a',
        entries: const [
          ConversationEntry(kind: ConversationEntryKind.user, text: 'Previous a'),
          ConversationEntry(kind: ConversationEntryKind.assistant, text: 'Earlier answer'),
        ],
      ),
    ]);
    await _panel(tester, runtime, store: store);
    await tester.tap(find.byKey(const ValueKey('ai-agent-history')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('ai-conversation-a')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('ai-agent-copy-1')));
    await tester.pumpAndSettle();
    expect(copied, 'Earlier answer');
    expect(find.text('Copied'), findsOneWidget);
    expect(find.byKey(const ValueKey('ai-agent-regenerate')), findsOneWidget);
    // Let the copy snackbar leave before tapping controls at the bottom edge.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('ai-agent-regenerate')));
    await tester.pump();
    expect(runtime.sentAnswerOnly, isTrue);
    expect(runtime.appendGoal, isFalse);
    expect(runtime.sentHistory.map((entry) => entry.text), ['Previous a']);
    expect(runtime.sentScope!.hosts, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const ValueKey('ai-agent-stop')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('ai-agent-withdraw')));
    await tester.pump();
    expect(tester.widget<TextField>(find.byKey(const ValueKey('ai-agent-goal'))).controller!.text, 'Previous a');
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
    await tester.tap(find.byKey(const ValueKey('ai-agent-history')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('ai-conversation-a')));
    await tester.pumpAndSettle();
    expect(runtime.approval, isNull);
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

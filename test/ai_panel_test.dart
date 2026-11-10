import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/design/brand.dart';
import 'package:sshairy/design/theme.dart';
import 'package:sshairy/features/ai/application/composer.dart';
import 'package:sshairy/features/ai/application/configuration.dart';
import 'package:sshairy/features/ai/application/output_store.dart';
import 'package:sshairy/features/ai/application/providers.dart';
import 'package:sshairy/features/ai/application/runtime.dart';
import 'package:sshairy/features/ai/domain/agent.dart';
import 'package:sshairy/features/ai/domain/model.dart';
import 'package:sshairy/features/ai/presentation/agent_panel.dart';
import 'package:sshairy/features/capabilities/api.dart';
import 'package:sshairy/foundation/cancellation.dart';
import 'package:sshairy/foundation/ids.dart';
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
        : ModelProfile(protocol: _profile.protocol, endpoint: _profile.endpoint, model: _profile.model),
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
  String? goal;
  AgentScope? sentScope;
  bool? approved;
  bool dataAnswered = false;
  String? shared;
  final entries = <AgentTimelineEntry>[];
  void refresh() => notifyListeners();
  @override
  bool get busy => active;
  @override
  List<AgentTimelineEntry> get timeline => List.unmodifiable(entries);
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
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final container = ProviderContainer(
    overrides: [
      aiConfigurationProvider.overrideWith(() => _Configuration(enabled, tools)),
      agentBackendProvider.overrideWithValue(_Backend()),
      agentRuntimeProvider.overrideWithValue(runtime),
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

Future<void> _chooseHost(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('ai-agent-host')));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Production web').last);
  await tester.pumpAndSettle();
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
    expect(runtime.busy, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('server scope is explicit and a busy local draft survives Stop', (tester) async {
    final runtime = _Runtime();
    final container = await _panel(tester, runtime);
    await _chooseHost(tester);
    expect(find.text('Fixed diagnostics allowed · commands ask first'), findsOneWidget);
    expect(find.textContaining('Fixed Linux diagnostics may send'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('ai-agent-scope-details')));
    await tester.pump();
    expect(find.textContaining('Fixed Linux diagnostics may send'), findsOneWidget);
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

  testWidgets('closing and reopening preserves target and unsent input', (tester) async {
    final runtime = _Runtime();
    final container = await _panel(tester, runtime);
    await _chooseHost(tester);
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
    expect(
      tester.getTopLeft(find.text('Check storage')).dy,
      lessThan(tester.getTopLeft(find.text('I will collect disk capacity.')).dy),
    );
    expect(
      tester.getTopLeft(find.text('I will collect disk capacity.')).dy,
      lessThan(tester.getTopLeft(find.text('user@web.example')).dy),
    );
    expect(
      tester.getTopLeft(find.text('user@web.example')).dy,
      lessThan(tester.getTopLeft(find.text('The disk still has space.')).dy),
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

  testWidgets('text-only models hide remote controls and errors use a safe actionable message', (tester) async {
    final runtime = _Runtime()..error = 'scopeChanged';
    await _panel(tester, runtime, tools: false);
    expect(find.text('Text only'), findsOneWidget);
    expect(find.byKey(const ValueKey('ai-agent-host')), findsNothing);
    expect(find.textContaining('Start a new task to authorize the current target.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final width in [300.0, 560.0]) {
    testWidgets('Agent remains usable at width $width with a short scaled viewport', (tester) async {
      final runtime = _Runtime();
      await _panel(tester, runtime, size: Size(width, 420), textScale: 1.5);
      await _chooseHost(tester);
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

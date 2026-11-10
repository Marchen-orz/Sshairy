import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/design/theme.dart';
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
  model: 'test',
  tools: true,
);

class _Configuration extends AiConfigurationController {
  _Configuration(this.enabled);
  final bool enabled;
  @override
  AiConfiguration build() => AiConfiguration(enabled: enabled, profile: _profile);
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
  void refresh() => notifyListeners();
  @override
  bool get busy => active;
  @override
  Future<void> start(String value, AgentScope scope) async {
    goal = value;
    sentScope = scope;
    active = true;
    phase = AgentPhase.streaming;
    notifyListeners();
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

Future<ProviderContainer> _panel(WidgetTester tester, _Runtime runtime, {bool enabled = true}) async {
  tester.view.physicalSize = const Size(440, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final container = ProviderContainer(
    overrides: [
      aiConfigurationProvider.overrideWith(() => _Configuration(enabled)),
      agentBackendProvider.overrideWithValue(_Backend()),
      agentRuntimeProvider.overrideWithValue(runtime),
    ],
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
    runtime.dispose();
  });
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: buildTheme(Brightness.light).copyWith(splashFactory: NoSplash.splashFactory),
        home: const Scaffold(body: AgentPanel()),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 250));
  return container;
}

void main() {
  testWidgets('disabled AI offers configuration and cannot start a request', (tester) async {
    final runtime = _Runtime();
    await _panel(tester, runtime, enabled: false);
    expect(find.text('Configure a model and enable AI in Settings to begin.'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('ai-agent-send'))).onPressed, isNull);
    expect(runtime.goal, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('execution requires an explicitly selected server and Stop calls the runtime', (tester) async {
    final runtime = _Runtime();
    await _panel(tester, runtime);
    await tester.tap(find.byKey(const ValueKey('ai-agent-mode')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Approve each command').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('ai-agent-goal')), 'Check the server');
    await tester.pump();
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('ai-agent-send'))).onPressed, isNull);
    expect(find.textContaining('Fixed Linux diagnostics may send'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('ai-agent-host')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Production web').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('ai-agent-send')));
    await tester.pump();
    expect(runtime.goal, 'Check the server');
    expect(runtime.sentScope!.mode, AgentMode.execute);
    expect(runtime.sentScope!.hosts, {const HostId('web')});
    await tester.tap(find.byKey(const ValueKey('ai-agent-stop')));
    await tester.pump();
    expect(runtime.busy, isFalse);
    expect(find.text('Stopped'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('approval shows exact command and output sharing enforces the UTF-8 budget', (tester) async {
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
    final field = tester.widget<TextField>(projection);
    expect(field.controller!.text.length, 4097);
    expect(field.decoration!.errorText, AppLocalizations.of(tester.element(projection)).aiAgentProjectionTooLarge);
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('ai-agent-share-output'))).onPressed, isNull);
    await tester.tap(find.text('Keep local'));
    await tester.pump();
    expect(runtime.dataAnswered, isTrue);
    expect(runtime.shared, isNull);
    expect(tester.takeException(), isNull);
  });
}

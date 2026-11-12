import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/features/ai/adapters/model_provider.dart';
import 'package:sshairy/features/ai/application/configuration.dart';
import 'package:sshairy/features/ai/application/model_selection.dart';
import 'package:sshairy/features/ai/application/permission_mode.dart';
import 'package:sshairy/features/ai/application/providers.dart';
import 'package:sshairy/features/ai/domain/agent.dart';
import 'package:sshairy/features/ai/domain/model.dart';
import 'package:sshairy/features/capabilities/api.dart';
import 'package:sshairy/features/credentials/api.dart';
import 'package:sshairy/features/settings/settings.dart' show SettingKeys, settingsProvider;
import 'package:sshairy/foundation/cancellation.dart';
import 'package:sshairy/foundation/data_dir.dart';
import 'package:sshairy/foundation/ids.dart';
import 'package:sshairy/foundation/secret.dart';

ModelProfile _profile({
  String model = 'default-model',
  String endpoint = 'https://model.invalid/v1',
  ModelProtocol protocol = ModelProtocol.openai,
  bool tools = true,
}) => ModelProfile(protocol: protocol, endpoint: endpoint, model: model, tools: tools);

class _Configuration extends AiConfigurationController {
  _Configuration(this.initial);
  final AiConfiguration initial;

  @override
  AiConfiguration build() => initial;

  void replace(AiConfiguration next) => state = next;
}

class _Credentials implements AiCredentials {
  final values = <String, Secret>{};
  final reads = <String>[];

  @override
  Stream<void> get changes => const Stream.empty();
  @override
  Future<bool> has(String identity) async => values.containsKey(identity);
  @override
  Future<Secret?> read(String identity) async {
    reads.add(identity);
    return values[identity];
  }

  @override
  Future<void> save(String identity, Secret value) async => values[identity] = value;
  @override
  Future<void> clear(String identity) async => values.remove(identity);
}

class _Backend implements AgentBackend {
  @override
  List<AgentHost> get hosts => const [];
  @override
  Future<AgentTarget> prepare(HostId host, CancellationToken cancel) => throw StateError('no test connection');
}

class _Journal implements OperationJournal {
  @override
  Future<List<OperationRecord>> load() async => const [];
  @override
  Future<void> record(OperationRecord record) async {}
  @override
  Future<void> get saved async {}
}

class _BlockingModel implements ModelProvider {
  final entered = Completer<void>();
  final requests = <ModelRequest>[];
  final cancellations = <CancellationToken>[];

  @override
  Stream<ModelEvent> stream(ModelRequest request, CancellationToken cancel) async* {
    requests.add(request);
    cancellations.add(cancel);
    if (!entered.isCompleted) entered.complete();
    await cancel.whenCancelled;
  }

  @override
  void close() {}
}

/// A fresh data directory stands for a restarted app; pass the same path to simulate the next launch.
String _dataDir() {
  final dir = Directory.systemTemp.createTempSync('sshairy-model-selection-');
  addTearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } on FileSystemException {
      // A settings lock can outlive the test on Windows; the temp directory is disposable.
    }
  });
  return dir.path;
}

ProviderContainer _container(AiConfiguration initial, {_Credentials? credentials, String? dataDir}) {
  final container = ProviderContainer(
    overrides: [
      aiConfigurationProvider.overrideWith(() => _Configuration(initial)),
      aiCredentialsProvider.overrideWithValue(credentials ?? _Credentials()),
      dataDirProvider.overrideWithValue(dataDir ?? _dataDir()),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  test('effective Agent model defaults to configured profile without touching credentials', () {
    final credentials = _Credentials();
    final profile = _profile();
    final container = _container(AiConfiguration(enabled: true, profile: profile), credentials: credentials);
    expect(container.read(selectedAgentModelProvider), isNull);
    final effective = container.read(effectiveAgentProfileProvider)!;
    expect(effective.identity, profile.identity);
    expect(effective.tools, isTrue);
    expect(effective.contextWindow, profile.contextWindow);
    expect(effective.maxOutputTokens, profile.maxOutputTokens);
    expect(container.read(aiConfigurationProvider).profile, same(profile));
    expect(credentials.reads, isEmpty);
  });

  test('model choice persists for the next launch and preserves inline/completion models', () async {
    final profile = _profile();
    final config = AiConfiguration(
      enabled: true,
      profile: profile,
      inlineModel: 'inline-model',
      completionModel: 'completion-model',
    );
    final dataDir = _dataDir();
    final container = _container(config, dataDir: dataDir);
    container.read(selectedAgentModelProvider.notifier).select('airy-selected-model');
    await container.read(settingsProvider.notifier).saved;
    expect(container.read(settingsProvider).get(SettingKeys.agentModel), 'airy-selected-model');
    expect(File('$dataDir/settings.json').existsSync(), isTrue);
    final effective = container.read(effectiveAgentProfileProvider)!;
    expect(effective.model, 'airy-selected-model');
    expect(effective.protocol, profile.protocol);
    expect(effective.endpoint, profile.endpoint);
    expect(effective.tools, isTrue);
    expect(effective.contextWindow, profile.contextWindow);
    expect(effective.maxOutputTokens, profile.maxOutputTokens);
    expect(effective.identity, isNot(profile.identity));
    final unchanged = container.read(aiConfigurationProvider);
    expect(unchanged, same(config));
    expect(unchanged.profile!.model, 'default-model');
    expect(unchanged.profileForInline!.model, 'inline-model');
    expect(unchanged.profileForCompletion!.model, 'completion-model');
    expect(unchanged.profileForInline!.tools, isFalse);
    expect(unchanged.profileForCompletion!.tools, isFalse);
    final relaunched = _container(config, dataDir: dataDir);
    expect(relaunched.read(selectedAgentModelProvider), 'airy-selected-model');
    expect(relaunched.read(effectiveAgentProfileProvider)!.model, 'airy-selected-model');
    final otherDestination = _container(config, dataDir: _dataDir());
    expect(otherDestination.read(selectedAgentModelProvider), isNull);
    expect(otherDestination.read(effectiveAgentProfileProvider)!.model, 'default-model');
  });

  test('legacy tools false is normalized for Airy while terminal lanes stay without tools', () {
    final profile = _profile(tools: false);
    final config = AiConfiguration(enabled: true, profile: profile);
    final container = _container(config);
    final effective = container.read(effectiveAgentProfileProvider)!;
    expect(effective.identity, profile.identity);
    expect(effective.tools, isTrue);
    expect(container.read(aiConfigurationProvider).profile!.tools, isFalse);
    expect(config.profileForInline!.tools, isFalse);
    expect(config.profileForCompletion!.tools, isFalse);
    container.read(selectedAgentModelProvider.notifier).select('new-window-model');
    final selected = container.read(effectiveAgentProfileProvider)!;
    expect(selected.model, 'new-window-model');
    expect(selected.tools, isTrue);
    expect(config.profile!.model, 'default-model');
  });

  test('selection made before configuration never invents a model destination', () {
    final container = _container(const AiConfiguration());
    container.read(selectedAgentModelProvider.notifier).select('pending-model');
    expect(container.read(effectiveAgentProfileProvider), isNull);
    final configured = _profile(model: 'new-default');
    (container.read(aiConfigurationProvider.notifier) as _Configuration).replace(
      AiConfiguration(enabled: true, profile: configured),
    );
    expect(container.read(effectiveAgentProfileProvider)!.identity, configured.identity);
    expect(container.read(selectedAgentModelProvider), isNull);
  });

  test('actual provider profile changes clear window selection while unrelated settings keep it', () {
    final profile = _profile();
    final container = _container(AiConfiguration(enabled: true, profile: profile));
    final config = container.read(aiConfigurationProvider.notifier) as _Configuration;
    container.read(selectedAgentModelProvider.notifier).select('local-choice');
    expect(container.read(effectiveAgentProfileProvider)!.model, 'local-choice');
    config.replace(AiConfiguration(enabled: true, profile: profile, revision: 1, inlineModel: 'changed-inline'));
    expect(container.read(selectedAgentModelProvider), 'local-choice');
    expect(container.read(effectiveAgentProfileProvider)!.model, 'local-choice');
    final changed = _profile(endpoint: 'https://other-model.invalid/v1', model: 'other-default');
    config.replace(AiConfiguration(enabled: true, profile: changed, revision: 2));
    expect(container.read(effectiveAgentProfileProvider)!.identity, changed.identity);
    expect(container.read(selectedAgentModelProvider), isNull);
    config.replace(const AiConfiguration());
    expect(container.read(effectiveAgentProfileProvider), isNull);
  });

  test('permission mode is window-local, defaults to confirm and cannot change a running turn', () async {
    final profile = _profile();
    final model = _BlockingModel();
    final container = ProviderContainer(
      overrides: [
        aiConfigurationProvider.overrideWith(() => _Configuration(AiConfiguration(enabled: true, profile: profile))),
        aiCredentialsProvider.overrideWithValue(_Credentials()),
        aiModelProvider.overrideWithValue(model),
        agentBackendProvider.overrideWithValue(_Backend()),
        aiJournalProvider.overrideWithValue(_Journal()),
        capabilityDispatcherProvider.overrideWithValue(CapabilityDispatcher([])),
        dataDirProvider.overrideWithValue(_dataDir()),
      ],
    );
    addTearDown(() async {
      if (container.exists(agentRuntimeProvider)) await container.read(agentRuntimeProvider).shutdown();
      container.dispose();
    });
    expect(container.read(selectedAgentPermissionModeProvider), AgentPermissionMode.confirm);
    final selected = container.read(selectedAgentPermissionModeProvider.notifier);
    selected.select(AgentPermissionMode.auto);
    final runtime = container.read(agentRuntimeProvider);
    final work = runtime.start(
      'hold this turn',
      AgentScope(permissionMode: container.read(selectedAgentPermissionModeProvider)),
    );
    await model.entered.future.timeout(const Duration(seconds: 2));
    selected.select(AgentPermissionMode.observe);
    expect(container.read(selectedAgentPermissionModeProvider), AgentPermissionMode.auto);
    expect(runtime.permissionMode, AgentPermissionMode.auto);
    runtime.stop();
    await work.timeout(const Duration(seconds: 2));
    selected.select(AgentPermissionMode.observe);
    expect(container.read(selectedAgentPermissionModeProvider), AgentPermissionMode.observe);
    expect(runtime.permissionMode, AgentPermissionMode.auto);
    final otherWindow = _container(AiConfiguration(enabled: true, profile: profile));
    expect(otherWindow.read(selectedAgentPermissionModeProvider), AgentPermissionMode.confirm);
    expect(container.read(aiConfigurationProvider).profile, same(profile));
  });

  test('model choice changes cancel the active owner without replacing AgentRuntime identity', () async {
    final profile = _profile();
    final model = _BlockingModel();
    final container = ProviderContainer(
      overrides: [
        aiConfigurationProvider.overrideWith(() => _Configuration(AiConfiguration(enabled: true, profile: profile))),
        aiCredentialsProvider.overrideWithValue(_Credentials()),
        aiModelProvider.overrideWithValue(model),
        agentBackendProvider.overrideWithValue(_Backend()),
        aiJournalProvider.overrideWithValue(_Journal()),
        capabilityDispatcherProvider.overrideWithValue(CapabilityDispatcher([])),
        dataDirProvider.overrideWithValue(_dataDir()),
      ],
    );
    addTearDown(() async {
      if (container.exists(agentRuntimeProvider)) await container.read(agentRuntimeProvider).shutdown();
      container.dispose();
    });
    final runtime = container.read(agentRuntimeProvider);
    final work = runtime.start('wait until selection changes', AgentScope());
    await model.entered.future.timeout(const Duration(seconds: 2));
    expect(runtime.busy, isTrue);
    container.read(selectedAgentModelProvider.notifier).select('other-selected-model');
    expect(container.read(effectiveAgentProfileProvider)!.model, 'other-selected-model');
    await work.timeout(const Duration(seconds: 2));
    expect(model.cancellations.single.isCancelled, isTrue);
    expect(runtime.busy, isFalse);
    expect(container.read(agentRuntimeProvider), same(runtime));
    expect(model.requests.single.profile.identity, profile.identity);
  });

  test('model variants at exact configured protocol and endpoint share only the default credential', () async {
    final profile = _profile();
    final credentials = _Credentials()..values[profile.identity] = const Secret('synthetic-default-model-key');
    final container = _container(AiConfiguration(enabled: true, profile: profile), credentials: credentials);
    final provider = container.read(aiModelProvider) as HttpModelProvider;
    expect(credentials.reads, isEmpty);
    for (final model in ['default-model', 'airy-model', 'inline-model', 'completion-model', 'review-model']) {
      final selected = profile.withModel(model);
      final key = await provider.readKey(selected.identity);
      expect(key?.reveal(), 'synthetic-default-model-key');
    }
    expect(credentials.reads, List.filled(5, profile.identity));
    expect(container.read(aiConfigurationProvider).profile, same(profile));
  });

  test('a different protocol, endpoint origin or endpoint path cannot borrow configured credentials', () async {
    final profile = _profile();
    final credentials = _Credentials()..values[profile.identity] = const Secret('synthetic-default-model-key');
    final container = _container(AiConfiguration(enabled: true, profile: profile), credentials: credentials);
    final provider = container.read(aiModelProvider) as HttpModelProvider;
    final requests = [
      _profile(protocol: ModelProtocol.anthropic, model: 'selected'),
      _profile(endpoint: 'https://other.invalid/v1', model: 'selected'),
      _profile(endpoint: 'https://model.invalid/other', model: 'selected'),
      _profile(endpoint: 'https://model.invalid:444/v1', model: 'selected'),
    ];
    for (final request in requests) {
      expect(await provider.readKey(request.identity), isNull);
    }
    expect(credentials.reads, requests.map((profile) => profile.identity).toList());
    expect(credentials.reads, isNot(contains(profile.identity)));
  });

  test('credential mapping follows current configured provider and preserves foreign exact identity lookup', () async {
    final first = _profile();
    final next = _profile(protocol: ModelProtocol.anthropic, endpoint: 'https://second.invalid/v1', model: 'second');
    final foreign = _profile(endpoint: 'https://foreign.invalid/v1', model: 'foreign');
    final credentials = _Credentials()
      ..values[first.identity] = const Secret('synthetic-first-key')
      ..values[next.identity] = const Secret('synthetic-second-key')
      ..values[foreign.identity] = const Secret('synthetic-foreign-key');
    final container = _container(AiConfiguration(enabled: true, profile: first), credentials: credentials);
    final provider = container.read(aiModelProvider) as HttpModelProvider;
    expect((await provider.readKey(first.withModel('variant').identity))?.reveal(), 'synthetic-first-key');
    (container.read(aiConfigurationProvider.notifier) as _Configuration).replace(
      AiConfiguration(enabled: true, profile: next, revision: 1),
    );
    expect((await provider.readKey(next.withModel('variant').identity))?.reveal(), 'synthetic-second-key');
    expect(await provider.readKey(first.withModel('variant').identity), isNull);
    expect((await provider.readKey(foreign.identity))?.reveal(), 'synthetic-foreign-key');
    expect(credentials.reads, [first.identity, next.identity, first.withModel('variant').identity, foreign.identity]);
  });

  test('without a configured profile credentials retain exact destination identities', () async {
    final profile = _profile();
    final credentials = _Credentials()..values[profile.identity] = const Secret('synthetic-exact-key');
    final container = _container(const AiConfiguration(), credentials: credentials);
    final provider = container.read(aiModelProvider) as HttpModelProvider;
    expect((await provider.readKey(profile.identity))?.reveal(), 'synthetic-exact-key');
    expect(await provider.readKey(profile.withModel('variant').identity), isNull);
    expect(credentials.reads, [profile.identity, profile.withModel('variant').identity]);
  });

  test('non-profile JSON identity shapes never borrow the configured credential', () async {
    final profile = _profile();
    final credentials = _Credentials()..values[profile.identity] = const Secret('synthetic-default-model-key');
    final container = _container(AiConfiguration(enabled: true, profile: profile), credentials: credentials);
    final provider = container.read(aiModelProvider) as HttpModelProvider;
    final identities = [
      jsonEncode({'protocol': profile.protocol.name, 'endpoint': profile.endpoint, 'model': 'variant'}),
      jsonEncode([profile.protocol.name, profile.endpoint]),
      jsonEncode([profile.protocol.name, '${profile.endpoint}.untrusted', 'variant']),
    ];
    for (final identity in identities) {
      expect(await provider.readKey(identity), isNull);
    }
    expect(credentials.reads, identities);
  });
}

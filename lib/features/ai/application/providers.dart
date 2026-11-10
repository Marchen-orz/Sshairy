import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../foundation/data_dir.dart';
import '../../capabilities/api.dart';
import '../../credentials/api.dart';
import '../adapters/model_provider.dart';
import '../adapters/operation_journal.dart';
import '../domain/agent.dart';
import '../domain/model.dart';
import 'configuration.dart';
import 'runtime.dart';

final agentBackendProvider = Provider<AgentBackend>((_) => throw StateError('Agent backend not installed'));
final aiModelProvider = Provider<ModelProvider>((ref) {
  final provider = HttpModelProvider(readKey: ref.read(aiCredentialsProvider).read);
  ref.onDispose(provider.close);
  return provider;
});
final aiJournalProvider = Provider<OperationJournal>((ref) => JsonOperationJournal(ref.read(dataDirProvider)));
final agentRuntimeProvider = Provider<AgentRuntime>((ref) {
  final runtime = AgentRuntime(
    model: ref.read(aiModelProvider),
    backend: ref.read(agentBackendProvider),
    journal: ref.read(aiJournalProvider),
    dispatcher: ref.read(capabilityDispatcherProvider),
    configuration: () {
      final value = ref.read(aiConfigurationProvider);
      return (enabled: value.enabled, profile: value.profile, revision: value.revision);
    },
  );
  ref.listen(aiConfigurationProvider, (_, _) => runtime.stop());
  final keys = ref.read(aiCredentialsProvider).changes.listen((_) => runtime.stop());
  ref.onDispose(keys.cancel);
  ref.onDispose(runtime.dispose);
  return runtime;
});

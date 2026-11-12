import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../foundation/data_dir.dart';
import '../../../foundation/ids.dart';
import '../../capabilities/api.dart';
import '../../credentials/api.dart';
import '../../terminal/api.dart';
import '../adapters/model_provider.dart';
import '../adapters/operation_journal.dart';
import '../domain/agent.dart';
import '../domain/model.dart';
import '../domain/resources.dart';
import 'configuration.dart';
import 'model_selection.dart';
import 'runtime.dart';
import 'terminal_service.dart';

final aiTerminalServiceProvider = Provider<AiTerminalService>((ref) {
  final service = AiTerminalService(
    model: ref.read(aiModelProvider),
    configuration: () => ref.read(aiConfigurationProvider),
    hosts: () => ref.read(aiTerminalHostsProvider),
  );
  ref.listen(aiConfigurationProvider, (_, _) => service.invalidate());
  ref.listen(aiTerminalHostsProvider, (_, _) => service.invalidate());
  final keys = ref.read(aiCredentialsProvider).changes.listen((_) => service.invalidate());
  ref.onDispose(keys.cancel);
  ref.onDispose(service.dispose);
  return service;
});

/// The app supplies opaque route/security fingerprints without connecting or exposing configuration.
final agentConversationRoutesProvider = Provider<Map<HostId, String> Function()>(
  (_) =>
      () => const {},
);

final agentTerminalHistoryProvider = Provider<TerminalHistoryReader?>((_) => null);
final agentResourceReaderProvider = Provider<AgentResourceReader?>((_) => null);
final agentBackendProvider = Provider<AgentBackend>((_) => throw StateError('Agent backend not installed'));
final aiModelProvider = Provider<ModelProvider>((ref) {
  final provider = HttpModelProvider(
    readKey: (identity) {
      final configured = ref.read(aiConfigurationProvider).profile;
      var credentialIdentity = identity;
      if (configured != null) {
        // Model choices share a key only within the exact configured protocol and endpoint.
        final requested = jsonDecode(identity);
        if (requested is List &&
            requested.length == 3 &&
            requested[0] == configured.protocol.name &&
            requested[1] == configured.endpoint) {
          credentialIdentity = configured.identity;
        }
      }
      return ref.read(aiCredentialsProvider).read(credentialIdentity);
    },
  );
  ref.onDispose(provider.close);
  return provider;
});
final aiJournalProvider = Provider<OperationJournal>((ref) => JsonOperationJournal(ref.read(dataDirProvider)));
final agentRuntimeProvider = Provider<AgentRuntime>((ref) {
  final runtime = AgentRuntime(
    model: ref.read(aiModelProvider),
    estimateInputBytes: estimateModelRequestBytes,
    backend: ref.read(agentBackendProvider),
    terminalHistory: ref.read(agentTerminalHistoryProvider),
    resources: ref.read(agentResourceReaderProvider),
    journal: ref.read(aiJournalProvider),
    dispatcher: ref.read(capabilityDispatcherProvider),
    hostRoutes: () => ref.read(agentConversationRoutesProvider)(),
    reviewProfile: () => ref.read(aiConfigurationProvider).profileForReview ?? ref.read(effectiveAgentProfileProvider),
    configuration: () {
      final value = ref.read(aiConfigurationProvider);
      return (enabled: value.enabled, profile: ref.read(effectiveAgentProfileProvider), revision: value.revision);
    },
  );
  final activeTurn = ref.read(agentTurnActiveProvider.notifier);
  void syncActivity() => activeTurn.update(runtime.busy);
  runtime.addListener(syncActivity);
  ref.onDispose(() => runtime.removeListener(syncActivity));
  ref.listen(aiConfigurationProvider, (_, _) => runtime.invalidateHostApprovals());
  ref.listen(effectiveAgentProfileProvider, (_, _) => runtime.invalidateHostApprovals());
  final keys = ref.read(aiCredentialsProvider).changes.listen((_) => runtime.invalidateHostApprovals());
  ref.onDispose(keys.cancel);
  ref.onDispose(runtime.dispose);
  return runtime;
});

import 'package:flutter/material.dart' show Icons;
import 'package:flutter_riverpod/misc.dart';

import '../features/ai/api.dart';
import '../features/connections/api.dart';
import '../features/capabilities/api.dart';
import '../features/credentials/api.dart';
import '../features/hosts/api.dart';
import '../features/files/api.dart';
import '../features/forwarding/api.dart';
import '../features/link/api.dart';
import '../features/settings/api.dart';
import '../features/snippets/api.dart';
import '../features/terminal/api.dart';
import '../features/workspace/api.dart';
import '../foundation/ids.dart';
import '../platform/device_form_factor.dart';
import 'ai_backend.dart';
import 'ai_resources.dart';
import 'ai_terminal_history.dart';
import 'ai_terminal_hosts.dart';
import 'link_bridge.dart';
import 'capabilities/ai.dart';
import 'capabilities/hosts.dart';
import 'capabilities/host_library.dart';
import 'capabilities/credentials.dart';
import 'capabilities/workspace.dart';
import 'capabilities/files.dart';
import 'capabilities/local_files.dart';
import 'capabilities/settings.dart';
import 'capabilities/snippets.dart';
import 'capabilities/forwarding.dart';
import 'mcp/settings.dart';

/// The composition root: the one place that knows every feature and registers what each one offers.
List<Override> appOverrides() => [
  aiTerminalHostsProvider.overrideWith((ref) => aiTerminalHosts(ref.watch(hostsProvider))),
  agentTerminalHistoryProvider.overrideWith(
    (ref) =>
        WorkspaceTerminalHistoryReader(() => ref.read(workspaceProvider), () => ref.read(terminalSessionsProvider)),
  ),
  agentResourceReaderProvider.overrideWith(
    (ref) => AppAgentResources(
      workspace: () => ref.read(workspaceProvider),
      sessions: () => ref.read(terminalSessionsProvider),
      forwards: () => ref.read(forwardsProvider),
      forwardBinding: (id) => ref.read(forwardsProvider.notifier).resourceBinding(id),
      transfers: () => ref.read(transfersProvider).where((t) => !t.sessionOnly).toList(),
      transferBinding: (id) => ref.read(transfersProvider.notifier).resourceBinding(id),
      hosts: () => ref.read(hostsProvider),
      hostRevision: () => ref.read(hostsProvider.notifier).revision,
    ),
  ),
  agentFocusedHostProvider.overrideWith((ref) {
    final tab = ref.watch(workspaceProvider).activeTab;
    final sessions = ref.watch(terminalSessionsProvider);
    final host = tab == null ? null : sessions[tab.layout.focusedLeaf.session]?.sshHost;
    return host == null || host.transient ? null : host.id;
  }),
  agentConversationRoutesProvider.overrideWith((ref) {
    var bindings = <HostId, ({String signature, String session})>{};
    // Observe every saved snapshot so changing a route back cannot revive an old grant.
    ref.listen(hostsProvider, (_, hosts) {
      bindings = {
        for (final host in aiTerminalHosts(hosts))
          host.id: (
            signature: host.signature,
            session: bindings[host.id]?.signature == host.signature ? bindings[host.id]!.session : newId(),
          ),
      };
    }, fireImmediately: true);
    return () {
      final trustRevision = ref.read(hostTrustProvider).revision;
      final credentialRevision = ref.read(connectionCredentialsProvider).revision;
      return {
        for (final entry in bindings.entries)
          entry.key: conversationRouteFingerprint(
            entry.value.signature,
            trustRevision: trustRevision,
            credentialRevision: credentialRevision,
            securitySession: entry.value.session,
          ),
      };
    };
  }),
  terminalAiServiceProvider.overrideWith((ref) => ref.watch(aiTerminalServiceProvider)),
  agentBackendProvider.overrideWith(
    (ref) => SshAgentBackend(ref.read(connectionManagerProvider), () => ref.read(hostsProvider)),
  ),
  settingsSectionsProvider.overrideWith(
    (ref) => [
      SettingsSection(
        (l) => l.aiConfigTitle,
        (_) => const AiSettings(),
        id: SettingsSectionId.ai,
        icon: Icons.auto_awesome_outlined,
      ),
      if (isDesktopPlatform)
        SettingsSection(
          (l) => l.mcpTitle,
          (_) => const McpSettings(),
          id: SettingsSectionId.mcp,
          icon: Icons.extension_outlined,
        ),
      SettingsSection(
        (l) => l.translationService,
        (_) => TranslationSettings(
          credentials: ref.read(translationCredentialsProvider),
          onCredentialsChanged: () => ref.invalidate(completionTranslationsProvider),
        ),
        id: SettingsSectionId.translation,
        icon: Icons.translate_outlined,
      ),
    ],
  ),
  linkDesktopBridgeProvider.overrideWith((ref) {
    final bridge = AppLinkDesktopBridge(ref);
    ref.onDispose(bridge.dispose);
    return bridge;
  }),
  linkMobileBridgeProvider.overrideWith((ref) => AppLinkMobileBridge(ref)),
  fileLocationsProvider.overrideWith(linkFileLocations),
  linkCredentialCatalogProvider.overrideWith(
    (ref) => () {
      final aiProfile = ref.read(aiConfigurationProvider).profile;
      return (
        hosts: [
          for (final h in ref.read(hostsProvider))
            if (!h.transient) (id: h.id.value, label: '${h.title} (${h.target})'),
        ],
        keys: [for (final k in ref.read(keysProvider)) (id: k.id, label: '${k.label} (${k.algorithm})')],
        aiProfileLabel: aiProfile == null ? null : 'Airy AI · ${aiProfile.model}',
      );
    },
  ),
  terminalSnippetsProvider.overrideWith(
    (ref) => [for (final snippet in ref.watch(snippetsProvider)) CommandSnippet(snippet.text, snippet.label)],
  ),
  keyReferencesProvider.overrideWith(
    (ref) =>
        (id) => ref.read(hostsProvider.notifier).library.keyReferences(id),
  ),
  snippetInsertionProvider.overrideWith(
    (ref) => (text, {required run, cancel}) async {
      final session = ref.read(workspaceProvider.notifier).focusedSession;
      final confirm = ref.read(terminalInsertUiProvider).confirm;
      if (session == null || confirm == null) return InsertResult.unavailable;
      return session.insert(
        text,
        run: run,
        cancel: cancel,
        confirm: confirm,
        confirmMultiline: ref.read(settingsProvider).get(SettingKeys.confirmPaste),
      );
    },
  ),
  capabilityDispatcherProvider.overrideWith(
    (ref) => CapabilityDispatcher([
      ...aiCapabilities(ref),
      ...hostCapabilities(ref),
      ...hostLibraryCapabilities(ref),
      ...keyCapabilities(ref),
      ...workspaceCapabilities(ref),
      ...settingsCapabilities(ref),
      ...fileCapabilities(ref),
      ...localFileCapabilities(ref),
      ...snippetCapabilities(ref),
      ...forwardCapabilities(ref),
    ]),
  ),
  paletteSourcesProvider.overrideWithValue([
    workspacePaletteEntries,
    hostPaletteEntries,
    filesPaletteEntries,
    settingsPaletteEntries,
    snippetPaletteEntries,
    forwardPaletteEntries,
  ]),
];

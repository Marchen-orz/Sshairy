import 'package:flutter/material.dart' show Icons;
import 'package:flutter_riverpod/misc.dart';

import '../features/ai/api.dart';
import '../features/connections/api.dart';
import '../features/capabilities/api.dart';
import '../features/credentials/api.dart';
import '../features/hosts/api.dart';
import '../features/settings/api.dart';
import '../features/snippets/api.dart';
import '../features/terminal/api.dart';
import '../features/workspace/api.dart';
import '../foundation/ids.dart';
import 'ai_backend.dart';
import 'ai_terminal_hosts.dart';
import 'capabilities/ai.dart';
import 'capabilities/hosts.dart';
import 'capabilities/host_library.dart';
import 'capabilities/credentials.dart';
import 'capabilities/workspace.dart';
import 'capabilities/files.dart';
import 'capabilities/settings.dart';
import 'capabilities/snippets.dart';
import 'capabilities/forwarding.dart';

/// The composition root: the one place that knows every feature and registers what each one offers.
List<Override> appOverrides() => [
  aiTerminalHostsProvider.overrideWith((ref) => aiTerminalHosts(ref.watch(hostsProvider))),
  agentFocusedHostProvider.overrideWith((ref) {
    final tab = ref.watch(workspaceProvider).activeTab;
    final sessions = ref.watch(terminalSessionsProvider);
    final host = tab == null ? null : sessions[tab.layout.focusedLeaf.session]?.sshHost;
    return host == null || host.transient ? null : host.id;
  }),
  agentConversationRoutesProvider.overrideWith((ref) {
    // Security revisions reset at startup, so server history requires a new conversation after restart.
    final securitySession = newId();
    return () {
      final trustRevision = ref.read(hostTrustProvider).revision;
      final credentialRevision = ref.read(connectionCredentialsProvider).revision;
      return {
        for (final host in aiTerminalHosts(ref.read(hostsProvider)))
          host.id: conversationRouteFingerprint(
            host.signature,
            trustRevision: trustRevision,
            credentialRevision: credentialRevision,
            securitySession: securitySession,
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

import 'package:flutter_riverpod/misc.dart';

import '../features/capabilities/api.dart';
import '../features/connections/api.dart';
import '../features/credentials/api.dart';
import '../features/hosts/api.dart';
import '../features/settings/api.dart';
import '../features/snippets/api.dart';
import '../features/terminal/api.dart';
import '../features/workspace/api.dart';
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
  settingsSectionsProvider.overrideWithValue([trustSettingsSection]),
];

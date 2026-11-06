import 'package:flutter_riverpod/misc.dart';

import '../features/capabilities/api.dart';
import '../features/connections/api.dart';
import '../features/credentials/api.dart';
import '../features/files/api.dart';
import '../features/hosts/api.dart';
import '../features/settings/api.dart';
import '../features/workspace/api.dart';

/// The composition root: the one place that knows every feature and registers what each one offers.
List<Override> appOverrides() => [
      capabilityDispatcherProvider.overrideWith(
        (ref) => CapabilityDispatcher([
          ...hostCapabilities(ref),
          ...keyCapabilities(ref),
          ...workspaceCapabilities(ref),
          ...settingsCapabilities(ref),
          ...fileCapabilities(ref),
        ]),
      ),
      paletteSourcesProvider
          .overrideWithValue([workspacePaletteEntries, hostPaletteEntries, filesPaletteEntries, settingsPaletteEntries]),
      settingsSectionsProvider.overrideWithValue([trustSettingsSection]),
    ];

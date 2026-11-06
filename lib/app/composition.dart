import 'package:flutter_riverpod/misc.dart';

import '../features/capabilities/api.dart';
import '../features/hosts/api.dart';
import '../features/settings/api.dart';
import '../features/workspace/api.dart';

/// The composition root: the one place that knows every feature and registers what each one offers.
List<Override> appOverrides() => [
      capabilityDispatcherProvider.overrideWith(
        (ref) => CapabilityDispatcher([
          ...hostCapabilities(ref),
          ...workspaceCapabilities(ref),
          ...settingsCapabilities(ref),
        ]),
      ),
      paletteSourcesProvider.overrideWithValue([workspacePaletteEntries, hostPaletteEntries, settingsPaletteEntries]),
    ];

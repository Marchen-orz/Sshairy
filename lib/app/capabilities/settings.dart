import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/theme.dart';
import '../../design/theme_names.dart';
import '../../foundation/result.dart';
import '../../features/capabilities/api.dart';
import '../../features/settings/api.dart';

/// Both read and write through [SettingKeys]; an agent only sees and changes settings marked as exposed.
List<Capability> settingsCapabilities(Ref ref) => [
  FunctionCapability('settings.get', Effect.query, agentExposed: true, (_, c) async {
    final s = ref.read(settingsProvider);
    return Ok({
      'revision': ref.read(settingsProvider.notifier).revision,
      'settings': {
        for (final d in SettingKeys.all)
          if (c.origin != Origin.agent || d.agentExposed) d.key: d.encode(s.get(d)),
      },
    });
  }),
  FunctionCapability(
    'settings.patch',
    Effect.localChange,
    agentExposed: true,
    inputSchema: {
      'type': 'object',
      'additionalProperties': false,
      'properties': {
        for (final d in SettingKeys.all) d.key: d.schema,
        'expectedRevision': {'type': 'integer', 'minimum': 0},
      },
    },
    (a, c) => ref
        .read(settingsProvider.notifier)
        .patch(
          {...a.raw}..remove('expectedRevision'),
          exposedOnly: c.origin == Origin.agent,
          expectedRevision: a.optional<int>('expectedRevision'),
        ),
  ),
];

List<PaletteEntry> settingsPaletteEntries(PaletteContext c) {
  final l = c.l;
  PaletteEntry entry(String title, IconData icon, Map<String, Object?> patch) => PaletteEntry(
    section: PaletteSection.actions,
    title: title,
    icon: icon,
    run: () => c.dispatch('settings.patch', patch),
  );
  return [
    PaletteEntry(
      section: PaletteSection.actions,
      title: l.settings,
      icon: Icons.settings_outlined,
      run: () async {
        if (!c.context.mounted) return;
        await showSettingsDialog(c.context);
      },
    ),
    entry('${l.theme}: ${l.themeLight}', Icons.light_mode_outlined, {'themeMode': 'light'}),
    entry('${l.theme}: ${l.themeDark}', Icons.dark_mode_outlined, {'themeMode': 'dark'}),
    entry('${l.theme}: ${l.themeSystem}', Icons.brightness_auto_outlined, {'themeMode': 'system'}),
    for (final a in Accent.values) entry('${l.accent}: ${a.label(l)}', Icons.palette_outlined, {'accent': a.name}),
  ];
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/side_drawer.dart';
import '../../design/theme.dart';
import '../../foundation/result.dart';
import '../capabilities/api.dart';
import 'presentation/settings_panel.dart';
import 'settings.dart';

/// Both read and write through [SettingKeys]; an agent only sees and changes settings marked as exposed.
List<Capability> settingsCapabilities(Ref ref) => [
      FunctionCapability('settings.get', Effect.query, (_, c) async {
        final s = ref.read(settingsProvider);
        return Ok({
          for (final d in SettingKeys.all)
            if (c.origin != Origin.agent || d.agentExposed) d.key: d.encode(s.get(d)),
        });
      }),
      FunctionCapability(
        'settings.patch',
        Effect.localChange,
        inputSchema: {
          'type': 'object',
          'additionalProperties': false,
          'properties': {for (final d in SettingKeys.all) d.key: d.schema},
        },
        (a, c) => ref.read(settingsProvider.notifier).patch(a.raw, exposedOnly: c.origin == Origin.agent),
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
        if (c.context.mounted) await showSideDrawer<void>(c.context, (_) => const SettingsPanel());
      },
    ),
    entry('${l.theme}: ${l.themeLight}', Icons.light_mode_outlined, {'themeMode': 'light'}),
    entry('${l.theme}: ${l.themeDark}', Icons.dark_mode_outlined, {'themeMode': 'dark'}),
    entry('${l.theme}: ${l.themeSystem}', Icons.brightness_auto_outlined, {'themeMode': 'system'}),
    for (final (a, name) in [
      (Accent.blue, l.accentBlue),
      (Accent.green, l.accentGreen),
      (Accent.violet, l.accentViolet),
      (Accent.orange, l.accentOrange),
    ])
      entry('${l.accent}: $name', Icons.palette_outlined, {'accent': a.name}),
  ];
}

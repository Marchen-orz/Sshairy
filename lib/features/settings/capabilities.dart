import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/side_drawer.dart';
import '../../design/theme.dart';
import '../../foundation/result.dart';
import '../capabilities/api.dart';
import 'presentation/settings_panel.dart';
import 'settings.dart';

/// The renderer is left out: it is a platform choice, not something to change from a palette or an agent.
List<Capability> settingsCapabilities(Ref ref) => [
      FunctionCapability('settings.get', Effect.query, (_, _) async {
        final s = ref.read(settingsProvider);
        return Ok({'themeMode': s.themeMode.name, 'accent': s.accent.name, 'fontSize': s.fontSize, 'locale': s.locale});
      }),
      FunctionCapability(
        'settings.patch',
        Effect.localChange,
        inputSchema: {
          'type': 'object',
          'properties': {
            'themeMode': {'type': 'string', 'enum': ThemeMode.values.map((m) => m.name).toList()},
            'accent': {'type': 'string', 'enum': Accent.values.map((a) => a.name).toList()},
            'fontSize': {'type': 'number', 'minimum': Settings.minFontSize, 'maximum': Settings.maxFontSize},
            'locale': {
              'type': ['string', 'null'],
              'enum': ['zh', 'en', null],
            },
          },
        },
        (a, _) async {
          final themeMode = a.optional<String>('themeMode');
          final accent = a.optional<String>('accent');
          final mode = themeMode == null ? null : ThemeMode.values.asNameMap()[themeMode];
          final color = accent == null ? null : Accent.values.asNameMap()[accent];
          if ((themeMode != null && mode == null) || (accent != null && color == null)) {
            return const Err(AppError('invalidArgument'));
          }
          final locale = a.optional<String>('locale');
          if (locale != null && !const ['zh', 'en'].contains(locale)) return const Err(AppError('invalidArgument'));
          await ref.read(settingsProvider.notifier).update(
                themeMode: mode,
                accent: color,
                fontSize: a.optional<num>('fontSize')?.toDouble(),
                locale: a.has('locale') ? () => locale : null,
              );
          return const Ok(null);
        },
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

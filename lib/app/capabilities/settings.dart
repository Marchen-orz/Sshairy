import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/theme.dart';
import '../../design/theme_names.dart';
import '../../foundation/result.dart';
import '../../foundation/json_file.dart';
import '../../l10n/app_localizations.dart';
import '../../features/capabilities/api.dart';
import '../../features/settings/api.dart';

/// Both read and write through [SettingKeys]; an agent only sees and changes settings marked as exposed.
List<Capability> settingsCapabilities(Ref ref) => [
  FunctionCapability('settings.get', Effect.query, agentExposed: true, externalAgentExposed: true, (_, c) async {
    final s = ref.read(settingsProvider);
    final language = s.locale ?? PlatformDispatcher.instance.locale.languageCode;
    final locale = language == 'zh' ? 'zh' : 'en';
    final l = lookupAppLocalizations(Locale(locale));
    return Ok({
      'revision': ref.read(settingsProvider.notifier).revision,
      'settings': {
        for (final d in SettingKeys.all)
          if (!c.origin.isAgent || d.agentExposed) d.key: d.encode(s.get(d)),
      },
      if (c.origin.isAgent) ...{
        'locale': locale,
        'definitions': {
          for (final d in SettingKeys.all)
            if (d.agentExposed) d.key: settingDescription(d, l),
        },
      },
    });
  }),
  FunctionCapability(
    'settings.patch',
    Effect.localChange,
    agentExposed: true,
    externalAgentExposed: true,
    inputSchema: {
      'type': 'object',
      'additionalProperties': false,
      'properties': {
        for (final d in SettingKeys.all)
          if (d.agentExposed) d.key: d.schema,
        'expectedRevision': {'type': 'integer', 'minimum': 0},
      },
      'required': ['expectedRevision'],
    },
    (a, c) async {
      try {
        return await ref
            .read(settingsProvider.notifier)
            .patch(
              {...a.raw}..remove('expectedRevision'),
              exposedOnly: c.origin.isAgent,
              expectedRevision: c.origin.isAgent
                  ? a.require<int>('expectedRevision')
                  : a.optional<int>('expectedRevision'),
            );
      } on JsonFileError catch (error) {
        return Err(AppError(error.kind.name));
      }
    },
  ),
];

/// Uses the same localized strings and stable values as the settings controls.
Map<String, Object?> settingDescription(SettingDef<Object?> d, AppLocalizations l) {
  final label = switch (d.key) {
    'themeMode' => l.theme,
    'accent' => l.accent,
    'locale' => l.language,
    'uiScale' => l.uiScale,
    'uiFontFamily' => l.uiFont,
    'uiFontSize' => l.uiFontSize,
    'appBackgroundOpacity' => '${l.appBackgroundImage} · ${l.backgroundOpacity}',
    'terminalBackgroundOpacity' => '${l.terminalBackgroundImage} · ${l.backgroundOpacity}',
    'terminalFontFamily' => l.terminalFont,
    'fontSize' => l.fontSize,
    'scrollback' => l.scrollback,
    'cursorShape' => l.cursorShape,
    'copyOnSelect' => l.copyOnSelect,
    'keywordHighlight' => l.keywordHighlight,
    'highlightKeywords' => l.highlightKeywords,
    'rightClick' => l.rightClick,
    'aiTextStyle' => l.aiTextStyle,
    'aiCompletionDelay' => l.aiCompletionDelay,
    'connectTimeout' => l.connectTimeout,
    'keepAlive' => l.keepAlive,
    'idleTtl' => l.idleTtl,
    'autoReconnect' => l.autoReconnect,
    'hostView' => '${l.hosts} · ${l.gridView} / ${l.listView}',
    'hostOrder' => '${l.sortName} / ${l.sortRecent}',
    'monitorWidth' => l.resizeMonitor,
    'navigationWidth' => l.resizeNavigation,
    'showMonitor' => l.monitor,
    'showFiles' => l.files,
    'monitorInterval' => l.monitorInterval,
    'filesDock' => l.filesDock,
    'navigationExpanded' => l.navigationExpand,
    'showHidden' => l.hiddenFiles,
    'transferConcurrency' => l.transferConcurrency,
    _ => d.key,
  };
  final options = switch (d.key) {
    'themeMode' => <Object?, String>{'system': l.themeSystem, 'light': l.themeLight, 'dark': l.themeDark},
    'accent' => <Object?, String>{for (final a in Accent.values) a.name: a.label(l)},
    'locale' => <Object?, String>{null: l.themeSystem, 'zh': l.langZh, 'en': l.langEn},
    'cursorShape' => <Object?, String>{'block': l.cursorBlock, 'underline': l.cursorUnderline, 'bar': l.cursorBar},
    'rightClick' => <Object?, String>{'menu': l.rightClickMenu, 'paste': l.paste},
    'aiTextStyle' => <Object?, String>{
      'italicFaint': l.aiTextItalicFaint,
      'italic': l.aiTextItalic,
      'faint': l.aiTextFaint,
      'plain': l.aiTextPlain,
    },
    'hostView' => <Object?, String>{'grid': l.gridView, 'list': l.listView},
    'hostOrder' => <Object?, String>{'name': l.sortName, 'recent': l.sortRecent},
    'filesDock' => <Object?, String>{'left': l.dockLeft, 'right': l.dockRight, 'bottom': l.dockBottom},
    _ => <Object?, String>{},
  };
  return {
    'label': label,
    'schema': d.schema,
    'apply': d.apply.name,
    if (options.isNotEmpty)
      'options': [
        for (final e in options.entries) {'value': e.key, 'label': e.value},
      ],
    if (d.key == 'uiScale') 'description': 'Ratio: 1.25 means 125%.',
    if (d.key.endsWith('Opacity')) 'description': 'Ratio from 0 (transparent) to 1 (opaque).',
    if (const {'connectTimeout', 'keepAlive', 'idleTtl', 'monitorInterval'}.contains(d.key)) 'unit': 'seconds',
    if (const {'monitorWidth', 'navigationWidth', 'fontSize', 'uiFontSize'}.contains(d.key)) 'unit': 'logicalPixels',
  };
}

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

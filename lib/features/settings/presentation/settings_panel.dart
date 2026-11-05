import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../design/theme.dart';
import '../../../l10n/app_localizations.dart';
import '../settings.dart';

class SettingsPanel extends ConsumerWidget {
  const SettingsPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final settings = ref.watch(settingsProvider);
    final notifier = ref.read(settingsProvider.notifier);
    Widget field(String label, Widget child) => Padding(
          padding: const EdgeInsets.only(bottom: Space.xl),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label),
            const SizedBox(height: Space.sm),
            child,
          ]),
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(l.settings, style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: Space.xl),
      field(
        l.theme,
        SegmentedButton<ThemeMode>(
          showSelectedIcon: false,
          segments: [
            ButtonSegment(value: ThemeMode.system, label: Text(l.themeSystem)),
            ButtonSegment(value: ThemeMode.light, label: Text(l.themeLight)),
            ButtonSegment(value: ThemeMode.dark, label: Text(l.themeDark)),
          ],
          selected: {settings.themeMode},
          onSelectionChanged: (s) => notifier.update(themeMode: s.single),
        ),
      ),
      field(
        l.language,
        SegmentedButton<String>(
          showSelectedIcon: false,
          segments: [
            ButtonSegment(value: '', label: Text(l.themeSystem)),
            ButtonSegment(value: 'zh', label: Text(l.langZh)),
            ButtonSegment(value: 'en', label: Text(l.langEn)),
          ],
          selected: {settings.locale ?? ''},
          onSelectionChanged: (s) => notifier.update(locale: () => s.single.isEmpty ? null : s.single),
        ),
      ),
      field(
        l.fontSize,
        Row(children: [
          Expanded(
            child: Slider(
              value: settings.fontSize,
              min: Settings.minFontSize,
              max: Settings.maxFontSize,
              divisions: (Settings.maxFontSize - Settings.minFontSize).round(),
              onChanged: (v) => notifier.update(fontSize: v),
            ),
          ),
          SizedBox(width: Space.xxl, child: Text('${settings.fontSize.round()}', textAlign: TextAlign.end)),
        ]),
      ),
    ]);
  }
}

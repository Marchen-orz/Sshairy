import 'dart:io';

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
    final running = ref.watch(runningRendererProvider);
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
        l.accent,
        Wrap(spacing: Space.sm, children: [
          for (final a in Accent.values)
            _Swatch(
              color: a.of(Theme.of(context).brightness),
              label: switch (a) {
                Accent.blue => l.accentBlue,
                Accent.green => l.accentGreen,
                Accent.violet => l.accentViolet,
                Accent.orange => l.accentOrange,
              },
              selected: settings.accent == a,
              onTap: () => notifier.update(accent: a),
            ),
        ]),
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
      if (Platform.isWindows)
        field(
          l.renderer,
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SegmentedButton<Renderer>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: Renderer.skia, label: Text('Skia')),
                ButtonSegment(value: Renderer.impeller, label: Text('Impeller')),
              ],
              selected: {settings.renderer},
              onSelectionChanged: (s) => notifier.update(renderer: s.single),
            ),
            if (running != null && running != settings.renderer) ...[
              const SizedBox(height: Space.sm),
              Text(l.restartToApply, style: Theme.of(context).textTheme.bodySmall),
            ],
          ]),
        ),
    ]);
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({required this.color, required this.label, required this.selected, required this.onTap});

  final Color color;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: label,
      child: Semantics(
        label: label,
        selected: selected,
        button: true,
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: Container(
            width: 32,
            height: 32,
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: selected ? color : scheme.outlineVariant, width: 2),
            ),
            child: DecoratedBox(
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              child: selected ? Icon(Icons.check, size: 16, color: onColor(color)) : null,
            ),
          ),
        ),
      ),
    );
  }
}

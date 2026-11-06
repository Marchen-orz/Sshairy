import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../design/theme.dart';
import '../../../foundation/data_dir.dart';
import '../../../foundation/open_external.dart';
import '../../../l10n/app_localizations.dart';
import '../settings.dart';

const appVersion = '0.1.0';

/// A section another feature adds to the panel, such as trust records from connections; settings cannot import
/// those features without a cycle, so the app wires them in.
class SettingsSection {
  const SettingsSection(this.title, this.build);

  final String Function(AppLocalizations l) title;
  final WidgetBuilder build;
}

final settingsSectionsProvider = Provider<List<SettingsSection>>((_) => const []);

class SettingsPanel extends ConsumerWidget {
  const SettingsPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final settings = ref.watch(settingsProvider);
    final notifier = ref.read(settingsProvider.notifier);
    final running = ref.watch(runningRendererProvider);

    Widget segmented<T extends Enum>(EnumSetting<T> d, Map<T, String> labels) => SegmentedButton<T>(
          showSelectedIcon: false,
          segments: [for (final MapEntry(:key, :value) in labels.entries) ButtonSegment(value: key, label: Text(value))],
          selected: {settings.get(d)},
          onSelectionChanged: (s) => notifier.set(d, s.single),
        );

    Widget seconds(IntSetting d, List<int> choices, {bool zeroIsOff = false}) => _Choice<int>(
          value: settings.get(d),
          choices: {...choices, settings.get(d)}.toList()..sort(),
          label: (n) => zeroIsOff && n == 0 ? l.off : l.seconds(n),
          onChanged: (v) => notifier.set(d, v),
        );

    Widget toggle(BoolSetting d) => Switch(value: settings.get(d), onChanged: (v) => notifier.set(d, v));

    String? hint(SettingDef<Object?> d) => switch (d.apply) {
          ApplyMode.newSessions => l.appliesNewSessions,
          ApplyMode.nextConnection => l.appliesNextConnection,
          ApplyMode.restart when running != null && running != settings.renderer => l.restartToApply,
          _ => null,
        };

    final extra = ref.watch(settingsSectionsProvider);
    // End padding keeps the scrollbar off the controls.
    return ListView(padding: const EdgeInsets.only(right: Space.lg), children: [
      Text(l.settings, style: theme.textTheme.titleMedium),
      _Section(l.appearance, [
        _Field.stacked(l.theme, segmented(SettingKeys.themeMode, {
          ThemeMode.system: l.themeSystem,
          ThemeMode.light: l.themeLight,
          ThemeMode.dark: l.themeDark,
        })),
        _Field.stacked(
          l.accent,
          Wrap(spacing: Space.sm, children: [
            for (final a in Accent.values)
              _Swatch(
                color: a.of(theme.brightness),
                label: switch (a) {
                  Accent.blue => l.accentBlue,
                  Accent.green => l.accentGreen,
                  Accent.violet => l.accentViolet,
                  Accent.orange => l.accentOrange,
                },
                selected: settings.accent == a,
                onTap: () => notifier.set(SettingKeys.accent, a),
              ),
          ]),
        ),
        _Field.stacked(
          l.language,
          SegmentedButton<String>(
            showSelectedIcon: false,
            segments: [
              ButtonSegment(value: '', label: Text(l.themeSystem)),
              ButtonSegment(value: 'zh', label: Text(l.langZh)),
              ButtonSegment(value: 'en', label: Text(l.langEn)),
            ],
            selected: {settings.locale ?? ''},
            onSelectionChanged: (s) => notifier.set(SettingKeys.locale, s.single.isEmpty ? null : s.single),
          ),
        ),
        if (Platform.isWindows)
          _Field.stacked(
            l.renderer,
            segmented(SettingKeys.renderer, const {Renderer.skia: 'Skia', Renderer.impeller: 'Impeller'}),
            hint: hint(SettingKeys.renderer),
          ),
      ]),
      _Section(l.terminal, [
        _Field.stacked(
          l.fontSize,
          Row(children: [
            Expanded(
              child: Slider(
                value: settings.fontSize,
                min: SettingKeys.fontSize.min,
                max: SettingKeys.fontSize.max,
                divisions: (SettingKeys.fontSize.max - SettingKeys.fontSize.min).round(),
                onChanged: (v) => notifier.set(SettingKeys.fontSize, v),
              ),
            ),
            SizedBox(width: Space.xxl, child: Text('${settings.fontSize.round()}', textAlign: TextAlign.end)),
          ]),
        ),
        _Field.stacked(l.cursorShape, segmented(SettingKeys.cursorShape, {
          CursorShape.block: l.cursorBlock,
          CursorShape.underline: l.cursorUnderline,
          CursorShape.bar: l.cursorBar,
        })),
        _Field(
          l.scrollback,
          _Choice<int>(
            value: settings.get(SettingKeys.scrollback),
            choices: {1000, 2000, 5000, 10000, 20000, settings.get(SettingKeys.scrollback)}.toList()..sort(),
            label: (n) => '$n',
            onChanged: (v) => notifier.set(SettingKeys.scrollback, v),
          ),
          hint: hint(SettingKeys.scrollback),
        ),
        _Field(l.rightClick, segmented(SettingKeys.rightClick, {RightClick.menu: l.rightClickMenu, RightClick.paste: l.paste})),
        _Field(l.copyOnSelect, toggle(SettingKeys.copyOnSelect)),
        _Field(l.confirmPaste, toggle(SettingKeys.confirmPaste)),
      ]),
      _Section(l.connection, [
        _Field(l.connectTimeout, seconds(SettingKeys.connectTimeout, const [10, 20, 30, 60]),
            hint: hint(SettingKeys.connectTimeout)),
        _Field(l.keepAlive, seconds(SettingKeys.keepAlive, const [0, 15, 30, 60], zeroIsOff: true),
            hint: hint(SettingKeys.keepAlive)),
        _Field(l.idleTtl, seconds(SettingKeys.idleTtl, const [0, 30, 60, 120, 300], zeroIsOff: true)),
        _Field(l.autoReconnect, toggle(SettingKeys.autoReconnect)),
      ]),
      for (final s in extra) _Section(s.title(l), [s.build(context)]),
      _Section(l.about, [
        _Field(l.version, Text(appVersion, style: theme.textTheme.bodyMedium)),
        _Field(
          l.dataDir,
          TextButton(onPressed: () => openExternal(ref.read(dataDirProvider)), child: Text(l.open)),
          hint: ref.read(dataDirProvider),
        ),
      ]),
    ]);
  }
}

class _Section extends StatelessWidget {
  const _Section(this.title, this.children);

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: Space.xl),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(title, style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.primary)),
        const SizedBox(height: Space.md),
        ...children,
      ]),
    );
  }
}

/// A label beside its control, or above it when the control needs the width.
class _Field extends StatelessWidget {
  const _Field(this.label, this.child, {this.hint}) : stacked = false;
  const _Field.stacked(this.label, this.child, {this.hint}) : stacked = true;

  final String label;
  final Widget child;
  final String? hint;
  final bool stacked;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Text(label),
      if (hint != null)
        Text(hint!, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
    ]);
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.lg),
      child: stacked
          ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [text, const SizedBox(height: Space.sm), child])
          : Row(children: [Expanded(child: text), const SizedBox(width: Space.md), child]),
    );
  }
}

class _Choice<T> extends StatelessWidget {
  const _Choice({required this.value, required this.choices, required this.label, required this.onChanged});

  final T value;
  final List<T> choices;
  final String Function(T) label;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) => DropdownButton<T>(
        value: value,
        underline: const SizedBox.shrink(),
        borderRadius: BorderRadius.circular(Radii.control),
        items: [for (final c in choices) DropdownMenuItem(value: c, child: Text(label(c)))],
        onChanged: (v) {
          if (v != null) onChanged(v);
        },
      );
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

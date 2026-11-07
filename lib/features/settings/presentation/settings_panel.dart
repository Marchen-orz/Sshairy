import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../design/controls.dart';
import '../../../design/select.dart';
import '../../../design/theme.dart';
import '../../../foundation/data_dir.dart';
import '../../../foundation/open_external.dart';
import '../../../l10n/app_localizations.dart';
import '../../../platform/system_fonts.dart';
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

final systemFontsProvider = FutureProvider<List<SystemFont>>((_) => loadSystemFonts());

class SettingsPanel extends ConsumerWidget {
  const SettingsPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final settings = ref.watch(settingsProvider);
    final notifier = ref.read(settingsProvider.notifier);
    final running = ref.watch(runningRendererProvider);

    Widget segmented<T extends Enum>(EnumSetting<T> d, Map<T, String> labels) =>
        AppSegmented<T>(segments: labels, selected: settings.get(d), onChanged: (v) => notifier.set(d, v));

    Widget seconds(IntSetting d, List<int> choices, {bool zeroIsOff = false}) => _Choice<int>(
      value: settings.get(d),
      choices: {...choices, settings.get(d)}.toList()..sort(),
      label: (n) => zeroIsOff && n == 0 ? l.off : l.seconds(n),
      onChanged: (v) => notifier.set(d, v),
    );

    Widget toggle(BoolSetting d) => AppSwitch(value: settings.get(d), onChanged: (v) => notifier.set(d, v));

    Widget slider(DoubleSetting d) => Row(
      children: [
        Expanded(
          child: Slider(
            value: settings.get(d),
            min: d.min,
            max: d.max,
            divisions: (d.max - d.min).round(),
            onChanged: (v) => notifier.set(d, v),
          ),
        ),
        SizedBox(width: Space.xl, child: Text('${settings.get(d).round()}', textAlign: TextAlign.end)),
      ],
    );

    final fonts = ref.watch(systemFontsProvider).value ?? const <SystemFont>[];
    Widget font(FontSetting d, {required String fallback, bool monoOnly = false}) {
      final current = settings.get(d);
      final names = {
        for (final f in fonts)
          if (!monoOnly || f.mono) f.name,
        ?current,
      }.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      return AppSelect<String?>(
        value: current,
        searchable: true,
        searchHint: l.searchFonts,
        options: [
          AppOption(null, '${l.defaultFont} · $fallback'),
          for (final name in names) AppOption(name, name, style: TextStyle(fontFamily: name)),
        ],
        onChanged: (v) => notifier.set(d, v),
      );
    }

    String? hint(SettingDef<Object?> d) => switch (d.apply) {
      ApplyMode.newSessions => l.appliesNewSessions,
      ApplyMode.nextConnection => l.appliesNextConnection,
      ApplyMode.restart when running != null && running != settings.renderer => l.restartToApply,
      _ => null,
    };

    final extra = ref.watch(settingsSectionsProvider);
    // End padding keeps the scrollbar off the controls.
    return ListView(
      padding: const EdgeInsets.only(right: Space.md),
      children: [
        Text(l.settings, style: theme.textTheme.titleMedium),
        _Section(l.appearance, [
          _Field.stacked(
            l.theme,
            segmented(SettingKeys.themeMode, {
              ThemeMode.system: l.themeSystem,
              ThemeMode.light: l.themeLight,
              ThemeMode.dark: l.themeDark,
            }),
          ),
          _Field.stacked(
            l.accent,
            Wrap(
              spacing: Space.sm,
              children: [
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
              ],
            ),
          ),
          _Field.stacked(
            l.language,
            AppSegmented<String>(
              segments: {'': l.themeSystem, 'zh': l.langZh, 'en': l.langEn},
              selected: settings.locale ?? '',
              onChanged: (v) => notifier.set(SettingKeys.locale, v.isEmpty ? null : v),
            ),
          ),
          _Field.stacked(l.uiFont, font(SettingKeys.uiFontFamily, fallback: AppFonts.ui ?? AppFonts.cjk.first)),
          _Field.stacked(l.uiFontSize, slider(SettingKeys.uiFontSize)),
          if (Platform.isWindows)
            _Field.stacked(
              l.renderer,
              segmented(SettingKeys.renderer, const {Renderer.skia: 'Skia', Renderer.impeller: 'Impeller'}),
              hint: hint(SettingKeys.renderer),
            ),
        ]),
        _Section(l.terminal, [
          _Field.stacked(l.terminalFont, font(SettingKeys.terminalFontFamily, fallback: AppFonts.mono, monoOnly: true)),
          _Field.stacked(l.fontSize, slider(SettingKeys.fontSize)),
          _Field.stacked(
            l.cursorShape,
            segmented(SettingKeys.cursorShape, {
              CursorShape.block: l.cursorBlock,
              CursorShape.underline: l.cursorUnderline,
              CursorShape.bar: l.cursorBar,
            }),
          ),
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
          _Field(
            l.rightClick,
            segmented(SettingKeys.rightClick, {RightClick.menu: l.rightClickMenu, RightClick.paste: l.paste}),
          ),
          _Field(l.copyOnSelect, toggle(SettingKeys.copyOnSelect)),
          _Field(l.confirmPaste, toggle(SettingKeys.confirmPaste)),
        ]),
        _Section(l.workspaceSection, [
          _Field(l.monitor, toggle(SettingKeys.showMonitor)),
          _Field(
            l.filesDock,
            segmented(SettingKeys.filesDock, {
              FilesDock.left: l.dockLeft,
              FilesDock.right: l.dockRight,
              FilesDock.bottom: l.dockBottom,
            }),
          ),
          _Field(l.confirmQuit, toggle(SettingKeys.confirmQuit)),
        ]),
        _Section(l.connection, [
          _Field(
            l.connectTimeout,
            seconds(SettingKeys.connectTimeout, const [10, 20, 30, 60]),
            hint: hint(SettingKeys.connectTimeout),
          ),
          _Field(
            l.keepAlive,
            seconds(SettingKeys.keepAlive, const [0, 15, 30, 60], zeroIsOff: true),
            hint: hint(SettingKeys.keepAlive),
          ),
          _Field(l.idleTtl, seconds(SettingKeys.idleTtl, const [0, 30, 60, 120, 300], zeroIsOff: true)),
          _Field(l.autoReconnect, toggle(SettingKeys.autoReconnect)),
        ]),
        _Section(l.files, [
          _Field(l.hiddenFiles, toggle(SettingKeys.showHidden)),
          _Field(
            l.transferConcurrency,
            _Choice<int>(
              value: settings.get(SettingKeys.transferConcurrency),
              choices: const [1, 2, 3, 4, 6, 8],
              label: (n) => '$n',
              onChanged: (v) => notifier.set(SettingKeys.transferConcurrency, v),
            ),
          ),
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
      ],
    );
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
      padding: const EdgeInsets.only(top: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.primary)),
          const SizedBox(height: Space.sm),
          ...children,
        ],
      ),
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
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label),
        if (hint != null)
          Text(hint!, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      ],
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.md),
      child: stacked
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [text, const SizedBox(height: Space.sm), child],
            )
          : Row(
              children: [
                Expanded(child: text),
                const SizedBox(width: Space.md),
                child,
              ],
            ),
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
  Widget build(BuildContext context) => AppSelect<T>(
    width: 132,
    value: value,
    options: [for (final c in choices) AppOption(c, label(c))],
    onChanged: onChanged,
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
            width: 26,
            height: 26,
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: selected ? color : scheme.outlineVariant, width: 2),
            ),
            child: DecoratedBox(
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              child: selected ? Icon(Icons.check, size: 14, color: onColor(color)) : null,
            ),
          ),
        ),
      ),
    );
  }
}

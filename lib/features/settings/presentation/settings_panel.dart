import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../design/brand.dart';
import '../../../design/controls.dart';
import '../../../design/dialog.dart';
import '../../../design/select.dart';
import '../../../design/theme.dart';
import '../../../design/theme_names.dart';
import '../../../foundation/data_dir.dart';
import '../../../foundation/open_external.dart';
import '../../../l10n/app_localizations.dart';
import '../../../platform/system_fonts.dart';
import '../settings.dart';
import '../domain/background.dart';
import 'background_image.dart';

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

final _settingsDialogs = Expando<Future<void>>();

Future<void> showSettingsDialog(BuildContext context) {
  final navigator = Navigator.of(context, rootNavigator: true);
  final existing = _settingsDialogs[navigator];
  if (existing != null) return existing;

  Future<void> open() async {
    try {
      await showAppDialog<void>(
        context: context,
        builder: (context) => CallbackShortcuts(
          bindings: {const SingleActivator(LogicalKeyboardKey.escape): () => Navigator.maybePop(context)},
          child: Focus(
            autofocus: true,
            child: AppDialog(
              width: WorkspaceSize.settingsDialog,
              title: Row(
                children: [
                  Expanded(child: Text(AppLocalizations.of(context).settings)),
                  IconButton(
                    tooltip: AppLocalizations.of(context).close,
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              content: const SettingsPanel(),
            ),
          ),
        ),
      );
    } finally {
      _settingsDialogs[navigator] = null;
    }
  }

  final future = open();
  _settingsDialogs[navigator] = future;
  return future;
}

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
        SizedBox(
          width: Space.xl,
          child: Text('${settings.get(d).round()}', textAlign: TextAlign.end),
        ),
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
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
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
              _ThemeGrid(selected: settings.accent, onChanged: (a) => notifier.set(SettingKeys.accent, a)),
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
            _Field.stacked(
              l.uiScale,
              _Choice<double>(
                value: settings.uiScale,
                choices: {.8, .9, 1.0, 1.1, 1.25, 1.5, settings.uiScale}.toList()..sort(),
                label: (value) => '${(value * 100).round()}%',
                onChanged: (value) => notifier.set(SettingKeys.uiScale, value),
              ),
            ),
            _Field.stacked(l.appBackgroundImage, const BackgroundImageControls(slot: BackgroundSlot.app)),
            if (Platform.isWindows)
              _Field.stacked(
                l.renderer,
                segmented(SettingKeys.renderer, const {Renderer.skia: 'Skia', Renderer.impeller: 'Impeller'}),
                hint: hint(SettingKeys.renderer),
              ),
          ]),
          _Section(l.terminal, [
            _Field.stacked(l.terminalBackgroundImage, const BackgroundImageControls(slot: BackgroundSlot.terminal)),
            _Field.stacked(
              l.terminalFont,
              font(SettingKeys.terminalFontFamily, fallback: AppFonts.mono, monoOnly: true),
            ),
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
            _Field(l.files, toggle(SettingKeys.showFiles)),
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
            const Padding(
              padding: EdgeInsets.symmetric(vertical: Space.md),
              child: Align(alignment: Alignment.centerLeft, child: BrandLogo()),
            ),
            _Field(l.version, Text(appVersion, style: theme.textTheme.bodyMedium)),
            _Field(
              l.dataDir,
              TextButton(onPressed: () => openExternal(ref.read(dataDirProvider)), child: Text(l.open)),
              hint: ref.read(dataDirProvider),
            ),
          ]),
        ],
      ),
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
              children: [
                text,
                const SizedBox(height: Space.sm),
                child,
              ],
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

/// The six themes as a 3×2 grid of previews; rows share a height so cards line up when a long name wraps.
class _ThemeGrid extends StatelessWidget {
  const _ThemeGrid({required this.selected, required this.onChanged});

  final Accent selected;
  final ValueChanged<Accent> onChanged;

  static const columns = 3;

  @override
  Widget build(BuildContext context) {
    final cards = [
      for (final a in Accent.values) _ThemeCard(accent: a, selected: a == selected, onTap: () => onChanged(a)),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < cards.length; i += columns) ...[
          if (i > 0) const SizedBox(height: Space.sm),
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var j = i; j < i + columns; j++) ...[
                  if (j > i) const SizedBox(width: Space.sm),
                  Expanded(child: j < cards.length ? cards[j] : const SizedBox.shrink()),
                ],
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _ThemeCard extends StatefulWidget {
  const _ThemeCard({required this.accent, required this.selected, required this.onTap});

  final Accent accent;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_ThemeCard> createState() => _ThemeCardState();
}

class _ThemeCardState extends State<_ThemeCard> {
  var _hovered = false, _focused = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final label = widget.accent.label(AppLocalizations.of(context));
    final selected = widget.selected;
    return Semantics(
      label: label,
      button: true,
      selected: selected,
      inMutuallyExclusiveGroup: true,
      onTap: widget.onTap,
      child: FocusableActionDetector(
        mouseCursor: SystemMouseCursors.click,
        onShowHoverHighlight: (v) => setState(() => _hovered = v),
        onShowFocusHighlight: (v) => setState(() => _focused = v),
        actions: {ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) => widget.onTap())},
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: ExcludeSemantics(
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(Radii.card + 2),
                border: Border.all(color: _focused ? scheme.primary : Colors.transparent, width: 2),
              ),
              child: Container(
                padding: const EdgeInsets.all(Space.sm),
                decoration: BoxDecoration(color: scheme.surface, borderRadius: BorderRadius.circular(Radii.card)),
                foregroundDecoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(Radii.card),
                  border: Border.all(
                    color: selected
                        ? scheme.primary
                        : _hovered
                        ? scheme.outline
                        : scheme.outlineVariant,
                    width: selected ? 2 : 1,
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _ThemeMock(widget.accent.palette(theme.brightness)),
                    const SizedBox(height: Space.sm),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Text(
                            label,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelMedium?.copyWith(color: scheme.onSurface),
                          ),
                        ),
                        const SizedBox(width: Space.xs),
                        SizedBox.square(
                          dimension: 16,
                          child: selected
                              ? DecoratedBox(
                                  decoration: BoxDecoration(color: scheme.primary, shape: BoxShape.circle),
                                  child: Icon(Icons.check_rounded, size: 12, color: scheme.onPrimary),
                                )
                              : null,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A miniature of the shell in [p]: sidebar, title line, and a panel with text lines and a primary button.
class _ThemeMock extends StatelessWidget {
  const _ThemeMock(this.p);

  final BrandPalette p;

  @override
  Widget build(BuildContext context) {
    Widget bar(Color color, double width, [double height = 3]) => Container(
      width: width,
      height: height,
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(height / 2)),
    );
    return Container(
      height: 48,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: p.background,
        borderRadius: BorderRadius.circular(Radii.control - 2),
        border: Border.all(color: p.borderSubtle),
      ),
      child: Row(
        children: [
          Container(
            width: 24,
            padding: const EdgeInsets.all(6),
            color: p.sidebar,
            child: Column(
              children: [
                Container(
                  width: 12,
                  height: 12,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(color: p.selection, borderRadius: BorderRadius.circular(3)),
                  child: Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(color: p.accent, shape: BoxShape.circle),
                  ),
                ),
                const SizedBox(height: Space.xs),
                bar(p.textSecondary, 12),
                const SizedBox(height: Space.xs),
                bar(p.textSecondary, 12),
              ],
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  bar(p.text, 32, 4),
                  const SizedBox(height: Space.xs),
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 5),
                      decoration: BoxDecoration(
                        color: p.surface,
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: p.borderSubtle),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [bar(p.textSecondary, 26), const SizedBox(height: 3), bar(p.textSecondary, 16)],
                            ),
                          ),
                          Container(
                            width: 14,
                            height: 8,
                            decoration: BoxDecoration(color: p.primary, borderRadius: BorderRadius.circular(4)),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

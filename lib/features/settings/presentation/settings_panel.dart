import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../design/brand.dart';
import '../../../design/controls.dart';
import '../../../design/dialog.dart';
import '../../../design/form_save.dart';
import '../../../design/select.dart';
import '../../../design/theme.dart';
import '../../../design/theme_names.dart';
import '../../../foundation/app_info.dart';
import '../../../foundation/data_dir.dart';
import '../../../foundation/open_external.dart';
import '../../../foundation/shortcuts.dart';
import '../../../l10n/app_localizations.dart';
import '../../../platform/desktop_window.dart';
import '../../../platform/system_fonts.dart';
import '../settings.dart';
import '../domain/background.dart';
import 'background_image.dart';
import 'shortcut_field.dart';
import 'update_check.dart';

enum SettingsSectionId {
  appearance,
  terminal,
  workspace,
  shortcuts,
  connection,
  files,
  ai,
  mcp,
  translation,
  security,
  about,
}

/// A section another feature adds to the panel, such as trust records from connections; settings cannot import
/// those features without a cycle, so the app wires them in.
class SettingsSection {
  const SettingsSection(this.title, this.build, {required this.id, this.icon = Icons.tune_outlined});

  final SettingsSectionId id;
  final String Function(AppLocalizations l) title;
  final WidgetBuilder build;
  final IconData icon;
}

final settingsSectionsProvider = Provider<List<SettingsSection>>((_) => const []);

final systemFontsProvider = FutureProvider<List<SystemFont>>((_) => loadSystemFonts());

class _SettingsDialogHandle {
  _SettingsDialogHandle(this.section);

  final panel = GlobalKey<_SettingsPanelState>();
  SettingsSectionId? section;
  late final Future<void> closed;

  void select(SettingsSectionId section) {
    this.section = section;
    panel.currentState?._showSection(section);
  }
}

final _settingsDialogs = Expando<_SettingsDialogHandle>();

Future<void> showSettingsDialog(BuildContext context, {SettingsSectionId? section}) {
  final navigator = Navigator.of(context, rootNavigator: true);
  final existing = _settingsDialogs[navigator];
  if (existing != null) {
    if (section != null) existing.select(section);
    return existing.closed;
  }

  final handle = _SettingsDialogHandle(section);
  Future<void> open() async {
    try {
      await showAppDialog<void>(context: context, builder: (_) => _SettingsDialog(handle));
    } finally {
      _settingsDialogs[navigator] = null;
    }
  }

  handle.closed = open();
  _settingsDialogs[navigator] = handle;
  return handle.closed;
}

class _SettingsDialog extends StatefulWidget {
  const _SettingsDialog(this.handle);

  final _SettingsDialogHandle handle;

  @override
  State<_SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<_SettingsDialog> {
  bool _saving = false;

  Future<void> _close() async {
    await widget.handle.panel.currentState?.flush();
    if (mounted) await Navigator.maybePop(context);
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving,
    child: CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): () => unawaited(_close())},
      child: Focus(
        autofocus: true,
        child: AppDialog(
          width: WorkspaceSize.settingsDialog,
          title: Row(
            children: [
              Expanded(child: Text(AppLocalizations.of(context).settings)),
              IconButton(
                tooltip: AppLocalizations.of(context).close,
                onPressed: _saving ? null : () => unawaited(_close()),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
          content: SettingsPanel(
            key: widget.handle.panel,
            initialSection: widget.handle.section,
            onSavingChanged: (saving) {
              if (_saving != saving) setState(() => _saving = saving);
            },
          ),
        ),
      ),
    ),
  );
}

/// Resetting into a default another action now uses would store a duplicate map and fail.
bool _canResetShortcut(Map<String, String> overrides, AppShortcutAction action) {
  final fallback = AppShortcuts.resolve(const {}, action);
  return overrides.containsKey(action.name) &&
      fallback != null &&
      AppShortcuts.conflict(AppShortcuts.withoutBinding(overrides, action), action, fallback) == null;
}

class SettingsPanel extends ConsumerStatefulWidget {
  const SettingsPanel({super.key, this.onSavingChanged, this.initialSection});

  final ValueChanged<bool>? onSavingChanged;
  final SettingsSectionId? initialSection;

  @override
  ConsumerState<SettingsPanel> createState() => _SettingsPanelState();
}

class _SettingsPanelState extends ConsumerState<SettingsPanel> {
  final _scroll = ScrollController();
  final _navigationScroll = ScrollController();
  final _saves = FormSaveController();
  final _anchors = <GlobalKey>[];
  final _navigationKeys = <GlobalKey>[];
  List<SettingsSectionId> _sectionIds = const [];
  SettingsSectionId? _requestedSection;
  int _selected = 0, _navigationGeneration = 0;
  int? _navigating;
  bool _syncScheduled = false, _sectionScheduled = false;

  @override
  void initState() {
    super.initState();
    _requestedSection = widget.initialSection;
    _scroll.addListener(_syncSelection);
    _saves.addListener(_saveStateChanged);
  }

  void _saveStateChanged() {
    if (!mounted) return;
    widget.onSavingChanged?.call(_saves.busy);
    setState(() {});
  }

  void _showSection(SettingsSectionId section) {
    _requestedSection = section;
    _scheduleSection();
  }

  void _scheduleSection() {
    if (_requestedSection == null || _sectionScheduled) return;
    _sectionScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _sectionScheduled = false;
      if (!mounted || _requestedSection == null) return;
      final index = _sectionIds.indexOf(_requestedSection!);
      _requestedSection = null;
      if (index >= 0) unawaited(_goTo(index));
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  double? _offset(int index) {
    final target = _anchors[index].currentContext?.findRenderObject();
    if (target == null || !target.attached) return null;
    return RenderAbstractViewport.of(target).getOffsetToReveal(target, 0).offset;
  }

  void _select(int index) {
    if (_selected == index) return;
    setState(() => _selected = index);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final context = _navigationKeys[index].currentContext;
      if (context != null) {
        Scrollable.ensureVisible(
          context,
          duration: Motion.of(context, Motion.quick),
          alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
        );
      }
    });
  }

  void _syncSelection() {
    if (!mounted || !_scroll.hasClients || !_scroll.position.hasContentDimensions || _navigating != null) return;
    final position = _scroll.position;
    var selected = 0;
    if (position.maxScrollExtent > 0 && position.pixels >= position.maxScrollExtent - Space.xs) {
      selected = _anchors.length - 1;
    } else {
      for (var index = 0; index < _anchors.length; index++) {
        final offset = _offset(index);
        if (offset != null && offset <= position.pixels + Space.lg) selected = index;
      }
    }
    _select(selected);
  }

  void _scheduleSync() {
    if (_syncScheduled) return;
    _syncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _syncScheduled = false;
      _syncSelection();
    });
  }

  Future<void> _goTo(int index) async {
    if (!_scroll.hasClients) return;
    final offset = _offset(index);
    if (offset == null) return;
    final generation = ++_navigationGeneration;
    _navigating = index;
    _select(index);
    final target = offset.clamp(0.0, _scroll.position.maxScrollExtent);
    final duration = Motion.of(context, Motion.panel);
    if (duration == Duration.zero) {
      _scroll.jumpTo(target);
    } else {
      await _scroll.animateTo(target, duration: duration, curve: Curves.easeOutCubic);
    }
    if (!mounted || generation != _navigationGeneration) return;
    _navigating = null;
    _syncSelection();
  }

  Future<void> flush() async {
    if (_saves.dirty && _saves.canSave) await _saves.save();
  }

  @override
  void dispose() {
    _scroll.dispose();
    _navigationScroll.dispose();
    _saves.removeListener(_saveStateChanged);
    _saves.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final settings = ref.watch(settingsProvider);
    final notifier = ref.read(settingsProvider.notifier);
    final running = ref.watch(runningRendererProvider);

    Widget choices<T>(T value, Map<T, String> labels, ValueChanged<T> onChanged) => LayoutBuilder(
      builder: (context, constraints) => constraints.maxWidth < WorkspaceSize.toolPanel
          ? AppSelect<T>(
              value: value,
              options: [for (final entry in labels.entries) AppOption(entry.key, entry.value)],
              onChanged: onChanged,
            )
          : AppSegmented<T>(segments: labels, selected: value, onChanged: onChanged),
    );

    Widget segmented<T extends Enum>(EnumSetting<T> d, Map<T, String> labels) =>
        choices<T>(settings.get(d), labels, (v) => notifier.set(d, v));

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
    final sections = [
      _Section(SettingsSectionId.appearance, l.appearance, Icons.palette_outlined, [
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
          choices<String>(settings.locale ?? '', {
            '': l.themeSystem,
            'zh': l.langZh,
            'en': l.langEn,
          }, (v) => notifier.set(SettingKeys.locale, v.isEmpty ? null : v)),
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
        _Field.stacked(
          l.motion,
          segmented(SettingKeys.motion, {
            MotionLevel.off: l.off,
            MotionLevel.light: l.motionLight,
            MotionLevel.full: l.motionFull,
          }),
        ),
        _Field.stacked(l.appBackgroundImage, const BackgroundImageControls(slot: BackgroundSlot.app)),
        if (Platform.isWindows || Platform.isMacOS || Platform.isLinux)
          _Field.stacked(
            l.renderer,
            segmented(SettingKeys.renderer, {Renderer.impeller: l.rendererPerformance, Renderer.skia: l.rendererLight}),
            hint: settings.renderer == Renderer.impeller ? l.rendererPerformanceHint : l.rendererLightHint,
            warning: hint(SettingKeys.renderer),
            onWarning: DesktopWindow.instance.restart,
          ),
      ]),
      _Section(SettingsSectionId.terminal, l.terminal, Icons.terminal_outlined, [
        _Field.stacked(l.terminalBackgroundImage, const BackgroundImageControls(slot: BackgroundSlot.terminal)),
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
        _Field(
          l.aiTextStyle,
          segmented(SettingKeys.aiTextStyle, {
            AiTextStyle.italicFaint: l.aiTextItalicFaint,
            AiTextStyle.italic: l.aiTextItalic,
            AiTextStyle.faint: l.aiTextFaint,
            AiTextStyle.plain: l.aiTextPlain,
          }),
        ),
        _Field(
          l.aiTaskSteps,
          _Choice<int>(
            value: settings.get(SettingKeys.aiTaskSteps),
            choices: {5, 12, 20, 30, 50, 100, settings.get(SettingKeys.aiTaskSteps)}.toList()..sort(),
            label: (n) => '$n',
            onChanged: (v) => notifier.set(SettingKeys.aiTaskSteps, v),
          ),
        ),
        _Field(
          l.aiCompletionDelay,
          _Choice<int>(
            value: settings.get(SettingKeys.aiCompletionDelay),
            choices: {300, 500, 800, 1200, 2000, settings.get(SettingKeys.aiCompletionDelay)}.toList()..sort(),
            label: l.milliseconds,
            onChanged: (v) => notifier.set(SettingKeys.aiCompletionDelay, v),
          ),
        ),
      ]),
      _Section(SettingsSectionId.workspace, l.workspaceSection, Icons.space_dashboard_outlined, [
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
      _Section(SettingsSectionId.shortcuts, l.shortcuts, Icons.keyboard_outlined, [
        for (final action in AppShortcutAction.values)
          _Field(
            shortcutActionLabel(l, action),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 240,
                  child: ShortcutField(
                    key: ValueKey('shortcut-${action.name}'),
                    action: action,
                    overrides: settings.shortcuts,
                    onChanged: (binding) => notifier.set(
                      SettingKeys.shortcuts,
                      AppShortcuts.withBinding(settings.shortcuts, action, binding),
                    ),
                  ),
                ),
                const SizedBox(width: Space.xs),
                IconButton(
                  tooltip: l.shortcutReset,
                  onPressed: _canResetShortcut(settings.shortcuts, action)
                      ? () =>
                            notifier.set(SettingKeys.shortcuts, AppShortcuts.withoutBinding(settings.shortcuts, action))
                      : null,
                  style: IconButton.styleFrom(
                    minimumSize: const Size.square(WorkspaceSize.tabHeight),
                    fixedSize: const Size.square(WorkspaceSize.tabHeight),
                    padding: EdgeInsets.zero,
                    visualDensity: VisualDensity.standard,
                  ),
                  icon: const Icon(Icons.restore_rounded, size: 16),
                ),
              ],
            ),
          ),
      ]),
      _Section(SettingsSectionId.connection, l.connection, Icons.dns_outlined, [
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
      _Section(SettingsSectionId.files, l.files, Icons.folder_outlined, [
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
      for (final s in extra) _Section(s.id, s.title(l), s.icon, [s.build(context)]),
      _Section(SettingsSectionId.about, l.about, Icons.info_outline, [
        const Padding(
          padding: EdgeInsets.symmetric(vertical: Space.md),
          child: Align(alignment: Alignment.centerLeft, child: BrandLogo()),
        ),
        _Field(
          l.version,
          Wrap(
            spacing: Space.md,
            runSpacing: Space.sm,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(appVersion, style: theme.textTheme.bodyMedium),
              const UpdateCheckControl(),
            ],
          ),
        ),
        _Field(
          l.dataDir,
          TextButton(onPressed: () => openExternal(ref.read(dataDirProvider)), child: Text(l.open)),
          hint: ref.read(dataDirProvider),
        ),
      ]),
    ];
    while (_anchors.length < sections.length) {
      _anchors.add(GlobalKey());
      _navigationKeys.add(GlobalKey());
    }
    if (_anchors.length > sections.length) {
      _anchors.removeRange(sections.length, _anchors.length);
      _navigationKeys.removeRange(sections.length, _navigationKeys.length);
    }
    _sectionIds = [for (final section in sections) section.id];
    _selected = _selected.clamp(0, sections.length - 1);
    _scheduleSection();
    _scheduleSync();
    return FormSaveScope(
      controller: _saves,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < WorkspaceSize.settingsDialog * .7;
          return SizedBox(
            height: math.min(WorkspaceSize.settingsHeight, constraints.maxHeight),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(
                        width: compact ? WorkspaceSize.settingsNavigationCompact : WorkspaceSize.settingsNavigation,
                        child: SingleChildScrollView(
                          key: const ValueKey('settings-navigation'),
                          controller: _navigationScroll,
                          child: Padding(
                            padding: const EdgeInsets.only(right: Space.sm),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                for (var index = 0; index < sections.length; index++)
                                  Padding(
                                    key: _navigationKeys[index],
                                    padding: const EdgeInsets.only(bottom: Space.xs),
                                    child: Semantics(
                                      selected: index == _selected,
                                      inMutuallyExclusiveGroup: true,
                                      child: TweenAnimationBuilder<double>(
                                        tween: Tween(end: index == _selected ? 1 : 0),
                                        duration: Motion.of(context, Motion.normal),
                                        curve: Motion.move,
                                        builder: (context, t, child) => TextButton(
                                          key: ValueKey('settings-tab-$index'),
                                          style: TextButton.styleFrom(
                                            alignment: compact ? Alignment.center : Alignment.centerLeft,
                                            padding: EdgeInsets.symmetric(
                                              horizontal: compact ? Space.sm : Space.md,
                                              vertical: Space.md,
                                            ),
                                            backgroundColor: t == 0
                                                ? null
                                                : theme.colorScheme.primaryContainer.withValues(
                                                    alpha: theme.colorScheme.primaryContainer.a * t,
                                                  ),
                                            foregroundColor: Color.lerp(
                                              theme.colorScheme.onSurfaceVariant,
                                              theme.colorScheme.onPrimaryContainer,
                                              t,
                                            ),
                                          ),
                                          onPressed: () => _goTo(index),
                                          child: child!,
                                        ),
                                        child: compact
                                            ? Column(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  Icon(sections[index].icon),
                                                  const SizedBox(height: Space.xs),
                                                  Text(sections[index].title, textAlign: TextAlign.center),
                                                ],
                                              )
                                            : Row(
                                                children: [
                                                  Icon(sections[index].icon),
                                                  const SizedBox(width: Space.sm),
                                                  Expanded(child: Text(sections[index].title)),
                                                ],
                                              ),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const VerticalDivider(width: Space.lg),
                      Expanded(
                        child: NotificationListener<ScrollMetricsNotification>(
                          onNotification: (_) {
                            _scheduleSync();
                            return false;
                          },
                          child: SingleChildScrollView(
                            key: const ValueKey('settings-content'),
                            controller: _scroll,
                            child: Padding(
                              padding: const EdgeInsets.only(left: Space.sm, top: Space.sm, bottom: Space.lg),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  for (var index = 0; index < sections.length; index++) ...[
                                    if (index > 0)
                                      const Padding(
                                        padding: EdgeInsets.symmetric(vertical: Space.xl),
                                        child: Divider(height: WorkspaceSize.divider),
                                      ),
                                    KeyedSubtree(key: _anchors[index], child: sections[index]),
                                  ],
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.id, this.title, this.icon, this.children);

  final SettingsSectionId id;
  final String title;
  final IconData icon;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(title, style: Theme.of(context).textTheme.titleSmall),
      const SizedBox(height: Space.lg),
      ...children,
    ],
  );
}

/// A label beside its control, or above it when the control needs the width.
class _Field extends StatelessWidget {
  const _Field(this.label, this.child, {this.hint}) : stacked = false, warning = null, onWarning = null;
  const _Field.stacked(this.label, this.child, {this.hint, this.warning, this.onWarning}) : stacked = true;

  final String label;
  final Widget child;
  final String? hint;

  /// Shown after [hint] in the error colour; a link when [onWarning] is set.
  final String? warning;
  final VoidCallback? onWarning;
  final bool stacked;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final warningStyle = TextStyle(color: theme.colorScheme.error);
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label),
        if (hint != null || warning != null)
          Text.rich(
            TextSpan(
              text: hint,
              children: [
                if (warning != null && hint != null) TextSpan(text: ' · ', style: warningStyle),
                if (warning != null)
                  onWarning == null
                      ? TextSpan(text: warning, style: warningStyle)
                      : WidgetSpan(
                          alignment: PlaceholderAlignment.baseline,
                          baseline: TextBaseline.alphabetic,
                          child: Semantics(
                            button: true,
                            child: MouseRegion(
                              cursor: SystemMouseCursors.click,
                              child: GestureDetector(
                                onTap: onWarning,
                                child: Text(
                                  warning!,
                                  style: theme.textTheme.bodySmall?.merge(
                                    warningStyle.copyWith(
                                      decoration: TextDecoration.underline,
                                      decorationColor: theme.colorScheme.error,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
              ],
            ),
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
      ],
    );
    return LayoutBuilder(
      builder: (context, constraints) => Padding(
        padding: const EdgeInsets.only(bottom: Space.md),
        child: stacked || constraints.maxWidth < WorkspaceSize.toolPanel
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

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final columns = constraints.maxWidth < WorkspaceSize.toolPanel ? 2 : 3;
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
    },
  );
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

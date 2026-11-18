import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../design/form_field.dart';
import '../../../design/theme.dart';
import '../../../foundation/shortcuts.dart';
import '../../../l10n/app_localizations.dart';

String shortcutActionLabel(AppLocalizations l, AppShortcutAction action) => switch (action) {
  AppShortcutAction.commandPalette => l.shortcutCommandPalette,
  AppShortcutAction.newConnection => l.shortcutNewConnection,
  AppShortcutAction.closeTab => l.shortcutCloseTab,
  AppShortcutAction.settings => l.shortcutSettings,
  AppShortcutAction.toggleAgent => l.shortcutToggleAgent,
  AppShortcutAction.inlineGenerate => l.shortcutInlineGenerate,
  AppShortcutAction.terminalCopy => l.shortcutTerminalCopy,
  AppShortcutAction.terminalPaste => l.shortcutTerminalPaste,
  AppShortcutAction.terminalSearch => l.shortcutTerminalSearch,
  AppShortcutAction.commandHistory => l.shortcutCommandHistory,
  AppShortcutAction.previousPane => l.shortcutPreviousPane,
  AppShortcutAction.nextPane => l.shortcutNextPane,
  AppShortcutAction.previousTab => l.shortcutPreviousTab,
  AppShortcutAction.nextTab => l.shortcutNextTab,
};

/// Click, press a key combination, and the combination is stored unless another action already uses it.
class ShortcutField extends StatefulWidget {
  const ShortcutField({super.key, required this.action, required this.overrides, required this.onChanged});

  final AppShortcutAction action;
  final Map<String, String> overrides;
  final ValueChanged<ShortcutBinding> onChanged;

  @override
  State<ShortcutField> createState() => _ShortcutFieldState();
}

class _ShortcutFieldState extends State<ShortcutField> {
  final _focus = FocusNode();
  var _recording = false, _hovered = false;
  AppShortcutAction? _conflict;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_focusChanged);
  }

  void _focusChanged() {
    if (!mounted) return;
    setState(() {
      if (!_focus.hasFocus) _recording = false;
    });
  }

  void _begin() {
    setState(() {
      _recording = true;
      _conflict = null;
    });
    _focus.requestFocus();
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent event) {
    if (!_recording || event is! KeyDownEvent) return KeyEventResult.ignored;
    final keys = HardwareKeyboard.instance;
    if (event.logicalKey == LogicalKeyboardKey.escape &&
        !keys.isControlPressed &&
        !keys.isAltPressed &&
        !keys.isShiftPressed &&
        !keys.isMetaPressed) {
      setState(() => _recording = false);
      return KeyEventResult.handled;
    }
    final binding = ShortcutBinding.fromEvent(event);
    if (binding == null) return KeyEventResult.handled;
    final conflict = AppShortcuts.conflict(widget.overrides, widget.action, binding);
    if (conflict != null) {
      setState(() => _conflict = conflict);
      return KeyEventResult.handled;
    }
    setState(() {
      _recording = false;
      _conflict = null;
    });
    widget.onChanged(binding);
    return KeyEventResult.handled;
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context), theme = Theme.of(context);
    final binding = AppShortcuts.resolve(widget.overrides, widget.action);
    final focused = _focus.hasFocus || _recording;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          button: true,
          label: shortcutActionLabel(l, widget.action),
          value: binding?.label(),
          child: Focus(
            focusNode: _focus,
            onKeyEvent: _onKey,
            child: MouseRegion(
              onEnter: (_) => setState(() => _hovered = true),
              onExit: (_) => setState(() => _hovered = false),
              child: GestureDetector(
                onTap: _begin,
                child: AnimatedContainer(
                  duration: Motion.of(context, Motion.quick),
                  height: AppFormField.height(context),
                  constraints: const BoxConstraints(minWidth: 180),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  decoration: BoxDecoration(
                    color: AppFormField.fill(context),
                    borderRadius: BorderRadius.circular(Radii.control),
                    border: Border.fromBorderSide(AppFormField.border(context, focused: focused, hovered: _hovered)),
                  ),
                  alignment: Alignment.centerLeft,
                  child: Text(
                    _recording ? l.shortcutPress : binding?.label() ?? l.shortcutUnset,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: _recording ? theme.colorScheme.primary : theme.colorScheme.onSurface,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        if (_conflict case final action?)
          Padding(
            padding: const EdgeInsets.only(top: Space.xs),
            child: Text(
              l.shortcutConflict(shortcutActionLabel(l, action)),
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
            ),
          ),
      ],
    );
  }
}

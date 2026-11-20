import 'package:flutter/material.dart';

import '../../../design/theme.dart';
import '../../../l10n/app_localizations.dart';

enum TouchModifierState { off, oneshot, locked }

/// Transforms a typed key string with active sticky Ctrl / Alt touch modifiers.
String applyTouchModifiers(String input, {required bool ctrl, required bool alt}) {
  if (input.isEmpty || (!ctrl && !alt)) return input;
  var out = input;
  if (ctrl && out.length == 1) {
    final code = out.toUpperCase().codeUnitAt(0);
    if (code >= 0x40 && code <= 0x5F) {
      out = String.fromCharCode(code - 0x40);
    } else if (out == ' ') {
      out = '\x00';
    }
  }
  if (alt) {
    out = '\x1b$out';
  }
  return out;
}

/// Touch-ergonomic single-row shortcut bar docked directly above the mobile soft keyboard (docs/MOBILE.md §3.2).
class MobileTerminalKeyBar extends StatelessWidget {
  const MobileTerminalKeyBar({
    super.key,
    required this.ctrl,
    required this.alt,
    required this.onToggleCtrl,
    required this.onLockCtrl,
    required this.onToggleAlt,
    required this.onLockAlt,
    required this.onSendSequence,
    required this.onPaste,
    required this.onOpenComposer,
    required this.onOpenSearch,
    this.onOpenSnippets,
    required this.onToggleKeyboard,
    required this.keyboardFocused,
  });

  final TouchModifierState ctrl;
  final TouchModifierState alt;
  final VoidCallback onToggleCtrl;
  final VoidCallback onLockCtrl;
  final VoidCallback onToggleAlt;
  final VoidCallback onLockAlt;
  final ValueChanged<String> onSendSequence;
  final VoidCallback onPaste;
  final VoidCallback onOpenComposer;
  final VoidCallback onOpenSearch;
  final VoidCallback? onOpenSnippets;
  final VoidCallback onToggleKeyboard;
  final bool keyboardFocused;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final l = AppLocalizations.of(context);
    return Material(
      color: scheme.surfaceContainerLow,
      child: Container(
        key: const ValueKey('mobile-terminal-key-bar'),
        height: 44,
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: scheme.outlineVariant.withValues(alpha: .5))),
        ),
        child: Row(
          children: [
            Expanded(
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: Space.xs, vertical: Space.xs),
                children: [
                  _KeyChip(label: 'ESC', onTap: () => onSendSequence('\x1b')),
                  _KeyChip(label: 'TAB', onTap: () => onSendSequence('\t')),
                  _ModifierChip(
                    key: const ValueKey('touch-key-ctrl'),
                    label: 'CTRL',
                    state: ctrl,
                    onTap: onToggleCtrl,
                    onDoubleTap: onLockCtrl,
                  ),
                  _ModifierChip(
                    key: const ValueKey('touch-key-alt'),
                    label: 'ALT',
                    state: alt,
                    onTap: onToggleAlt,
                    onDoubleTap: onLockAlt,
                  ),
                  _KeyChip(label: '^C', onTap: () => onSendSequence('\x03')),
                  _KeyChip(label: '^D', onTap: () => onSendSequence('\x04')),
                  _KeyChip(label: '↑', onTap: () => onSendSequence('\x1b[A')),
                  _KeyChip(label: '↓', onTap: () => onSendSequence('\x1b[B')),
                  _KeyChip(label: '←', onTap: () => onSendSequence('\x1b[D')),
                  _KeyChip(label: '→', onTap: () => onSendSequence('\x1b[C')),
                  _KeyChip(label: 'HOME', onTap: () => onSendSequence('\x1b[H')),
                  _KeyChip(label: 'END', onTap: () => onSendSequence('\x1b[F')),
                  _KeyChip(label: '|', onTap: () => onSendSequence('|')),
                  _KeyChip(label: '/', onTap: () => onSendSequence('/')),
                  _KeyChip(label: '~', onTap: () => onSendSequence('~')),
                  _KeyChip(label: '-', onTap: () => onSendSequence('-')),
                  _KeyChip(label: '_', onTap: () => onSendSequence('_')),
                ],
              ),
            ),
            VerticalDivider(width: 1, indent: 8, endIndent: 8, color: scheme.outlineVariant.withValues(alpha: .5)),
            IconButton(
              tooltip: l.paste,
              visualDensity: VisualDensity.compact,
              onPressed: onPaste,
              icon: const Icon(Icons.content_paste_outlined, size: 18),
            ),
            if (onOpenSnippets != null)
              IconButton(
                tooltip: l.snippets,
                visualDensity: VisualDensity.compact,
                onPressed: onOpenSnippets,
                icon: const Icon(Icons.code, size: 18),
              ),
            IconButton(
              tooltip: l.terminalMultilineInput,
              visualDensity: VisualDensity.compact,
              onPressed: onOpenComposer,
              icon: const Icon(Icons.edit_note_outlined, size: 18),
            ),
            IconButton(
              tooltip: l.find,
              visualDensity: VisualDensity.compact,
              onPressed: onOpenSearch,
              icon: const Icon(Icons.search, size: 18),
            ),
            IconButton(
              tooltip: keyboardFocused ? l.close : l.terminal,
              visualDensity: VisualDensity.compact,
              onPressed: onToggleKeyboard,
              icon: Icon(keyboardFocused ? Icons.keyboard_hide_outlined : Icons.keyboard_outlined, size: 18),
            ),
          ],
        ),
      ),
    );
  }
}

class _KeyChip extends StatelessWidget {
  const _KeyChip({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Material(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(Radii.control),
        child: InkWell(
          borderRadius: BorderRadius.circular(Radii.control),
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(minWidth: 36),
            padding: const EdgeInsets.symmetric(horizontal: Space.sm),
            alignment: Alignment.center,
            child: Text(
              label,
              style: mono(context, Theme.of(context).textTheme.labelMedium).copyWith(
                fontWeight: FontWeight.w600,
                color: scheme.onSurface,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ModifierChip extends StatelessWidget {
  const _ModifierChip({
    super.key,
    required this.label,
    required this.state,
    required this.onTap,
    required this.onDoubleTap,
  });

  final String label;
  final TouchModifierState state;
  final VoidCallback onTap;
  final VoidCallback onDoubleTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final active = state != TouchModifierState.off;
    final locked = state == TouchModifierState.locked;
    final bg = locked
        ? scheme.primary
        : active
        ? scheme.primary.withValues(alpha: .2)
        : scheme.surfaceContainerHigh;
    final fg = locked
        ? scheme.onPrimary
        : active
        ? scheme.primary
        : scheme.onSurface;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Material(
        color: bg,
        borderRadius: BorderRadius.circular(Radii.control),
        child: InkWell(
          borderRadius: BorderRadius.circular(Radii.control),
          onTap: onTap,
          onDoubleTap: onDoubleTap,
          child: Container(
            constraints: const BoxConstraints(minWidth: 44),
            padding: const EdgeInsets.symmetric(horizontal: Space.sm),
            alignment: Alignment.center,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              spacing: 3,
              children: [
                Text(
                  label,
                  style: mono(context, Theme.of(context).textTheme.labelMedium).copyWith(
                    fontWeight: FontWeight.w700,
                    color: fg,
                  ),
                ),
                if (locked) Container(width: 4, height: 4, decoration: BoxDecoration(color: fg, shape: BoxShape.circle)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../design/theme.dart';
import '../../../l10n/app_localizations.dart';

enum TouchModifierState { off, oneshot, locked }

typedef MobileCompletionItem = ({String label, String? detail, bool isDir});

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

/// Touch-ergonomic shortcut bar + virtual cursor trackpad + optional IME/AI command draft bar (docs/MOBILE.md §3.2).
class MobileTerminalKeyBar extends StatefulWidget {
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
    this.onOpenAiry,
    this.onOpenInlineAi,
    this.onGenerateDraft,
    this.prediction,
    this.onAcceptPrediction,
    this.suggestions = const [],
    this.onAcceptSuggestion,
    required this.onToggleKeyboard,
    required this.keyboardFocused,
    this.hapticsEnabled = true,
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
  final VoidCallback? onOpenAiry;
  final VoidCallback? onOpenInlineAi;
  final Future<String?> Function(String instruction)? onGenerateDraft;
  final String? prediction;
  final VoidCallback? onAcceptPrediction;
  final List<MobileCompletionItem> suggestions;
  final ValueChanged<int>? onAcceptSuggestion;
  final VoidCallback onToggleKeyboard;
  final bool keyboardFocused;
  final bool hapticsEnabled;

  @override
  State<MobileTerminalKeyBar> createState() => _MobileTerminalKeyBarState();
}

class _MobileTerminalKeyBarState extends State<MobileTerminalKeyBar> {
  var _draftOpen = false;
  var _generating = false;
  final _draftController = TextEditingController();
  final _draftFocus = FocusNode();

  @override
  void dispose() {
    _draftController.dispose();
    _draftFocus.dispose();
    super.dispose();
  }

  void _haptic() {
    if (widget.hapticsEnabled) {
      unawaited(HapticFeedback.selectionClick());
    }
  }

  void _send(String seq) {
    _haptic();
    widget.onSendSequence(seq);
  }

  void _submitDraft({required bool run}) {
    final text = _draftController.text;
    if (text.isEmpty) return;
    _haptic();
    widget.onSendSequence(run ? '$text\r' : text);
    _draftController.clear();
  }

  Future<void> _runAiDraft() async {
    final gen = widget.onGenerateDraft;
    final instruction = _draftController.text.trim();
    if (gen == null || instruction.isEmpty || _generating) return;
    _haptic();
    setState(() => _generating = true);
    try {
      final command = await gen(instruction);
      if (!mounted) return;
      if (command != null && command.trim().isNotEmpty) {
        _draftController.text = command.trim();
        _draftController.selection = TextSelection.collapsed(offset: _draftController.text.length);
      }
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final palette = BrandPalette.of(context);
    final l = AppLocalizations.of(context);

    final hasCompletions =
        (widget.prediction != null && widget.prediction!.isNotEmpty && widget.onAcceptPrediction != null) ||
        (widget.suggestions.isNotEmpty && widget.onAcceptSuggestion != null);

    return Material(
      color: palette.surface,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Reveal(
            open: hasCompletions,
            duration: Motion.quick,
            child: Container(
              key: const ValueKey('mobile-completion-bar'),
              height: 36,
              decoration: BoxDecoration(
                color: palette.raised,
                border: Border(top: BorderSide(color: scheme.outlineVariant.withValues(alpha: .4))),
              ),
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: Space.sm, vertical: 4),
                children: [
                  if (widget.prediction != null && widget.prediction!.isNotEmpty && widget.onAcceptPrediction != null)
                    Padding(
                      padding: const EdgeInsets.only(right: Space.xs),
                      child: Material(
                        key: const ValueKey('mobile-prediction-chip'),
                        color: palette.primary.withValues(alpha: .16),
                        borderRadius: BorderRadius.circular(Radii.control),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(Radii.control),
                          onTap: () {
                            _haptic();
                            widget.onAcceptPrediction!();
                          },
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: Space.sm),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.auto_awesome_rounded, size: 13, color: palette.primary),
                                const SizedBox(width: 4),
                                ConstrainedBox(
                                  constraints: const BoxConstraints(maxWidth: 220),
                                  child: Text(
                                    widget.prediction!,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: mono(
                                      context,
                                      Theme.of(context).textTheme.labelSmall,
                                    ).copyWith(color: palette.primary, fontWeight: FontWeight.w600),
                                  ),
                                ),
                                const SizedBox(width: 4),
                                Icon(Icons.keyboard_tab_rounded, size: 13, color: palette.primary),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  for (var i = 0; i < widget.suggestions.length; i++)
                    Padding(
                      padding: const EdgeInsets.only(right: Space.xs),
                      child: Material(
                        key: ValueKey('mobile-completion-chip-$i'),
                        color: palette.surface,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(Radii.control),
                          side: BorderSide(color: scheme.outlineVariant.withValues(alpha: .45)),
                        ),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(Radii.control),
                          onTap: () {
                            _haptic();
                            widget.onAcceptSuggestion!(i);
                          },
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: Space.sm),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (widget.suggestions[i].isDir) ...[
                                  Icon(Icons.folder_outlined, size: 12, color: scheme.onSurfaceVariant),
                                  const SizedBox(width: 4),
                                ],
                                ConstrainedBox(
                                  constraints: const BoxConstraints(maxWidth: 180),
                                  child: Text(
                                    widget.suggestions[i].label,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: mono(context, Theme.of(context).textTheme.labelSmall),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          Reveal(
            open: _draftOpen,
            duration: Motion.quick,
            child: Container(
              key: const ValueKey('mobile-terminal-draft-bar'),
              padding: const EdgeInsets.fromLTRB(Space.md, Space.xs, Space.sm, Space.xs),
              decoration: BoxDecoration(
                color: palette.raised,
                border: Border(top: BorderSide(color: scheme.outlineVariant.withValues(alpha: .45))),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _draftController,
                      focusNode: _draftFocus,
                      style: mono(context, Theme.of(context).textTheme.bodyMedium),
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _submitDraft(run: true),
                      decoration: InputDecoration(
                        isDense: true,
                        border: InputBorder.none,
                        hintText: l.mobileDraftPlaceholder,
                        contentPadding: const EdgeInsets.symmetric(horizontal: Space.xs, vertical: Space.xs),
                      ),
                    ),
                  ),
                  if (widget.onGenerateDraft != null)
                    IconButton(
                      key: const ValueKey('mobile-draft-ai-button'),
                      tooltip: l.terminalAiGenerate,
                      visualDensity: VisualDensity.compact,
                      onPressed: _generating ? null : _runAiDraft,
                      icon: _generating
                          ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                          : Icon(Icons.auto_awesome_rounded, size: 18, color: palette.primary),
                    ),
                  IconButton(
                    tooltip: l.terminalMultilineSend,
                    visualDensity: VisualDensity.compact,
                    onPressed: () => _submitDraft(run: true),
                    icon: Icon(Icons.send_rounded, size: 18, color: palette.primary),
                  ),
                ],
              ),
            ),
          ),
          Container(
            key: const ValueKey('mobile-terminal-key-bar'),
            height: 46,
            padding: const EdgeInsets.symmetric(horizontal: Space.xs),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: scheme.outlineVariant.withValues(alpha: .45))),
            ),
            child: Row(
              children: [
                Expanded(
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: Space.xs, vertical: 5),
                    children: [
                      _KeyChip(label: 'ESC', onTap: () => _send('\x1b')),
                      _KeyChip(label: 'TAB', onTap: () => _send('\t')),
                      _ModifierChip(
                        key: const ValueKey('touch-key-ctrl'),
                        label: 'CTRL',
                        state: widget.ctrl,
                        onTap: () {
                          _haptic();
                          widget.onToggleCtrl();
                        },
                        onDoubleTap: () {
                          _haptic();
                          widget.onLockCtrl();
                        },
                      ),
                      _ModifierChip(
                        key: const ValueKey('touch-key-alt'),
                        label: 'ALT',
                        state: widget.alt,
                        onTap: () {
                          _haptic();
                          widget.onToggleAlt();
                        },
                        onDoubleTap: () {
                          _haptic();
                          widget.onLockAlt();
                        },
                      ),
                      _KeyChip(label: '^C', onTap: () => _send('\x03')),
                      _KeyChip(label: '^D', onTap: () => _send('\x04')),
                      _RepeatableKeyChip(label: '↑', onFire: () => _send('\x1b[A')),
                      _RepeatableKeyChip(label: '↓', onFire: () => _send('\x1b[B')),
                      _RepeatableKeyChip(label: '←', onFire: () => _send('\x1b[D')),
                      _RepeatableKeyChip(label: '→', onFire: () => _send('\x1b[C')),
                      _KeyChip(label: 'HOME', onTap: () => _send('\x1b[H')),
                      _KeyChip(label: 'END', onTap: () => _send('\x1b[F')),
                      _KeyChip(label: '|', onTap: () => _send('|')),
                      _KeyChip(label: '/', onTap: () => _send('/')),
                      _KeyChip(label: '~', onTap: () => _send('~')),
                      _KeyChip(label: '-', onTap: () => _send('-')),
                      _KeyChip(label: '_', onTap: () => _send('_')),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: _TrackpadChip(
                    key: const ValueKey('touch-key-trackpad'),
                    tooltip: l.mobileTrackpad,
                    onStep: _send,
                  ),
                ),
                VerticalDivider(width: 1, indent: 8, endIndent: 8, color: scheme.outlineVariant.withValues(alpha: .45)),
                IconButton(
                  key: const ValueKey('mobile-draft-toggle'),
                  tooltip: l.mobileDraftMode,
                  visualDensity: VisualDensity.compact,
                  onPressed: () {
                    _haptic();
                    setState(() => _draftOpen = !_draftOpen);
                    if (_draftOpen) {
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (mounted) _draftFocus.requestFocus();
                      });
                    }
                  },
                  icon: Icon(
                    Icons.edit_note_rounded,
                    size: 20,
                    color: _draftOpen ? palette.primary : scheme.onSurfaceVariant,
                  ),
                ),
                if (widget.onOpenSnippets != null)
                  IconButton(
                    tooltip: l.snippets,
                    visualDensity: VisualDensity.compact,
                    onPressed: () {
                      _haptic();
                      widget.onOpenSnippets!();
                    },
                    icon: const Icon(Icons.bolt_rounded, size: 20),
                  ),
                IconButton(
                  tooltip: l.paste,
                  visualDensity: VisualDensity.compact,
                  onPressed: () {
                    _haptic();
                    widget.onPaste();
                  },
                  icon: const Icon(Icons.content_paste_rounded, size: 18),
                ),
                if (widget.onOpenInlineAi != null)
                  IconButton(
                    key: const ValueKey('mobile-keybar-inline-ai'),
                    tooltip: l.terminalAiGenerate,
                    visualDensity: VisualDensity.compact,
                    onPressed: () {
                      _haptic();
                      widget.onOpenInlineAi!();
                    },
                    icon: Icon(Icons.auto_fix_high_rounded, size: 18, color: palette.primary),
                  ),
                if (widget.onOpenAiry != null)
                  IconButton(
                    key: const ValueKey('mobile-keybar-airy'),
                    tooltip: l.mobileAskAiry,
                    visualDensity: VisualDensity.compact,
                    onPressed: () {
                      _haptic();
                      widget.onOpenAiry!();
                    },
                    icon: Icon(Icons.auto_awesome_rounded, size: 18, color: palette.primary),
                  ),
                IconButton(
                  tooltip: l.find,
                  visualDensity: VisualDensity.compact,
                  onPressed: widget.onOpenSearch,
                  icon: const Icon(Icons.search_rounded, size: 18),
                ),
                IconButton(
                  tooltip: widget.keyboardFocused ? l.close : l.terminal,
                  visualDensity: VisualDensity.compact,
                  onPressed: widget.onToggleKeyboard,
                  icon: Icon(widget.keyboardFocused ? Icons.keyboard_hide_rounded : Icons.keyboard_rounded, size: 18),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Hold and drag to glide the terminal cursor smoothly in all 4 directions (Termius-style virtual trackpad).
class _TrackpadChip extends StatefulWidget {
  const _TrackpadChip({super.key, required this.tooltip, required this.onStep});

  final String tooltip;
  final ValueChanged<String> onStep;

  @override
  State<_TrackpadChip> createState() => _TrackpadChipState();
}

class _TrackpadChipState extends State<_TrackpadChip> {
  static const _stepPx = 14.0;
  var _dx = 0.0;
  var _dy = 0.0;
  var _active = false;

  void _onPanStart(DragStartDetails _) {
    _dx = 0;
    _dy = 0;
    setState(() => _active = true);
  }

  void _onPanUpdate(DragUpdateDetails d) {
    _dx += d.delta.dx;
    _dy += d.delta.dy;
    while (_dx >= _stepPx) {
      _dx -= _stepPx;
      widget.onStep('\x1b[C');
    }
    while (_dx <= -_stepPx) {
      _dx += _stepPx;
      widget.onStep('\x1b[D');
    }
    while (_dy >= _stepPx) {
      _dy -= _stepPx;
      widget.onStep('\x1b[B');
    }
    while (_dy <= -_stepPx) {
      _dy += _stepPx;
      widget.onStep('\x1b[A');
    }
  }

  void _onPanEnd(DragEndDetails _) => setState(() => _active = false);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final palette = BrandPalette.of(context);
    return Tooltip(
      message: widget.tooltip,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: GestureDetector(
          onPanStart: _onPanStart,
          onPanUpdate: _onPanUpdate,
          onPanEnd: _onPanEnd,
          onPanCancel: () => setState(() => _active = false),
          child: AnimatedContainer(
            duration: Motion.of(context, Motion.quick),
            curve: Motion.move,
            constraints: const BoxConstraints(minWidth: 42),
            padding: const EdgeInsets.symmetric(horizontal: Space.sm),
            decoration: BoxDecoration(
              color: _active ? palette.primary : scheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(Radii.control),
            ),
            alignment: Alignment.center,
            child: Icon(Icons.open_with_rounded, size: 16, color: _active ? scheme.onPrimary : palette.primary),
          ),
        ),
      ),
    );
  }
}

class _RepeatableKeyChip extends StatefulWidget {
  const _RepeatableKeyChip({required this.label, required this.onFire});

  final String label;
  final VoidCallback onFire;

  @override
  State<_RepeatableKeyChip> createState() => _RepeatableKeyChipState();
}

class _RepeatableKeyChipState extends State<_RepeatableKeyChip> {
  Timer? _timer;

  void _stop() {
    _timer?.cancel();
    _timer = null;
  }

  @override
  void dispose() {
    _stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: GestureDetector(
        onLongPressStart: (_) {
          widget.onFire();
          _timer = Timer.periodic(const Duration(milliseconds: 90), (_) => widget.onFire());
        },
        onLongPressEnd: (_) => _stop(),
        onLongPressCancel: _stop,
        child: Material(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(Radii.control),
          child: InkWell(
            borderRadius: BorderRadius.circular(Radii.control),
            onTap: widget.onFire,
            child: Container(
              constraints: const BoxConstraints(minWidth: 36),
              padding: const EdgeInsets.symmetric(horizontal: Space.sm),
              alignment: Alignment.center,
              child: Text(
                widget.label,
                style: mono(
                  context,
                  Theme.of(context).textTheme.labelMedium,
                ).copyWith(fontWeight: FontWeight.w600, color: scheme.onSurface),
              ),
            ),
          ),
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
              style: mono(
                context,
                Theme.of(context).textTheme.labelMedium,
              ).copyWith(fontWeight: FontWeight.w600, color: scheme.onSurface),
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
      child: AnimatedContainer(
        duration: Motion.of(context, Motion.quick),
        curve: Motion.move,
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(Radii.control)),
        child: Material(
          type: MaterialType.transparency,
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
                    style: mono(
                      context,
                      Theme.of(context).textTheme.labelMedium,
                    ).copyWith(fontWeight: FontWeight.w700, color: fg),
                  ),
                  if (locked)
                    Container(
                      width: 4,
                      height: 4,
                      decoration: BoxDecoration(color: fg, shape: BoxShape.circle),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

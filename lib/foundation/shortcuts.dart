import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// App-level actions whose keys the user can change (docs/UI.md §6).
enum AppShortcutAction {
  commandPalette,
  newConnection,
  closeTab,
  settings,
  toggleAgent,
  inlineGenerate,
  terminalCopy,
  terminalPaste,
  terminalSearch,
  commandHistory,
  previousPane,
  nextPane,
  previousTab,
  nextTab,
}

/// One key plus modifiers, stored as a portable "Ctrl+Shift+P" string.
class ShortcutBinding {
  const ShortcutBinding(this.key, {this.control = false, this.alt = false, this.shift = false, this.meta = false});

  final LogicalKeyboardKey key;
  final bool control, alt, shift, meta;

  SingleActivator get activator => SingleActivator(key, control: control, alt: alt, shift: shift, meta: meta);

  bool matches(KeyEvent event) => activator.accepts(event, HardwareKeyboard.instance);

  String encode() => [
    if (control) 'Ctrl',
    if (alt) 'Alt',
    if (shift) 'Shift',
    if (meta) 'Meta',
    _keyToken(key) ?? key.keyLabel,
  ].join('+');

  /// Display text follows the platform's modifier names and order.
  String label() {
    final mac = defaultTargetPlatform == TargetPlatform.macOS;
    return [
      if (meta) mac ? '⌘' : 'Meta',
      if (control) mac ? '⌃' : 'Ctrl',
      if (alt) mac ? '⌥' : 'Alt',
      if (shift) mac ? '⇧' : 'Shift',
      _keyToken(key) ?? key.keyLabel,
    ].join('+');
  }

  static ShortcutBinding? parse(String value) {
    final parts = value.split('+').map((part) => part.trim()).toList();
    if (parts.any((part) => part.isEmpty)) return null;
    var control = false, alt = false, shift = false, meta = false;
    LogicalKeyboardKey? key;
    for (final part in parts) {
      switch (part.toLowerCase()) {
        case 'ctrl' || 'control':
          if (control) return null;
          control = true;
        case 'alt' || 'option':
          if (alt) return null;
          alt = true;
        case 'shift':
          if (shift) return null;
          shift = true;
        case 'meta' || 'cmd' || 'command' || 'win' || 'super':
          if (meta) return null;
          meta = true;
        default:
          if (key != null) return null;
          key = _keyFor(part);
          if (key == null) return null;
      }
    }
    if (key == null || _isModifier(key)) return null;
    return ShortcutBinding(key, control: control, alt: alt, shift: shift, meta: meta);
  }

  /// Captures the current key press, ignoring modifier-only events.
  static ShortcutBinding? fromEvent(KeyEvent event) {
    if (_isModifier(event.logicalKey)) return null;
    final keys = HardwareKeyboard.instance;
    return ShortcutBinding(
      event.logicalKey,
      control: keys.isControlPressed,
      alt: keys.isAltPressed,
      shift: keys.isShiftPressed,
      meta: keys.isMetaPressed,
    );
  }

  static bool _isModifier(LogicalKeyboardKey key) =>
      key == LogicalKeyboardKey.controlLeft ||
      key == LogicalKeyboardKey.controlRight ||
      key == LogicalKeyboardKey.shiftLeft ||
      key == LogicalKeyboardKey.shiftRight ||
      key == LogicalKeyboardKey.altLeft ||
      key == LogicalKeyboardKey.altRight ||
      key == LogicalKeyboardKey.metaLeft ||
      key == LogicalKeyboardKey.metaRight;
}

abstract final class AppShortcuts {
  static bool get _mac => defaultTargetPlatform == TargetPlatform.macOS;

  static String defaultFor(AppShortcutAction action) => switch (action) {
    AppShortcutAction.commandPalette => _mac ? 'Meta+Shift+P' : 'Ctrl+Shift+P',
    AppShortcutAction.newConnection => _mac ? 'Meta+Shift+N' : 'Ctrl+Shift+N',
    AppShortcutAction.closeTab => _mac ? 'Meta+W' : 'Ctrl+Shift+W',
    AppShortcutAction.settings => _mac ? 'Meta+,' : 'Ctrl+,',
    AppShortcutAction.toggleAgent => _mac ? 'Meta+Shift+A' : 'Ctrl+Shift+A',
    AppShortcutAction.inlineGenerate => 'Alt+Enter',
    AppShortcutAction.terminalCopy => _mac ? 'Meta+C' : 'Ctrl+Shift+C',
    AppShortcutAction.terminalPaste => _mac ? 'Meta+V' : 'Ctrl+Shift+V',
    AppShortcutAction.terminalSearch => _mac ? 'Meta+F' : 'Ctrl+Shift+F',
    AppShortcutAction.commandHistory => _mac ? 'Meta+Shift+H' : 'Ctrl+Shift+H',
    AppShortcutAction.previousPane => _mac ? 'Meta+Alt+ArrowLeft' : 'Alt+ArrowLeft',
    AppShortcutAction.nextPane => _mac ? 'Meta+Alt+ArrowRight' : 'Alt+ArrowRight',
    AppShortcutAction.previousTab => _mac ? 'Meta+Shift+Tab' : 'Ctrl+Shift+Tab',
    AppShortcutAction.nextTab => _mac ? 'Meta+Tab' : 'Ctrl+Tab',
  };

  static ShortcutBinding? resolve(Map<String, String> overrides, AppShortcutAction action) =>
      ShortcutBinding.parse(overrides[action.name] ?? defaultFor(action));

  static bool matches(Map<String, String> overrides, AppShortcutAction action, KeyEvent event) {
    if (resolve(overrides, action)?.matches(event) ?? false) return true;
    // shortcut: the pre-settings Meta alias for the agent toggle stays on Windows/Linux until overridden.
    if (action == AppShortcutAction.toggleAgent && !_mac && !overrides.containsKey(action.name)) {
      return const ShortcutBinding(LogicalKeyboardKey.keyA, shift: true, meta: true).matches(event);
    }
    return false;
  }

  /// The other action already using [candidate], if any.
  static AppShortcutAction? conflict(
    Map<String, String> overrides,
    AppShortcutAction action,
    ShortcutBinding candidate,
  ) {
    final encoded = candidate.encode();
    for (final other in AppShortcutAction.values) {
      if (other == action) continue;
      if (resolve(overrides, other)?.encode() == encoded) return other;
    }
    return null;
  }

  static Map<String, String> withBinding(
    Map<String, String> overrides,
    AppShortcutAction action,
    ShortcutBinding binding,
  ) => {...overrides, action.name: binding.encode()};

  static Map<String, String> withoutBinding(Map<String, String> overrides, AppShortcutAction action) =>
      {...overrides}..remove(action.name);
}

final Map<String, LogicalKeyboardKey> _namedKeys = {
  'enter': LogicalKeyboardKey.enter,
  'numpadenter': LogicalKeyboardKey.numpadEnter,
  'tab': LogicalKeyboardKey.tab,
  'space': LogicalKeyboardKey.space,
  'escape': LogicalKeyboardKey.escape,
  'backspace': LogicalKeyboardKey.backspace,
  'delete': LogicalKeyboardKey.delete,
  'insert': LogicalKeyboardKey.insert,
  'home': LogicalKeyboardKey.home,
  'end': LogicalKeyboardKey.end,
  'pageup': LogicalKeyboardKey.pageUp,
  'pagedown': LogicalKeyboardKey.pageDown,
  'arrowleft': LogicalKeyboardKey.arrowLeft,
  'arrowright': LogicalKeyboardKey.arrowRight,
  'arrowup': LogicalKeyboardKey.arrowUp,
  'arrowdown': LogicalKeyboardKey.arrowDown,
  ',': LogicalKeyboardKey.comma,
  '.': LogicalKeyboardKey.period,
  '/': LogicalKeyboardKey.slash,
  ';': LogicalKeyboardKey.semicolon,
  "'": LogicalKeyboardKey.quote,
  '[': LogicalKeyboardKey.bracketLeft,
  ']': LogicalKeyboardKey.bracketRight,
  r'\': LogicalKeyboardKey.backslash,
  '-': LogicalKeyboardKey.minus,
  '=': LogicalKeyboardKey.equal,
  '`': LogicalKeyboardKey.backquote,
  for (var i = 1; i <= 12; i++)
    'f$i': [
      LogicalKeyboardKey.f1,
      LogicalKeyboardKey.f2,
      LogicalKeyboardKey.f3,
      LogicalKeyboardKey.f4,
      LogicalKeyboardKey.f5,
      LogicalKeyboardKey.f6,
      LogicalKeyboardKey.f7,
      LogicalKeyboardKey.f8,
      LogicalKeyboardKey.f9,
      LogicalKeyboardKey.f10,
      LogicalKeyboardKey.f11,
      LogicalKeyboardKey.f12,
    ][i - 1],
};

final Map<int, String> _tokens = {
  for (final entry in _namedKeys.entries)
    if (entry.key.length > 1) entry.value.keyId: _displayToken(entry.key),
};

const _letters = [
  LogicalKeyboardKey.keyA,
  LogicalKeyboardKey.keyB,
  LogicalKeyboardKey.keyC,
  LogicalKeyboardKey.keyD,
  LogicalKeyboardKey.keyE,
  LogicalKeyboardKey.keyF,
  LogicalKeyboardKey.keyG,
  LogicalKeyboardKey.keyH,
  LogicalKeyboardKey.keyI,
  LogicalKeyboardKey.keyJ,
  LogicalKeyboardKey.keyK,
  LogicalKeyboardKey.keyL,
  LogicalKeyboardKey.keyM,
  LogicalKeyboardKey.keyN,
  LogicalKeyboardKey.keyO,
  LogicalKeyboardKey.keyP,
  LogicalKeyboardKey.keyQ,
  LogicalKeyboardKey.keyR,
  LogicalKeyboardKey.keyS,
  LogicalKeyboardKey.keyT,
  LogicalKeyboardKey.keyU,
  LogicalKeyboardKey.keyV,
  LogicalKeyboardKey.keyW,
  LogicalKeyboardKey.keyX,
  LogicalKeyboardKey.keyY,
  LogicalKeyboardKey.keyZ,
];

const _digits = [
  LogicalKeyboardKey.digit0,
  LogicalKeyboardKey.digit1,
  LogicalKeyboardKey.digit2,
  LogicalKeyboardKey.digit3,
  LogicalKeyboardKey.digit4,
  LogicalKeyboardKey.digit5,
  LogicalKeyboardKey.digit6,
  LogicalKeyboardKey.digit7,
  LogicalKeyboardKey.digit8,
  LogicalKeyboardKey.digit9,
];

LogicalKeyboardKey? _keyFor(String token) {
  if (token.length == 1) {
    final code = token.toUpperCase().codeUnitAt(0);
    if (code >= 65 && code <= 90) return _letters[code - 65];
    if (code >= 48 && code <= 57) return _digits[code - 48];
  }
  return _namedKeys[token.toLowerCase()];
}

String _displayToken(String token) => switch (token) {
  'numpadenter' => 'NumpadEnter',
  'pageup' => 'PageUp',
  'pagedown' => 'PageDown',
  'arrowleft' => 'ArrowLeft',
  'arrowright' => 'ArrowRight',
  'arrowup' => 'ArrowUp',
  'arrowdown' => 'ArrowDown',
  _ => token[0].toUpperCase() + token.substring(1),
};

String? _keyToken(LogicalKeyboardKey key) {
  final label = key.keyLabel;
  if (label.length == 1 && RegExp(r'[A-Za-z0-9]').hasMatch(label)) return label.toUpperCase();
  return _tokens[key.keyId];
}

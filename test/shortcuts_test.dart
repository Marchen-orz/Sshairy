import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/features/settings/settings.dart' show SettingKeys;
import 'package:sshairy/foundation/shortcuts.dart';

void main() {
  test('bindings round-trip through their portable encoding', () {
    for (final encoded in ['Ctrl+Shift+P', 'Alt+Enter', 'Meta+W', 'Ctrl+,', 'Shift+Tab']) {
      expect(ShortcutBinding.parse(encoded)?.encode(), encoded);
    }
    expect(ShortcutBinding.parse('Command+Shift+A')?.encode(), 'Shift+Meta+A');
    expect(ShortcutBinding.parse('Ctrl+Ctrl+P'), isNull);
    expect(ShortcutBinding.parse('Ctrl+Shift'), isNull);
    expect(ShortcutBinding.parse('Ctrl+Shift+'), isNull);
    expect(ShortcutBinding.parse('Ctrl+Banana'), isNull);
    expect(ShortcutBinding.parse('Ctrl+P+Q'), isNull);
  });

  test('defaults cover every action with Ctrl/Alt modifiers and parse cleanly on Windows and Linux', () {
    for (final action in AppShortcutAction.values) {
      final binding = AppShortcuts.resolve(const {}, action);
      expect(binding, isNotNull, reason: action.name);
      expect(binding!.control || binding.alt || binding.meta, isTrue, reason: action.name);
      expect(
        ShortcutBinding.parse(AppShortcuts.defaultFor(action))?.encode(),
        AppShortcuts.defaultFor(action),
        reason: action.name,
      );
    }
    expect(AppShortcuts.defaultFor(AppShortcutAction.inlineGenerate), 'Alt+Enter');
  });

  test('conflicts name the other owner, and overrides reset independently', () {
    const candidate = ShortcutBinding(LogicalKeyboardKey.keyP, control: true, shift: true);
    expect(AppShortcuts.conflict(const {}, AppShortcutAction.settings, candidate), AppShortcutAction.commandPalette);
    final overrides = AppShortcuts.withBinding(const {}, AppShortcutAction.settings, candidate);
    expect(overrides[AppShortcutAction.settings.name], 'Ctrl+Shift+P');
    expect(AppShortcuts.conflict(overrides, AppShortcutAction.settings, candidate), AppShortcutAction.commandPalette);
    final free = const ShortcutBinding(LogicalKeyboardKey.f12, alt: true);
    expect(AppShortcuts.conflict(overrides, AppShortcutAction.settings, free), isNull);
    expect(AppShortcuts.withoutBinding(overrides, AppShortcutAction.settings), isEmpty);
    final taken = AppShortcuts.withBinding(
      const {},
      AppShortcutAction.settings,
      ShortcutBinding.parse('Ctrl+Shift+P')!,
    );
    expect(
      AppShortcuts.conflict(
        AppShortcuts.withoutBinding(taken, AppShortcutAction.commandPalette),
        AppShortcutAction.commandPalette,
        AppShortcuts.resolve(const {}, AppShortcutAction.commandPalette)!,
      ),
      AppShortcutAction.settings,
      reason: 'reset must not store a duplicate of another action',
    );
  });

  test('stored shortcut maps reject unknown actions, bad strings and duplicates', () {
    expect(SettingKeys.shortcuts.accepts(const {'settings': 'Ctrl+,'}), isTrue);
    expect(SettingKeys.shortcuts.accepts(const {}), isTrue);
    expect(SettingKeys.shortcuts.accepts(const {'nope': 'Ctrl+,'}), isFalse);
    expect(SettingKeys.shortcuts.accepts(const {'settings': 'banana'}), isFalse);
    expect(SettingKeys.shortcuts.accepts(const {'settings': 'Ctrl+Ctrl+P'}), isFalse);
    expect(SettingKeys.shortcuts.accepts(const {'settings': 'Ctrl+,', 'commandPalette': 'Ctrl+,'}), isFalse);
  });

  testWidgets('key events match their binding and respect modifiers', (tester) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    expect(
      AppShortcuts.matches(
        const {},
        AppShortcutAction.commandPalette,
        KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.keyP,
          logicalKey: LogicalKeyboardKey.keyP,
          timeStamp: Duration.zero,
        ),
      ),
      isFalse,
      reason: 'modifiers were released before the check',
    );

    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
    expect(
      AppShortcuts.matches(
        const {},
        AppShortcutAction.inlineGenerate,
        KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.enter,
          logicalKey: LogicalKeyboardKey.enter,
          timeStamp: Duration.zero,
        ),
      ),
      isTrue,
    );
    await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
  });
}

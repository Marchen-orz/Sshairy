import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/design/controls.dart';
import 'package:sshairy/design/menu.dart';
import 'package:sshairy/design/select.dart';
import 'package:sshairy/design/theme.dart';

void main() {
  test('disabled input surfaces follow the muted palette in all twelve themes', () {
    for (final accent in Accent.values) {
      for (final brightness in Brightness.values) {
        final theme = buildTheme(brightness, accent);
        final palette = BrandPalette.fromTheme(theme);
        final decoration = theme.inputDecorationTheme;
        expect(WidgetStateProperty.resolveAs(decoration.fillColor!, {WidgetState.disabled}), palette.disabledSurface);
        expect(WidgetStateProperty.resolveAs(decoration.fillColor!, {}), theme.colorScheme.surface);
        expect(WidgetStateProperty.resolveAs(decoration.labelStyle!, {WidgetState.disabled}).color, palette.textMuted);
        expect(palette.disabledSurface, isNot(theme.colorScheme.surfaceContainerLow));
      }
    }
  });

  testWidgets('disabled selectors and controls stay muted and cannot change their values', (tester) async {
    var changes = 0;
    for (final brightness in Brightness.values) {
      final theme = buildTheme(brightness);
      final palette = BrandPalette.fromTheme(theme);
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Scaffold(
            body: Column(
              children: [
                const SizedBox(
                  width: 220,
                  child: AppSelect<int>(value: 1, options: [AppOption(1, 'Inherited identity')], onChanged: null),
                ),
                const AppToggleRow(title: 'Inherited authentication', value: true, onChanged: null),
                const AppCheckbox(value: true, onChanged: null),
                const AppSegmented<int>(segments: {1: 'One', 2: 'Two'}, selected: 1, onChanged: null),
                AppSwitch(value: true, onChanged: (_) => changes++),
                const TextField(enabled: false, decoration: InputDecoration(labelText: 'Inherited port')),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      BoxDecoration surface(Finder finder) =>
          tester
                  .widget<AnimatedContainer>(
                    find.descendant(of: finder, matching: find.byType(AnimatedContainer)).first,
                  )
                  .decoration!
              as BoxDecoration;
      final selector = find.byType(AppSelect<int>);
      expect(surface(selector).color, palette.disabledSurface);
      expect((surface(selector).border! as Border).top.color, theme.colorScheme.outlineVariant);
      expect(tester.widget<Text>(find.text('Inherited identity')).style!.color, palette.textMuted);
      expect(tester.widget<Text>(find.text('Inherited authentication')).style!.color, palette.textMuted);
      final disabledSwitch = find.descendant(of: find.byType(AppToggleRow), matching: find.byType(AppSwitch));
      expect(surface(disabledSwitch).color, theme.colorScheme.outlineVariant);
      expect(surface(find.byType(AppCheckbox)).color, palette.disabledSurface);
      final segmented = find.byType(AppSegmented<int>);
      final track = tester.widget<Container>(find.descendant(of: segmented, matching: find.byType(Container)).first);
      expect((track.decoration! as BoxDecoration).color, palette.disabledSurface);
      expect(tester.widget<Text>(find.text('One')).style!.color, palette.textMuted);
      for (final finder in [selector, disabledSwitch, find.byType(AppCheckbox), find.text('Two')]) {
        await tester.tap(finder);
        await tester.pumpAndSettle();
      }
      expect(find.text('Inherited identity'), findsOneWidget, reason: 'a disabled selector never opens a popup');
      expect(changes, 0);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('disabled checked and destructive menu items use muted colors', (tester) async {
    final theme = buildTheme(Brightness.light);
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Scaffold(
          body: AppMenuButton<int>(
            tooltip: 'Actions',
            items: () => const [
              AppMenuItem(
                value: 1,
                label: 'Unavailable',
                enabled: false,
                checked: true,
                destructive: true,
                icon: Icons.delete,
              ),
              AppMenuItem(value: 2, label: 'Available'),
            ],
            onSelected: (_) {},
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('Actions'));
    await tester.pumpAndSettle();
    final muted = BrandPalette.fromTheme(theme).textMuted;
    expect(tester.widget<Text>(find.text('Unavailable')).style!.color, muted);
    expect(tester.widget<Icon>(find.byIcon(Icons.check)).color, muted);
    expect(tester.widget<Icon>(find.byIcon(Icons.delete)).color, muted);
    await tester.tap(find.text('Unavailable'));
    await tester.pumpAndSettle();
    expect(find.text('Unavailable'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('disabling a focused selector removes its accent border', (tester) async {
    var enabled = true;
    late StateSetter rebuild;
    final theme = buildTheme(Brightness.light);
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              return SizedBox(
                width: 220,
                child: AppSelect<int>(
                  value: 1,
                  options: const [AppOption(1, 'Identity')],
                  onChanged: enabled ? (_) {} : null,
                ),
              );
            },
          ),
        ),
      ),
    );
    final selector = find.byType(AppSelect<int>);
    final detector = find.descendant(of: selector, matching: find.byType(FocusableActionDetector));
    final gesture = find.descendant(of: detector, matching: find.byType(GestureDetector));
    Focus.of(tester.element(gesture.first)).requestFocus();
    await tester.pumpAndSettle();
    rebuild(() => enabled = false);
    await tester.pumpAndSettle();
    final field = tester.widget<AnimatedContainer>(
      find.descendant(of: selector, matching: find.byType(AnimatedContainer)),
    );
    final decoration = field.decoration! as BoxDecoration;
    expect(decoration.color, BrandPalette.fromTheme(theme).disabledSurface);
    expect((decoration.border! as Border).top, BorderSide(color: theme.colorScheme.outlineVariant));
    expect(tester.takeException(), isNull);
  });
}

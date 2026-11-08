import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/design/brand.dart';
import 'package:sshairy/design/menu.dart';
import 'package:sshairy/design/scrolling.dart';
import 'package:sshairy/design/select.dart';
import 'package:sshairy/design/theme.dart';
import 'package:sshairy/features/hosts/api.dart';
import 'package:sshairy/features/credentials/application/credential_access.dart' show secretStoreProvider;
import 'package:sshairy/features/hosts/presentation/move_hosts_dialog.dart';
import 'package:sshairy/features/settings/api.dart';
import 'package:sshairy/foundation/data_dir.dart';
import 'package:sshairy/foundation/ids.dart';
import 'package:sshairy/l10n/app_localizations.dart';

import 'keys_test.dart' show MemorySecrets;

void main() {
  late Directory data;
  late ProviderContainer container;
  late HostsNotifier hosts;
  final connected = <HostId>[];

  setUp(() {
    data = Directory.systemTemp.createTempSync('sshairy-vault-select-');
    container = ProviderContainer(
      overrides: [dataDirProvider.overrideWithValue(data.path), secretStoreProvider.overrideWithValue(MemorySecrets())],
    );
    hosts = container.read(hostsProvider.notifier);
    connected.clear();
  });

  tearDown(() async {
    container.dispose();
    await data.delete(recursive: true);
  });

  Future<void> mount(WidgetTester tester, {int count = 4, HostView view = HostView.grid}) async {
    await tester.runAsync(() async {
      await container.read(settingsProvider.notifier).set(SettingKeys.importOffered, true);
      await container.read(settingsProvider.notifier).set(SettingKeys.hostView, view);
      if (count > 0) {
        await hosts.addGroup('Personal');
        await hosts.addGroup('Team');
      }
      for (var i = 0; i < count; i++) {
        await hosts.save(
          Host(id: HostId('h$i'), label: 'host-$i', address: 'h$i.example', username: 'u', group: 'Personal'),
        );
      }
    });
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildTheme(Brightness.light)
              .copyWith(platform: TargetPlatform.windows, splashFactory: NoSplash.splashFactory),
          scrollBehavior: const AppScrollBehavior(),
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: VaultPage(active: true, onConnect: (host) => connected.add(host.id))),
        ),
      ),
    );
    await tester.pumpAndSettle();
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
  }

  Finder tile(int index) => find.byKey(ValueKey(HostId('h$index')));

  List<int> selected(WidgetTester tester) => [
    for (var i = 0; i < 4; i++)
      if (tester
          .widgetList<Semantics>(find.descendant(of: tile(i), matching: find.byType(Semantics)))
          .any((widget) => widget.properties.selected == true))
        i,
  ];

  Future<void> click(WidgetTester tester, int index, {LogicalKeyboardKey? modifier}) async {
    if (modifier != null) await tester.sendKeyDownEvent(modifier);
    await tester.tap(find.text('host-$index'));
    if (modifier != null) await tester.sendKeyUpEvent(modifier);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
  }

  Future<void> chooseGroup(WidgetTester tester, String group) async {
    await tester.tap(find.byType(AppSelect<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text(group).last);
    await tester.pumpAndSettle();
  }

  Future<void> move(WidgetTester tester) async {
    await tester.tap(find.widgetWithText(FilledButton, 'Move to group…'));
    for (var i = 0; i < 100 && find.byType(MoveHostsDialog).evaluate().isNotEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    await tester.pumpAndSettle();
    expect(find.byType(MoveHostsDialog), findsNothing);
  }

  testWidgets('multi-selection menus show only batch actions and delete asks once for the selected set', (
    tester,
  ) async {
    await mount(tester);
    await click(tester, 0);
    await click(tester, 1, modifier: LogicalKeyboardKey.controlLeft);
    await tester.tap(find.text('host-0'), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    expect(find.text('Move to group…'), findsOneWidget);
    expect(find.text('Delete'), findsOneWidget);
    for (final label in ['Edit', 'Duplicate', 'Pin', 'Unpin']) {
      expect(find.text(label), findsNothing);
    }
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(find.text('Delete the selected 2 hosts?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(container.read(hostsProvider), hasLength(4));
    expect(selected(tester), [0, 1]);
    await tester.tap(find.descendant(of: tile(0), matching: find.byTooltip('More')));
    await tester.pumpAndSettle();
    expect(find.text('Edit'), findsNothing);
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    for (var i = 0; i < 100 && container.read(hostsProvider).length == 4; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
    await tester.pumpAndSettle();
    expect(container.read(hostsProvider).map((h) => h.id.value), ['h2', 'h3']);
    expect(selected(tester), isEmpty);
  });

  testWidgets('single-host right click keeps single actions and targets only the clicked unselected host', (
    tester,
  ) async {
    await mount(tester);
    await click(tester, 0);
    await click(tester, 1, modifier: LogicalKeyboardKey.controlLeft);
    await tester.tap(find.text('host-3'), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    expect(selected(tester), [3]);
    expect(find.text('Edit'), findsOneWidget);
    expect(find.text('Duplicate'), findsOneWidget);
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(find.textContaining('host-3'), findsWidgets);
    expect(find.text('Delete the selected 2 hosts?'), findsNothing);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(container.read(hostsProvider), hasLength(4));
  });

  testWidgets('group chip dragging persists sibling order and keeps the selected group', (tester) async {
    await mount(tester);
    await tester.tap(find.widgetWithText(ChoiceChip, 'Personal'));
    await tester.pumpAndSettle();
    final source = tester.getCenter(find.byKey(const ValueKey('group-chip-Team')));
    final target = tester.getRect(find.byKey(const ValueKey('group-chip-Personal')));
    final gesture = await tester.startGesture(source);
    await gesture.moveBy(const Offset(-12, 0));
    await tester.pump();
    await gesture.moveTo(Offset(target.left + 3, target.center.dy));
    await tester.pump();
    await gesture.up();
    for (var i = 0; i < 100 && hosts.library.groupPaths.first != 'Team'; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    await tester.pumpAndSettle();
    expect(hosts.library.groupPaths, ['Team', 'Personal']);
    expect(tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Personal')).selected, isTrue);
    final reopened = ProviderContainer(overrides: [dataDirProvider.overrideWithValue(data.path)]);
    expect(reopened.read(hostLibraryProvider).groupPaths, ['Team', 'Personal']);
    reopened.dispose();

    final moved = tester.getCenter(find.byKey(const ValueKey('group-chip-Team')));
    final last = tester.getRect(find.byKey(const ValueKey('group-chip-Personal')));
    final reverse = await tester.startGesture(moved);
    await reverse.moveBy(const Offset(12, 0));
    await tester.pump();
    await reverse.moveTo(Offset(last.right - 3, last.center.dy));
    await tester.pump();
    await reverse.up();
    for (var i = 0; i < 100 && hosts.library.groupPaths.first != 'Personal'; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    await tester.pumpAndSettle();
    expect(hosts.library.groupPaths, ['Personal', 'Team']);
    expect(tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Personal')).selected, isTrue);
  });

  testWidgets('empty home keeps the pose and shows a short localized instruction below it', (tester) async {
    await mount(tester, count: 0);
    expect(find.byType(BrandEmptyState), findsOneWidget);
    expect(find.text('No hosts yet'), findsOneWidget);
    expect(find.text('Add a host or import saved connections to get started.'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('No hosts yet')).dy,
      greaterThan(tester.getRect(find.byType(AnimatedSwitcher).last).bottom),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('group chip has a four point icon gap and centered icon and label', (tester) async {
    await mount(tester);
    final chip = find.widgetWithText(ChoiceChip, 'Personal');
    final icon = find.descendant(of: chip, matching: find.byIcon(Icons.folder_outlined));
    final label = find.descendant(of: chip, matching: find.text('Personal'));
    expect(tester.widget<ChoiceChip>(chip).avatar, isNull);
    expect(tester.getRect(label).left - tester.getRect(icon).right, 4);
    expect(tester.getRect(label).center.dy, closeTo(tester.getRect(icon).center.dy, .1));
  });

  for (final view in HostView.values) {
    testWidgets('plain Ctrl Shift selection in ${view.name} persists across view changes', (tester) async {
      await mount(tester, view: view);
      await click(tester, 0);
      expect(selected(tester), [0]);
      await click(tester, 2, modifier: LogicalKeyboardKey.controlLeft);
      expect(selected(tester), [0, 2]);
      await click(tester, 3, modifier: LogicalKeyboardKey.shiftLeft);
      expect(selected(tester), [2, 3]);
      await click(tester, 2, modifier: LogicalKeyboardKey.controlLeft);
      expect(selected(tester), [3]);
      expect(connected, isEmpty);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(selected(tester), [2, 3]);
      await tester.tap(find.byTooltip(view == HostView.grid ? 'List' : 'Grid'));
      for (var i = 0; i < 100 && container.read(settingsProvider).get(SettingKeys.hostView) == view; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 20));
      }
      await tester.pumpAndSettle();
      expect(selected(tester), [2, 3]);
      await tester.enterText(find.byType(TextField).first, 'host-0');
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, '');
      await tester.pumpAndSettle();
      expect(selected(tester), isEmpty);
      expect(connected, isEmpty);
    });
  }

  testWidgets('right click keeps selected hosts and batch move preserves all other host fields', (tester) async {
    await mount(tester);
    await click(tester, 0);
    await click(tester, 1, modifier: LogicalKeyboardKey.controlLeft);
    await tester.tap(find.text('host-0'), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    expect(selected(tester), [0, 1]);
    await tester.tap(find.text('Move to group…'));
    await tester.pumpAndSettle();
    expect(find.text('Move 2 hosts to group'), findsOneWidget);
    await chooseGroup(tester, 'Team');
    await move(tester);
    expect(hosts.byId(const HostId('h0'))!.group, 'Team');
    expect(hosts.byId(const HostId('h1'))!.group, 'Team');
    expect(hosts.byId(const HostId('h2'))!.group, 'Personal');
    expect(hosts.byId(const HostId('h0'))!.address, 'h0.example');
    expect(hosts.byId(const HostId('h0'))!.username, 'u');
    expect(selected(tester), [0, 1]);
  });

  testWidgets('an unselected host menu targets one host and Cancel leaves its group alone', (tester) async {
    await mount(tester);
    await click(tester, 0);
    await click(tester, 1, modifier: LogicalKeyboardKey.controlLeft);
    await tester.tap(find.text('host-3'), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    expect(selected(tester), [3]);
    await tester.tap(find.text('Move to group…'));
    await tester.pumpAndSettle();
    expect(find.text('Move host to group'), findsOneWidget);
    await chooseGroup(tester, 'Team');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(hosts.byId(const HostId('h3'))!.group, 'Personal');
    expect(connected, isEmpty);
  });

  testWidgets('a stale move dialog retains the selected hosts and publishes no partial move', (tester) async {
    await mount(tester);
    await click(tester, 0);
    await click(tester, 1, modifier: LogicalKeyboardKey.controlLeft);
    await tester.tap(find.text('host-0'), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Move to group…'));
    await tester.pumpAndSettle();
    await chooseGroup(tester, 'Team');
    await tester.runAsync(() => hosts.setPinned(hosts.byId(const HostId('h0'))!, true));
    await tester.tap(find.widgetWithText(FilledButton, 'Move to group…'));
    for (
      var i = 0;
      i < 100 && find.text('Could not save. Check access to the data directory and secure storage.').evaluate().isEmpty;
      i++
    ) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    await tester.pumpAndSettle();
    expect(find.byType(MoveHostsDialog), findsOneWidget);
    expect(find.text('Could not save. Check access to the data directory and secure storage.'), findsOneWidget);
    expect(hosts.byId(const HostId('h0'))!.group, 'Personal');
    expect(hosts.byId(const HostId('h1'))!.group, 'Personal');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(selected(tester), [0, 1]);
  });

  testWidgets('Ctrl Shift unions ranges, visible select-all clears, and plain double click connects', (tester) async {
    await mount(tester);
    await click(tester, 0);
    await click(tester, 2, modifier: LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await click(tester, 3, modifier: LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    expect(selected(tester), [0, 2, 3]);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(selected(tester), [0, 1, 2, 3]);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(selected(tester), isEmpty);
    await tester.tap(find.text('host-1'));
    await tester.tap(find.text('host-1'));
    await tester.pump();
    expect(connected, [const HostId('h1')]);
  });

  testWidgets('toolbar and tile more menus move the selection including to no group', (tester) async {
    await mount(tester);
    await click(tester, 0);
    await click(tester, 1, modifier: LogicalKeyboardKey.controlLeft);
    final toolbar = find.byWidgetPredicate(
      (w) => w is AppMenuButton<VoidCallback> && w.icon is Icon && (w.icon as Icon).icon == Icons.tune_outlined,
    );
    await tester.tap(toolbar);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Move to group…'));
    await tester.pumpAndSettle();
    await chooseGroup(tester, 'No group');
    await move(tester);
    expect(hosts.byId(const HostId('h0'))!.group, '');
    expect(hosts.byId(const HostId('h1'))!.groupId, isNull);
    await tester.tap(find.descendant(of: tile(0), matching: find.byTooltip('More')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Move to group…'));
    await tester.pumpAndSettle();
    expect(find.text('Move 2 hosts to group'), findsOneWidget);
    await chooseGroup(tester, 'Team');
    await move(tester);
    expect(hosts.byId(const HostId('h0'))!.group, 'Team');
    expect(hosts.byId(const HostId('h1'))!.group, 'Team');
    expect(tester.takeException(), isNull);
  });
}

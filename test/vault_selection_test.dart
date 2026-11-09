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

  Finder groupChip(String path) => find.byKey(ValueKey('group-chip-$path'));

  void expectGroupCount(WidgetTester tester, String path, int count) {
    final number = find.descendant(of: groupChip(path), matching: find.text('$count'));
    final label = find.descendant(of: groupChip(path), matching: find.text(path.isEmpty ? 'All' : path));
    expect(number, findsOneWidget);
    expect(tester.getRect(number).left, greaterThan(tester.getRect(label).right));
  }

  testWidgets('group counts include all hosts, descendants and empty groups regardless of search', (tester) async {
    final semantics = tester.ensureSemantics();
    await mount(tester);
    await tester.runAsync(() async {
      await hosts.addGroup('Personal/Remote');
      await hosts.save(
        const Host(
          id: HostId('h4'),
          label: 'remote',
          address: 'remote.example',
          username: 'u',
          group: 'Personal/Remote',
        ),
      );
      await hosts.save(const Host(id: HostId('h5'), label: 'ungrouped', address: 'ungrouped.example', username: 'u'));
    });
    await tester.pumpAndSettle();
    expectGroupCount(tester, '', 6);
    expectGroupCount(tester, 'Personal', 5);
    expectGroupCount(tester, 'Personal/Remote', 1);
    expectGroupCount(tester, 'Team', 0);
    expect(tester.getSemantics(groupChip('Personal')).getSemanticsData().label, contains('5'));
    await tester.tap(groupChip('Personal'));
    await tester.pumpAndSettle();
    expect(tile(4), findsOneWidget);
    expect(tile(5), findsNothing);
    await tester.enterText(find.byType(TextField).first, 'host-0');
    await tester.pumpAndSettle();
    expect(tile(0), findsOneWidget);
    expect(tile(4), findsNothing);
    expectGroupCount(tester, '', 6);
    expectGroupCount(tester, 'Personal', 5);
    expectGroupCount(tester, 'Personal/Remote', 1);
    expectGroupCount(tester, 'Team', 0);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('group counts update after host creation, movement and deletion', (tester) async {
    await mount(tester, count: 0);
    await tester.runAsync(() async {
      await hosts.addGroup('Personal/Remote');
      await hosts.addGroup('Team');
    });
    await tester.pumpAndSettle();
    expectGroupCount(tester, '', 0);
    expectGroupCount(tester, 'Personal', 0);
    expectGroupCount(tester, 'Personal/Remote', 0);
    expectGroupCount(tester, 'Team', 0);
    await tester.runAsync(
      () => hosts.save(
        const Host(
          id: HostId('h0'),
          label: 'remote',
          address: 'remote.example',
          username: 'u',
          group: 'Personal/Remote',
        ),
      ),
    );
    await tester.pumpAndSettle();
    expectGroupCount(tester, '', 1);
    expectGroupCount(tester, 'Personal', 1);
    expectGroupCount(tester, 'Personal/Remote', 1);
    await tester.runAsync(() => hosts.moveToGroup([const HostId('h0')], hosts.library.groupIdFor('Team')));
    await tester.pumpAndSettle();
    expectGroupCount(tester, '', 1);
    expectGroupCount(tester, 'Personal', 0);
    expectGroupCount(tester, 'Personal/Remote', 0);
    expectGroupCount(tester, 'Team', 1);
    await tester.runAsync(() => hosts.deleteMany([const HostId('h0')]));
    await tester.pumpAndSettle();
    expectGroupCount(tester, '', 0);
    expectGroupCount(tester, 'Personal', 0);
    expectGroupCount(tester, 'Personal/Remote', 0);
    expectGroupCount(tester, 'Team', 0);
    expect(tester.takeException(), isNull);
  });

  Future<void> waitForOrder(WidgetTester tester, List<String> paths) async {
    for (var i = 0; i < 100 && hosts.library.groupPaths.join('|') != paths.join('|'); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    await tester.pumpAndSettle();
    expect(hosts.library.groupPaths, paths);
    expect(tester.takeException(), isNull);
  }

  testWidgets('group dragging shows the final gap before saving and keeps selection and the fixed All chip', (
    tester,
  ) async {
    await mount(tester);
    await click(tester, 0);
    await click(tester, 1, modifier: LogicalKeyboardKey.controlLeft);
    await tester.tap(groupChip('Personal'));
    await tester.pumpAndSettle();
    final all = tester.getRect(groupChip(''));
    final personal = tester.getRect(groupChip('Personal'));
    final team = tester.getRect(groupChip('Team'));
    final revision = hosts.revision;
    final gesture = await tester.startGesture(team.center, kind: PointerDeviceKind.mouse);
    await gesture.moveBy(const Offset(-24, 0));
    await tester.pump();
    await gesture.moveTo(personal.center);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(hosts.library.groupPaths, ['Personal', 'Team'], reason: 'dragging is only a preview');
    expect(hosts.revision, revision);
    expect(tester.getRect(groupChip('Personal')).left, greaterThan(personal.left + team.width / 2));
    expect(tester.getRect(groupChip('')), all);
    await gesture.up();
    await waitForOrder(tester, ['Team', 'Personal']);
    expect(hosts.revision, revision + 1, reason: 'one release makes one write');
    expect(tester.widget<ChoiceChip>(groupChip('Personal')).selected, isTrue);
    expect(selected(tester), [0, 1]);
    final reopened = ProviderContainer(overrides: [dataDirProvider.overrideWithValue(data.path)]);
    expect(reopened.read(hostLibraryProvider).groupPaths, ['Team', 'Personal']);
    reopened.dispose();

    final last = tester.getRect(groupChip('Personal'));
    final first = tester.getRect(groupChip('Team'));
    final reverse = await tester.startGesture(first.center, kind: PointerDeviceKind.mouse);
    await reverse.moveBy(const Offset(24, 0));
    await tester.pump();
    await reverse.moveTo(Offset(last.right + first.width / 2 + Space.md, last.center.dy));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.getRect(groupChip('Personal')).left, lessThan(last.left - first.width / 2));
    await reverse.up();
    await waitForOrder(tester, ['Personal', 'Team']);
    expect(tester.widget<ChoiceChip>(groupChip('Personal')).selected, isTrue);
    expect(selected(tester), [0, 1]);
    final fixed = await tester.startGesture(tester.getCenter(groupChip('')), kind: PointerDeviceKind.mouse);
    await fixed.moveBy(const Offset(180, 0));
    await fixed.up();
    await tester.pumpAndSettle();
    expect(hosts.library.groupPaths, ['Personal', 'Team']);
    expect(tester.getRect(groupChip('')), all);
  });

  testWidgets('parent dragging moves its children and nested dragging only reorders siblings', (tester) async {
    await mount(tester);
    await tester.runAsync(() async {
      await hosts.addGroup('Personal/Alpha');
      await hosts.addGroup('Personal/Beta');
      await hosts.addGroup('Team/Remote');
    });
    await tester.pumpAndSettle();
    final originalParents = {for (final group in hosts.library.groups) group.id: group.parentId};
    final personal = tester.getRect(groupChip('Personal'));
    final alpha = tester.getRect(groupChip('Personal/Alpha'));
    final betaEnd = tester.getRect(groupChip('Personal/Beta'));
    final team = tester.getRect(groupChip('Team'));
    final teamEnd = tester.getRect(groupChip('Team/Remote'));
    final parent = await tester.startGesture(personal.center, kind: PointerDeviceKind.mouse);
    await parent.moveBy(const Offset(24, 0));
    await tester.pump();
    final delta = teamEnd.center.dx - betaEnd.right;
    await parent.moveTo(personal.center + Offset(delta, 0));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.getRect(groupChip('Personal/Alpha')).left - alpha.left, closeTo(delta, .1));
    expect(tester.getRect(groupChip('Team')).left, lessThan(team.left));
    await parent.up();
    await waitForOrder(tester, ['Team', 'Team/Remote', 'Personal', 'Personal/Alpha', 'Personal/Beta']);

    await tester.tap(groupChip('Personal/Alpha'));
    await tester.pumpAndSettle();
    final beta = await tester.startGesture(tester.getCenter(groupChip('Personal/Beta')), kind: PointerDeviceKind.mouse);
    await beta.moveBy(const Offset(-24, 0));
    await tester.pump();
    await beta.moveTo(tester.getCenter(groupChip('Personal/Alpha')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await beta.up();
    await waitForOrder(tester, ['Team', 'Team/Remote', 'Personal', 'Personal/Beta', 'Personal/Alpha']);
    expect(tester.widget<ChoiceChip>(groupChip('Personal/Alpha')).selected, isTrue);
    expect({for (final group in hosts.library.groups) group.id: group.parentId}, originalParents);

    final unchanged = hosts.revision;
    final crossParent = await tester.startGesture(
      tester.getCenter(groupChip('Personal/Beta')),
      kind: PointerDeviceKind.mouse,
    );
    await crossParent.moveBy(const Offset(-24, 0));
    await tester.pump();
    await crossParent.moveTo(tester.getCenter(groupChip('Team/Remote')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await crossParent.up();
    await tester.pumpAndSettle();
    expect(hosts.revision, unchanged, reason: 'the first child stays first when dragged outside its siblings');
    expect({for (final group in hosts.library.groups) group.id: group.parentId}, originalParents);
    expect(tester.takeException(), isNull);
  });

  for (final nested in [false, true]) {
    testWidgets('group drag auto-scrolls an overflowing ${nested ? 'child' : 'root'} strip', (tester) async {
      await mount(tester, count: 0);
      final prefix = nested ? 'Personal/' : '';
      await tester.runAsync(() async {
        for (var i = 0; i < 16; i++) {
          await hosts.addGroup('${prefix}Group-${i.toString().padLeft(2, '0')}');
        }
      });
      await tester.binding.setSurfaceSize(const Size(960, 640));
      await tester.pumpAndSettle();
      final all = tester.getRect(groupChip(''));
      final source = '${prefix}Group-00';
      final scrollable = find.ancestor(of: groupChip(source), matching: find.byType(Scrollable)).first;
      final state = tester.state<ScrollableState>(scrollable);
      final bounds = tester.getRect(scrollable);
      expect(state.position.maxScrollExtent, greaterThan(0));
      final gesture = await tester.startGesture(tester.getCenter(groupChip(source)), kind: PointerDeviceKind.mouse);
      await gesture.moveBy(const Offset(24, 0));
      await tester.pump();
      await gesture.moveTo(Offset(bounds.right - 2, bounds.center.dy));
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(state.position.pixels, greaterThan(0));
      expect(tester.getRect(groupChip('')), all);
      await gesture.up();
      for (
        var i = 0;
        i < 100 &&
            hosts.library.groupChildren(nested ? hosts.library.groupIdFor('Personal') : null).first.name == 'Group-00';
        i++
      ) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 20));
      }
      await tester.pumpAndSettle();
      final siblings = hosts.library.groupChildren(nested ? hosts.library.groupIdFor('Personal') : null);
      expect(siblings.indexWhere((group) => group.name == 'Group-00'), greaterThan(0));
      expect(siblings, hasLength(16));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a changed library cancels the drag instead of saving stale group positions', (tester) async {
    await mount(tester);
    final gesture = await tester.startGesture(tester.getCenter(groupChip('Team')), kind: PointerDeviceKind.mouse);
    await gesture.moveBy(const Offset(-24, 0));
    await tester.pump();
    await gesture.moveTo(tester.getCenter(groupChip('Personal')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.runAsync(() => hosts.addGroup('Work'));
    await tester.pump();
    final revision = hosts.revision;
    await gesture.up();
    await tester.pumpAndSettle();
    expect(hosts.library.groupPaths, ['Personal', 'Team', 'Work']);
    expect(hosts.revision, revision);
    expect(find.text('Could not save. Check access to the data directory and secure storage.'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('group chips still filter on click and open the existing menu on right click', (tester) async {
    await mount(tester);
    await tester.tap(groupChip('Team'));
    await tester.pumpAndSettle();
    expect(tester.widget<ChoiceChip>(groupChip('Team')).selected, isTrue);
    expect(tile(0), findsNothing);
    final revision = hosts.revision;
    await tester.tap(groupChip('Personal'), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    expect(find.text('Edit group'), findsOneWidget);
    expect(find.text('Dissolve group'), findsOneWidget);
    expect(tester.widget<ChoiceChip>(groupChip('Team')).selected, isTrue);
    expect(hosts.revision, revision);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await tester.tap(groupChip(''));
    await tester.pumpAndSettle();
    expect(tile(0), findsOneWidget);
    expect(tester.takeException(), isNull);
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

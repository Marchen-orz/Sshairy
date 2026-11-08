import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/design/theme.dart';
import 'package:sshairy/design/scrolling.dart';
import 'package:sshairy/design/brand.dart';
import 'package:sshairy/design/icon_rail.dart';
import 'package:sshairy/design/dock_panel.dart';
import 'package:sshairy/design/popup.dart';
import 'package:sshairy/features/connections/api.dart';
import 'package:sshairy/features/hosts/api.dart';
import 'package:sshairy/features/monitor/api.dart';
import 'package:sshairy/features/settings/api.dart';
import 'package:sshairy/features/terminal/api.dart';
import 'package:sshairy/features/workspace/presentation/workspace_page.dart';
import 'package:sshairy/foundation/data_dir.dart';
import 'package:sshairy/foundation/ids.dart';
import 'package:sshairy/l10n/app_localizations.dart';

import 'connection_manager_test.dart' show FakeTransport;

const _hosts = [
  Host(id: HostId('web'), label: 'web-1', address: 'web.example', username: 'u', group: 'Prod/Web'),
  Host(id: HostId('db'), label: 'db-1', address: 'db.example', username: 'u', group: 'Prod'),
  Host(id: HostId('local'), label: 'local', address: 'localhost', username: 'u'),
];

class _Hosts extends HostsNotifier {
  @override
  List<Host> build() => _hosts;
}

class _ManyHosts extends HostsNotifier {
  @override
  List<Host> build() => [
    for (var i = 0; i < 40; i++) Host(id: HostId('h$i'), label: 'host-$i', address: 'h$i.example', username: 'u'),
  ];
}

class _TestAssets extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async => key == 'AssetManifest.bin'
      ? const StandardMessageCodec().encodeMessage(<String, Object?>{})!
      : ByteData.sublistView(File(key).readAsBytesSync());
}

/// Settings are written by real file IO, which fake time does not advance. The state changes once the write has
/// finished and released its lock; reading the file meanwhile would hold it open and fail the replace on Windows.
Future<void> _settled(WidgetTester tester, ProviderContainer container, bool Function(Settings) done) async {
  for (var i = 0; i < 400 && !done(container.read(settingsProvider)); i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(done(container.read(settingsProvider)), isTrue);
}

void main() {
  testWidgets('the icon rail keeps every page and panel at the minimum window size', (tester) async {
    final dir = Directory.systemTemp.createTempSync('sshairy-layout-');
    addTearDown(() => dir.deleteSync(recursive: true));
    await tester.binding.setSurfaceSize(const Size(1400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final container = ProviderContainer(
      overrides: [dataDirProvider.overrideWithValue(dir.path), hostsProvider.overrideWith(_Hosts.new)],
    );
    addTearDown(container.dispose);
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: DefaultAssetBundle(
          bundle: _TestAssets(),
          child: MaterialApp(
            scrollBehavior: const AppScrollBehavior(),
            theme: buildTheme(Brightness.light).copyWith(platform: TargetPlatform.windows),
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: WorkspacePage(openPalette: (_) async {}),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(BrandWatermark), findsOneWidget, reason: 'three hosts leave the lower page blank');
    for (final label in ['Hosts', 'SFTP', 'Keys', 'Proxy', 'Logs', 'Trusted host keys', 'Snippets', 'Settings']) {
      expect(find.byTooltip(label), findsOneWidget, reason: label);
    }
    expect(find.byTooltip('Server monitor'), findsNothing, reason: 'no terminal tab is open');
    await tester.binding.setSurfaceSize(const Size(800, 600));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Keys'), findsOneWidget);
    expect(find.byTooltip('New connection'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // Quick connect lists the library under the + button.
    await tester.tap(find.byTooltip('New connection'));
    await tester.pumpAndSettle();
    expect(find.text('web-1'), findsWidgets);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    // An empty flyout list shows a small translucent pose with its label.
    await tester.tap(find.byTooltip('Port forwarding'));
    await tester.pumpAndSettle();
    expect(find.byType(BrandHint), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    // New management panels use the same flyout and Escape path.
    for (final label in ['Proxy', 'Logs']) {
      await tester.tap(find.byTooltip(label));
      await tester.pumpAndSettle();
      expect(find.byType(PopupSurface), findsOneWidget, reason: label);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(PopupSurface), findsNothing, reason: label);
    }

    // Panels open as flyouts beside the rail and close with Escape.
    await tester.tap(find.byTooltip('Trusted host keys'));
    await tester.pumpAndSettle();
    final flyout = find.descendant(of: find.byType(PopupSurface), matching: find.text('Trusted host keys'));
    expect(flyout, findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(flyout, findsNothing);
    expect(tester.getSize(find.byType(IconRail)).width, WorkspaceSize.rail);
    expect(tester.getTopLeft(find.byType(BrandMark)).dy, greaterThanOrEqualTo(Space.xs));
    expect(tester.getTopLeft(find.byTooltip('New connection')).dy, greaterThanOrEqualTo(Space.xs));

    await tester.tap(find.byTooltip('Expand navigation'));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(IconRail)).width, WorkspaceSize.navigationExpanded);
    expect(find.text('Hosts'), findsOneWidget);
    expect(find.text('Trusted host keys'), findsOneWidget);
    expect(find.byType(BrandLogo), findsOneWidget);
    expect(tester.getTopLeft(find.byType(BrandLogo)).dy, greaterThanOrEqualTo(Space.sm));
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.byType(PopupSurface)).dx, WorkspaceSize.navigationExpanded + Space.xs);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    // The expanded navigation resizes from its divider: only a guide moves until release, within 176-320.
    double railWidth() => tester.getSize(find.byType(IconRail)).width;
    Offset divider() => Offset(railWidth() + WorkspaceSize.divider / 2, 400);
    final drag = await tester.startGesture(divider(), kind: PointerDeviceKind.mouse);
    await drag.moveBy(const Offset(60, 0));
    await drag.moveBy(const Offset(500, 0));
    await tester.pump();
    expect(railWidth(), WorkspaceSize.navigationExpanded, reason: 'the page does not reflow while dragging');
    await drag.up();
    await tester.pumpAndSettle();
    expect(railWidth(), WorkspaceSize.navigationMax);
    expect(tester.getTopLeft(find.byType(BrandLogo)).dx, greaterThanOrEqualTo(Space.lg));
    await tester.dragFrom(divider(), const Offset(-500, 0), kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    expect(railWidth(), WorkspaceSize.navigationMin);
    expect(tester.getSize(find.byType(BrandLogo)).width, lessThanOrEqualTo(WorkspaceSize.navigationMin - Space.lg * 2));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(railWidth(), WorkspaceSize.navigationMin + Space.xl, reason: 'the focused divider steps with arrow keys');
    // Width and expansion are remembered like the files dock.
    await _settled(
      tester,
      container,
      (s) => s.get(SettingKeys.navigationExpanded) && s.get(SettingKeys.navigationWidth) == railWidth(),
    );
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.byType(PopupSurface)).dx, railWidth() + Space.xs);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await tester.tapAt(divider(), kind: PointerDeviceKind.mouse);
    await tester.pump(kDoubleTapMinTime);
    await tester.tapAt(divider(), kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    expect(railWidth(), WorkspaceSize.navigationExpanded, reason: 'double-click restores the default');
    await tester.tap(find.byTooltip('Collapse navigation'));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(IconRail)).width, WorkspaceSize.rail);
    expect(find.byType(BrandMark), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _settled(
      tester,
      container,
      (s) =>
          !s.get(SettingKeys.navigationExpanded) &&
          s.get(SettingKeys.navigationWidth) == WorkspaceSize.navigationExpanded,
    );
    final saved = jsonDecode(File('${dir.path}/settings.json').readAsStringSync()) as Map<String, dynamic>;
    expect((saved['navigationExpanded'], saved['navigationWidth']), (false, WorkspaceSize.navigationExpanded));
  });

  testWidgets('the monitor panel resizes from its divider without rebuilding the page', (tester) async {
    final dir = Directory.systemTemp.createTempSync('sshairy-layout-');
    addTearDown(() => dir.deleteSync(recursive: true));
    // A saved tab comes back unconnected, which is all the monitor panel needs to show.
    File('${dir.path}/workspace.json').writeAsStringSync(
      jsonEncode({
        'schemaVersion': 1,
        'tabs': [
          {
            'layout': {
              'root': {'type': 'leaf', 'pane': 'p', 'session': 's'},
              'focused': 'p',
            },
            'hosts': {'s': 'web'},
          },
        ],
        'active': 0,
      }),
    );
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1400, 800);
    addTearDown(tester.view.reset);
    await tester.binding.setSurfaceSize(const Size(1400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final manager = ConnectionManager((_, _, _) async => FakeTransport(), park: Duration.zero);
    addTearDown(manager.closeAll);
    final container = ProviderContainer(
      overrides: [
        dataDirProvider.overrideWithValue(dir.path),
        hostsProvider.overrideWith(_Hosts.new),
        connectionManagerProvider.overrideWithValue(manager),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: DefaultAssetBundle(
          bundle: _TestAssets(),
          child: MaterialApp(
            scrollBehavior: const AppScrollBehavior(),
            theme: buildTheme(Brightness.light).copyWith(platform: TargetPlatform.windows),
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: WorkspacePage(openPalette: (_) async {}),
          ),
        ),
      ),
    );
    Future<void> settle() async {
      for (var i = 0; i < 3; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    await settle();

    double monitor() => tester.getSize(find.byType(MonitorPanel)).width;
    final handle = find.bySemanticsLabel('Resize monitor');
    expect(find.byType(TerminalPane), findsOneWidget);
    expect(monitor(), WorkspaceSize.monitor);
    final panel = tester.state(find.byType(MonitorPanel));
    final dock = tester.state(find.byType(DockPanel));
    final terminal = tester.element(find.byType(TerminalPane));
    void expectKept(String reason) {
      expect(identical(tester.state(find.byType(DockPanel)), dock), isTrue, reason: reason);
      expect(identical(tester.element(find.byType(TerminalPane)), terminal), isTrue, reason: reason);
    }

    // Only a guide moves until release, within 240-400.
    final drag = await tester.startGesture(tester.getCenter(handle), kind: PointerDeviceKind.mouse);
    await drag.moveBy(const Offset(60, 0));
    await drag.moveBy(const Offset(500, 0));
    await tester.pump();
    expect(monitor(), WorkspaceSize.monitor, reason: 'the page does not reflow while dragging');
    await drag.up();
    await tester.pump();
    expect(monitor(), WorkspaceSize.monitorMax);
    expect(identical(tester.state(find.byType(MonitorPanel)), panel), isTrue, reason: 'resizing keeps the panel');
    expectKept('resizing');
    await _settled(tester, container, (s) => s.get(SettingKeys.monitorWidth) == WorkspaceSize.monitorMax);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(monitor(), WorkspaceSize.monitorMax - Space.xl, reason: 'the focused divider steps with arrow keys');

    // Below 1200 px the panel is not shown, and it returns at the stored width.
    tester.view.physicalSize = const Size(1100, 800);
    await tester.binding.setSurfaceSize(const Size(1100, 800));
    await settle();
    expect(find.byType(MonitorPanel), findsNothing);
    expect(handle, findsNothing);
    expect(find.byTooltip('Server monitor'), findsNothing);
    expectKept('a narrow window');
    tester.view.physicalSize = const Size(1400, 800);
    await tester.binding.setSurfaceSize(const Size(1400, 800));
    await settle();
    expect(monitor(), WorkspaceSize.monitorMax - Space.xl);
    expectKept('a wide window');

    // The toggle hides it without losing the width.
    await tester.tap(find.byTooltip('Server monitor'));
    await _settled(tester, container, (s) => !s.get(SettingKeys.showMonitor));
    expect(find.byType(MonitorPanel), findsNothing);
    expectKept('the toggle');
    await tester.tap(find.byTooltip('Server monitor'));
    await _settled(tester, container, (s) => s.get(SettingKeys.showMonitor));
    expect(monitor(), WorkspaceSize.monitorMax - Space.xl);
    expectKept('the toggle');

    final at = tester.getCenter(handle);
    await tester.tapAt(at, kind: PointerDeviceKind.mouse);
    await tester.pump(kDoubleTapMinTime);
    await tester.tapAt(at, kind: PointerDeviceKind.mouse);
    await settle();
    expect(monitor(), WorkspaceSize.monitor, reason: 'double-click restores the default');
    await _settled(tester, container, (s) => s.get(SettingKeys.monitorWidth) == WorkspaceSize.monitor);
    final saved = jsonDecode(File('${dir.path}/settings.json').readAsStringSync()) as Map<String, dynamic>;
    expect((saved['monitorWidth'], saved['showMonitor']), (WorkspaceSize.monitor, true));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a full host library leaves no room for the watermark', (tester) async {
    final dir = Directory.systemTemp.createTempSync('sshairy-layout-');
    addTearDown(() => dir.deleteSync(recursive: true));
    await tester.binding.setSurfaceSize(const Size(1400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [dataDirProvider.overrideWithValue(dir.path), hostsProvider.overrideWith(_ManyHosts.new)],
        child: DefaultAssetBundle(
          bundle: _TestAssets(),
          child: MaterialApp(
            scrollBehavior: const AppScrollBehavior(),
            theme: buildTheme(Brightness.light).copyWith(platform: TargetPlatform.windows),
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: WorkspacePage(openPalette: (_) async {}),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('host-0'), findsOneWidget);
    expect(find.byType(BrandWatermark), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('host tree searches collapsed descendants and connects through its callback', (tester) async {
    Host? selected;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [hostsProvider.overrideWith(_Hosts.new)],
        child: MaterialApp(
          scrollBehavior: const AppScrollBehavior(),
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: SizedBox(width: 224, child: HostTree(onConnect: (h) => selected = h)),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Prod'), findsOneWidget);
    expect(find.text('Web'), findsOneWidget);
    expect(find.text('web-1'), findsOneWidget);
    await tester.tap(find.text('Prod'));
    await tester.pump();
    expect(find.text('web-1'), findsNothing);
    await tester.enterText(find.byType(TextField), 'web.example');
    await tester.pump();
    expect(find.text('web-1'), findsOneWidget);
    expect(find.text('db-1'), findsNothing);
    expect(find.text('local'), findsNothing);
    await tester.tap(find.text('web-1'));
    expect(selected?.id, const HostId('web'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('dock panel preserves editor state when moving over a narrow main view; Escape closes it', (
    tester,
  ) async {
    var open = true;
    var width = 1000.0;
    late StateSetter rebuild;
    const mainKey = ValueKey('main');
    await tester.pumpWidget(
      MaterialApp(
        scrollBehavior: const AppScrollBehavior(),
        theme: buildTheme(Brightness.light).copyWith(platform: TargetPlatform.windows),
        home: Scaffold(
          body: Center(
            child: StatefulBuilder(
              builder: (context, setState) {
                rebuild = setState;
                return SizedBox(
                  width: width,
                  height: 500,
                  child: DockPanel(
                    open: open,
                    onClose: () => setState(() => open = false),
                    closeLabel: 'Close panel',
                    resizeLabel: 'Resize panel',
                    panel: const TextField(),
                    child: const SizedBox(key: mainKey),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
    // The test's physical viewport must be larger than the requested logical width.
    await tester.binding.setSurfaceSize(const Size(1200, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byKey(mainKey)).width, 639);
    await tester.enterText(find.byType(TextField), 'unsent draft');
    rebuild(() => width = 780);
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byKey(mainKey)).width, 780);
    expect(find.text('unsent draft'), findsOneWidget);
    expect(find.descendant(of: find.byType(DockPanel), matching: find.byType(ModalBarrier)), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(open, isFalse);
    expect(find.byType(TextField), findsNothing);
    expect(tester.getSize(find.byKey(mainKey)).width, 780);
    expect(tester.takeException(), isNull);
  });

  testWidgets('dock panel commits a bounded width on release and supports keyboard resizing', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1600, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    const mainKey = ValueKey('main');
    await tester.pumpWidget(
      MaterialApp(
        scrollBehavior: const AppScrollBehavior(),
        theme: buildTheme(Brightness.dark).copyWith(platform: TargetPlatform.windows),
        home: Scaffold(
          body: DockPanel(
            open: true,
            onClose: () {},
            closeLabel: 'Close panel',
            resizeLabel: 'Resize panel',
            panel: const Text('files'),
            child: const SizedBox(key: mainKey),
          ),
        ),
      ),
    );
    final handle = find.bySemanticsLabel('Resize panel');
    expect(tester.getSize(find.byKey(mainKey)).width, 1239);
    final drag = await tester.startGesture(tester.getCenter(handle));
    await drag.moveBy(const Offset(-20, 0));
    await drag.moveBy(const Offset(-400, 0));
    await tester.pump();
    expect(tester.getSize(find.byKey(mainKey)).width, 1239, reason: 'dragging only paints a guide');
    await drag.up();
    await tester.pump();
    expect(tester.getSize(find.byKey(mainKey)).width, 1039, reason: '560 px maximum');
    await tester.tap(handle);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(tester.getSize(find.byKey(mainKey)).width, 1063);
    await tester.drag(handle, const Offset(500, 0));
    await tester.pump();
    expect(tester.getSize(find.byKey(mainKey)).width, 1299, reason: '300 px minimum');
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a bottom dock panel takes a bounded height', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    const mainKey = ValueKey('main');
    await tester.pumpWidget(
      MaterialApp(
        scrollBehavior: const AppScrollBehavior(),
        theme: buildTheme(Brightness.light).copyWith(platform: TargetPlatform.windows),
        home: Scaffold(
          body: DockPanel(
            open: true,
            side: DockSide.bottom,
            onClose: () {},
            closeLabel: 'Close panel',
            resizeLabel: 'Resize panel',
            panel: const Text('files'),
            child: const SizedBox(key: mainKey),
          ),
        ),
      ),
    );
    expect(tester.getSize(find.byKey(mainKey)).height, 439);
    await tester.drag(find.bySemanticsLabel('Resize panel'), const Offset(0, -600));
    await tester.pump();
    expect(tester.getSize(find.byKey(mainKey)).height, closeTo(279, 1), reason: '60 % of the height at most');
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.takeException(), isNull);
  });
}

import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/app/composition.dart';
import 'package:sshairy/design/theme.dart';
import 'package:sshairy/design/scrolling.dart';
import 'package:sshairy/design/brand.dart';
import 'package:sshairy/design/icon_rail.dart';
import 'package:sshairy/design/dock_panel.dart';
import 'package:sshairy/design/popup.dart';
import 'package:sshairy/design/dialog.dart';
import 'package:sshairy/features/connections/api.dart';
import 'package:sshairy/features/files/api.dart' show SideFilesPanel;
import 'package:sshairy/features/hosts/api.dart';
import 'package:sshairy/features/monitor/api.dart';
import 'package:sshairy/features/settings/api.dart';
import 'package:sshairy/features/terminal/api.dart';
import 'package:sshairy/features/workspace/api.dart' show workspaceProvider;
import 'package:sshairy/features/workspace/presentation/workspace_page.dart';
import 'package:sshairy/foundation/data_dir.dart';
import 'package:sshairy/foundation/file_system.dart';
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

/// A server with an empty home folder: the files panel has a connection to open and nothing to list.
class _Server extends FakeTransport {
  @override
  Future<FileSystem> openFiles() async => _Files();
}

class _Files implements FileSystem {
  @override
  PathStyle get style => PathStyle.posix;
  @override
  bool get canReplace => false;
  @override
  bool get canChmod => false;
  @override
  Future<String> home() async => '/home/u';
  @override
  Future<String> resolve(String path) async => path;
  @override
  Future<List<FileEntry>> list(String dir) async => const [];
  @override
  Future<void> close() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError('${invocation.memberName}');
}

/// Lets connects, rebuilds and the panels' first frames run; none of it needs real time.
Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// Disk writes started by tab changes and settings finish before the directory goes.
Future<void> _flush(WidgetTester tester, ProviderContainer container) async {
  var done = false;
  final saved = Future.wait([
    container.read(workspaceProvider.notifier).saved,
    container.read(settingsProvider.notifier).saved,
  ]).then((_) => done = true);
  for (var i = 0; i < 400 && !done; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(done, isTrue, reason: 'queued writes finish before disposing the workspace');
  await saved;
}

Map<String, dynamic> _savedSettings(Directory dir) =>
    jsonDecode(File('${dir.path}/settings.json').readAsStringSync()) as Map<String, dynamic>;

Map<String, Object?> _savedTab(String pane, String session, String host) => {
  'layout': {
    'root': {'type': 'leaf', 'pane': pane, 'session': session},
    'focused': pane,
  },
  'hosts': {session: host},
};

/// The workspace over [dir], wide enough for the monitor, with a server that records the address of every dial and
/// refuses authentication for the addresses left in [refused].
Future<ProviderContainer> _mountWorkspace(
  WidgetTester tester,
  Directory dir,
  List<String> dials, {
  Set<String> refused = const {},
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1400, 800);
  addTearDown(tester.view.reset);
  final manager = ConnectionManager((host, _, _) async {
    dials.add(host.address);
    if (refused.contains(host.address)) throw const ConnectError(ConnectFailure.auth);
    return _Server();
  }, park: Duration.zero);
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
  return container;
}

void main() {
  testWidgets('split headers put close at the pane edge and file docking menu stays compact with position icons', (
    tester,
  ) async {
    final dir = Directory.systemTemp.createTempSync('sshairy-pane-header-');
    File('${dir.path}/workspace.json').writeAsStringSync(
      jsonEncode({
        'schemaVersion': 1,
        'tabs': [
          {
            'layout': {
              'root': {
                'type': 'split',
                'axis': 'vertical',
                'ratios': [.5, .5],
                'children': [
                  {'type': 'leaf', 'pane': 'p1', 'session': 's1'},
                  {'type': 'leaf', 'pane': 'p2', 'session': 's2'},
                ],
              },
              'focused': 'p1',
            },
            'hosts': {'s1': 'web', 's2': 'web'},
          },
        ],
        'active': 0,
      }),
    );
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1400, 800);
    addTearDown(tester.view.reset);
    final manager = ConnectionManager((_, _, _) async => _Server(), park: Duration.zero);
    final container = ProviderContainer(
      overrides: [
        dataDirProvider.overrideWithValue(dir.path),
        hostsProvider.overrideWith(_Hosts.new),
        connectionManagerProvider.overrideWithValue(manager),
      ],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: DefaultAssetBundle(
          bundle: _TestAssets(),
          child: MaterialApp(
            theme: buildTheme(Brightness.light).copyWith(platform: TargetPlatform.windows),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: WorkspacePage(openPalette: (_) async {}),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final panes = find.byType(TerminalPane);
    expect(panes, findsNWidgets(2));
    final close = find.byTooltip('Close pane');
    expect(close, findsNWidgets(2));
    for (var i = 0; i < 2; i++) {
      expect(tester.getRect(close.at(i)).right, closeTo(tester.getRect(panes.at(i)).right, 5));
    }
    // The files panel waits for its terminal, which a restored tab only starts on request.
    await tester.tap(find.descendant(of: panes, matching: find.text('Connect')).first);
    await _frames(tester);
    await tester.tap(find.byTooltip('Files'));
    await _settled(tester, container, (s) => s.get(SettingKeys.showFiles));
    await _frames(tester);
    await tester.tap(find.byTooltip('Dock position'));
    await _frames(tester);
    expect(find.byType(DockSideIcon), findsNWidgets(3));
    expect(tester.getSize(find.byType(PopupSurface).last).width, lessThan(170));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await _frames(tester);
    await _flush(tester, container);
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
    manager.closeAll();
    dir.deleteSync(recursive: true);
  });

  testWidgets('the icon rail keeps every page and panel at the minimum window size', (tester) async {
    final dir = Directory.systemTemp.createTempSync('sshairy-layout-');
    addTearDown(() => dir.deleteSync(recursive: true));
    await tester.binding.setSurfaceSize(const Size(1400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final container = ProviderContainer(
      overrides: [
        ...appOverrides(),
        dataDirProvider.overrideWithValue(dir.path),
        hostsProvider.overrideWith(_Hosts.new),
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
    await tester.pumpAndSettle();
    expect(find.byType(BrandWatermark), findsOneWidget, reason: 'three hosts leave the lower page blank');
    for (final label in ['Hosts', 'SFTP', 'Keys', 'Proxy', 'Logs', 'Host keys', 'Snippets', 'Settings']) {
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
    await tester.tap(find.byTooltip('Host keys'));
    await tester.pumpAndSettle();
    final flyout = find.descendant(of: find.byType(PopupSurface), matching: find.text('Trusted host keys'));
    expect(flyout, findsOneWidget);
    expect(find.byTooltip('Import known_hosts'), findsOneWidget);
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
    expect(find.text('Host keys'), findsOneWidget);
    expect(find.byType(BrandLogo), findsOneWidget);
    expect(tester.getTopLeft(find.byType(BrandLogo)).dy, greaterThanOrEqualTo(Space.sm));
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    expect(find.byType(AppDialog), findsOneWidget);
    expect(tester.getCenter(find.byType(PopupSurface)).dx, 400);
    final sections = container.read(settingsSectionsProvider);
    expect(sections, hasLength(1));
    final settingsContext = tester.element(find.byType(SettingsPanel));
    expect(sections.single.title(AppLocalizations.of(settingsContext)), 'Translation service');
    expect(sections.single.build(settingsContext), isA<TranslationSettings>());
    expect(find.text('Trusted host keys'), findsNothing);
    expect(find.byTooltip('Import known_hosts'), findsNothing);
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
    expect(find.byType(AppDialog), findsOneWidget);
    expect(tester.getCenter(find.byType(PopupSurface)).dx, 400);
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

  testWidgets('the files switch is saved and shared by every tab; a restored tab does not dial for it', (tester) async {
    final dir = Directory.systemTemp.createTempSync('sshairy-files-switch-');
    addTearDown(() => dir.deleteSync(recursive: true));
    File('${dir.path}/settings.json').writeAsStringSync(
      jsonEncode({'schemaVersion': 1, 'showFiles': true, 'filesDock': 'left', 'monitorWidth': 320.0}),
    );
    File('${dir.path}/workspace.json').writeAsStringSync(
      jsonEncode({
        'schemaVersion': 1,
        'tabs': [_savedTab('p1', 's1', 'web'), _savedTab('p2', 's2', 'db')],
        'active': 0,
      }),
    );
    final dials = <String>[];
    final container = await _mountWorkspace(tester, dir, dials);
    final workspace = container.read(workspaceProvider.notifier);
    final panels = find.byType(SideFilesPanel);
    List<String> active() => [
      for (final p in tester.widgetList<SideFilesPanel>(panels))
        if (p.active) p.host.label,
    ];
    void show(int tab) => workspace.activate(container.read(workspaceProvider).tabs[tab].id);
    Future<void> connect() async {
      await tester.tap(find.descendant(of: find.byType(TerminalPane), matching: find.text('Connect')).first);
      await _frames(tester);
    }

    // The switch was left on, but a restored tab is unconnected and the panel would dial.
    await _frames(tester);
    expect(container.read(settingsProvider).get(SettingKeys.showFiles), isTrue);
    expect(panels, findsNothing);
    expect(dials, isEmpty);

    await connect();
    expect(dials, ['web.example']);
    expect(active(), ['web-1']);
    expect(panels, findsOneWidget, reason: 'the second tab has not started');

    show(1);
    await _frames(tester);
    expect(dials, ['web.example'], reason: 'showing a restored tab connects nothing');
    expect(panels, findsOneWidget);
    await connect();
    expect(dials, ['web.example', 'db.example']);
    expect(panels, findsNWidgets(2));
    expect(active(), ['db-1']);

    show(0);
    await _frames(tester);
    expect(active(), ['web-1']);
    expect(dials, hasLength(2), reason: 'the panel uses the terminal connection');

    // Closing from the panel is saved for every tab and leaves the dock side and widths alone.
    await tester.tap(find.byTooltip('Close pane').first);
    await _settled(tester, container, (s) => !s.get(SettingKeys.showFiles));
    await _frames(tester);
    expect(panels, findsNothing);
    final saved = _savedSettings(dir);
    expect((saved['showFiles'], saved['filesDock'], saved['monitorWidth']), (false, 'left', 320.0));

    await tester.tap(find.byTooltip('Files'));
    await _settled(tester, container, (s) => s.get(SettingKeys.showFiles));
    await _frames(tester);
    expect(panels, findsNWidgets(2));
    expect(active(), ['web-1']);
    expect(dials, hasLength(2), reason: 'reopening reuses the connections');

    // A window too narrow for both covers the terminal; the scrim closes the panel like the button does.
    tester.view.physicalSize = const Size(800, 600);
    await _frames(tester);
    final scrims = find.descendant(of: find.byType(DockPanel), matching: find.byType(ModalBarrier));
    expect(scrims, findsNWidgets(2));
    await tester.tapAt(const Offset(700, 300));
    await _settled(tester, container, (s) => !s.get(SettingKeys.showFiles));
    await _frames(tester);
    expect(panels, findsNothing);
    expect(scrims, findsNothing);
    expect(_savedSettings(dir)['showFiles'], isFalse);

    await _flush(tester, container);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a tab opened later shows the files panel as it was left, open or closed', (tester) async {
    final dir = Directory.systemTemp.createTempSync('sshairy-files-switch-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final dials = <String>[];
    final container = await _mountWorkspace(tester, dir, dials);
    final workspace = container.read(workspaceProvider.notifier);
    final panels = find.byType(SideFilesPanel);
    List<String> active() => [
      for (final p in tester.widgetList<SideFilesPanel>(panels))
        if (p.active) p.host.label,
    ];
    // Quick-connect hosts are not saved, so opening them writes nothing but the workspace.
    const quick = [
      Host(id: HostId(''), label: 'web-1', address: 'web.example', username: 'u'),
      Host(id: HostId(''), label: 'db-1', address: 'db.example', username: 'u'),
      Host(id: HostId(''), label: 'local', address: 'localhost', username: 'u'),
    ];

    workspace.openHost(quick[0]);
    await _frames(tester);
    expect(dials, ['web.example']);
    expect(panels, findsNothing, reason: 'closed until someone opens it');

    await tester.tap(find.byTooltip('Files'));
    await _settled(tester, container, (s) => s.get(SettingKeys.showFiles));
    await _frames(tester);
    expect(active(), ['web-1']);
    expect(dials, ['web.example'], reason: 'the panel uses the terminal connection');

    workspace.openHost(quick[1]);
    await _frames(tester);
    expect(active(), ['db-1']);
    expect(panels, findsNWidgets(2));
    expect(dials, ['web.example', 'db.example']);

    await tester.tap(find.byTooltip('Files'));
    await _settled(tester, container, (s) => !s.get(SettingKeys.showFiles));
    await _frames(tester);
    expect(panels, findsNothing);

    workspace.openHost(quick[2]);
    await _frames(tester);
    expect(dials, ['web.example', 'db.example', 'localhost']);
    expect(panels, findsNothing, reason: 'closed stays closed for the next tab');
    expect(_savedSettings(dir)['showFiles'], isFalse);

    await _flush(tester, container);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a refused terminal connection shows no files panel and makes no second dial until it succeeds', (
    tester,
  ) async {
    final dir = Directory.systemTemp.createTempSync('sshairy-files-refused-');
    addTearDown(() => dir.deleteSync(recursive: true));
    File('${dir.path}/settings.json').writeAsStringSync(jsonEncode({'schemaVersion': 1, 'showFiles': true}));
    File('${dir.path}/workspace.json').writeAsStringSync(
      jsonEncode({
        'schemaVersion': 1,
        'tabs': [_savedTab('p1', 's1', 'web')],
        'active': 0,
      }),
    );
    final dials = <String>[];
    final refused = {'web.example'};
    final container = await _mountWorkspace(tester, dir, dials, refused: refused);
    final panels = find.byType(SideFilesPanel);
    Future<void> press(String label) async {
      await tester.tap(find.descendant(of: find.byType(TerminalPane), matching: find.text(label)).first);
      await _frames(tester);
    }

    await _frames(tester);
    expect(panels, findsNothing, reason: 'restored and unconnected');
    expect(dials, isEmpty);

    await press('Connect');
    await _frames(tester);
    expect(dials, ['web.example']);
    expect(find.text('Reconnect'), findsOneWidget, reason: 'the terminal failed');
    expect(panels, findsNothing, reason: 'a refused session is not dialed again for the panel');
    expect(container.read(settingsProvider).get(SettingKeys.showFiles), isTrue, reason: 'the switch is left alone');

    refused.clear();
    await press('Reconnect');
    expect(dials, ['web.example', 'web.example']);
    expect(panels, findsOneWidget);
    expect(tester.widget<SideFilesPanel>(panels).active, isTrue);

    await _flush(tester, container);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the tab menu closes the tabs beside the clicked one and disables an empty side', (tester) async {
    final dir = Directory.systemTemp.createTempSync('sshairy-tab-menu-');
    addTearDown(() => dir.deleteSync(recursive: true));
    File('${dir.path}/workspace.json').writeAsStringSync(
      jsonEncode({
        'schemaVersion': 1,
        'tabs': [_savedTab('p1', 's1', 'web'), _savedTab('p2', 's2', 'db'), _savedTab('p3', 's3', 'local')],
        'active': 0,
      }),
    );
    final container = await _mountWorkspace(tester, dir, []);
    final workspace = container.read(workspaceProvider.notifier);
    List<String> open() => [
      for (final t in container.read(workspaceProvider).tabs)
        workspace.session(t.layout.focusedLeaf.session)!.host.label,
    ];
    Future<void> menu(String tab) async {
      final title = find.descendant(of: find.byType(ReorderableListView), matching: find.text(tab));
      await tester.tap(title, buttons: kSecondaryButton);
      await _frames(tester);
    }

    Future<void> choose(String item) async {
      await tester.tap(find.text(item));
      await _frames(tester);
    }

    await _frames(tester);
    expect(open(), ['web-1', 'db-1', 'local']);

    await menu('web-1');
    await choose('Close tabs to the left');
    expect(open(), hasLength(3), reason: 'nothing is left of the first tab');
    expect(find.text('Close other tabs'), findsOneWidget, reason: 'a disabled entry leaves the menu open');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await _frames(tester);

    await menu('db-1');
    await choose('Close tabs to the right');
    expect(open(), ['web-1', 'db-1']);

    await menu('db-1');
    await choose('Close tabs to the right');
    expect(open(), ['web-1', 'db-1'], reason: 'nothing is right of the last tab');
    await choose('Close tabs to the left');
    expect(open(), ['db-1']);

    await menu('db-1');
    await choose('Close other tabs');
    expect(open(), ['db-1'], reason: 'a lone tab has no others');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await _frames(tester);

    await _flush(tester, container);
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

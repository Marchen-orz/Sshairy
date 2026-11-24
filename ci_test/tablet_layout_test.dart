import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/app/composition.dart';
import 'package:sshairy/design/theme.dart';
import 'package:sshairy/features/connections/api.dart';
import 'package:sshairy/features/credentials/api.dart';
import 'package:sshairy/features/hosts/api.dart';
import 'package:sshairy/features/link/api.dart';
import 'package:sshairy/features/settings/api.dart';
import 'package:sshairy/features/terminal/api.dart';
import 'package:sshairy/features/workspace/api.dart';
import 'package:sshairy/foundation/data_dir.dart';
import 'package:sshairy/foundation/ids.dart';
import 'package:sshairy/foundation/secret.dart';
import 'package:sshairy/l10n/app_localizations.dart';
import 'package:sshairy/platform/device_form_factor.dart';

class _TestLinkCredentials implements LinkCredentials {
  Secret? _seed;

  @override
  Future<Secret?> readIdentity() async => _seed;

  @override
  Future<void> saveIdentity(Secret seed) async => _seed = seed;

  @override
  Future<void> clearIdentity() async => _seed = null;
}

class _TestShellChannel implements ShellChannel {
  final _done = Completer<void>();

  @override
  Stream<Uint8List> get stdout => const Stream.empty();

  @override
  Stream<Uint8List> get stderr => const Stream.empty();

  @override
  Future<void> get done => _done.future;

  @override
  void write(Uint8List data) {}

  @override
  void resize(int cols, int rows) {}

  @override
  void close() {
    if (!_done.isCompleted) _done.complete();
  }
}

class _NoLanScanLinkClient extends LinkClientController {
  _NoLanScanLinkClient({required super.credentials, required super.store, required super.bridge});

  @override
  Future<void> discoverLan() async {}
}

class _FakeDiscoveredLinkClient extends LinkClientController {
  _FakeDiscoveredLinkClient({
    required super.credentials,
    required super.store,
    required super.bridge,
    required List<DiscoveredDesktop> discovered,
  }) : _fakeDiscovered = discovered;

  final List<DiscoveredDesktop> _fakeDiscovered;
  ({String host, int port, String code})? lastPairCall;

  @override
  List<DiscoveredDesktop> get discoveredDesktops => _fakeDiscovered;

  @override
  Future<bool> pair({
    required String host,
    required int port,
    required String pairingCode,
    String? expectedPublicKey,
    String? deviceName,
  }) async {
    lastPairCall = (host: host, port: port, code: pairingCode);
    return true;
  }
}

({Directory dir, ProviderContainer container}) _createEnv(String prefix) {
  final dir = Directory.systemTemp.createTempSync(prefix);
  File('${dir.path}/settings.json').writeAsStringSync(
    jsonEncode({
      'schemaVersion': 1,
      'values': {'importOffered': true},
    }),
  );
  final container = ProviderContainer(
    overrides: [
      ...appOverrides(),
      dataDirProvider.overrideWithValue(dir.path),
      linkCredentialsProvider.overrideWithValue(_TestLinkCredentials()),
      linkClientControllerProvider.overrideWith((ref) {
        final controller = _NoLanScanLinkClient(
          credentials: ref.read(linkCredentialsProvider),
          store: LinkPeerStore('${ref.read(dataDirProvider)}/link_client'),
          bridge: ref.read(linkMobileBridgeProvider),
        );
        ref.onDispose(controller.dispose);
        return controller;
      }),
    ],
  );
  return (dir: dir, container: container);
}

Widget _wrapApp(Widget child, {required ProviderContainer container}) => UncontrolledProviderScope(
  container: container,
  child: MaterialApp(
    theme: buildTheme(Brightness.light, Accent.blue, 14, null, null),
    locale: const Locale('en'),
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    supportedLocales: AppLocalizations.supportedLocales,
    home: child,
  ),
);

void main() {
  for (final (label, size) in [('landscape', const Size(1280, 800)), ('portrait', const Size(800, 1280))]) {
    testWidgets('Android tablet ($label) uses MobileWorkspace with safe area, 2-column hosts, Link tab, and keybar', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      tester.view.padding = const FakeViewPadding(top: 32, bottom: 24);
      addTearDown(tester.view.reset);

      final env = _createEnv('sshairy_tablet_${label}_test_');
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        env.container.dispose();
        await tester.runAsync(() async {
          try {
            if (env.dir.existsSync()) env.dir.deleteSync(recursive: true);
          } on FileSystemException {
            // Windows may briefly hold a file handle during async teardown.
          }
        });
      });

      await tester.runAsync(() async {
        await env.container
            .read(hostsProvider.notifier)
            .save(const Host(id: HostId('h1'), label: 'Alpha Node', address: '10.0.0.1', username: 'root'));
        await env.container
            .read(hostsProvider.notifier)
            .save(const Host(id: HostId('h2'), label: 'Beta Node', address: '10.0.0.2', username: 'root'));
        await env.container
            .read(hostsProvider.notifier)
            .save(const Host(id: HostId('h3'), label: 'Gamma Node', address: '10.0.0.3', username: 'root'));
      });

      await tester.pumpWidget(_wrapApp(WorkspacePage(openPalette: (_) async {}), container: env.container));
      await tester.pumpAndSettle();

      // The tablet terminal keeps its file panel docked below unless it is closed (docs/MOBILE.md §3.2.1).
      expect(env.container.read(settingsProvider).get(SettingKeys.mobileTabletFilesOpen), isTrue);

      final workspaceFinder = find.byKey(const ValueKey('mobile-workspace'));
      expect(workspaceFinder, findsOneWidget);
      final useRail = size.width >= MobileSize.railBreakpoint;
      final navFinder = find.byKey(ValueKey(useRail ? 'mobile-nav-rail' : 'mobile-bottom-nav'));
      expect(navFinder, findsOneWidget);

      final wsContext = tester.element(workspaceFinder);
      expect(isCompactWorkspace(wsContext), isTrue);
      expect(isTabletWorkspace(wsContext), isTrue);
      expect(isPhoneWorkspace(wsContext), isFalse);

      // Top status bar safe area is respected.
      final hostsTabRect = tester.getRect(find.byKey(const ValueKey('mobile-hosts-tab')));
      expect(hostsTabRect.top, greaterThanOrEqualTo(32));

      // Hosts render in a 3-column grid on landscape tablets and 2-column grid on portrait tablets.
      final firstHost = tester.getRect(find.byKey(const ValueKey('mobile-host-h1')));
      final secondHost = tester.getRect(find.byKey(const ValueKey('mobile-host-h2')));
      final thirdHost = tester.getRect(find.byKey(const ValueKey('mobile-host-h3')));
      expect(firstHost.top, closeTo(secondHost.top, 0.5));
      expect(secondHost.left, greaterThan(firstHost.right));
      if (useRail) {
        expect(firstHost.top, closeTo(thirdHost.top, 0.5));
        expect(thirdHost.left, greaterThan(secondHost.right));
      } else {
        expect(thirdHost.top, greaterThan(firstHost.bottom));
      }

      // Link tab shows desktop-like 2-column layout on landscape tablets and centered 1-column on portrait tablets.
      await tester.tap(find.descendant(of: navFinder, matching: find.byIcon(Icons.phonelink_outlined)));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('mobile-link-disconnected')), findsOneWidget);
      expect(find.byKey(const ValueKey('link-scan-qr-button')), findsOneWidget);
      expect(find.byKey(const ValueKey('link-pair-submit')), findsOneWidget);
      final qrRect = tester.getRect(find.byKey(const ValueKey('link-scan-qr-button')));
      final manualHostRect = tester.getRect(find.byKey(const ValueKey('link-manual-host')));
      if (useRail) {
        expect(manualHostRect.left, greaterThan(qrRect.right));
      } else {
        expect(qrRect.width, lessThanOrEqualTo(MobileSize.contentMaxWidth + 0.5));
      }

      // Airy and Me tabs switch cleanly on tablet without overflow.
      await tester.tap(find.descendant(of: navFinder, matching: find.byIcon(Icons.auto_awesome_outlined)));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('mobile-airy-tab')), findsOneWidget);

      await tester.tap(find.descendant(of: navFinder, matching: find.byIcon(Icons.person_outline_rounded)));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('mobile-me-tab')), findsOneWidget);

      // Opening a session shows the floating session capsule and enters the mobile terminal with keybar + safe area.
      final shell = _TestShellChannel();
      env.container
          .read(workspaceProvider.notifier)
          .openRemote(
            const LinkTerminalTarget(
              peerId: 'desktop',
              peerName: 'PC',
              remoteId: 'server',
              title: 'Alpha Node',
              targetLabel: 'PC / Alpha Node',
              kind: LinkTerminalKind.proxy,
            ),
            (_, _) async => shell,
          );
      await tester.pumpAndSettle();

      final capsule = find.byKey(const ValueKey('mobile-session-capsule'));
      expect(capsule, findsOneWidget);
      expect(tester.getRect(capsule).width, lessThanOrEqualTo(MobileSize.wideContentMaxWidth + 0.5));

      await tester.tap(capsule);
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('mobile-terminal-screen')), findsOneWidget);
      final backRect = tester.getRect(find.byKey(const ValueKey('mobile-terminal-back')));
      expect(backRect.top, greaterThanOrEqualTo(32));
      expect(find.byKey(const ValueKey('touch-key-ctrl')), findsOneWidget);
      expect(find.byKey(const ValueKey('mobile-draft-toggle')), findsOneWidget);

      if (useRail) {
        expect(find.byKey(const ValueKey('tablet-terminal-tab-strip')), findsOneWidget);
        expect(find.byKey(const ValueKey('tablet-terminal-add-tab')), findsOneWidget);

        // Open a second session and verify both tabs appear in the top tab bar and can be switched.
        final secondShell = _TestShellChannel();
        env.container
            .read(workspaceProvider.notifier)
            .openRemote(
              const LinkTerminalTarget(
                peerId: 'desktop',
                peerName: 'PC',
                remoteId: 'server-2',
                title: 'Beta Node',
                targetLabel: 'PC / Beta Node',
                kind: LinkTerminalKind.proxy,
              ),
              (_, _) async => secondShell,
            );
        await tester.pumpAndSettle();
        final tabs = env.container.read(workspaceProvider).tabs;
        expect(tabs.length, 2);
        expect(find.byKey(ValueKey('tablet-tab-${tabs[0].id.value}')), findsOneWidget);
        expect(find.byKey(ValueKey('tablet-tab-${tabs[1].id.value}')), findsOneWidget);

        await tester.tap(find.byKey(ValueKey('tablet-tab-${tabs[0].id.value}')));
        await tester.pumpAndSettle();
        expect(env.container.read(workspaceProvider).active, tabs[0].id);

        // Dock Airy and Snippets side panels on landscape tablet.
        await tester.tap(find.byKey(const ValueKey('mobile-terminal-airy')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('tablet-side-airy')), findsOneWidget);

        // The side panel resizes from its divider like the desktop dock.
        final airy = find.byKey(const ValueKey('tablet-side-airy'));
        final airyWidth = tester.getRect(airy).width;
        final resizeHandle = find.byWidgetPredicate(
          (widget) =>
              widget is Semantics && widget.properties.label == lookupAppLocalizations(const Locale('en')).aiAgentTitle,
        );
        expect(resizeHandle, findsOneWidget);
        await tester.drag(resizeHandle, const Offset(-80, 0));
        await tester.pumpAndSettle();
        expect(tester.getRect(airy).width, greaterThan(airyWidth));

        await tester.tap(find.byKey(const ValueKey('tablet-terminal-snippets')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('tablet-side-snippets')), findsOneWidget);
        expect(find.byKey(const ValueKey('tablet-side-airy')), findsNothing);

        await tester.tap(find.byKey(const ValueKey('tablet-terminal-snippets')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('tablet-side-snippets')), findsNothing);
      } else {
        expect(find.byKey(const ValueKey('tablet-terminal-tab-strip')), findsNothing);
      }

      expect(tester.takeException(), isNull);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  }

  testWidgets('Windows stays on desktop workspace even at narrow width', (tester) async {
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final env = _createEnv('sshairy_windows_narrow_test_');
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      env.container.dispose();
      await tester.runAsync(() async {
        try {
          if (env.dir.existsSync()) env.dir.deleteSync(recursive: true);
        } on FileSystemException {
          // Windows may briefly hold a file handle during async teardown.
        }
      });
    });

    await tester.pumpWidget(_wrapApp(WorkspacePage(openPalette: (_) async {}), container: env.container));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('mobile-workspace')), findsNothing);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('Tapping an unpaired discovered LAN desktop prompts for pairing code and pairs', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final dir = Directory.systemTemp.createTempSync('sshairy_link_discovered_test_');
    final creds = _TestLinkCredentials();
    final store = LinkPeerStore('${dir.path}/peers.json');
    final baseContainer = ProviderContainer(
      overrides: [
        ...appOverrides(),
        dataDirProvider.overrideWithValue(dir.path),
        linkCredentialsProvider.overrideWithValue(creds),
      ],
    );
    final fakeClient = _FakeDiscoveredLinkClient(
      credentials: creds,
      store: store,
      bridge: baseContainer.read(linkMobileBridgeProvider),
      discovered: [
        DiscoveredDesktop(
          deviceId: 'pc-1',
          name: 'Office PC',
          address: '192.168.31.10',
          port: 44871,
          discoveredAt: DateTime(2026),
        ),
      ],
    );
    final container = ProviderContainer(
      overrides: [
        ...appOverrides(),
        dataDirProvider.overrideWithValue(dir.path),
        linkCredentialsProvider.overrideWithValue(creds),
        linkClientControllerProvider.overrideWithValue(fakeClient),
      ],
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose();
      baseContainer.dispose();
      await tester.runAsync(() async {
        try {
          if (dir.existsSync()) dir.deleteSync(recursive: true);
        } on FileSystemException {
          // Windows may briefly hold a file handle during async teardown.
        }
      });
    });

    await tester.pumpWidget(_wrapApp(const Scaffold(body: MobileLinkPage()), container: container));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('link-discovered-pc-1')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('link-discovered-code-input')), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('link-discovered-code-input')), '123456');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('link-discovered-pair-confirm')));
    await tester.pumpAndSettle();

    expect(fakeClient.lastPairCall, (host: '192.168.31.10', port: 44871, code: '123456'));
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}

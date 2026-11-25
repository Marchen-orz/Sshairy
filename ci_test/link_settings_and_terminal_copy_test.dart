import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show ImageByteFormat;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/design/theme.dart';
import 'package:sshairy/features/connections/api.dart';
import 'package:sshairy/features/credentials/api.dart';
import 'package:sshairy/features/link/api.dart';
import 'package:sshairy/features/settings/api.dart';
import 'package:sshairy/features/terminal/api.dart';
import 'package:sshairy/foundation/data_dir.dart';
import 'package:sshairy/foundation/ids.dart';
import 'package:sshairy/foundation/secret.dart';
import 'package:sshairy/l10n/app_localizations.dart';

class _TestLinkCredentials implements LinkCredentials {
  Secret? _seed;

  @override
  Future<Secret?> readIdentity() async => _seed;

  @override
  Future<void> saveIdentity(Secret seed) async => _seed = seed;

  @override
  Future<void> clearIdentity() async => _seed = null;
}

class _FakeLinkHostController extends LinkHostController {
  _FakeLinkHostController({required super.credentials, required super.store, required super.bridge});

  @override
  Future<void> configure({
    required bool enabled,
    required int port,
    required bool discovery,
    String? deviceName,
  }) async {}
}

class _FakeShellChannel implements ShellChannel {
  final _stdout = StreamController<Uint8List>.broadcast();
  final _done = Completer<void>();

  void emit(String text) => _stdout.add(Uint8List.fromList(utf8.encode(text)));

  @override
  Stream<Uint8List> get stdout => _stdout.stream;

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
    unawaited(_stdout.close());
  }
}

Widget _app({required ProviderContainer container, required Widget child, ThemeData? theme}) =>
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        theme: (theme ?? buildTheme(Brightness.light, Accent.blue, 14, null, null)).copyWith(
          splashFactory: NoSplash.splashFactory,
        ),
        home: Scaffold(body: child),
      ),
    );

Future<void> _waitUntil(WidgetTester tester, bool Function() check) async {
  for (var i = 0; i < 40; i++) {
    if (check()) return;
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  testWidgets('LinkSettings auto-saves switches and fields without a manual Save button', (tester) async {
    late Directory dir;
    await tester.runAsync(() async {
      dir = Directory.systemTemp.createTempSync('sshairy-link-settings-');
    });
    addTearDown(() => tester.runAsync(() async => dir.deleteSync(recursive: true)));

    final container = ProviderContainer(
      overrides: [
        dataDirProvider.overrideWithValue(dir.path),
        linkHostControllerProvider.overrideWith((ref) {
          final host = _FakeLinkHostController(
            credentials: _TestLinkCredentials(),
            store: LinkPeerStore(dir.path),
            bridge: ref.read(linkDesktopBridgeProvider),
          );
          ref.onDispose(host.dispose);
          return host;
        }),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      _app(
        container: container,
        child: const SizedBox(width: 480, height: 640, child: LinkSettings()),
      ),
    );
    await tester.pump();

    expect(find.byKey(const ValueKey('link-save')), findsNothing);
    expect(find.byKey(const ValueKey('link-reset')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('link-enabled-switch')));
    await _waitUntil(tester, () => container.read(settingsProvider).get(SettingKeys.linkEnabled));
    expect(container.read(settingsProvider).get(SettingKeys.linkEnabled), isTrue);

    await tester.tap(find.byKey(const ValueKey('link-discovery-switch')));
    await _waitUntil(tester, () => !container.read(settingsProvider).get(SettingKeys.linkDiscovery));
    expect(container.read(settingsProvider).get(SettingKeys.linkDiscovery), isFalse);

    await tester.enterText(find.byKey(const ValueKey('link-name-field')), 'Desk Box');
    await tester.pump(const Duration(milliseconds: 550));
    await _waitUntil(tester, () => container.read(settingsProvider).get(SettingKeys.linkDeviceName) == 'Desk Box');
    expect(container.read(settingsProvider).get(SettingKeys.linkDeviceName), 'Desk Box');

    await tester.enterText(find.byKey(const ValueKey('link-port-field')), '49100');
    await tester.pump(const Duration(milliseconds: 550));
    await _waitUntil(tester, () => container.read(settingsProvider).get(SettingKeys.linkPort) == 49100);
    expect(container.read(settingsProvider).get(SettingKeys.linkPort), 49100);

    // Invalid port reverts to the last saved port on blur.
    await tester.enterText(find.byKey(const ValueKey('link-port-field')), '99');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('link-name-field')));
    await tester.pump();
    final portField = tester.widget<TextField>(find.byKey(const ValueKey('link-port-field')));
    expect(portField.controller?.text, '49100');
    expect(container.read(settingsProvider).get(SettingKeys.linkPort), 49100);
  });

  testWidgets('TerminalPane renders GNU ls blue-on-green directory names at readable contrast', (tester) async {
    final dir = Directory.systemTemp.createTempSync('sshairy-terminal-color-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final channel = _FakeShellChannel();
    final session = TerminalSession.remote(
      const SessionId('contrast'),
      const LinkTerminalTarget(
        peerId: 'd1',
        peerName: 'Desk',
        remoteId: 'r1',
        title: 'Demo',
        targetLabel: 'Demo',
        kind: LinkTerminalKind.mirror,
      ),
      (_, _) async => channel,
    );
    addTearDown(session.dispose);
    final container = ProviderContainer(overrides: [dataDirProvider.overrideWithValue(dir.path)]);
    addTearDown(container.dispose);
    const boundary = ValueKey('terminal-colors');
    await tester.pumpWidget(
      _app(
        container: container,
        theme: buildTheme(Brightness.dark, Accent.deepSea, 14, null, null),
        child: SizedBox(
          width: 360,
          height: 140,
          child: RepaintBoundary(key: boundary, child: TerminalPane(session, active: true)),
        ),
      ),
    );
    await tester.pump();
    channel.emit('\x1b[34;42m  █ writable directory  \x1b[0m\r\n');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    final render = tester.renderObject<RenderRepaintBoundary>(find.byKey(boundary));
    final pixels = (await tester.runAsync(() async {
      final image = await render.toImage();
      try {
        return await image.toByteData(format: ImageByteFormat.rawRgba);
      } finally {
        image.dispose();
      }
    }))!;
    final palette = Accent.deepSea.palette(Brightness.dark);
    final foreground = palette.ansi[4];
    final originalBackground = palette.ansi[2];
    final colors = <int, int>{};
    for (var offset = 0; offset < pixels.lengthInBytes; offset += 4) {
      final rgb = pixels.getUint32(offset) >> 8 | 0xFF000000;
      colors.update(rgb, (count) => count + 1, ifAbsent: () => 1);
    }
    expect(colors, contains(foreground.toARGB32()));
    expect(colors, isNot(contains(originalBackground.toARGB32())));
    colors.remove(palette.terminalBackground.toARGB32());
    colors.remove(foreground.toARGB32());
    final fill = colors.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
    expect(colorContrast(foreground, Color(fill)), greaterThanOrEqualTo(4.5));
  });

  testWidgets('TerminalPane shows a lightweight copied notice after copying selected text', (tester) async {
    late Directory dir;
    await tester.runAsync(() async {
      dir = Directory.systemTemp.createTempSync('sshairy-terminal-copy-');
    });
    addTearDown(() => tester.runAsync(() async => dir.deleteSync(recursive: true)));

    String? clipboardText;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboardText = (call.arguments as Map)['text'] as String?;
          return null;
        }
        return null;
      },
    );
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    final channel = _FakeShellChannel();
    final session = TerminalSession.remote(
      const SessionId('s1'),
      const LinkTerminalTarget(
        peerId: 'd1',
        peerName: 'Desk',
        remoteId: 'r1',
        title: 'Demo',
        targetLabel: 'Demo',
        kind: LinkTerminalKind.mirror,
      ),
      (_, _) async => channel,
    );
    addTearDown(session.dispose);

    final container = ProviderContainer(overrides: [dataDirProvider.overrideWithValue(dir.path)]);
    addTearDown(container.dispose);

    await tester.pumpWidget(
      _app(
        container: container,
        child: SizedBox(width: 640, height: 360, child: TerminalPane(session, active: true)),
      ),
    );
    await tester.pump();
    channel.emit('hello sshairy\r\n');
    await tester.pump();

    expect(find.byKey(const ValueKey('terminal-copy-notice')), findsNothing);

    final center = tester.getCenter(find.byType(TerminalPane));
    // Open context menu -> Select all.
    await tester.tapAt(center, buttons: 2);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Select all'));
    await tester.pumpAndSettle();

    // Open context menu -> Copy.
    await tester.tapAt(center, buttons: 2);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copy'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(clipboardText, contains('hello sshairy'));
    expect(find.byKey(const ValueKey('terminal-copy-notice')), findsOneWidget);
    expect(
      find.descendant(of: find.byKey(const ValueKey('terminal-copy-notice')), matching: find.text('Copied')),
      findsOneWidget,
    );

    // Notice disappears automatically after its lightweight display duration.
    await tester.pump(const Duration(milliseconds: 1500));
    expect(find.byKey(const ValueKey('terminal-copy-notice')), findsNothing);
  });
}

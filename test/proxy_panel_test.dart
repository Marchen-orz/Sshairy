import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/design/controls.dart';
import 'package:sshairy/design/select.dart';
import 'package:sshairy/design/theme.dart';
import 'package:sshairy/features/credentials/application/credential_access.dart' show secretStoreProvider;
import 'package:sshairy/features/hosts/api.dart';
import 'package:sshairy/foundation/data_dir.dart';
import 'package:sshairy/foundation/ids.dart';
import 'package:sshairy/foundation/json_file.dart';
import 'package:sshairy/l10n/app_localizations.dart';

import 'keys_test.dart' show MemorySecrets;

void main() {
  late Directory dir;
  late ProviderContainer container;
  late HostsNotifier hosts;
  const upstream = Proxy(ProxyKind.socks5, 'proxy.example', 1080);
  const own = Proxy(ProxyKind.http, 'other.example', 8080, username: 'operator');
  const host = Host(
    id: HostId('target'),
    label: 'target',
    address: 'target.example',
    username: 'u',
    overrides: ConnectionOverrides(authentication: OverrideValue.value(Authentication.inline('u', AuthPolicy()))),
  );

  setUp(() {
    dir = Directory.systemTemp.createTempSync('sshairy-proxy-');
    container = ProviderContainer(
      overrides: [dataDirProvider.overrideWithValue(dir.path), secretStoreProvider.overrideWithValue(MemorySecrets())],
    );
    hosts = container.read(hostsProvider.notifier);
  });

  tearDown(() async {
    container.dispose();
    await dir.delete(recursive: true).then((_) {}, onError: (Object _) {});
  });

  test('proxy patches preserve other connection fields and distinguish inherit from direct', () async {
    await hosts.saveDefaults(
      const ConnectionOverrides(
        port: OverrideValue.value(2222),
        proxy: OverrideValue.value(upstream),
        legacy: OverrideValue.value(true),
      ),
    );
    final group = await hosts.createGroup('lab', defaults: const ConnectionOverrides(port: OverrideValue.value(2200)));
    await hosts.save(host.copyWith(groupId: () => group));
    await hosts.setHostProxy(host.id, const OverrideValue.value(own), expectedRevision: hosts.revision);
    final saved = hosts.byId(host.id)!;
    expect((saved.port, saved.legacy, saved.username, saved.address), (2200, true, 'u', 'target.example'));
    expect(saved.proxy!.key, own.key);
    expect(saved.overrides!.port.mode, OverrideMode.inherit);
    await hosts.setHostProxy(host.id, const OverrideValue.disabled(), expectedRevision: hosts.revision);
    expect(hosts.byId(host.id)!.proxy, isNull);
    expect(hosts.byId(host.id)!.overrides!.proxy.mode, OverrideMode.disabled);
    await hosts.setHostProxy(host.id, const OverrideValue.inherit(), expectedRevision: hosts.revision);
    expect(hosts.byId(host.id)!.proxy!.key, upstream.key);
    await hosts.setGroupProxy(group, const OverrideValue.value(own), expectedRevision: hosts.revision);
    expect(hosts.byId(host.id)!.proxy!.key, own.key);
    expect(hosts.library.groupById(group)!.defaults.port.value, 2200);
    await hosts.setDefaultProxy(const OverrideValue.disabled(), expectedRevision: hosts.revision);
    expect(hosts.library.defaults.port.value, 2222);
    expect(hosts.library.defaults.legacy.value, isTrue);
    await hosts.setGroupProxy(group, const OverrideValue.inherit(), expectedRevision: hosts.revision);
    expect(hosts.byId(host.id)!.proxy, isNull);
  });

  test('stale proxy changes and invalid endpoints leave the current snapshot intact', () async {
    await hosts.save(host);
    final stale = hosts.revision;
    await hosts.setPinned(host, true);
    await expectLater(
      hosts.setHostProxy(host.id, const OverrideValue.value(upstream), expectedRevision: stale),
      throwsA(isA<JsonFileError>().having((e) => e.kind, 'kind', JsonFileFailure.conflict)),
    );
    final before = File('${dir.path}/hosts.json').readAsStringSync();
    await expectLater(
      hosts.setDefaultProxy(
        const OverrideValue.value(Proxy(ProxyKind.http, 'bad host', 80)),
        expectedRevision: hosts.revision,
      ),
      throwsArgumentError,
    );
    expect(hosts.byId(host.id)!.pinned, isTrue);
    expect(hosts.byId(host.id)!.proxy, isNull);
    expect(File('${dir.path}/hosts.json').readAsStringSync(), before);
  });

  test('a failed proxy write does not publish or replace the previous settings', () async {
    await hosts.save(host);
    final path = '${dir.path}/hosts.json';
    final original = File(path).readAsStringSync();
    await File(path).delete();
    await Directory(path).create();
    try {
      await expectLater(
        hosts.setHostProxy(host.id, const OverrideValue.value(upstream), expectedRevision: hosts.revision),
        throwsA(isA<Object>()),
      );
      expect(hosts.byId(host.id)!.proxy, isNull);
    } finally {
      await Directory(path).delete(recursive: true);
      await File(path).writeAsString(original);
    }
  });

  Future<void> pumpPanel(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildTheme(Brightness.light).copyWith(splashFactory: NoSplash.splashFactory),
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(body: ProxyPanel()),
        ),
      ),
    );
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pumpAndSettle();
  }

  Future<void> until(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 100 && !done(); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pumpAndSettle();
    expect(done(), isTrue);
  }

  testWidgets('the panel shows the outer jump proxy and searches its endpoint', (tester) async {
    await tester.runAsync(() async {
      await hosts.save(
        const Host(id: HostId('jump'), label: 'gateway', address: 'jump.example', username: 'u', proxy: upstream),
      );
      await hosts.save(
        host.copyWith(
          overrides: () => const ConnectionOverrides(
            authentication: OverrideValue.value(Authentication.inline('u', AuthPolicy())),
            jump: OverrideValue.value(HostId('jump')),
            proxy: OverrideValue.value(own),
          ),
        ),
      );
    });
    await pumpPanel(tester);
    final targetRow = find.byKey(const ValueKey('target'));
    expect(find.descendant(of: targetRow, matching: find.textContaining('proxy.example:1080')), findsOneWidget);
    expect(find.descendant(of: targetRow, matching: find.textContaining('other.example')), findsNothing);
    expect(find.descendant(of: targetRow, matching: find.textContaining('gateway')), findsOneWidget);
    expect(find.byTooltip('Edit the jump host proxy'), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, 'proxy.example');
    await tester.pump();
    expect(targetRow, findsOneWidget);
    expect(find.text('Global defaults'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a concurrent edit keeps the proxy draft open and preserves the newer configuration', (tester) async {
    await tester.runAsync(() => hosts.save(host));
    await pumpPanel(tester);
    await tester.tap(find.descendant(of: find.byKey(const ValueKey('target')), matching: find.byTooltip('Edit')));
    await tester.pumpAndSettle();
    await tester.runAsync(() => hosts.setPinned(host, true));
    await tester.pump();
    await tester.tap(find.text('Save'));
    await until(
      tester,
      () => find.text('Configuration changed. Reopen this editor and try again.').evaluate().isNotEmpty,
    );
    expect(find.text('Save'), findsOneWidget);
    expect(hosts.byId(host.id)!.pinned, isTrue);
    expect(hosts.byId(host.id)!.overrides!.proxy.mode, OverrideMode.inherit);
    expect(tester.takeException(), isNull);
  });

  testWidgets('editing supports own, direct and inherited values without parsing a disabled draft', (tester) async {
    await tester.runAsync(() async {
      await hosts.saveDefaults(const ConnectionOverrides(proxy: OverrideValue.value(upstream)));
      await hosts.save(host);
    });
    await pumpPanel(tester);
    final targetRow = find.byKey(const ValueKey('target'));
    await tester.tap(find.descendant(of: targetRow, matching: find.byTooltip('Edit')));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(AppSwitch));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, 'Port'), 'invalid');
    await tester.tap(find.byType(AppSwitch));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await until(tester, () => find.text('Save').evaluate().isEmpty);
    expect(hosts.byId(host.id)!.overrides!.proxy.mode, OverrideMode.inherit);

    await tester.tap(find.descendant(of: targetRow, matching: find.byTooltip('Edit')));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(AppSwitch));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(AppSelect<ProxyKind?>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Direct').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await until(tester, () => find.text('Save').evaluate().isEmpty);
    expect(hosts.byId(host.id)!.overrides!.proxy.mode, OverrideMode.disabled);
    expect(hosts.byId(host.id)!.proxy, isNull);
    await tester.tap(find.descendant(of: targetRow, matching: find.byTooltip('Edit')));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppSelect<ProxyKind?>, 'Direct'), findsOneWidget);
    await tester.tap(find.text('Save'));
    await until(tester, () => find.text('Save').evaluate().isEmpty);
    expect(hosts.byId(host.id)!.overrides!.proxy.mode, OverrideMode.disabled);
    expect(tester.takeException(), isNull);
  });
}

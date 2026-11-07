import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/app/composition.dart';
import 'package:sshairy/design/side_drawer.dart';
import 'package:sshairy/design/theme.dart';
import 'package:sshairy/features/credentials/application/credential_access.dart' show secretStoreProvider;
import 'package:flutter/gestures.dart';
import 'package:sshairy/features/hosts/api.dart';
import 'package:sshairy/features/hosts/presentation/group_panel.dart';
import 'package:sshairy/features/hosts/presentation/identities_panel.dart';
import 'package:sshairy/features/hosts/presentation/host_form.dart';
import 'package:sshairy/foundation/data_dir.dart';
import 'package:sshairy/foundation/ids.dart';
import 'package:sshairy/l10n/app_localizations.dart';

import 'keys_test.dart' show MemorySecrets;

const _password = AuthPolicy();

ConnectionOverrides _login(String user) =>
    ConnectionOverrides(authentication: OverrideValue.value(Authentication.inline(user, _password)));

void main() {
  late Directory dir;
  late ProviderContainer container;
  late HostsNotifier hosts;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('sshairy-editor-');
    container = ProviderContainer(
      overrides: [
        dataDirProvider.overrideWithValue(dir.path),
        secretStoreProvider.overrideWithValue(MemorySecrets()),
        ...appOverrides(),
      ],
    );
    hosts = container.read(hostsProvider.notifier);
  });

  tearDown(() async {
    // A test that failed halfway can leave a write queued on the fake clock, which would never run again.
    container.dispose();
    await dir.delete(recursive: true).then((_) {}, onError: (Object _) {});
  });

  Future<void> pumpApp(WidgetTester tester, Widget home, {Size size = const Size(900, 1800)}) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          // The default ink needs a shader asset, which a widget test run without assets does not have.
          theme: buildTheme(Brightness.light).copyWith(splashFactory: NoSplash.splashFactory),
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: home,
        ),
      ),
    );
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pumpAndSettle();
  }

  /// Opens [panel] in the side drawer the way the vault does.
  Future<void> open(WidgetTester tester, Widget panel) async {
    await pumpApp(
      tester,
      Builder(
        builder: (context) => Scaffold(
          body: TextButton(onPressed: () => showSideDrawer<void>(context, (_) => panel), child: const Text('open')),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  /// Lets queued writes finish on the real clock until [done] holds.
  Future<void> until(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 100 && !done(); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pumpAndSettle();
    expect(done(), isTrue, reason: 'the change should have landed');
  }

  /// Real file IO does not complete inside the fake clock of a widget test.
  Future<void> prepare(WidgetTester tester, Future<void> Function() body) async {
    await tester.runAsync(body);
  }

  /// Saves and waits for the drawer to close, which it does only when the write has landed.
  Future<void> save(WidgetTester tester) async {
    await tester.tap(find.text('Save'));
    await until(tester, () => find.text('Save').evaluate().isEmpty);
  }

  Finder field(String label) => find.widgetWithText(TextFormField, label);
  bool enabled(WidgetTester tester, Finder f) => tester.widget<TextFormField>(f).enabled;

  group('host form', () {
    testWidgets('a new host in a group follows what the group and the defaults give it', (tester) async {
      await prepare(tester, () async {
        await hosts.saveDefaults(_login('root'));
        await hosts.createGroup('lab', defaults: const ConnectionOverrides(port: OverrideValue.value(2200)));
      });
      await open(tester, const HostForm(group: 'lab'));

      expect(find.text('2200'), findsOneWidget, reason: 'the inherited port is shown');
      expect(enabled(tester, field('Port')), isFalse, reason: 'a linked field cannot be typed into');
      expect(enabled(tester, field('Username')), isFalse);
      expect(find.byTooltip('Inherited from lab'), findsOneWidget);
      expect(find.byTooltip('Inherited from Global defaults'), findsOneWidget);

      await tester.enterText(field('Address'), 'a.example');
      await save(tester);

      final host = hosts.library.hosts.single;
      expect((host.port, host.username, host.group), (2200, 'root', 'lab'));
      expect(host.overrides!.isEmpty, isTrue, reason: 'a host that owns nothing stores nothing');

      await prepare(
        tester,
        () => hosts.saveGroup(
          hosts.library.groups.single.copyWith(defaults: const ConnectionOverrides(port: OverrideValue.value(2300))),
        ),
      );
      expect(hosts.byId(host.id)!.port, 2300);
    });

    testWidgets('unlinking a field starts from the inherited value and stores an own one', (tester) async {
      await prepare(tester, () async {
        await hosts.saveDefaults(_login('root'));
        await hosts.createGroup('lab', defaults: const ConnectionOverrides(port: OverrideValue.value(2200)));
      });
      await open(tester, const HostForm(group: 'lab'));

      await tester.tap(find.byTooltip('Inherited from lab'));
      await tester.pump();
      expect(enabled(tester, field('Port')), isTrue);
      expect(find.text('2200'), findsOneWidget, reason: 'the own value starts as the inherited one');
      expect(find.byTooltip('Use the value from lab'), findsOneWidget);
      await tester.enterText(field('Port'), '2022');
      await tester.enterText(field('Address'), 'a.example');
      await save(tester);

      final host = hosts.library.hosts.single;
      expect(host.port, 2022);
      expect(host.overrides!.port.mode, OverrideMode.value);
      expect(host.overrides!.authentication.mode, OverrideMode.inherit, reason: 'the login is still inherited');
    });

    testWidgets('a host without defaults to follow starts with plain own values', (tester) async {
      await open(tester, const HostForm());
      expect(enabled(tester, field('Port')), isTrue);
      expect(enabled(tester, field('Username')), isTrue);

      await tester.enterText(field('Address'), 'a.example');
      await tester.enterText(field('Username'), 'me');
      await save(tester);

      final host = hosts.library.hosts.single;
      expect((host.port, host.username, host.auth), (22, 'me', AuthKind.password));
      expect(host.overrides!.authentication.mode, OverrideMode.value);
    });

    testWidgets('an existing host with its own settings is saved back unchanged', (tester) async {
      const host = Host(
        id: HostId('h'),
        label: 'h',
        address: 'h.example',
        port: 2222,
        username: 'root',
        auth: AuthKind.key,
        keyPath: '~/id',
      );
      await prepare(tester, () => hosts.save(host));
      await open(tester, HostForm(host: hosts.byId(host.id)));

      expect(enabled(tester, field('Port')), isTrue);
      expect(find.text('2222'), findsOneWidget);
      await save(tester);

      final saved = hosts.byId(host.id)!;
      expect((saved.port, saved.username, saved.auth, saved.keyPath), (2222, 'root', AuthKind.key, '~/id'));
      expect(saved.policy.allowInteractive, isTrue);
      expect(saved.overrides!.port.mode, OverrideMode.value);
    });

    testWidgets('an identity can be chosen instead of typing a login', (tester) async {
      await prepare(
        tester,
        () => hosts.saveIdentity(const HostIdentity(id: 'i', label: 'ops', username: 'operator', policy: _password)),
      );
      await open(tester, const HostForm());

      await tester.tap(find.text('Custom'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('ops · operator').last);
      await tester.pumpAndSettle();
      expect(field('Username'), findsNothing, reason: 'an identity brings its own username');
      await tester.enterText(field('Address'), 'a.example');
      await save(tester);

      final host = hosts.library.hosts.single;
      expect(host.username, 'operator');
      expect(host.overrides!.authentication.value!.identityId, 'i');
    });
  });

  group('route section', () {
    testWidgets('a failed save opens the folded route section that holds the error', (tester) async {
      await open(tester, const HostForm());
      await tester.tap(find.text('Connection route'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Inherited from Default').at(1));
      await tester.pump();
      await tester.tap(find.widgetWithText(DropdownButtonFormField<ProxyKind>, 'Proxy'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('SOCKS5').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Connection route'));
      await tester.pumpAndSettle();
      expect(find.text('Proxy address'), findsNothing, reason: 'the section is folded');

      await tester.enterText(field('Address'), 'a.example');
      await tester.enterText(field('Username'), 'me');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(find.text('Required'), findsOneWidget, reason: 'the proxy address is empty and now visible');
      expect(hosts.library.hosts, isEmpty);
    });
  });

  group('groups, defaults and identities', () {
    testWidgets('a group left with every field linked stores no defaults of its own', (tester) async {
      await open(tester, const GroupPanel());
      await tester.enterText(field('Group'), 'edge');
      await save(tester);

      expect(hosts.library.groupPaths, ['edge']);
      expect(hosts.library.groups.single.defaults.isEmpty, isTrue);
    });

    testWidgets('a group is renamed and its defaults edited in the same drawer', (tester) async {
      await prepare(
        tester,
        () => hosts.createGroup('edge', defaults: const ConnectionOverrides(port: OverrideValue.value(2201))),
      );
      await open(tester, GroupPanel(group: hosts.library.groups.single));

      expect(enabled(tester, field('Port')), isTrue, reason: 'the group owns its port');
      await tester.enterText(field('Group'), 'prod');
      await tester.enterText(field('Port'), '2300');
      await save(tester);

      expect(hosts.library.groupPaths, ['prod']);
      expect(hosts.library.groups.single.defaults.port.value, 2300);
    });

    testWidgets('a path another group already has is refused and nothing changes', (tester) async {
      await prepare(tester, () async {
        await hosts.createGroup('a');
        await hosts.createGroup('b');
      });
      await open(tester, GroupPanel(group: hosts.library.groups.last));
      await tester.enterText(field('Group'), 'a');
      await tester.tap(find.text('Save'));
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pumpAndSettle();

      expect(find.text('That group path is taken or invalid.'), findsOneWidget);
      expect(hosts.library.groupPaths, ['a', 'b']);
    });

    testWidgets('the global login is set by unlinking it, and every host without its own login follows', (
      tester,
    ) async {
      await open(tester, const DefaultsPanel());
      await tester.tap(find.byTooltip('Inherited from Default').at(1));
      await tester.pump();
      await tester.enterText(field('Username'), 'root');
      await save(tester);

      final login = hosts.library.defaults.authentication.value!;
      expect(login.username, 'root');
      expect(login.policy!.methods, [AuthKind.password]);
      expect(hosts.library.defaults.port.mode, OverrideMode.inherit);
    });

    testWidgets('identities are created, listed and removed unless something uses them', (tester) async {
      await open(tester, const IdentitiesPanel());
      await tester.tap(find.text('New identity'));
      await tester.pumpAndSettle();
      await tester.enterText(field('Name'), 'ops');
      await tester.enterText(field('Username'), 'operator');
      await save(tester);
      expect(find.text('ops'), findsOneWidget);
      expect(hosts.library.identities.single.username, 'operator');

      final id = hosts.library.identities.single.id;
      await prepare(
        tester,
        () => hosts.save(
          Host(
            id: const HostId('h'),
            label: 'h',
            address: 'h.example',
            username: '',
            overrides: ConnectionOverrides(authentication: OverrideValue.value(Authentication.identity(id))),
          ),
        ),
      );
      await tester.pumpAndSettle();
      IconButton remove() => tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.delete_outline));
      expect(remove().onPressed, isNull, reason: 'a host still uses it');

      await prepare(tester, () => hosts.save(hosts.byId(const HostId('h'))!.copyWith(overrides: () => _login('own'))));
      await tester.pumpAndSettle();
      expect(remove().onPressed, isNotNull);
      await tester.tap(find.widgetWithIcon(IconButton, Icons.delete_outline));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Delete'));
      await until(tester, () => hosts.library.identities.isEmpty);
    });
  });

  group('vault', () {
    testWidgets('a jump host cannot be deleted while a host routes through it', (tester) async {
      await prepare(tester, () async {
        await hosts.saveDefaults(_login('root'));
        await hosts.save(const Host(id: HostId('bastion'), label: 'bastion', address: 'b.example', username: 'u'));
        await hosts.save(
          const Host(
            id: HostId('inner'),
            label: 'inner',
            address: 'i.example',
            username: 'u',
            jumpHostId: HostId('bastion'),
          ),
        );
      });
      await pumpApp(
        tester,
        Scaffold(body: VaultPage(active: true, onConnect: (_) {})),
        size: const Size(1200, 800),
      );

      // Hosts are listed by name, so the first card is the bastion.
      await tester.tap(find.descendant(of: find.byType(Card).first, matching: find.byTooltip('More')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Delete'));
      await until(tester, () => find.text('Jump host of inner').evaluate().isNotEmpty);
      expect(hosts.byId(const HostId('bastion')), isNotNull);
    });

    testWidgets('a double click connects and a single one only focuses', (tester) async {
      await prepare(tester, () async {
        await hosts.saveDefaults(_login('root'));
        await hosts.save(const Host(id: HostId('h'), label: 'h', address: 'h.example', username: 'u'));
      });
      final connected = <String>[];
      await pumpApp(
        tester,
        Scaffold(body: VaultPage(active: true, onConnect: (h) => connected.add(h.id.value))),
        size: const Size(1200, 800),
      );

      await tester.tap(find.text('u@h.example'));
      await tester.pump();
      expect(connected, isEmpty);
      await tester.tap(find.text('u@h.example'));
      await tester.pump();
      expect(connected, ['h']);

      await tester.runAsync(() => Future<void>.delayed(kDoubleTapTimeout + const Duration(milliseconds: 100)));
      await tester.tap(find.text('u@h.example'));
      await tester.pump();
      expect(connected, ['h'], reason: 'the pair was used up and the next click starts a new one');
      await tester.runAsync(() => Future<void>.delayed(kDoubleTapTimeout + const Duration(milliseconds: 100)));
      await tester.tap(find.text('u@h.example'));
      await tester.pump();
      expect(connected, ['h'], reason: 'two clicks far apart are not a pair');
    });

    testWidgets('empty groups show, and dissolving one that has defaults asks first', (tester) async {
      await prepare(tester, () async {
        await hosts.saveDefaults(_login('root'));
        await hosts.createGroup('empty');
        await hosts.createGroup('prod', defaults: const ConnectionOverrides(port: OverrideValue.value(2201)));
        await hosts.save(const Host(id: HostId('h'), label: 'h', address: 'h.example', username: 'u', group: 'prod'));
      });
      await pumpApp(
        tester,
        Scaffold(body: VaultPage(active: true, onConnect: (_) {})),
        size: const Size(1200, 800),
      );
      expect(find.text('empty'), findsOneWidget);

      Future<void> dissolve(String chip) async {
        await tester.tap(find.text(chip), buttons: kSecondaryMouseButton);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Dissolve group'));
        await tester.pumpAndSettle();
      }

      await dissolve('prod');
      expect(find.textContaining('Dissolve prod?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(hosts.library.groupPaths, ['empty', 'prod']);

      await dissolve('prod');
      await tester.tap(find.widgetWithText(TextButton, 'Dissolve group'));
      await until(tester, () => !hosts.library.groupPaths.contains('prod'));
      expect(hosts.byId(const HostId('h'))!.group, '');

      await dissolve('empty');
      expect(find.textContaining('Dissolve'), findsNothing, reason: 'a group without defaults needs no confirmation');
      await until(tester, () => hosts.library.groupPaths.isEmpty);
    });
  });
}

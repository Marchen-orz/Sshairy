import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/app/composition.dart';
import 'package:sshairy/design/side_drawer.dart';
import 'package:sshairy/design/theme.dart';
import 'package:sshairy/features/credentials/adapters/secure_store.dart';
import 'package:sshairy/features/credentials/api.dart';
import 'package:sshairy/features/credentials/application/credential_access.dart' show secretStoreProvider;
import 'package:sshairy/features/hosts/api.dart';
import 'package:sshairy/features/hosts/presentation/host_form.dart';
import 'package:sshairy/foundation/data_dir.dart';
import 'package:sshairy/foundation/ids.dart';
import 'package:sshairy/foundation/secret.dart';
import 'package:sshairy/l10n/app_localizations.dart';

class _Secrets implements SecretStore {
  final values = <SecretRef, Secret>{};
  final written = <SecretRef>[];
  final deleted = <SecretRef>[];
  Completer<Secret?>? pendingRead;
  Completer<void>? pendingWrite;
  Completer<void>? pendingDelete;
  bool failRead = false;
  bool failWrite = false;
  bool failAfterWrite = false;
  bool failDelete = false;

  @override
  Future<Secret?> read(SecretRef ref) async {
    if (failRead) throw StateError('locked');
    final pending = pendingRead;
    if (pending != null) return pending.future;
    return values[ref];
  }

  @override
  Future<void> write(SecretRef ref, Secret value) async {
    written.add(ref);
    await pendingWrite?.future;
    if (failWrite) throw StateError('locked');
    values[ref] = value;
    if (failAfterWrite) throw StateError('write outcome unknown');
  }

  @override
  Future<void> delete(SecretRef ref) async {
    deleted.add(ref);
    await pendingDelete?.future;
    if (failDelete) throw StateError('locked');
    values.remove(ref);
  }
}

const _host = Host(id: HostId('h'), label: 'existing', address: 'h.example', username: 'operator');

void main() {
  late Directory dir;
  late ProviderContainer container;
  late HostsNotifier hosts;
  late _Secrets secrets;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('sshairy-password-');
    secrets = _Secrets();
    container = ProviderContainer(
      overrides: [
        dataDirProvider.overrideWithValue(dir.path),
        secretStoreProvider.overrideWithValue(secrets),
        ...appOverrides(),
      ],
    );
    hosts = container.read(hostsProvider.notifier);
  });

  tearDown(() async {
    container.dispose();
    await dir.delete(recursive: true).then((_) {}, onError: (Object _) {});
  });

  Finder field(String label) => find.widgetWithText(TextFormField, label);
  TextField passwordField(WidgetTester t) =>
      t.widget<TextField>(find.descendant(of: field('Password'), matching: find.byType(TextField)));

  Future<void> open(WidgetTester t, {Host? host, Widget? panel, double fontSize = AppFonts.uiSize}) async {
    await t.binding.setSurfaceSize(const Size(900, 1800));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildTheme(Brightness.light, Accent.blue, fontSize).copyWith(splashFactory: NoSplash.splashFactory),
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showSideDrawer<void>(context, (_) => panel ?? HostForm(host: host)),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    addTearDown(() => t.pumpWidget(const SizedBox.shrink()));
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
  }

  Future<void> until(WidgetTester t, bool Function() done) async {
    for (var i = 0; i < 100 && !done(); i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await t.pump(const Duration(milliseconds: 50));
    }
    await t.pumpAndSettle();
    expect(done(), isTrue);
  }

  Future<void> save(WidgetTester t) async {
    await t.tap(find.text('Save'));
    await until(t, () => find.text('Save').evaluate().isEmpty);
  }

  Future<void> createDraft(WidgetTester t) async {
    await open(t);
    await t.enterText(field('Address'), 'new.example');
    await t.enterText(field('Username'), 'new-user');
    await t.enterText(field('Password'), 'draft-password');
  }

  test('the host editor port touches only its host password and shares credential revisions', () async {
    final editor = container.read(hostPasswordEditorProvider);
    final connections = container.read(connectionCredentialsProvider);
    final other = SecretRef.hostPassword(const HostId('other'));
    final key = SecretRef.privateKey('shared');
    secrets.values[other] = const Secret('other-password');
    secrets.values[key] = const Secret('private-key');
    expect(await editor.readPassword(_host.id), isNull);
    await editor.savePassword(_host.id, const Secret('one'));
    expect((await editor.readPassword(_host.id))?.reveal(), 'one');
    expect(connections.revision, 1, reason: 'an explicit edit also invalidates an existing credential-less pool');
    await editor.savePassword(_host.id, const Secret('one'));
    await editor.savePassword(_host.id, const Secret(''));
    expect(connections.revision, 1);
    expect(secrets.written, [_host.passwordRef]);
    await editor.savePassword(_host.id, const Secret('two'));
    expect(connections.revision, 2);
    await editor.clearPassword(_host.id);
    expect(await editor.readPassword(_host.id), isNull);
    expect(connections.revision, 3);
    expect(secrets.values[other]?.reveal(), 'other-password');
    expect(secrets.values[key]?.reveal(), 'private-key');
  });

  test('failed reads never write and uncertain writes invalidate pooled credentials', () async {
    final editor = container.read(hostPasswordEditorProvider);
    final connections = container.read(connectionCredentialsProvider);
    secrets.values[_host.passwordRef] = const Secret('old');
    secrets.failRead = true;
    await expectLater(editor.readPassword(_host.id), throwsStateError);
    await expectLater(editor.savePassword(_host.id, const Secret('new')), throwsStateError);
    expect(secrets.written, isEmpty);
    expect(secrets.values[_host.passwordRef]?.reveal(), 'old');
    secrets.failRead = false;
    secrets.failAfterWrite = true;
    await expectLater(editor.savePassword(_host.id, const Secret('new')), throwsStateError);
    expect(connections.revision, 1);
    expect(secrets.values[_host.passwordRef]?.reveal(), 'new');
    secrets.failDelete = true;
    await expectLater(editor.clearPassword(_host.id), throwsStateError);
    expect(connections.revision, 2);
  });

  testWidgets('a new host saves pre-entered login and password without serializing the password', (t) async {
    await createDraft(t);
    expect(passwordField(t).obscureText, isTrue);
    expect(passwordField(t).obscuringCharacter, '•');
    await save(t);
    final host = hosts.library.hosts.single;
    expect(host.username, 'new-user');
    expect(secrets.values[host.passwordRef]?.reveal(), 'draft-password');
    expect(secrets.written, [host.passwordRef]);
    expect(jsonEncode(hosts.library.toJson()), isNot(contains('draft-password')));
    expect(File('${dir.path}/hosts.json').readAsStringSync(), isNot(contains('draft-password')));
  });

  testWidgets('editing loads the saved password masked and the eye toggles visibility without saving', (t) async {
    await t.runAsync(() => hosts.save(_host));
    secrets.values[_host.passwordRef] = const Secret('saved-password');
    await open(t, host: hosts.byId(_host.id));
    expect(passwordField(t).controller!.text, 'saved-password');
    expect(passwordField(t).obscureText, isTrue);
    await t.tap(find.byTooltip('Show password'));
    await t.pump();
    expect(passwordField(t).obscureText, isFalse);
    await t.tap(find.byTooltip('Hide password'));
    await t.pump();
    expect(passwordField(t).obscureText, isTrue);
    await save(t);
    expect(secrets.written, isEmpty);
    expect(secrets.deleted, isEmpty);
  });

  testWidgets('an empty edited draft keeps the old password, explicit removal commits only on save', (t) async {
    await t.runAsync(() => hosts.save(_host));
    secrets.values[_host.passwordRef] = const Secret('saved-password');
    await open(t, host: hosts.byId(_host.id));
    await t.enterText(field('Password'), '');
    await save(t);
    expect(secrets.values[_host.passwordRef]?.reveal(), 'saved-password');
    expect(secrets.written, isEmpty);
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
    await t.tap(find.text('Remove saved password'));
    await t.pump();
    expect(secrets.deleted, isEmpty);
    await save(t);
    expect(secrets.values[_host.passwordRef], isNull);
    expect(secrets.deleted, [_host.passwordRef]);
  });

  testWidgets('cancel clears the transient controller without writing or deleting', (t) async {
    await createDraft(t);
    final controller = passwordField(t).controller!;
    await t.tap(find.text('Cancel'));
    await t.pumpAndSettle();
    expect(controller.text, isEmpty);
    expect(hosts.library.hosts, isEmpty);
    expect(secrets.written, isEmpty);
    expect(secrets.deleted, isEmpty);
  });

  testWidgets('a late read cannot replace text typed while secure storage is opening', (t) async {
    await t.runAsync(() => hosts.save(_host));
    secrets.pendingRead = Completer<Secret?>();
    await open(t, host: hosts.byId(_host.id));
    await t.enterText(field('Password'), 'new-draft');
    secrets.pendingRead!.complete(const Secret('old-password'));
    secrets.pendingRead = null;
    await t.pumpAndSettle();
    expect(passwordField(t).controller!.text, 'new-draft');
    await save(t);
    expect(secrets.values[_host.passwordRef]?.reveal(), 'new-draft');
  });

  testWidgets('switching targets discards the old draft and ignores its pending read', (t) async {
    const second = Host(id: HostId('second'), label: 'second', address: 'second.example', username: 'second');
    await t.runAsync(() async {
      await hosts.save(_host);
      await hosts.save(second);
    });
    final selected = ValueNotifier<Host>(_host);
    addTearDown(selected.dispose);
    final pending = secrets.pendingRead = Completer<Secret?>();
    await open(
      t,
      panel: ValueListenableBuilder<Host>(
        valueListenable: selected,
        builder: (_, host, _) => HostForm(host: host),
      ),
    );
    await t.enterText(field('Password'), 'discarded-draft');
    secrets.pendingRead = null;
    secrets.values[second.passwordRef] = const Secret('second-password');
    selected.value = second;
    await t.pump();
    pending.complete(const Secret('first-password'));
    await t.pumpAndSettle();
    expect(passwordField(t).controller!.text, 'second-password');
    expect(passwordField(t).obscureText, isTrue);
    expect(secrets.written, isEmpty);
  });

  testWidgets('failed password loading is visible and blocks save until a successful retry', (t) async {
    await t.runAsync(() => hosts.save(_host));
    secrets.values[_host.passwordRef] = const Secret('old-password');
    secrets.failRead = true;
    await open(t, host: hosts.byId(_host.id));
    expect(find.text('Could not read the saved password. Unlock secure storage and retry.'), findsOneWidget);
    await t.enterText(field('Password'), 'new-password');
    await t.tap(find.text('Save'));
    await t.pumpAndSettle();
    expect(secrets.written, isEmpty);
    secrets.failRead = false;
    await t.tap(find.text('Retry password loading'));
    await t.pumpAndSettle();
    expect(passwordField(t).controller!.text, 'new-password');
    await save(t);
    expect(secrets.values[_host.passwordRef]?.reveal(), 'new-password');
  });

  testWidgets('a metadata save conflict leaves the draft and never writes the password', (t) async {
    await createDraft(t);
    // A different edit after this form opened makes its expected revision stale.
    await t.runAsync(() => hosts.save(_host));
    await t.pump();
    await t.tap(find.text('Save'));
    await until(t, () => find.textContaining('Could not save this host.').evaluate().isNotEmpty);
    expect(passwordField(t).controller!.text, 'draft-password');
    expect(hosts.library.hosts.map((h) => h.id), [_host.id]);
    expect(secrets.written, isEmpty);
    expect(secrets.deleted, isEmpty);
  });

  testWidgets('a credential failure leaves a partial-success message and retry reuses the new host id', (t) async {
    await createDraft(t);
    secrets.failWrite = true;
    await t.tap(find.text('Save'));
    await until(t, () => find.textContaining('Host settings were saved,').evaluate().isNotEmpty);
    final id = hosts.library.hosts.single.id;
    expect(passwordField(t).controller!.text, 'draft-password');
    expect(find.text('Save'), findsOneWidget);
    expect(secrets.values, isEmpty);
    secrets.failWrite = false;
    await save(t);
    expect(hosts.library.hosts.single.id, id);
    expect(secrets.values[SecretRef.hostPassword(id)]?.reveal(), 'draft-password');
    expect(secrets.written, [SecretRef.hostPassword(id), SecretRef.hostPassword(id)]);
  });

  testWidgets('proxy cleanup failure keeps the exact commit and retries cleanup before saving the password', (t) async {
    const proxy = Proxy(ProxyKind.socks5, 'old-proxy.example', 1080);
    const original = Host(id: HostId('h'), label: 'existing', address: 'h.example', username: 'operator', proxy: proxy);
    await t.runAsync(() => hosts.save(original));
    secrets.values[original.proxyRef] = const Secret('proxy-password');
    await open(t, host: original);
    await t.enterText(field('Proxy address'), 'new-proxy.example');
    await t.enterText(field('Password'), 'new-password');
    secrets.failDelete = true;
    await t.tap(find.text('Save'));
    await until(
      t,
      () => find.textContaining('Host settings were saved, but old proxy credentials').evaluate().isNotEmpty,
    );
    expect(hosts.byId(original.id)!.proxy!.address, 'new-proxy.example');
    expect(secrets.values[original.proxyRef]?.reveal(), 'proxy-password');
    expect(secrets.written, isEmpty);
    expect(passwordField(t).controller!.text, 'new-password');
    secrets.failDelete = false;
    await save(t);
    expect(hosts.library.hosts.single.id, original.id);
    expect(secrets.deleted, [original.proxyRef, original.proxyRef]);
    expect(secrets.values[original.proxyRef], isNull);
    expect(secrets.values[original.passwordRef]?.reveal(), 'new-password');
  });

  testWidgets('queued metadata changes are not absorbed after a partial credential failure', (t) async {
    await createDraft(t);
    final write = secrets.pendingWrite = Completer<void>();
    secrets.failWrite = true;
    await t.tap(find.text('Save'));
    await until(t, () => secrets.written.isNotEmpty);
    final committed = hosts.byId(hosts.library.hosts.single.id)!;
    // The password write is outside the host queue, so another edit can commit before it reports failure.
    await t.runAsync(() => hosts.save(committed.copyWith(label: 'later edit')));
    write.complete();
    secrets.pendingWrite = null;
    await t.pumpAndSettle();
    expect(find.textContaining('Host settings were saved,'), findsOneWidget);
    secrets.failWrite = false;
    await t.tap(find.text('Save'));
    await until(t, () => find.textContaining('Could not save this host.').evaluate().isNotEmpty);
    expect(hosts.byId(committed.id)!.label, 'later edit');
    expect(secrets.written, [committed.passwordRef], reason: 'stale metadata must not reach the password writer again');
  });

  testWidgets('queued metadata changes are not absorbed after a partial proxy-cleanup failure', (t) async {
    const proxy = Proxy(ProxyKind.socks5, 'old-proxy.example', 1080);
    const original = Host(id: HostId('h'), label: 'existing', address: 'h.example', username: 'operator', proxy: proxy);
    await t.runAsync(() => hosts.save(original));
    await open(t, host: original);
    await t.enterText(field('Proxy address'), 'new-proxy.example');
    await t.enterText(field('Password'), 'new-password');
    final deletion = secrets.pendingDelete = Completer<void>();
    secrets.failDelete = true;
    await t.tap(find.text('Save'));
    await until(t, () => secrets.deleted.isNotEmpty);
    final current = hosts.byId(original.id)!;
    var queuedDone = false;
    Object? queuedError;
    hosts
        .save(current.copyWith(label: 'queued edit'))
        .then<void>(
          (_) => queuedDone = true,
          onError: (Object error) {
            queuedError = error;
            queuedDone = true;
          },
        );
    deletion.complete();
    secrets.pendingDelete = null;
    await until(t, () => queuedDone);
    expect(queuedError, isA<HostProxyCleanupFailure>());
    expect(hosts.byId(original.id)!.label, 'queued edit');
    secrets.failDelete = false;
    await t.tap(find.text('Save'));
    await until(t, () => find.textContaining('Could not save this host.').evaluate().isNotEmpty);
    expect(hosts.byId(original.id)!.label, 'queued edit');
    expect(secrets.written, isEmpty);
  });

  testWidgets('an old Host parameter seeds current metadata and connection overrides', (t) async {
    await t.runAsync(() async {
      await hosts.save(_host);
      await hosts.save(
        const Host(
          id: HostId('h'),
          label: 'updated',
          address: 'updated.example',
          port: 2222,
          username: 'updated-user',
          pinned: true,
        ),
      );
    });
    await open(t, host: _host);
    expect(find.text('updated'), findsOneWidget);
    expect(find.text('updated.example'), findsOneWidget);
    expect(find.text('updated-user'), findsOneWidget);
    expect(find.text('2222'), findsOneWidget);
    await save(t);
    final current = hosts.byId(_host.id)!;
    expect(
      (current.label, current.address, current.port, current.username, current.pinned),
      ('updated', 'updated.example', 2222, 'updated-user', true),
    );
  });

  testWidgets('a removed Host parameter is rejected and cannot revive the deleted host', (t) async {
    await t.runAsync(() async {
      await hosts.save(_host);
      await hosts.delete(_host);
    });
    await open(t, host: _host);
    expect(find.text('The host no longer exists'), findsOneWidget);
    expect(t.widget<FilledButton>(find.widgetWithText(FilledButton, 'Save')).onPressed, isNull);
    expect(secrets.written, isEmpty);
    expect(hosts.library.hosts, isEmpty);
  });

  testWidgets('switching to a stale target reseeds it from the latest host snapshot', (t) async {
    const second = Host(id: HostId('second'), label: 'stale', address: 'second.example', username: 'second');
    await t.runAsync(() async {
      await hosts.save(_host);
      await hosts.save(second.copyWith(label: 'current target'));
    });
    final selected = ValueNotifier<Host>(_host);
    addTearDown(selected.dispose);
    await open(
      t,
      panel: ValueListenableBuilder<Host>(
        valueListenable: selected,
        builder: (_, host, _) => HostForm(host: host),
      ),
    );
    selected.value = second;
    await t.pumpAndSettle();
    expect(find.text('current target'), findsOneWidget);
    expect(find.text('stale'), findsNothing);
    await save(t);
    expect(hosts.byId(second.id)!.label, 'current target');
  });

  testWidgets('saving excludes keyboard focus and ignores late IME updates while credentials are pending', (t) async {
    await createDraft(t);
    await t.enterText(field('Name'), 'submitted');
    final controller = t.widget<TextFormField>(field('Name')).controller!;
    final gate = secrets.pendingWrite = Completer<void>();
    await t.tap(find.text('Save'));
    await until(t, () => secrets.written.isNotEmpty);
    for (var i = 0; i < 10; i++) {
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await t.pump();
      expect(
        find.descendant(
          of: find.byType(HostForm),
          matching: find.byWidgetPredicate((widget) => widget is EditableText && widget.focusNode.hasFocus),
        ),
        findsNothing,
      );
      t.testTextInput.updateEditingValue(const TextEditingValue(text: 'late IME'));
      await t.pump();
    }
    expect(controller.text, 'submitted');
    expect(passwordField(t).controller!.text, 'draft-password');
    gate.complete();
    secrets.pendingWrite = null;
    await until(t, () => find.text('Save').evaluate().isEmpty);
    expect(hosts.library.hosts.single.label, 'submitted');
  });

  testWidgets('a host with an inherited identity keeps that identity and stores only a host-owned password', (t) async {
    await t.runAsync(() async {
      await hosts.saveIdentity(
        const HostIdentity(id: 'shared', label: 'Ops', username: 'operator', policy: AuthPolicy()),
      );
      await hosts.saveDefaults(
        const ConnectionOverrides(authentication: OverrideValue.value(Authentication.identity('shared'))),
      );
    });
    await open(t);
    await t.enterText(field('Address'), 'new.example');
    await t.enterText(field('Password'), 'host-only');
    await save(t);
    final host = hosts.library.hosts.single;
    expect(host.username, 'operator');
    expect(host.overrides!.authentication.mode, OverrideMode.inherit);
    expect(hosts.library.identities.single.username, 'operator');
    expect(secrets.written, [host.passwordRef]);
    expect(secrets.values[host.passwordRef]?.reveal(), 'host-only');
  });

  for (final size in [AppFonts.uiSize, AppFonts.uiSizeMax]) {
    testWidgets('the first populated floating label stays inside the scroll viewport at font size $size', (t) async {
      await t.runAsync(() => hosts.save(_host));
      await open(t, host: hosts.byId(_host.id), fontSize: size);
      final label = find.descendant(of: field('Name'), matching: find.text('Name'));
      final viewport = find.ancestor(of: label, matching: find.byType(Viewport)).first;
      final bounds = t.getRect(label);
      final clip = t.getRect(viewport);
      expect(bounds.top, greaterThanOrEqualTo(clip.top));
      expect(bounds.bottom, lessThanOrEqualTo(clip.bottom));
      expect(t.takeException(), isNull);
    });
  }
}

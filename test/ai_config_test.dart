import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/design/controls.dart';
import 'package:sshairy/design/theme.dart';
import 'package:sshairy/features/ai/application/configuration.dart';
import 'package:sshairy/features/ai/domain/model_profile.dart';
import 'package:sshairy/features/ai/presentation/ai_settings.dart';
import 'package:sshairy/features/credentials/adapters/secure_store.dart';
import 'package:sshairy/features/credentials/api.dart';
import 'package:sshairy/features/credentials/application/credential_access.dart' show secretStoreProvider;
import 'package:sshairy/foundation/data_dir.dart';
import 'package:sshairy/foundation/ids.dart';
import 'package:sshairy/foundation/json_file.dart';
import 'package:sshairy/foundation/secret.dart';
import 'package:sshairy/l10n/app_localizations.dart';

class _Store extends SecretStore {
  final values = <SecretRef, Secret>{};
  final reads = <SecretRef>[], writes = <SecretRef>[], deletes = <SecretRef>[];
  var failRead = false, failWrite = false;

  @override
  Future<Secret?> read(SecretRef ref) async {
    reads.add(ref);
    if (failRead) throw StateError('storage unavailable');
    return values[ref];
  }

  @override
  Future<void> write(SecretRef ref, Secret value) async {
    writes.add(ref);
    if (failWrite) throw StateError('storage unavailable');
    values[ref] = value;
  }

  @override
  Future<void> delete(SecretRef ref) async {
    deletes.add(ref);
    values.remove(ref);
  }
}

class _UiCredentials implements AiCredentials {
  @override
  Stream<void> get changes => const Stream.empty();

  final values = <String, Secret>{};
  final checked = <String>[];
  final saved = <String>[];
  var reads = 0;

  @override
  Future<bool> has(String identity) async {
    checked.add(identity);
    return values.containsKey(identity);
  }

  @override
  Future<Secret?> read(String identity) async {
    reads++;
    return values[identity];
  }

  @override
  Future<void> save(String identity, Secret value) async {
    saved.add(identity);
    values[identity] = value;
  }

  @override
  Future<void> clear(String identity) async {
    values.remove(identity);
  }
}

ModelProfile _profile([String endpoint = 'https://model.example/v1']) =>
    ModelProfile(protocol: ModelProtocol.openai, endpoint: endpoint, model: 'user-selected-model', tools: true);

void main() {
  late Directory dir;
  late ProviderContainer container;
  late _Store store;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('sshairy-ai-config-');
    store = _Store();
    container = ProviderContainer(
      overrides: [dataDirProvider.overrideWithValue(dir.path), secretStoreProvider.overrideWithValue(store)],
    );
  });

  tearDown(() {
    container.dispose();
    dir.deleteSync(recursive: true);
  });

  test('AI starts disabled without creating files or reading secure storage', () {
    final state = container.read(aiConfigurationProvider);
    expect(state.enabled, isFalse);
    expect(state.profile, isNull);
    expect(state.revision, 0);
    expect(state.loadFailed, isFalse);
    expect(dir.listSync(), isEmpty);
    expect(store.reads, isEmpty);
  });

  test('configuration persists only profile metadata and revisions, independent of its key', () async {
    final profile = _profile();
    final notifier = container.read(aiConfigurationProvider.notifier);
    await container.read(aiCredentialsProvider).save(profile.identity, const Secret('synthetic-ai-private-key'));
    await notifier.save(enabled: true, profile: profile);
    await notifier.saved;
    final json = jsonDecode(File('${dir.path}/ai.json').readAsStringSync()) as Map;
    expect(json['enabled'], isTrue);
    expect(json['revision'], 1);
    expect(json['profile'], profile.toJson());
    expect(jsonEncode(json), isNot(contains('synthetic-ai-private-key')));
    final restart = ProviderContainer(overrides: [dataDirProvider.overrideWithValue(dir.path)]);
    try {
      final state = restart.read(aiConfigurationProvider);
      expect(state.enabled, isTrue);
      expect(state.profile!.identity, profile.identity);
      expect(state.revision, 1);
    } finally {
      restart.dispose();
    }
    await notifier.save(enabled: false, profile: profile, expectedRevision: 1);
    expect(container.read(aiConfigurationProvider).revision, 2);
  });

  test('bad and future configuration stay protected while AI remains disabled', () async {
    final file = File('${dir.path}/ai.json');
    for (final content in [
      '{broken',
      '{"schemaVersion":99,"enabled":true,"profile":null}',
      '{"enabled":true,"profile":null}',
      '{"enabled":false,"profile":null,"apiKey":"synthetic-key"}',
    ]) {
      file.writeAsStringSync(content);
      container.invalidate(aiConfigurationProvider);
      final state = container.read(aiConfigurationProvider);
      expect(state.enabled, isFalse);
      expect(state.loadFailed, isTrue);
      await expectLater(
        container.read(aiConfigurationProvider.notifier).save(enabled: false, profile: null),
        throwsA(isA<JsonFileError>()),
      );
      expect(file.readAsStringSync(), content);
    }
    file.writeAsStringSync('{"schemaVersion":1,"revision":3,"enabled":false,"profile":null}');
    container.read(aiConfigurationProvider.notifier).reload();
    expect(container.read(aiConfigurationProvider).loadFailed, isFalse);
    expect(container.read(aiConfigurationProvider).revision, 3);
  });

  test('stale configuration cannot overwrite a newer profile', () async {
    final notifier = container.read(aiConfigurationProvider.notifier);
    await notifier.save(enabled: false, profile: _profile());
    final before = File('${dir.path}/ai.json').readAsBytesSync();
    await expectLater(
      notifier.save(enabled: true, profile: _profile(), expectedRevision: 0),
      throwsA(isA<JsonFileError>().having((error) => error.kind, 'kind', JsonFileFailure.conflict)),
    );
    expect(File('${dir.path}/ai.json').readAsBytesSync(), before);
    expect(container.read(aiConfigurationProvider).enabled, isFalse);
    await notifier.save(enabled: true, profile: _profile(), expectedRevision: 1);
    expect(container.read(aiConfigurationProvider).revision, 2);
  });

  test('API keys have a dedicated exact destination namespace and never alter SSH or translation keys', () async {
    final identity = _profile().identity, other = _profile('https://other.example/v1').identity;
    final hostRef = SecretRef.hostPassword(const HostId('host'));
    final translation = SecretRef.translation(identity);
    store.values[hostRef] = const Secret('synthetic-host-password');
    store.values[translation] = const Secret('synthetic-translation-key');
    final credentials = container.read(aiCredentialsProvider);
    final ssh = container.read(connectionCredentialsProvider);
    final revision = ssh.revision;
    await credentials.save(identity, const Secret('synthetic-ai-key'));
    expect(await credentials.has(identity), isTrue);
    expect(await credentials.has(other), isFalse);
    expect((await credentials.read(identity))!.reveal(), 'synthetic-ai-key');
    expect(SecretRef.ai(identity).storageKey, 'ai/${Uri.encodeComponent(identity)}/apiKey');
    expect(SecretRef.ai('a/b'), isNot(SecretRef.ai('a%2Fb')));
    await credentials.clear(identity);
    expect(store.values[hostRef]!.reveal(), 'synthetic-host-password');
    expect(store.values[translation]!.reveal(), 'synthetic-translation-key');
    expect(ssh.revision, revision);
    expect(store.deletes, [SecretRef.ai(identity)]);
  });

  test('AI key validation and storage failures do not leak values or poison the shared queue', () async {
    final credentials = container.read(aiCredentialsProvider), identity = _profile().identity;
    for (final invalid in [
      '',
      '  ',
      'x' * 8193,
      'synthetic-private-marker\r\nheader',
      'synthetic-private-marker\u007f',
    ]) {
      await expectLater(
        credentials.save(identity, Secret(invalid)),
        throwsA(
          isA<ArgumentError>().having((error) => '$error', 'safe error', isNot(contains('synthetic-private-marker'))),
        ),
      );
    }
    expect(store.writes, isEmpty);
    for (final invalid in ['', ' ', 'x' * 4097, 'identity\n']) {
      await expectLater(credentials.has(invalid), throwsArgumentError);
      await expectLater(credentials.read(invalid), throwsArgumentError);
      await expectLater(credentials.save(invalid, const Secret('synthetic-key')), throwsArgumentError);
      await expectLater(credentials.clear(invalid), throwsArgumentError);
    }
    store.failWrite = true;
    await expectLater(credentials.save(identity, const Secret('synthetic-key')), throwsStateError);
    store.failWrite = false;
    await credentials.save(identity, const Secret('synthetic-key'));
    store.failRead = true;
    await expectLater(credentials.has(identity), throwsStateError);
    store.failRead = false;
    expect((await credentials.read(identity))!.reveal(), 'synthetic-key');
    store.values[SecretRef.ai(identity)] = const Secret('synthetic-invalid\nkey');
    await expectLater(credentials.read(identity), throwsArgumentError);
  });

  test('every attempted key mutation revokes requests, including partial platform failure', () async {
    final credentials = container.read(aiCredentialsProvider), identity = _profile().identity;
    var changes = 0;
    final subscription = credentials.changes.listen((_) => changes++);
    await credentials.has(identity);
    await credentials.read(identity);
    expect(changes, 0);
    await expectLater(credentials.save(identity, const Secret('')), throwsArgumentError);
    expect(changes, 0);
    await credentials.save(identity, const Secret('synthetic-key'));
    expect(changes, 1);
    store.failWrite = true;
    await expectLater(credentials.save(identity, const Secret('synthetic-replacement')), throwsStateError);
    expect(changes, 2);
    await credentials.clear(identity);
    expect(changes, 3);
    expect(container.read(connectionCredentialsProvider).revision, 0);
    await subscription.cancel();
  });

  test('AI credential operations wait for the same SSH import queue', () async {
    final entered = Completer<void>(), release = Completer<void>();
    final importing = container.read(hostPasswordImportProvider).importMissing({}, () async {
      entered.complete();
      await release.future;
    });
    await entered.future;
    var finished = false;
    final saving = container
        .read(aiCredentialsProvider)
        .save(_profile().identity, const Secret('synthetic-key'))
        .then((_) => finished = true);
    await Future<void>.delayed(Duration.zero);
    expect(finished, isFalse);
    expect(store.writes, isEmpty);
    release.complete();
    await importing;
    await saving;
    expect(finished, isTrue);
  });

  Future<void> drainConfiguration(WidgetTester tester, ProviderContainer scope) async {
    var complete = false;
    Object? failure;
    scope
        .read(aiConfigurationProvider.notifier)
        .saved
        .then(
          (_) => complete = true,
          onError: (Object error) {
            failure = error;
            complete = true;
          },
        );
    await tester.pump();
    for (var attempt = 0; !complete && attempt < 250; attempt++) {
      // Real IO progresses outside FakeAsync; its completion and notifier microtasks are then pumped here.
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(complete, isTrue, reason: 'AI configuration writes must finish within the bounded drain');
    expect(failure, isNull);
  }

  Future<_UiCredentials> showSettings(WidgetTester tester, {bool configured = true}) async {
    final credentials = _UiCredentials();
    final profile = _profile();
    if (configured) {
      File('${dir.path}/ai.json').writeAsStringSync(
        jsonEncode({'schemaVersion': 1, 'revision': 1, 'enabled': false, 'profile': profile.toJson()}),
      );
      credentials.values[profile.identity] = const Secret('synthetic-existing-key');
    }
    final scope = ProviderContainer(
      overrides: [dataDirProvider.overrideWithValue(dir.path), aiCredentialsProvider.overrideWithValue(credentials)],
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await drainConfiguration(tester, scope);
      scope.dispose();
    });
    await tester.binding.setSurfaceSize(const Size(900, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: scope,
        child: MaterialApp(
          theme: buildTheme(Brightness.light, Accent.blue).copyWith(splashFactory: NoSplash.splashFactory),
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(
            body: SingleChildScrollView(child: SizedBox(width: 500, child: AiSettings())),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return credentials;
  }

  testWidgets('settings only check saved key presence, and changing destinations clears the unsaved key', (
    tester,
  ) async {
    final credentials = await showSettings(tester);
    final key = find.byKey(const ValueKey('ai-config-key'));
    expect(tester.widget<TextField>(key).controller!.text, isEmpty);
    expect(tester.widget<TextField>(key).obscureText, isTrue);
    expect(credentials.reads, 0);
    await tester.enterText(key, 'synthetic-new-key');
    await tester.enterText(find.byKey(const ValueKey('ai-config-endpoint')), 'https://other.example/v1');
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(key).controller!.text, isEmpty);
    expect(credentials.reads, 0);
    expect(credentials.checked.last, _profile('https://other.example/v1').identity);
    expect(credentials.saved, isEmpty);
  });

  testWidgets('saving an enable change retains an existing key without reading it into the form', (tester) async {
    final credentials = await showSettings(tester);
    final toggle = tester.widget<AppToggleRow>(find.byType(AppToggleRow).first);
    toggle.onChanged!(true);
    await tester.pump();
    final context = tester.element(find.byType(AiSettings));
    final scope = ProviderScope.containerOf(context);
    await tester.tap(find.byKey(const ValueKey('ai-config-save')));
    await tester.pump();
    await drainConfiguration(tester, scope);
    await tester.pumpAndSettle();
    expect(credentials.reads, 0);
    expect(credentials.saved, isEmpty);
    expect(credentials.values[_profile().identity]!.reveal(), 'synthetic-existing-key');
    expect((jsonDecode(File('${dir.path}/ai.json').readAsStringSync()) as Map)['enabled'], isTrue);
  });
}

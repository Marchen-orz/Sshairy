import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/design/controls.dart';
import 'package:sshairy/design/theme.dart';
import 'package:sshairy/design/select.dart';
import 'package:sshairy/features/ai/presentation/model_picker.dart';
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
  var failRead = false, failHas = false;

  @override
  Future<bool> has(String identity) async {
    checked.add(identity);
    if (failHas) throw StateError('secure storage unavailable');
    return values.containsKey(identity);
  }

  @override
  Future<Secret?> read(String identity) async {
    reads++;
    if (failRead) throw StateError('secure storage unavailable');
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
    expect(state.inlineEnabled, isTrue);
    expect(state.completionEnabled, isTrue);
    expect(state.inlineExcludedHosts, isEmpty);
    expect(state.completionExcludedHosts, isEmpty);
    expect(state.reviewModel, isNull);
    expect(state.profileForReview, isNull);
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

  test('schema two without an approval model leaves the runtime fallback without rewriting', () {
    final profile = _profile();
    final file = File('${dir.path}/ai.json');
    final content = jsonEncode({'schemaVersion': 2, 'revision': 7, 'enabled': true, 'profile': profile.toJson()});
    file.writeAsStringSync(content);
    final state = container.read(aiConfigurationProvider);
    expect(state.loadFailed, isFalse);
    expect(state.revision, 7);
    expect(state.reviewModel, isNull);
    expect(state.profileForReview, isNull);
    expect(file.readAsStringSync(), content);
    expect(store.reads, isEmpty);
  });

  test('bad and future configuration stay protected while AI remains disabled', () async {
    final file = File('${dir.path}/ai.json');
    for (final content in [
      '{broken',
      '{"schemaVersion":99,"enabled":true,"profile":null}',
      '{"enabled":true,"profile":null}',
      '{"enabled":false,"profile":null,"apiKey":"synthetic-key"}',
      '{"schemaVersion":2,"enabled":false,"profile":null,"reviewModel":"reviewer"}',
      jsonEncode({'schemaVersion': 2, 'enabled': false, 'profile': _profile().toJson(), 'reviewModel': 12}),
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

  test('terminal features default on and preserve independent exclusions across model and service changes', () async {
    final notifier = container.read(aiConfigurationProvider.notifier);
    await notifier.save(enabled: true, profile: _profile());
    final initial = container.read(aiConfigurationProvider);
    expect(initial.inlineEnabled, isTrue);
    expect(initial.completionEnabled, isTrue);
    expect(initial.inlineExcludedHosts, isEmpty);
    expect(initial.completionExcludedHosts, isEmpty);
    await notifier.save(
      enabled: true,
      profile: _profile(),
      inlineEnabled: false,
      inlineExcludedHosts: {const HostId('web')},
      completionExcludedHosts: {const HostId('db')},
    );
    final restart = ProviderContainer(overrides: [dataDirProvider.overrideWithValue(dir.path)]);
    try {
      final state = restart.read(aiConfigurationProvider);
      expect(state.inlineEnabled, isFalse);
      expect(state.completionEnabled, isTrue);
      expect(state.inlineExcludedHosts, {const HostId('web')});
      expect(state.completionExcludedHosts, {const HostId('db')});
    } finally {
      restart.dispose();
    }
    await notifier.save(
      enabled: true,
      profile: _profile('https://new.example/v1'),
      inlineModel: 'new-inline',
      completionModel: 'new-completion',
    );
    final changed = container.read(aiConfigurationProvider);
    expect(changed.inlineEnabled, isFalse);
    expect(changed.completionEnabled, isTrue);
    expect(changed.inlineExcludedHosts, {const HostId('web')});
    expect(changed.completionExcludedHosts, {const HostId('db')});
    final json = jsonDecode(File('${dir.path}/ai.json').readAsStringSync()) as Map;
    expect(json['schemaVersion'], 2);
    for (final old in ['completionHistory', 'completionPosix', 'completionHosts', 'terminalDestination']) {
      expect(json.containsKey(old), isFalse);
    }
  });

  test('migration rejects malformed legacy policies and leaves their files untouched', () async {
    final file = File('${dir.path}/ai.json');
    final legacy = {'schemaVersion': 1, 'revision': 4, 'enabled': true, 'profile': _profile().toJson()};
    for (final invalid in [
      {...legacy, 'unknownPolicy': true},
      {...legacy, 'completionHosts': []},
      {
        ...legacy,
        'completionHosts': {'bad host': 'route'},
      },
      {
        ...legacy,
        'completionHosts': {'web': 12},
      },
      {...legacy, 'completionHistory': 'yes'},
      {...legacy, 'terminalDestination': 'another-destination'},
    ]) {
      final content = jsonEncode(invalid);
      file.writeAsStringSync(content);
      container.invalidate(aiConfigurationProvider);
      expect(container.read(aiConfigurationProvider).loadFailed, isTrue);
      await expectLater(
        container.read(aiConfigurationProvider.notifier).save(enabled: false, profile: null),
        throwsA(isA<JsonFileError>().having((error) => error.kind, 'kind', JsonFileFailure.migrationFailed)),
      );
      expect(file.readAsStringSync(), content);
    }
  });

  test('schema two rejects malformed host exclusions without overwriting the file', () async {
    final file = File('${dir.path}/ai.json');
    for (final excluded in [
      null,
      ['web', 'web'],
      [12],
      ['bad host'],
      {'web': true},
    ]) {
      final content = jsonEncode({
        'schemaVersion': 2,
        'enabled': true,
        'profile': _profile().toJson(),
        'inlineExcludedHosts': excluded,
      });
      file.writeAsStringSync(content);
      container.invalidate(aiConfigurationProvider);
      expect(container.read(aiConfigurationProvider).loadFailed, isTrue);
      await expectLater(
        container.read(aiConfigurationProvider.notifier).save(enabled: false, profile: null),
        throwsA(isA<JsonFileError>()),
      );
      expect(file.readAsStringSync(), content);
    }
  });

  test('new model defaults enable Agent tools and use one million context tokens', () {
    final profile = ModelProfile(protocol: ModelProtocol.openai, endpoint: 'https://model.example/v1', model: 'agent');
    expect(profile.tools, isTrue);
    expect(profile.contextWindow, 1000000);
    expect(profile.maxOutputTokens, 4096);
    final inline = profile.withModel('inline', tools: false);
    expect(inline.model, 'inline');
    expect(inline.tools, isFalse);
    expect(inline.endpoint, profile.endpoint);
    expect(inline.contextWindow, profile.contextWindow);
  });

  test('legacy policy migrates to default models with both terminal features enabled', () {
    final profile = _profile();
    File('${dir.path}/ai.json').writeAsStringSync(
      jsonEncode({
        'schemaVersion': 1,
        'revision': 4,
        'enabled': true,
        'profile': profile.toJson(),
        'inlineEnabled': false,
        'completionEnabled': false,
        'completionHistory': false,
        'completionPosix': false,
        'completionHosts': {'web': 'old-route'},
        'terminalDestination': profile.identity,
      }),
    );
    final state = container.read(aiConfigurationProvider);
    expect(state.loadFailed, isFalse);
    expect(state.inlineModel, profile.model);
    expect(state.completionModel, profile.model);
    expect(state.profileForInline!.tools, isFalse);
    expect(state.inlineEnabled, isTrue);
    expect(state.completionEnabled, isTrue);
    expect(state.inlineExcludedHosts, isEmpty);
    expect(state.completionExcludedHosts, isEmpty);
  });

  test('independent role models persist without resetting feature choices', () async {
    final notifier = container.read(aiConfigurationProvider.notifier);
    await notifier.save(
      enabled: true,
      profile: _profile(),
      inlineModel: 'inline-fast',
      completionModel: 'complete-fast',
      reviewModel: 'review-model',
      inlineEnabled: false,
      completionEnabled: true,
      inlineExcludedHosts: {const HostId('web')},
    );
    final before = container.read(aiConfigurationProvider);
    expect(before.profileForInline!.model, 'inline-fast');
    expect(before.profileForCompletion!.model, 'complete-fast');
    expect(before.profileForInline!.tools, isFalse);
    expect(before.profileForCompletion!.tools, isFalse);
    expect(before.profileForReview!.model, 'review-model');
    expect(before.profileForReview!.tools, isFalse);
    expect(before.profileForReview!.endpoint, before.profile!.endpoint);
    expect(before.profileForReview!.contextWindow, before.profile!.contextWindow);
    expect(before.profileForReview!.maxOutputTokens, before.profile!.maxOutputTokens);
    final restarted = ProviderContainer(overrides: [dataDirProvider.overrideWithValue(dir.path)]);
    expect(restarted.read(aiConfigurationProvider).inlineModel, 'inline-fast');
    expect(restarted.read(aiConfigurationProvider).completionModel, 'complete-fast');
    expect(restarted.read(aiConfigurationProvider).reviewModel, 'review-model');
    restarted.dispose();
    await notifier.save(enabled: true, profile: _profile(), inlineModel: 'another-inline');
    final changed = container.read(aiConfigurationProvider);
    expect(changed.inlineEnabled, isFalse);
    expect(changed.completionEnabled, isTrue);
    expect(changed.inlineExcludedHosts, {const HostId('web')});
    expect(changed.completionModel, 'complete-fast');
    expect(changed.reviewModel, 'review-model');
    await notifier.save(enabled: true, profile: _profile().withModel('new-agent'));
    expect(container.read(aiConfigurationProvider).reviewModel, 'review-model');
    await notifier.save(enabled: true, profile: _profile('https://other.example/v1'));
    final newProvider = container.read(aiConfigurationProvider);
    expect(newProvider.reviewModel, isNull);
    expect(newProvider.profileForReview, isNull);
    final json = jsonDecode(File('${dir.path}/ai.json').readAsStringSync()) as Map;
    expect(json['schemaVersion'], 2);
    expect(json['reviewModel'], isNull);
  });

  test('invalid role model and malformed host exclusions protect the file', () async {
    final notifier = container.read(aiConfigurationProvider.notifier);
    await notifier.save(enabled: true, profile: _profile());
    final file = File('${dir.path}/ai.json');
    final original = file.readAsBytesSync();
    for (final role in ['inline', 'review']) {
      await expectLater(
        notifier.save(
          enabled: true,
          profile: _profile(),
          inlineModel: role == 'inline' ? 'bad model' : null,
          reviewModel: role == 'review' ? 'bad model' : null,
        ),
        throwsA(isA<JsonFileError>().having((error) => error.kind, 'kind', JsonFileFailure.corrupt)),
      );
      expect(file.readAsBytesSync(), original);
    }
    final invalid = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    invalid['inlineExcludedHosts'] = ['bad host id'];
    file.writeAsStringSync(jsonEncode(invalid));
    container.invalidate(aiConfigurationProvider);
    expect(container.read(aiConfigurationProvider).loadFailed, isTrue);
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

  Future<_UiCredentials> showSettings(
    WidgetTester tester, {
    bool configured = true,
    bool enabled = false,
    double width = 500,
    Brightness brightness = Brightness.light,
    String? fontFamily,
    double textScale = 1,
    List<AiTerminalHost> hosts = const [],
  }) async {
    final credentials = _UiCredentials();
    final profile = _profile();
    if (configured) {
      File('${dir.path}/ai.json').writeAsStringSync(
        jsonEncode({'schemaVersion': 2, 'revision': 1, 'enabled': enabled, 'profile': profile.toJson()}),
      );
      credentials.values[profile.identity] = const Secret('synthetic-existing-key');
    }
    final scope = ProviderContainer(
      overrides: [
        dataDirProvider.overrideWithValue(dir.path),
        aiCredentialsProvider.overrideWithValue(credentials),
        aiTerminalHostsProvider.overrideWithValue(hosts),
      ],
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
          theme: buildTheme(
            brightness,
            Accent.blue,
            AppFonts.uiSize,
            fontFamily,
          ).copyWith(splashFactory: NoSplash.splashFactory),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: SingleChildScrollView(
              child: SizedBox(width: width, child: const AiSettings()),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return credentials;
  }

  testWidgets('new settings default to OpenAI with optional key before models and visible limits', (tester) async {
    await showSettings(tester, configured: false);
    final protocol = tester.widget<AppSelect<ModelProtocol>>(find.byType(AppSelect<ModelProtocol>));
    expect(protocol.value, ModelProtocol.openai);
    final endpoint = find.byKey(const ValueKey('ai-config-endpoint'));
    final key = find.byKey(const ValueKey('ai-config-key'));
    final model = find.byKey(const ValueKey('ai-config-model'));
    expect(tester.getTopLeft(endpoint).dy, lessThan(tester.getTopLeft(key).dy));
    expect(tester.getTopLeft(key).dy, lessThan(tester.getTopLeft(model).dy));
    expect(tester.widget<TextField>(key).enabled, isFalse);
    await tester.enterText(endpoint, 'https://model.example/v1');
    await tester.pump();
    expect(tester.widget<TextField>(key).enabled, isTrue);
    expect(tester.widget<AiModelPicker>(model).value, isEmpty);
    final review = find.byKey(const ValueKey('ai-config-review-model'));
    expect(tester.widget<AiModelPicker>(review).value, isEmpty);
    expect(tester.widget<AiModelPicker>(review).label, 'Approval model');
    expect(tester.getTopLeft(model).dy, lessThan(tester.getTopLeft(review).dy));
    expect(tester.widget<AppSelect<int>>(find.byKey(const ValueKey('ai-config-context-preset'))).value, 1000000);
    expect(tester.widget<TextFormField>(find.byKey(const ValueKey('ai-config-max-output'))).controller!.text, '4096');
    expect(find.byKey(const ValueKey('ai-config-advanced')), findsNothing);
    expect(find.text('Provide model tools'), findsNothing);
    expect(tester.widget<AppToggleRow>(find.byKey(const ValueKey('ai-config-inline'))).value, isTrue);
    expect(tester.widget<AppToggleRow>(find.byKey(const ValueKey('ai-config-completion'))).value, isTrue);
    expect(find.byKey(const ValueKey('ai-config-inline-advanced')), findsOneWidget);
    expect(find.byKey(const ValueKey('ai-config-completion-advanced')), findsOneWidget);
    expect(find.byKey(const ValueKey('ai-config-posix')), findsNothing);
    expect(find.byKey(const ValueKey('ai-config-history')), findsNothing);
  });

  Rect fieldContainer(WidgetTester tester, Finder field) {
    final editable = find.descendant(of: field, matching: find.byType(EditableText));
    if (editable.evaluate().isEmpty) return tester.getRect(field);
    final container = InputDecorator.containerOf(tester.element(editable))!;
    return container.localToGlobal(Offset.zero) & container.size;
  }

  testWidgets('an optional API key check failure leaves saving available', (tester) async {
    final credentials = await showSettings(tester, configured: false);
    final l = AppLocalizations.of(tester.element(find.byType(AiSettings)));
    final endpoint = find.byKey(const ValueKey('ai-config-endpoint'));
    await tester.enterText(endpoint, 'https://model.example/v1');
    await tester.pump();
    tester.widget<AiModelPicker>(find.byKey(const ValueKey('ai-config-model'))).onChanged!('agent-new');
    await tester.pumpAndSettle();
    expect(find.text(l.aiConfigKeyMissing), findsOneWidget);
    credentials.failHas = true;
    await tester.enterText(endpoint, 'https://model.example/v2');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(find.text(l.aiConfigKeyLoadFailed), findsOneWidget);
    final save = find.byKey(const ValueKey('ai-config-save'));
    expect(tester.widget<FilledButton>(save).onPressed, isNotNull);
    expect(tester.widget<TextField>(find.byKey(const ValueKey('ai-config-key'))).enabled, isFalse);
  });

  testWidgets('AI settings align labelled inputs and selections at the same control height', (tester) async {
    await showSettings(tester, enabled: true, width: 820);
    final preset = find.byKey(const ValueKey('ai-config-context-preset'));
    tester.widget<AppSelect<int>>(preset).onChanged!(-1);
    await tester.pumpAndSettle();
    final custom = find.byKey(const ValueKey('ai-config-context-custom'));
    final output = find.byKey(const ValueKey('ai-config-max-output'));
    final modelButton = find.descendant(
      of: find.byKey(const ValueKey('ai-config-model')),
      matching: find.byType(OutlinedButton),
    );
    for (final field in [
      find.byType(AppSelect<ModelProtocol>),
      find.byKey(const ValueKey('ai-config-endpoint')),
      find.byKey(const ValueKey('ai-config-key')),
      modelButton,
      preset,
      custom,
      output,
    ]) {
      expect(fieldContainer(tester, field).height, closeTo(WorkspaceSize.control, .01));
    }
    expect(tester.getTopLeft(preset).dy, tester.getTopLeft(custom).dy);
    expect(tester.getTopLeft(custom).dy, tester.getTopLeft(output).dy);
    expect(tester.getSize(preset).width, tester.getSize(custom).width);
    expect(tester.getSize(custom).width, tester.getSize(output).width);
    expect(tester.takeException(), isNull);
  });

  Future<void> loadFieldFont(WidgetTester tester) async {
    final path = '${Platform.environment['WINDIR'] ?? 'C:/Windows'}/Fonts/segoeui.ttf';
    await tester.runAsync(() async {
      final loader = FontLoader('SshairyFieldGeometry')
        ..addFont(Future.value(ByteData.sublistView(await File(path).readAsBytes())));
      await loader.load();
    });
  }

  for (final brightness in Brightness.values) {
    testWidgets('AI settings paint matching field borders with real UI font in ${brightness.name}', (tester) async {
      await loadFieldFont(tester);
      await showSettings(tester, enabled: true, width: 820, brightness: brightness, fontFamily: 'SshairyFieldGeometry');
      final endpoint = find.byKey(const ValueKey('ai-config-endpoint'));
      final key = find.byKey(const ValueKey('ai-config-key'));
      final protocol = find.byType(AppSelect<ModelProtocol>);
      final preset = find.byKey(const ValueKey('ai-config-context-preset'));
      final output = find.byKey(const ValueKey('ai-config-max-output'));
      final model = find.descendant(
        of: find.byKey(const ValueKey('ai-config-model')),
        matching: find.byType(OutlinedButton),
      );
      for (final field in [endpoint, key, protocol, preset, output, model]) {
        expect(fieldContainer(tester, field).height, closeTo(WorkspaceSize.control, .01));
      }
      expect(fieldContainer(tester, output).top, closeTo(fieldContainer(tester, preset).top, .01));
      final decoration = tester
          .widget<InputDecorator>(find.descendant(of: endpoint, matching: find.byType(InputDecorator)))
          .decoration;
      final selectDecoration =
          tester
                  .widget<AnimatedContainer>(find.descendant(of: protocol, matching: find.byType(AnimatedContainer)))
                  .decoration!
              as BoxDecoration;
      final buttonStyle = tester.widget<OutlinedButton>(model).style!;
      expect(decoration.enabledBorder!.borderSide, selectDecoration.border!.top);
      expect(decoration.enabledBorder!.borderSide, buttonStyle.side!.resolve({}));
      expect(decoration.focusedBorder!.borderSide, buttonStyle.side!.resolve({WidgetState.focused}));
      expect(decoration.disabledBorder!.borderSide, buttonStyle.side!.resolve({WidgetState.disabled}));
      final fill = (decoration.fillColor! as WidgetStateColor).resolve({});
      expect(fill, selectDecoration.color);
      expect(fill, buttonStyle.backgroundColor!.resolve({}));
      expect((decoration.enabledBorder! as OutlineInputBorder).borderRadius, BorderRadius.circular(Radii.control));
      await tester.enterText(output, 'invalid');
      tester.state<FormState>(find.byType(Form)).validate();
      await tester.pumpAndSettle();
      expect(fieldContainer(tester, output).height, closeTo(WorkspaceSize.control, .01));
      expect(tester.getSize(output).height, greaterThan(WorkspaceSize.control));
      expect(tester.takeException(), isNull);
    }, skip: !Platform.isWindows);
  }

  testWidgets('AI settings field borders grow together for large UI text', (tester) async {
    await loadFieldFont(tester);
    await showSettings(tester, enabled: true, width: 820, fontFamily: 'SshairyFieldGeometry', textScale: 1.5);
    final preset = find.byKey(const ValueKey('ai-config-context-preset'));
    final height = fieldContainer(tester, preset).height;
    expect(height, greaterThan(WorkspaceSize.control));
    for (final field in [
      find.byKey(const ValueKey('ai-config-endpoint')),
      find.byKey(const ValueKey('ai-config-key')),
      find.byKey(const ValueKey('ai-config-max-output')),
      find.descendant(of: find.byKey(const ValueKey('ai-config-model')), matching: find.byType(OutlinedButton)),
    ]) {
      expect(fieldContainer(tester, field).height, closeTo(height, .01));
    }
    expect(tester.takeException(), isNull);
  }, skip: !Platform.isWindows);

  testWidgets('AI settings wrap capacity fields into equal aligned columns in a narrow form', (tester) async {
    await showSettings(tester, enabled: true);
    final preset = find.byKey(const ValueKey('ai-config-context-preset'));
    tester.widget<AppSelect<int>>(preset).onChanged!(-1);
    await tester.pumpAndSettle();
    final custom = find.byKey(const ValueKey('ai-config-context-custom'));
    final output = find.byKey(const ValueKey('ai-config-max-output'));
    expect(tester.getTopLeft(preset).dy, tester.getTopLeft(custom).dy);
    expect(tester.getTopLeft(output).dy, greaterThan(tester.getTopLeft(custom).dy));
    expect(tester.getTopLeft(output).dx, tester.getTopLeft(preset).dx);
    expect(tester.getSize(custom), tester.getSize(output));
    expect(tester.takeException(), isNull);
  });

  testWidgets('feature host filters start collapsed and exclude hosts independently', (tester) async {
    const web = HostId('web'), db = HostId('db');
    await showSettings(
      tester,
      enabled: true,
      hosts: [const AiTerminalHost(web, 'Web', 'route-web'), const AiTerminalHost(db, 'DB', 'route-db')],
    );
    final inlineAdvanced = find.byKey(const ValueKey('ai-config-inline-advanced'));
    final completionAdvanced = find.byKey(const ValueKey('ai-config-completion-advanced'));
    final inlineWeb = find.byKey(const ValueKey('ai-config-inline-host-web'));
    final inlineDb = find.byKey(const ValueKey('ai-config-inline-host-db'));
    final completionWeb = find.byKey(const ValueKey('ai-config-completion-host-web'));
    final completionDb = find.byKey(const ValueKey('ai-config-completion-host-db'));
    expect(inlineWeb, findsNothing);
    expect(completionWeb, findsNothing);
    await tester.ensureVisible(inlineAdvanced);
    await tester.tap(inlineAdvanced);
    await tester.pumpAndSettle();
    expect(tester.widget<AppToggleRow>(inlineWeb).value, isTrue);
    expect(tester.widget<AppToggleRow>(inlineDb).value, isTrue);
    tester.widget<AppToggleRow>(inlineWeb).onChanged!(false);
    await tester.pump();
    await tester.ensureVisible(completionAdvanced);
    await tester.tap(completionAdvanced);
    await tester.pumpAndSettle();
    expect(tester.widget<AppToggleRow>(completionWeb).value, isTrue);
    expect(tester.widget<AppToggleRow>(completionDb).value, isTrue);
    tester.widget<AppToggleRow>(completionDb).onChanged!(false);
    await tester.pump();
    tester.widget<AiModelPicker>(find.byKey(const ValueKey('ai-config-inline-model'))).onChanged!('inline-new');
    tester.widget<AiModelPicker>(find.byKey(const ValueKey('ai-config-completion-model'))).onChanged!('completion-new');
    await tester.pump();
    expect(tester.widget<AppToggleRow>(find.byKey(const ValueKey('ai-config-inline'))).value, isTrue);
    expect(tester.widget<AppToggleRow>(find.byKey(const ValueKey('ai-config-completion'))).value, isTrue);
    expect(tester.widget<AppToggleRow>(inlineWeb).value, isFalse);
    expect(tester.widget<AppToggleRow>(completionDb).value, isFalse);
    await tester.ensureVisible(find.byKey(const ValueKey('ai-config-endpoint')));
    await tester.enterText(find.byKey(const ValueKey('ai-config-endpoint')), 'https://different.example/v1');
    await tester.pumpAndSettle();
    expect(tester.widget<AppToggleRow>(inlineWeb).value, isFalse);
    expect(tester.widget<AppToggleRow>(completionDb).value, isFalse);
    final scope = ProviderScope.containerOf(tester.element(find.byType(AiSettings)));
    await tester.ensureVisible(find.byKey(const ValueKey('ai-config-save')));
    await tester.tap(find.byKey(const ValueKey('ai-config-save')));
    await tester.pump();
    await drainConfiguration(tester, scope);
    await tester.pumpAndSettle();
    final state = scope.read(aiConfigurationProvider);
    expect(state.inlineExcludedHosts, {web});
    expect(state.completionExcludedHosts, {db});
    expect(state.inlineEnabled, isTrue);
    expect(state.completionEnabled, isTrue);
    tester.widget<AppToggleRow>(find.byKey(const ValueKey('ai-config-inline'))).onChanged!(false);
    await tester.pump();
    expect(inlineAdvanced, findsNothing);
    expect(completionAdvanced, findsOneWidget);
  });

  testWidgets('switching global AI off and on preserves independently disabled features', (tester) async {
    await showSettings(tester, enabled: true);
    final inline = find.byKey(const ValueKey('ai-config-inline'));
    final completion = find.byKey(const ValueKey('ai-config-completion'));
    tester.widget<AppToggleRow>(inline).onChanged!(false);
    tester.widget<AppToggleRow>(completion).onChanged!(false);
    await tester.pump();
    final enabled = tester.widget<AppToggleRow>(find.byType(AppToggleRow).first);
    enabled.onChanged!(false);
    await tester.pump();
    tester.widget<AppToggleRow>(find.byType(AppToggleRow).first).onChanged!(true);
    await tester.pump();
    expect(tester.widget<AppToggleRow>(inline).value, isFalse);
    expect(tester.widget<AppToggleRow>(completion).value, isFalse);
    final scope = ProviderScope.containerOf(tester.element(find.byType(AiSettings)));
    await tester.ensureVisible(find.byKey(const ValueKey('ai-config-save')));
    await tester.tap(find.byKey(const ValueKey('ai-config-save')));
    await tester.pump();
    await drainConfiguration(tester, scope);
    await tester.pumpAndSettle();
    expect(scope.read(aiConfigurationProvider).inlineEnabled, isFalse);
    expect(scope.read(aiConfigurationProvider).completionEnabled, isFalse);
  });

  testWidgets('approval model changes are dirty, resettable and save independently without reading a key', (
    tester,
  ) async {
    final credentials = await showSettings(tester);
    final review = find.byKey(const ValueKey('ai-config-review-model'));
    final save = find.byKey(const ValueKey('ai-config-save'));
    final l = AppLocalizations.of(tester.element(find.byType(AiSettings)));
    expect(tester.widget<AiModelPicker>(review).value, _profile().model);
    expect(tester.widget<FilledButton>(save).onPressed, isNull);
    tester.widget<AiModelPicker>(review).onChanged!('review-model');
    await tester.pump();
    expect(tester.widget<FilledButton>(save).onPressed, isNotNull);
    tester.widget<TextButton>(find.widgetWithText(TextButton, l.cancel)).onPressed!();
    await tester.pumpAndSettle();
    expect(tester.widget<AiModelPicker>(review).value, _profile().model);
    expect(tester.widget<FilledButton>(save).onPressed, isNull);
    tester.widget<AiModelPicker>(review).onChanged!('review-model');
    await tester.pump();
    final scope = ProviderScope.containerOf(tester.element(find.byType(AiSettings)));
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pump();
    await drainConfiguration(tester, scope);
    await tester.pumpAndSettle();
    final state = scope.read(aiConfigurationProvider);
    expect(state.reviewModel, 'review-model');
    expect(state.profile!.model, _profile().model);
    expect(state.inlineModel, _profile().model);
    expect(state.completionModel, _profile().model);
    expect(tester.widget<AiModelPicker>(review).value, 'review-model');
    expect(tester.widget<FilledButton>(save).onPressed, isNull);
    expect(credentials.reads, 0);
    expect(credentials.saved, isEmpty);
  });

  testWidgets('model changes retain a typed key and save independent model selections', (tester) async {
    final credentials = await showSettings(tester);
    final key = find.byKey(const ValueKey('ai-config-key'));
    final review = find.byKey(const ValueKey('ai-config-review-model'));
    await tester.enterText(key, 'synthetic-new-key');
    tester.widget<AiModelPicker>(find.byKey(const ValueKey('ai-config-model'))).onChanged!('agent-new');
    await tester.pump();
    expect(tester.widget<AiModelPicker>(review).value, 'agent-new');
    expect(tester.widget<TextField>(key).controller!.text, 'synthetic-new-key');
    tester.widget<AiModelPicker>(find.byKey(const ValueKey('ai-config-inline-model'))).onChanged!('inline-fast');
    tester.widget<AiModelPicker>(find.byKey(const ValueKey('ai-config-completion-model'))).onChanged!('complete-fast');
    tester.widget<AiModelPicker>(review).onChanged!('review-fast');
    await tester.pump();
    final preset = tester.widget<AppSelect<int>>(find.byKey(const ValueKey('ai-config-context-preset')));
    preset.onChanged!(256000);
    await tester.pump();
    final scope = ProviderScope.containerOf(tester.element(find.byType(AiSettings)));
    await tester.ensureVisible(find.byKey(const ValueKey('ai-config-save')));
    await tester.tap(find.byKey(const ValueKey('ai-config-save')));
    await tester.pump();
    await drainConfiguration(tester, scope);
    await tester.pumpAndSettle();
    final state = scope.read(aiConfigurationProvider);
    expect(state.profile!.model, 'agent-new');
    expect(state.profile!.tools, isTrue);
    expect(state.profile!.contextWindow, 256000);
    expect(state.inlineModel, 'inline-fast');
    expect(state.completionModel, 'complete-fast');
    expect(state.reviewModel, 'review-fast');
    expect(state.profileForReview!.tools, isFalse);
    expect(credentials.reads, 0);
    expect(credentials.values[state.profile!.identity]!.reveal(), 'synthetic-new-key');
    expect(File('${dir.path}/ai.json').readAsStringSync(), isNot(contains('synthetic-new-key')));
  });

  testWidgets('changing only the default model preserves its secure key without displaying it', (tester) async {
    final credentials = await showSettings(tester);
    tester.widget<AiModelPicker>(find.byKey(const ValueKey('ai-config-model'))).onChanged!('agent-new');
    await tester.pump();
    final key = find.byKey(const ValueKey('ai-config-key'));
    expect(tester.widget<TextField>(key).controller!.text, isEmpty);
    expect(credentials.reads, 0);
    final scope = ProviderScope.containerOf(tester.element(find.byType(AiSettings)));
    await tester.ensureVisible(find.byKey(const ValueKey('ai-config-save')));
    await tester.tap(find.byKey(const ValueKey('ai-config-save')));
    await tester.pump();
    await drainConfiguration(tester, scope);
    await tester.pumpAndSettle();
    final next = scope.read(aiConfigurationProvider).profile!;
    expect(next.model, 'agent-new');
    expect(scope.read(aiConfigurationProvider).reviewModel, isNull);
    expect(scope.read(aiConfigurationProvider).profileForReview, isNull);
    expect(credentials.reads, 1);
    expect(credentials.values[next.identity]!.reveal(), 'synthetic-existing-key');
    expect(tester.widget<TextField>(key).controller!.text, isEmpty);
  });

  testWidgets('model key copy failure keeps the old configuration and an empty key field', (tester) async {
    final credentials = await showSettings(tester);
    tester.widget<AiModelPicker>(find.byKey(const ValueKey('ai-config-model'))).onChanged!('agent-new');
    await tester.pump();
    credentials.failRead = true;
    await tester.ensureVisible(find.byKey(const ValueKey('ai-config-save')));
    await tester.tap(find.byKey(const ValueKey('ai-config-save')));
    await tester.pumpAndSettle();
    final scope = ProviderScope.containerOf(tester.element(find.byType(AiSettings)));
    expect(scope.read(aiConfigurationProvider).profile!.model, _profile().model);
    expect(credentials.saved, isEmpty);
    expect(tester.widget<TextField>(find.byKey(const ValueKey('ai-config-key'))).controller!.text, isEmpty);
    final l = AppLocalizations.of(tester.element(find.byType(AiSettings)));
    expect(find.text(l.aiConfigSaveFailed), findsOneWidget);
  });

  testWidgets('changing provider never copies the previous destination key', (tester) async {
    final credentials = await showSettings(tester);
    await tester.enterText(find.byKey(const ValueKey('ai-config-endpoint')), 'https://different.example/v1');
    await tester.pumpAndSettle();
    final scope = ProviderScope.containerOf(tester.element(find.byType(AiSettings)));
    await tester.ensureVisible(find.byKey(const ValueKey('ai-config-save')));
    await tester.tap(find.byKey(const ValueKey('ai-config-save')));
    await tester.pump();
    await drainConfiguration(tester, scope);
    await tester.pumpAndSettle();
    expect(scope.read(aiConfigurationProvider).profile!.endpoint, 'https://different.example/v1');
    expect(credentials.reads, 0);
    expect(credentials.saved, isEmpty);
    expect(credentials.values.keys, [_profile().identity]);
  });

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
    await tester.ensureVisible(find.byKey(const ValueKey('ai-config-save')));
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

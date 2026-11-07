import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/app/composition.dart';
import 'package:sshairy/design/theme.dart';
import 'package:sshairy/features/credentials/api.dart';
import 'package:sshairy/features/credentials/application/credential_access.dart' show secretStoreProvider;
import 'package:sshairy/features/hosts/adapters/host_import_files.dart';
import 'package:sshairy/features/hosts/api.dart';
import 'package:sshairy/features/hosts/application/host_import.dart';
import 'package:sshairy/features/hosts/domain/host_import.dart';
import 'package:sshairy/features/settings/api.dart';
import 'package:sshairy/foundation/data_dir.dart';
import 'package:sshairy/foundation/ids.dart';
import 'package:sshairy/l10n/app_localizations.dart';

import 'keys_test.dart' show MemorySecrets;

/// Stands in for the user's disk: FinalShell is "installed" and the file picker returns a CSV.
class _Files extends HostImportFiles {
  _Files();

  final asked = <ImportFormat?>[];
  String? finalShellPath;
  @override
  List<String> defaults(ImportFormat format) => ['/synthetic/${format.name}'];

  @override
  bool get hasRegistry => false;

  @override
  Future<ImportRead?> readDefault(ImportFormat format) async {
    if (format != ImportFormat.finalshell) return null;
    if (finalShellPath != null) return read(format, finalShellPath!);
    final files = [
      for (final (name, host) in [('web', 'w.example'), ('db', 'd.example')])
        ImportText('$name.json', jsonEncode({'name': name, 'host': host, 'port': 22, 'user_name': 'u'})),
    ];
    return ImportRead('conn', format, parseFinalShell(files, defaultUser: 'me'));
  }

  @override
  Future<ImportRead?> pick([ImportFormat? format]) async {
    asked.add(format);
    const csv = ImportText('hosts.csv', 'name,host,group\nsaved,s.example,\nnew,n.example,lab\n');
    return ImportRead(
      'hosts.csv',
      ImportFormat.csv,
      parseCsvHosts(csv, defaultUser: 'u'),
      path: '/synthetic/hosts.csv',
    );
  }
}

void main() {
  late Directory dir;
  late ProviderContainer container;
  late _Files files;
  late MemorySecrets secrets;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('sshairy-import-ui-');
    files = _Files();
    secrets = MemorySecrets();
    container = ProviderContainer(
      overrides: [
        dataDirProvider.overrideWithValue(dir.path),
        secretStoreProvider.overrideWithValue(secrets),
        ...appOverrides(),
        hostImportProvider.overrideWith(
          (ref) => HostImport(
            ref.read(hostsProvider.notifier),
            () => ref.read(hostsProvider),
            files: files,
            passwords: ref.read(hostPasswordImportProvider),
          ),
        ),
      ],
    );
  });

  tearDown(() async {
    container.dispose();
    await dir.delete(recursive: true).then((_) {}, onError: (Object _) {});
  });

  HostsNotifier hosts() => container.read(hostsProvider.notifier);
  bool offered() => container.read(settingsProvider).get(SettingKeys.importOffered);

  Future<void> pumpVault(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildTheme(Brightness.light).copyWith(splashFactory: NoSplash.splashFactory),
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: VaultPage(active: true, onConnect: (_) {})),
        ),
      ),
    );
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pumpAndSettle();
  }

  /// Real file IO does not complete inside the fake clock of a widget test.
  Future<void> until(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 100 && !done(); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pumpAndSettle();
    expect(done(), isTrue, reason: 'the change should have landed');
  }

  testWidgets('an empty vault offers the import once; a found program imports into the chosen group', (tester) async {
    await tester.runAsync(() => hosts().createGroup('prod'));
    await pumpVault(tester);

    expect(find.text('Import hosts'), findsOneWidget);
    expect(find.text('Skip'), findsOneWidget);
    await until(tester, offered);
    expect(find.text('PuTTY'), findsNothing, reason: 'no registry here');
    final tile = find.ancestor(of: find.text('FinalShell'), matching: find.byType(InkWell));
    expect(find.descendant(of: tile, matching: find.text('2')), findsOneWidget);

    await tester.tap(find.text('FinalShell'));
    await until(tester, () => find.text('u@w.example:22').evaluate().isNotEmpty);
    expect(find.text('u@w.example:22'), findsOneWidget);
    expect(find.text('Import saved login details'), findsOneWidget);
    expect(find.byTooltip('Choose another source'), findsOneWidget);
    expect(find.text('Import (2)'), findsOneWidget);

    await tester.tap(find.text('No group'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('prod').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('db'));
    await tester.pump();
    expect(find.text('Import (1)'), findsOneWidget);

    await tester.tap(find.text('Import (1)'));
    await until(tester, () => container.read(hostsProvider).isNotEmpty);
    expect(find.text('Import hosts'), findsNothing);
    expect(find.text('Imported 1 hosts'), findsOneWidget);
    final web = container.read(hostsProvider).single;
    expect((web.label, web.address, web.username, web.group), ('web', 'w.example', 'u', 'prod'));
  });

  testWidgets('skipping closes the offer and it does not come back', (tester) async {
    await pumpVault(tester);
    await tester.tap(find.text('Skip'));
    await tester.pumpAndSettle();
    expect(find.text('Import hosts'), findsNothing);
    await until(tester, offered);

    await tester.pumpWidget(const SizedBox.shrink());
    await pumpVault(tester);
    expect(find.text('Skip'), findsNothing);
  });

  testWidgets('the toolbar opens the dialog; a file is previewed with saved hosts left out', (tester) async {
    await tester.runAsync(
      () => hosts().save(const Host(id: HostId('s'), label: 's', address: 's.example', username: 'u')),
    );
    await pumpVault(tester);
    expect(find.text('Import hosts'), findsNothing, reason: 'the vault is not empty');

    await tester.tap(find.byIcon(Icons.input_rounded));
    await tester.pumpAndSettle();
    expect(find.text('Cancel'), findsOneWidget);
    await tester.tap(find.text('From file'));
    await tester.pumpAndSettle();
    expect(files.asked, [null]);
    expect(find.text('hosts.csv'), findsOneWidget);
    expect(find.text('Already saved'), findsOneWidget);
    expect(find.text('lab'), findsOneWidget);
    expect(find.text('Import (1)'), findsOneWidget);

    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.text('From file'), findsOneWidget);

    await tester.tap(find.text('CSV'));
    await tester.pumpAndSettle();
    expect(find.textContaining('UTF-8 CSV'), findsOneWidget);
    expect(files.asked, [null], reason: 'show guidance before opening the picker');
    await tester.tap(find.text('Choose file'));
    await tester.pumpAndSettle();
    expect(files.asked, [null, ImportFormat.csv]);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Import hosts'), findsNothing);
    expect(container.read(hostsProvider), hasLength(1));
  });

  testWidgets('missing software shows folder guidance before opening a picker at minimum window size', (tester) async {
    await pumpVault(tester);
    await tester.binding.setSurfaceSize(const Size(960, 640));
    await tester.tap(find.text('Xshell'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Xshell/Sessions under'), findsOneWidget);
    expect(find.text('Choose folder'), findsOneWidget);
    expect(files.asked, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Choose folder'));
    await tester.pumpAndSettle();
    expect(files.asked, [ImportFormat.xshell]);
    expect(find.text('/synthetic/hosts.csv'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an existing FinalShell host can receive a password; opt-out disables the update', (tester) async {
    final source = Directory('${dir.path}/synthetic-source')..createSync();
    File('${source.path}/one_connect_config.json').writeAsStringSync(
      jsonEncode({
        'name': 'source-name',
        'host': 's.example',
        'user_name': 'u',
        'authentication_type': 1,
        'password': 'AwsWISw3Qk2PudUQ9dh27AOgGBzot4CKoBfdJqXqTi0=',
      }),
    );
    files.finalShellPath = source.path;
    await tester.runAsync(
      () => hosts().save(const Host(id: HostId('s'), label: 'my name', address: 's.example', username: 'u')),
    );
    await pumpVault(tester);
    await tester.tap(find.byIcon(Icons.input_rounded));
    await until(tester, () => find.text('1').evaluate().isNotEmpty);
    await tester.tap(find.text('FinalShell'));
    await until(tester, () => find.text('Saved password available').evaluate().isNotEmpty);
    expect(find.text('Import (1)'), findsOneWidget);
    expect(find.text('synthetic-login-42'), findsNothing);
    expect(find.text(source.absolute.path), findsOneWidget);
    await tester.tap(find.text('Import saved login details'));
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Import (0)')).onPressed, isNull);
    await tester.tap(find.text('Import saved login details'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Select all'));
    await tester.pump();
    await tester.tap(find.text('Import (1)'));
    await until(tester, () => find.text('Import hosts').evaluate().isEmpty);
    expect(container.read(hostsProvider).single.label, 'my name');
    expect(secrets.values[SecretRef.hostPassword(const HostId('s'))], 'synthetic-login-42');
    expect(tester.takeException(), isNull);
  });
}

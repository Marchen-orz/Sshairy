import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/app/composition.dart';
import 'package:sshairy/design/controls.dart';
import 'package:sshairy/design/theme.dart';
import 'package:sshairy/features/connections/api.dart';
import 'package:sshairy/features/hosts/api.dart';
import 'package:sshairy/features/terminal/api.dart';
import 'package:sshairy/features/workspace/api.dart';
import 'package:sshairy/foundation/cancellation.dart';
import 'package:sshairy/foundation/data_dir.dart';
import 'package:sshairy/foundation/ids.dart';
import 'package:sshairy/l10n/app_localizations.dart';

const _shell = LocalShell(kind: LocalShellKind.pwsh, executable: r'C:\Program Files\PowerShell\7\pwsh.exe');
const _folder = r'D:\work\sshairy';

class _Hosts extends HostsNotifier {
  @override
  List<Host> build() => const [Host(id: HostId('h'), label: 'remote', address: 'example.com', username: 'u')];
}

class _Pty implements LocalPty {
  final bytes = StreamController<Uint8List>();
  final exited = Completer<int>();
  @override
  Stream<Uint8List> get output => bytes.stream;
  @override
  Future<int> get exitCode => exited.future;
  @override
  void write(Uint8List data) {}
  @override
  void resize(int cols, int rows) {}
  @override
  void close() {
    if (exited.isCompleted) return;
    bytes.close();
    exited.complete(0);
  }
}

class _Factory implements LocalPtyFactory {
  final directories = <String?>[];
  @override
  Future<LocalPty> start(
    LocalShell shell, {
    required int cols,
    required int rows,
    String? directory,
    CancellationToken? cancel,
  }) async {
    directories.add(directory);
    return _Pty();
  }
}

class _Assets extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async => key == 'AssetManifest.bin'
      ? const StandardMessageCodec().encodeMessage(<String, Object?>{})!
      : ByteData.sublistView(File(key).readAsBytesSync());
}

void main() {
  test('a saved local terminal round-trips and starts where it was saved', () {
    const profile = LocalProfile(id: 'p', label: 'api', shell: _shell, directory: _folder);
    final copy = LocalProfile.fromJson(jsonDecode(jsonEncode(profile.toJson())) as Map<String, Object?>);
    expect((copy.label, copy.shell, copy.directory), ('api', _shell, _folder));
    expect(copy.target.directory, _folder);
    expect(const LocalProfile(id: 'p', label: 'home', shell: _shell).target.directory, isNull);
    expect(() => const LocalProfile(id: 'p', label: ' ', shell: _shell).validate(), throwsArgumentError);
    expect(profile.matches('API sshairy'), isTrue);
    expect(profile.matches('remote'), isFalse);

    final target = LocalTerminalTarget.fromJson(profile.target.toJson());
    expect((target.shell, target.directory, target.label), (_shell, _folder, 'api'));
  });

  testWidgets('a local terminal made from New host shows apart from hosts and opens in its folder', (tester) async {
    final dir = Directory.systemTemp.createTempSync('sshairy-local-profile-');
    final factory = _Factory();
    final manager = ConnectionManager((_, _, _) async => throw const ConnectError(ConnectFailure.auth));
    final container = ProviderContainer(
      overrides: [
        ...appOverrides(),
        dataDirProvider.overrideWithValue(dir.path),
        hostsProvider.overrideWith(_Hosts.new),
        localShellsProvider.overrideWithValue(const [_shell]),
        localPtyProvider.overrideWithValue(factory),
        connectionManagerProvider.overrideWithValue(manager),
      ],
    );
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      var flushed = false;
      final pending = Future.wait([
        container.read(workspaceProvider.notifier).saved,
        container.read(terminalSessionsProvider.notifier).shutdown(),
      ]).then((_) => flushed = true);
      for (var i = 0; i < 400 && !flushed; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(flushed, isTrue);
      await pending;
      container.dispose();
      manager.closeAll();
      await tester.runAsync(() => dir.delete(recursive: true));
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: DefaultAssetBundle(
          bundle: _Assets(),
          child: MaterialApp(
            theme: buildTheme(Brightness.light)
                .copyWith(platform: TargetPlatform.windows, splashFactory: NoSplash.splashFactory),
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: WorkspacePage(openPalette: (_) async {}),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('New host'));
    await tester.pumpAndSettle();
    final switcher = find.byType(AppSegmented<bool>);
    final nameField = find.widgetWithText(TextFormField, 'Name');
    expect(tester.getSize(switcher).width, lessThan(tester.getSize(nameField).width * .6));
    expect((tester.getCenter(switcher).dx - tester.getCenter(nameField).dx).abs(), lessThan(2));
    await tester.tap(find.text('Local'));
    await tester.pumpAndSettle();
    expect(find.text('PowerShell'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextFormField, 'Name'), 'api');
    // Only Windows strips the quotes "Copy as path" adds; elsewhere they could be part of the name.
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Start in folder'),
      Platform.isWindows ? '"$_folder"' : _folder,
    );
    await tester.tap(find.text('Save'));
    for (var i = 0; i < 100 && find.text('Start in folder').evaluate().isNotEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pumpAndSettle();

    final saved = File('${dir.path}/local_terminals.json');
    expect(jsonDecode(saved.readAsStringSync())['terminals'].single['directory'], _folder);
    // Hosts come first, followed by local terminals under collapsible section headers.
    final vault = find.byType(VaultPage);
    final local = find.text('api'), host = find.text('remote');
    final hostsHeader = find.descendant(of: vault, matching: find.text('Hosts'));
    final localsHeader = find.descendant(of: vault, matching: find.text('Local terminals'));
    expect(hostsHeader, findsOneWidget);
    expect(localsHeader, findsOneWidget);
    expect(local, findsOneWidget);
    expect(find.text(_folder), findsOneWidget);
    expect(tester.getTopLeft(hostsHeader).dy, lessThan(tester.getTopLeft(host).dy));
    expect(tester.getTopLeft(host).dy, lessThan(tester.getTopLeft(localsHeader).dy));
    expect(tester.getTopLeft(localsHeader).dy, lessThan(tester.getTopLeft(local).dy));

    final openLocalsY = tester.getTopLeft(localsHeader).dy;
    await tester.tap(hostsHeader);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 90));
    final midLocalsY = tester.getTopLeft(localsHeader).dy;
    expect(midLocalsY, lessThan(openLocalsY), reason: 'collapsing section animates height smoothly under full motion');
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(localsHeader).dy, lessThan(midLocalsY));
    expect(host, findsNothing);
    expect(local, findsOneWidget);
    await tester.tap(hostsHeader);
    await tester.pumpAndSettle();
    expect(host, findsOneWidget);

    await tester.tap(localsHeader);
    await tester.pumpAndSettle();
    expect(local, findsNothing);
    await tester.tap(localsHeader);
    await tester.pumpAndSettle();
    expect(local, findsOneWidget);

    await tester.tap(local);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(local);
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(factory.directories, [_folder]);
    final session = container.read(workspaceProvider.notifier).focusedSession!;
    expect((session.title, session.localShell, session.localLabel), ('api', _shell, 'api'));

    // A split starts the same shell in the same folder.
    container.read(workspaceProvider.notifier).duplicate(container.read(workspaceProvider).active!);
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(factory.directories, [_folder, _folder]);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
}

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/design/theme.dart';
import 'package:sshairy/features/files/application/open_with.dart';
import 'package:sshairy/features/files/domain/open_with.dart';
import 'package:sshairy/features/files/presentation/open_with_dialog.dart';
import 'package:sshairy/foundation/data_dir.dart';
import 'package:sshairy/l10n/app_localizations.dart';

class _Launcher implements EditorLauncher {
  @override
  bool get canChoose => true;
  @override
  Future<List<OpenWithApp>> apps(String fileName) async => [OpenWithApp.program(r'C:\Apps\Code.exe')];
  @override
  Future<OpenWithApp?> program(String path) async => OpenWithApp.program(path);
  @override
  Future<EditorLaunch> launch(OpenWithApp app, String path) async => const EditorLaunch.failed();
}

void main() {
  testWidgets('choose a locally available app and remember it for the file type', (tester) async {
    final data = Directory.systemTemp.createTempSync('sshairy-open-with-ui-');
    final container = ProviderContainer(
      overrides: [dataDirProvider.overrideWithValue(data.path), editorLauncherProvider.overrideWithValue(_Launcher())],
    );
    OpenWithChoice? chosen;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildTheme(Brightness.light),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                chosen = await showOpenWithDialog(context, 'readme.txt');
              },
              child: const Text('choose'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('choose'));
    await tester.pumpAndSettle();
    expect(find.text('Visual Studio Code'), findsOneWidget);
    expect(find.text('Always use for .txt'), findsOneWidget);
    await tester.tap(find.text('Visual Studio Code'));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(chosen?.app.executable, r'C:\Apps\Code.exe');
    expect(chosen?.remember, isTrue);
    await tester.runAsync(() => container.read(editorAppsProvider.notifier).setDefault('readme.txt', chosen!.app));
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
    final restarted = ProviderContainer(overrides: [dataDirProvider.overrideWithValue(data.path)]);
    expect(restarted.read(editorAppsProvider).forFile('other.txt')?.executable, r'C:\Apps\Code.exe');
    restarted.dispose();
    data.deleteSync(recursive: true);
  });
}

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/app/configuration.dart';
import 'package:sshairy/foundation/json_file.dart';
import 'package:sshairy/l10n/app_localizations.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('sshairy-config-ui-'));
  tearDown(() => dir.deleteSync(recursive: true));

  void validate(Map<String, dynamic> data) {
    if (data['n'] is! int) throw const FormatException('invalid n');
  }

  Future<JsonFile> damaged() async {
    final path = '${dir.path}/hosts.json';
    final original = JsonFile(path, backups: true, validate: validate);
    await original.write({'n': 1});
    await original.write({'n': 2});
    File(path).writeAsStringSync('damaged');
    // Manual recovery uses the same validator, without automatic recovery in this focused UI test.
    final file = JsonFile(path, validate: validate);
    expect(file.read, throwsA(isA<JsonFileError>()));
    return file;
  }

  Future<void> show(WidgetTester tester, JsonFile storage, VoidCallback retry) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: ConfigurationErrorPage(ConfigurationIssue('hosts.json', retry, recovery: storage)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Restore a snapshot'));
    await tester.pumpAndSettle();
  }

  testWidgets('choosing a validated snapshot protects the original and retries the configuration', (tester) async {
    final file = (await tester.runAsync(damaged))!;
    var retried = false;
    await show(tester, file, () => retried = true);
    expect(find.text('Revision 1'), findsOneWidget);
    final restore = find.widgetWithText(FilledButton, 'Restore');
    expect(tester.widget<FilledButton>(restore).onPressed, isNull);
    await tester.tap(find.text('Revision 1'));
    await tester.pump();
    await tester.tap(restore);
    await tester.pumpAndSettle();
    expect(retried, isTrue);
    expect(jsonDecode(File(file.path).readAsStringSync())['n'], 1);
    final protection = dir.listSync().where((entry) => entry.path.contains('.before-restore-')).single as File;
    expect(protection.readAsStringSync(), 'damaged');
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a snapshot changed after selection keeps the error page and original bytes', (tester) async {
    final file = (await tester.runAsync(damaged))!;
    var retried = false;
    await show(tester, file, () => retried = true);
    await tester.tap(find.text('Revision 1'));
    await tester.pump();
    file.snapshots().single.writeAsStringSync('{"n":9,"revision":1}');
    await tester.tap(find.widgetWithText(FilledButton, 'Restore'));
    await tester.pumpAndSettle();
    expect(retried, isFalse);
    expect(File(file.path).readAsStringSync(), 'damaged');
    expect(find.text('Could not restore the snapshot. The current file was preserved.'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sshairy/app/composition.dart';
import 'package:sshairy/design/dialog.dart';
import 'package:sshairy/features/snippets/api.dart';
import 'package:sshairy/foundation/data_dir.dart';
import 'package:sshairy/main.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('snippet CRUD persists in the real Windows app without a connection', (tester) async {
    final dir = await Directory.systemTemp.createTemp('sshairy-snippets-ui-');
    await File('${dir.path}/settings.json').writeAsString(jsonEncode({'schemaVersion': 1, 'locale': 'en'}));
    Future<void> waitFor(bool Function() ready) async {
      for (var i = 0; i < 100; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        if (ready()) return;
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      fail('Timed out waiting for snippet UI');
    }

    Future<void> start() async {
      await tester.pumpWidget(
        ProviderScope(
          key: UniqueKey(),
          overrides: [dataDirProvider.overrideWithValue(dir.path), ...appOverrides()],
          child: const SshairyApp(),
        ),
      );
      await tester.pumpAndSettle();
    }

    try {
      await start();
      await tester.tap(find.byTooltip('Snippets'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('New snippet'));
      await tester.pumpAndSettle();
      final editor = find.byKey(const ValueKey('snippet-editor'));
      final fields = find.descendant(of: editor, matching: find.byType(TextField));
      await tester.enterText(fields.at(0), 'Status check');
      await tester.enterText(fields.at(1), 'printf sshairy-snippet');
      await tester.enterText(fields.at(2), 'ops, shell');
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await waitFor(() => editor.evaluate().isEmpty);
      expect(find.text('Status check'), findsOneWidget);
      final container = ProviderScope.containerOf(tester.element(find.byType(SnippetsPanel)));
      final saved = container.read(snippetsProvider).single;
      expect(saved.tags, ['ops', 'shell']);
      await tester.tap(find.widgetWithText(FilledButton, 'Insert'));
      await tester.pumpAndSettle();
      expect(find.byType(SnippetsPanel), findsOneWidget);
      expect(container.read(snippetsProvider).single.text, 'printf sshairy-snippet');
      await tester.tap(find.byTooltip('Edit'));
      await tester.pumpAndSettle();
      await tester.enterText(fields.at(0), 'Renamed check');
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await waitFor(() => editor.evaluate().isEmpty);
      await container.read(snippetsProvider.notifier).saved;
      await start();
      await tester.tap(find.byTooltip('Snippets'));
      await tester.pumpAndSettle();
      expect(find.text('Renamed check'), findsOneWidget);
      await tester.tap(find.byTooltip('Delete'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(of: find.byType(AppDialog), matching: find.widgetWithText(TextButton, 'Delete')),
      );
      await waitFor(() => find.text('Renamed check').evaluate().isEmpty);
      final json = jsonDecode(await File('${dir.path}/snippets.json').readAsString()) as Map;
      expect(json['snippets'], isEmpty);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await dir.delete(recursive: true);
    }
  });
}

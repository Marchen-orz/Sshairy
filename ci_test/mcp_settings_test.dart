import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/app/composition.dart';
import 'package:sshairy/app/mcp/controller.dart';
import 'package:sshairy/app/mcp/settings.dart';
import 'package:sshairy/app/mcp/storage.dart';
import 'package:sshairy/design/controls.dart';
import 'package:sshairy/design/theme.dart';
import 'package:sshairy/features/credentials/api.dart';
import 'package:sshairy/features/settings/api.dart';
import 'package:sshairy/foundation/data_dir.dart';
import 'package:sshairy/foundation/secret.dart';
import 'package:sshairy/l10n/app_localizations.dart';

void main() {
  testWidgets('MCP settings fit narrow and wide panels in both languages without overflow', (tester) async {
    final dir = Directory.systemTemp.createTempSync('sshairy-mcp-settings-');
    addTearDown(() => dir.deleteSync(recursive: true));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final scoped = ProviderContainer(
      overrides: [
        dataDirProvider.overrideWithValue(dir.path),
        mcpCredentialsProvider.overrideWithValue(_NoCredentials()),
        mcpClientsProvider.overrideWithValue(
          McpClients(environment: {Platform.isWindows ? 'USERPROFILE' : 'HOME': dir.path}, dataDirectory: dir.path),
        ),
        ...appOverrides(),
      ],
    );
    addTearDown(scoped.dispose);
    await tester.runAsync(() => scoped.read(settingsProvider.notifier).patch({'mcpMode': 'automatic'}));
    for (final (locale, width) in [('en', 340.0), ('zh', 340.0), ('en', 720.0), ('zh', 720.0)]) {
      await tester.binding.setSurfaceSize(Size(width, 900));
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: scoped,
          child: MaterialApp(
            theme: buildTheme(Brightness.light),
            locale: Locale(locale),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const Scaffold(
              body: SingleChildScrollView(padding: EdgeInsets.all(20), child: McpSettings()),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: '$locale $width');
      for (final client in McpClient.values) {
        expect(find.byWidgetPredicate((w) => w is AppIconToggle && w.tooltip.startsWith(client.label)), findsOneWidget);
      }
      expect(find.byType(AppToggleRow), findsOneWidget);
      expect(find.byType(AppCheckbox), findsNothing);
      expect(find.byIcon(Icons.dns_outlined), findsOneWidget);
      await tester.tap(find.byIcon(Icons.dns_outlined));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppToggleRow, locale == 'en' ? 'Select all' : '全选'), findsOneWidget);
      expect(tester.takeException(), isNull, reason: 'scope $locale $width');
      await tester.tap(find.text(locale == 'en' ? 'Close' : '关闭'));
      await tester.pumpAndSettle();
      expect(
        find.byType(AppSegmented<McpApprovalMode>),
        width >= WorkspaceSize.toolPanel ? findsOneWidget : findsNothing,
      );
    }
  });
}

class _NoCredentials implements McpCredentials {
  @override
  Future<Secret?> read(String client) async => null;
  @override
  Future<void> save(String client, Secret value) async {}
  @override
  Future<void> clear(String client) async {}
}

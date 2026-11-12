// Drives the real app against a local scripted endpoint; no API key is stored.
// Usage: flutter test integration_test/ai_optional_key_test.dart -d windows
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sshairy/app/composition.dart';
import 'package:sshairy/features/credentials/application/credential_access.dart' show secretStoreProvider;
import 'package:sshairy/features/settings/settings.dart';
import 'package:sshairy/foundation/data_dir.dart';
import 'package:sshairy/main.dart';

import 'support/credentials.dart';

Future<void> _until(WidgetTester tester, bool Function() done, {int seconds = 20}) async {
  final end = DateTime.now().add(Duration(seconds: seconds));
  while (!done()) {
    if (DateTime.now().isAfter(end)) {
      final texts = tester.widgetList<Text>(find.byType(Text)).map((text) => text.data).whereType<String>();
      fail('timed out waiting for the app; on screen: ${texts.take(40).toList()}');
    }
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('an endpoint without an API key answers through the running app', (tester) async {
    tester.testTextInput.register();
    final dir = await Directory.systemTemp.createTemp('sshairy-ai-ui');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final authorization = <String?>[];
    final served = Completer<void>();
    server.listen((request) async {
      authorization.add(request.headers.value(HttpHeaders.authorizationHeader));
      await utf8.decoder.bind(request).join();
      final response = request.response;
      response.headers.contentType = ContentType('text', 'event-stream', charset: 'utf-8');
      response.write(
        'data: ${jsonEncode({
          'id': 'chatcmpl-local',
          'choices': [
            {
              'index': 0,
              'delta': {'role': 'assistant', 'content': 'Hello from '},
            },
          ],
        })}\n\n',
      );
      response.write(
        'data: ${jsonEncode({
          'id': 'chatcmpl-local',
          'choices': [
            {
              'index': 0,
              'delta': {'content': 'the local endpoint.'},
              'finish_reason': 'stop',
            },
          ],
        })}\n\n',
      );
      response.write('data: [DONE]\n\n');
      await response.close();
      if (!served.isCompleted) served.complete();
    });
    addTearDown(() async {
      await server.close(force: true);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      for (var i = 0; i < 20 && await dir.exists(); i++) {
        try {
          await dir.delete(recursive: true);
        } on FileSystemException {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }
    });

    await File('${dir.path}/settings.json').writeAsString(jsonEncode({'locale': 'en', 'importOffered': true}));
    await File('${dir.path}/ai.json').writeAsString(
      jsonEncode({
        'schemaVersion': 2,
        'revision': 1,
        'enabled': true,
        'profile': {
          'protocol': 'openai',
          'endpoint': 'http://127.0.0.1:${server.port}/v1',
          'model': 'local-test',
          'tools': true,
          'maxOutputTokens': 4096,
          'contextWindow': 32000,
        },
        'inlineEnabled': false,
        'completionEnabled': false,
      }),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          dataDirProvider.overrideWithValue(dir.path),
          runningRendererProvider.overrideWithValue(Renderer.skia),
          ...appOverrides(),
          secretStoreProvider.overrideWithValue(EphemeralSecretStore()),
        ],
        child: const SshairyApp(),
      ),
    );
    await _until(tester, () => find.byTooltip('Airy').evaluate().isNotEmpty);
    await tester.tap(find.byTooltip('Airy'));
    await tester.pump();
    await tester.enterText(find.byKey(const ValueKey('ai-agent-goal')), 'say hello');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('ai-agent-send')));
    await _until(
      tester,
      () => find
          .byWidgetPredicate((w) => w is RichText && w.text.toPlainText().contains('local endpoint'))
          .evaluate()
          .isNotEmpty,
    );
    await served.future;
    expect(authorization, [null]);
  });
}

// Clicks through the running app for optional-key settings and reply actions.
// Usage: flutter test integration_test/ai_agent_ui_test.dart -d windows
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
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

Map<String, dynamic> _aiConfig(Directory dir) =>
    jsonDecode(File('${dir.path}/ai.json').readAsStringSync()) as Map<String, dynamic>;

Future<void> _start(WidgetTester tester, Directory dir, String endpoint) async {
  await File('${dir.path}/settings.json').writeAsString(jsonEncode({'locale': 'en', 'importOffered': true}));
  await File('${dir.path}/ai.json').writeAsString(
    jsonEncode({
      'schemaVersion': 2,
      'revision': 1,
      'enabled': true,
      'profile': {
        'protocol': 'openai',
        'endpoint': endpoint,
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
}

Future<void> _close(WidgetTester tester, Directory dir) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpAndSettle();
  for (var i = 0; i < 20 && await dir.exists(); i++) {
    try {
      await dir.delete(recursive: true);
    } on FileSystemException {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('an optional key allows saving the model settings from the running app', (tester) async {
    tester.testTextInput.register();
    final dir = await Directory.systemTemp.createTemp('sshairy-ai-settings-ui');
    addTearDown(() => _close(tester, dir));
    await _start(tester, dir, 'http://127.0.0.1:9/v1');

    await tester.tap(
      find.byWidgetPredicate((widget) => widget is Icon && widget.icon == Icons.tune_outlined && widget.size == 17),
    );
    await _until(tester, () => find.byKey(const ValueKey('ai-config-endpoint')).evaluate().isNotEmpty);
    expect(find.text('No key saved; leave empty if this endpoint needs none.'), findsOneWidget);

    const endpoint = 'http://127.0.0.1:10/v1';
    await tester.enterText(find.byKey(const ValueKey('ai-config-endpoint')), endpoint);
    await tester.pumpAndSettle();
    final save = find.byKey(const ValueKey('settings-save'));
    await tester.ensureVisible(save);
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(save).onPressed, isNotNull);
    await tester.tap(save);
    await _until(tester, () => (_aiConfig(dir)['profile'] as Map?)?['endpoint'] == endpoint);
    expect(File('${dir.path}/ai.json').readAsStringSync(), isNot(contains('secret')));
  });

  testWidgets('reply actions show while the turn is running and enable after it', (tester) async {
    tester.testTextInput.register();
    final dir = await Directory.systemTemp.createTemp('sshairy-ai-actions-ui');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final finish = Completer<void>();
    addTearDown(() async {
      if (!finish.isCompleted) finish.complete();
      await server.close(force: true);
      await _close(tester, dir);
    });
    server.listen((request) async {
      await utf8.decoder.bind(request).join();
      final response = request.response;
      response.bufferOutput = false;
      response.headers.contentType = ContentType('text', 'event-stream', charset: 'utf-8');
      response.write(
        'data: ${jsonEncode({
          'id': 'chatcmpl-local',
          'choices': [
            {
              'index': 0,
              'delta': {'role': 'assistant', 'content': 'Working'},
            },
          ],
        })}\n\n',
      );
      await response.flush();
      await finish.future;
      response.write(
        'data: ${jsonEncode({
          'id': 'chatcmpl-local',
          'choices': [
            {
              'index': 0,
              'delta': {'content': ' from the local endpoint.'},
              'finish_reason': 'stop',
            },
          ],
        })}\n\n',
      );
      response.write('data: [DONE]\n\n');
      await response.close();
    });
    await _start(tester, dir, 'http://127.0.0.1:${server.port}/v1');

    IconButton action(String prefix) => tester.widget<IconButton>(
      find.byWidgetPredicate(
        (widget) =>
            widget is IconButton &&
            widget.key is ValueKey<String> &&
            (widget.key! as ValueKey<String>).value.startsWith(prefix),
      ),
    );

    await tester.enterText(find.byKey(const ValueKey('ai-agent-goal')), 'say hello');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('ai-agent-send')));
    await _until(
      tester,
      () => find
          .byWidgetPredicate((w) => w is RichText && w.text.toPlainText().contains('Working'))
          .evaluate()
          .isNotEmpty,
    );
    expect(action('ai-agent-copy-').onPressed, isNotNull);
    expect(tester.widget<IconButton>(find.byKey(const ValueKey('ai-agent-regenerate'))).onPressed, isNull);
    expect(tester.widget<IconButton>(find.byKey(const ValueKey('ai-agent-withdraw'))).onPressed, isNull);

    finish.complete();
    await _until(
      tester,
      () => find
          .byWidgetPredicate((w) => w is RichText && w.text.toPlainText().contains('local endpoint'))
          .evaluate()
          .isNotEmpty,
    );
    await tester.pumpAndSettle();
    expect(tester.widget<IconButton>(find.byKey(const ValueKey('ai-agent-regenerate'))).onPressed, isNotNull);
    expect(tester.widget<IconButton>(find.byKey(const ValueKey('ai-agent-withdraw'))).onPressed, isNotNull);
  });
}

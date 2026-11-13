// Real app interactions with an injected file-picker result and a local scripted model.
// Usage: SSHAIRY_TEST_ISOLATED=1 flutter test integration_test/ai_attachments_ui_test.dart -d windows
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sshairy/app/composition.dart';
import 'package:sshairy/design/dialog.dart';
import 'package:sshairy/features/ai/adapters/attachments.dart';
import 'package:sshairy/features/ai/api.dart';
import 'package:sshairy/features/credentials/application/credential_access.dart' show secretStoreProvider;
import 'package:sshairy/features/settings/api.dart';
import 'package:sshairy/foundation/data_dir.dart';
import 'package:sshairy/main.dart';

import 'support/credentials.dart';

Future<void> _until(WidgetTester tester, bool Function() done) async {
  final end = DateTime.now().add(const Duration(seconds: 20));
  while (!done()) {
    if (DateTime.now().isAfter(end)) fail('Attachment UI condition timed out');
    await tester.pump(const Duration(milliseconds: 50));
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('attach preview remove send restore and send-to-bottom in the running app', (tester) async {
    tester.testTextInput.register();
    final directory = await Directory.systemTemp.createTemp('sshairy-attachment-ui-');
    final endpoint = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final selectedFile = File('${directory.path}/notes.txt');
    await selectedFile.writeAsString('selected attachment content 中文');
    final hold = Completer<void>();
    final requests = <Map>[];
    var picks = 0;
    endpoint.listen((request) async {
      requests.add(jsonDecode(await utf8.decoder.bind(request).join()) as Map);
      if (requests.length == 2) await hold.future;
      request.response.headers.contentType = ContentType('text', 'event-stream', charset: 'utf-8');
      request.response.write(
        'data: ${jsonEncode({
          'id': 'attachments',
          'choices': [
            {
              'index': 0,
              'delta': {'content': 'Attachment received.'},
              'finish_reason': 'stop',
            },
          ],
        })}\n\ndata: [DONE]\n\n',
      );
      await request.response.close();
    });
    addTearDown(() async {
      if (!hold.isCompleted) hold.complete();
      await endpoint.close(force: true);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await directory.delete(recursive: true);
    });
    await File('${directory.path}/settings.json').writeAsString(jsonEncode({'locale': 'en', 'importOffered': true}));
    await File('${directory.path}/ai.json').writeAsString(
      jsonEncode({
        'schemaVersion': 2,
        'enabled': true,
        'profile': {
          'protocol': 'openai',
          'endpoint': 'http://127.0.0.1:${endpoint.port}/v1',
          'model': 'attachment-test',
          'contextWindow': 1000000,
        },
        'inlineEnabled': false,
        'completionEnabled': false,
      }),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          dataDirProvider.overrideWithValue(directory.path),
          runningRendererProvider.overrideWithValue(Renderer.skia),
          ...appOverrides(),
          secretStoreProvider.overrideWithValue(EphemeralSecretStore()),
          agentAttachmentPickerProvider.overrideWithValue(
            AgentAttachmentPicker(
              pick: () async {
                picks++;
                if (picks == 1) return [selectedFile.path];
                await selectedFile.writeAsString('selected attachment content 中文\n' * 3000);
                return List.filled(6, selectedFile.path);
              },
            ),
          ),
        ],
        child: const SshairyApp(),
      ),
    );
    await _until(tester, () => find.byTooltip('Airy Agent').evaluate().isNotEmpty);
    await tester.tap(find.byTooltip('Airy Agent'));
    await tester.pump();
    final container = ProviderScope.containerOf(tester.element(find.byType(AgentPanel)));
    final conversations = container.read(agentConversationsProvider);
    await _until(tester, () => !conversations.loading);

    Finder keyPrefix(String prefix) => find.byWidgetPredicate(
      (widget) => widget.key is ValueKey<String> && (widget.key! as ValueKey<String>).value.startsWith(prefix),
    );
    await tester.tap(find.byKey(const ValueKey('ai-agent-attach')));
    await _until(tester, () => keyPrefix('ai-attachment-preview-').evaluate().isNotEmpty);
    await tester.tap(keyPrefix('ai-attachment-preview-'));
    await tester.pumpAndSettle();
    expect(find.text('selected attachment content 中文'), findsOneWidget);
    await tester.tap(find.descendant(of: find.byType(AppDialog), matching: find.text('Close')));
    await tester.pumpAndSettle();
    await tester.tap(keyPrefix('ai-attachment-remove-'));
    await tester.pump();
    expect(container.read(agentComposerProvider).attachments, isEmpty);
    await tester.tap(find.byKey(const ValueKey('ai-agent-attach')));
    await _until(tester, () => container.read(agentComposerProvider).attachments.isNotEmpty);
    await tester.tap(find.byKey(const ValueKey('ai-agent-send')));
    await _until(tester, () => !conversations.runtime.busy && requests.length == 1);
    expect(picks, 2);
    expect(jsonEncode(requests.single), contains('selected attachment content 中文'));
    expect(jsonEncode(requests.single), isNot(contains(directory.path)));
    final attachments = conversations.current!.entries.first.attachments;
    expect(attachments, hasLength(6));
    expect(attachments.every((item) => item.bytes > 65536), isTrue);
    expect(attachments.fold(0, (size, item) => size + item.bytes), greaterThan(512 << 10));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('ai-agent-withdraw')));
    await tester.pump();
    expect(container.read(agentComposerProvider).attachments, hasLength(6));
    expect(picks, 2);

    final entries = [
      for (var i = 0; i < 30; i++) ...[
        ConversationEntry(kind: ConversationEntryKind.user, text: 'previous question $i'),
        ConversationEntry(
          kind: ConversationEntryKind.assistant,
          text: 'previous answer $i with enough text for a longer list',
        ),
      ],
    ];
    final conversationId = conversations.selectedId;
    conversations.runtime.restoreConversation(entries);
    conversations.newConversation();
    conversations.select(conversationId);
    await tester.pump();
    final list = find.byWidgetPredicate((widget) => widget is ListView && widget.reverse);
    final scrollable = find.descendant(of: list, matching: find.byType(Scrollable)).first;
    final scroll = tester.state<ScrollableState>(scrollable).position;
    scroll.jumpTo(scroll.maxScrollExtent);
    await tester.pump();
    expect(scroll.pixels, greaterThan(0));
    await tester.enterText(find.byKey(const ValueKey('ai-agent-goal')), 'new message after scrolling');
    await tester.tap(find.byKey(const ValueKey('ai-agent-send')));
    await _until(tester, () => requests.length == 2);
    expect(scroll.pixels, scroll.minScrollExtent);
    scroll.jumpTo(scroll.maxScrollExtent);
    await tester.pump();
    expect(scroll.pixels, greaterThan(0), reason: 'Generation does not force manual history scrolling back down');
    hold.complete();
    await _until(tester, () => !conversations.runtime.busy);
    expect(tester.takeException(), isNull);
  });
}

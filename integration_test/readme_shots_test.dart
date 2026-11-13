// Regenerates the README screenshots from demo data: made-up hosts, a local shell and a scripted
// stand-in for the model. No server is contacted and no real model answers.
// Usage: SSHAIRY_README_SHOTS=<dir> flutter test integration_test/readme_shots_test.dart -d windows
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sshairy/app/composition.dart';
import 'package:sshairy/features/credentials/application/credential_access.dart' show secretStoreProvider;
import 'package:sshairy/features/settings/settings.dart';
import 'package:sshairy/features/terminal/application/local_terminal.dart';
import 'package:sshairy/features/workspace/api.dart';
import 'package:sshairy/foundation/data_dir.dart';
import 'package:sshairy/main.dart';
import 'package:xterm2/xterm.dart';

import 'support/credentials.dart';

final _shots = Platform.environment['SSHAIRY_README_SHOTS'];
final _boundary = GlobalKey();

// Addresses are from the documentation ranges (RFC 5737) and example.com.
const _hosts = [
  {
    'id': 'web-01',
    'label': 'web-01',
    'address': '192.0.2.11',
    'username': 'deploy',
    'group': 'Production',
    'tags': ['nginx'],
    'pinned': true,
  },
  {
    'id': 'web-02',
    'label': 'web-02',
    'address': '192.0.2.12',
    'username': 'deploy',
    'group': 'Production',
    'tags': ['nginx'],
  },
  {
    'id': 'db-primary',
    'label': 'db-primary',
    'address': '192.0.2.21',
    'username': 'postgres',
    'group': 'Production',
    'tags': ['postgres'],
    'pinned': true,
  },
  {
    'id': 'db-replica',
    'label': 'db-replica',
    'address': '192.0.2.22',
    'username': 'postgres',
    'group': 'Production',
    'tags': ['postgres'],
  },
  {'id': 'staging', 'label': 'staging', 'address': 'staging.example.com', 'username': 'ubuntu', 'group': 'Staging'},
  {
    'id': 'ci-runner',
    'label': 'ci-runner',
    'address': '198.51.100.7',
    'username': 'runner',
    'group': 'Staging',
    'tags': ['docker'],
  },
  {
    'id': 'bastion',
    'label': 'bastion',
    'address': 'bastion.example.com',
    'port': 2222,
    'username': 'ops',
    'group': 'Lab',
  },
  {
    'id': 'gpu-box',
    'label': 'gpu-box',
    'address': '203.0.113.40',
    'username': 'ml',
    'group': 'Lab',
    'tags': ['gpu'],
  },
  {'id': 'pi', 'label': 'raspberry-pi', 'address': '203.0.113.52', 'username': 'pi', 'group': 'Lab'},
];

String _chunk(Map<String, Object?> delta, [String? finish]) =>
    'data: ${jsonEncode({
      'id': 'demo',
      'choices': [
        {'index': 0, 'delta': delta, 'finish_reason': ?finish},
      ],
    })}\n\n';

Future<HttpServer> _model(bool zh) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  var posts = 0;
  server.listen((request) async {
    final response = request.response;
    if (request.method == 'GET') {
      response.headers.contentType = ContentType.json;
      response.write(jsonEncode({'data': <Object>[]}));
      await response.close();
      return;
    }
    await utf8.decoder.bind(request).join();
    response.headers.contentType = ContentType('text', 'event-stream', charset: 'utf-8');
    final call = posts++;
    if (call == 0) {
      // The Agent has to list hosts before it may ask to use one.
      response.write(
        _chunk({
          'tool_calls': [
            {
              'index': 0,
              'id': 'call_0',
              'type': 'function',
              'function': {'name': 'host_list', 'arguments': '{}'},
            },
          ],
        }, 'tool_calls'),
      );
    } else if (call == 1) {
      response.write(
        _chunk({'role': 'assistant', 'content': zh ? '我会把 gpu-box 移到 Staging。' : 'I will move gpu-box into Staging.'}),
      );
      response.write(
        _chunk({
          'tool_calls': [
            {
              'index': 0,
              'id': 'call_1',
              'type': 'function',
              'function': {
                'name': 'hosts_move',
                'arguments': jsonEncode({
                  'hostIds': ['gpu-box'],
                  'group': 'Staging',
                }),
              },
            },
          ],
        }, 'tool_calls'),
      );
    } else {
      response.write(_chunk({'role': 'assistant', 'content': zh ? '没有执行任何改动。' : 'Nothing was changed.'}, 'stop'));
    }
    response.write('data: [DONE]\n\n');
    await response.close();
  });
  return server;
}

Future<void> _until(WidgetTester tester, String what, bool Function() done, {int seconds = 30}) async {
  final end = DateTime.now().add(Duration(seconds: seconds));
  while (!done()) {
    if (DateTime.now().isAfter(end)) {
      final texts = tester.widgetList<Text>(find.byType(Text)).map((text) => text.data).whereType<String>();
      fail('timed out waiting for $what; on screen: ${texts.take(60).toList()}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await tester.pump();
  }
}

Future<void> _shot(WidgetTester tester, String name) async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await tester.pump();
  }
  final render = _boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final image = await render.toImage(pixelRatio: 2);
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  await File('$_shots/$name.png').writeAsBytes(png!.buffer.asUint8List());
  // ignore: avoid_print
  print('SHOT $name ${image.width}x${image.height}');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const accents = <(String, String)>[
    ('blue', 'Ice Blue / Mint'),
    ('green', 'Mint Green'),
    ('violet', 'Violet'),
    ('orange', 'Sunset Orange'),
    ('deepSea', 'Deep Sea Blue'),
    ('pink', 'Sakura Pink'),
  ];
  for (final (lang, mode, accent) in [('en', 'light', 'blue'), ('zh', 'light', 'blue')]) {
    testWidgets('README screenshots, $lang $mode', skip: _shots == null, (tester) async {
      tester.testTextInput.register();
      final dir = await Directory.systemTemp.createTemp('sshairy-readme-shots');
      final server = await _model(lang == 'zh');
      addTearDown(() async {
        await server.close(force: true);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 1));
        for (var i = 0; i < 20 && await dir.exists(); i++) {
          try {
            await dir.delete(recursive: true);
          } on FileSystemException {
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
        }
      });
      await File('${dir.path}/settings.json').writeAsString(
        jsonEncode({'locale': lang, 'importOffered': true, 'themeMode': mode, 'accent': accent, 'confirmQuit': false}),
      );
      await File('${dir.path}/hosts.json').writeAsString(jsonEncode({'schemaVersion': 1, 'hosts': _hosts}));
      await File('${dir.path}/ai.json').writeAsString(
        jsonEncode({
          'schemaVersion': 2,
          'revision': 1,
          'enabled': true,
          'profile': {
            'protocol': 'openai',
            'endpoint': 'http://127.0.0.1:${server.port}/v1',
            'model': 'demo-model',
            'tools': true,
            'maxOutputTokens': 4096,
            'contextWindow': 256000,
          },
          'inlineEnabled': false,
          'completionEnabled': false,
        }),
      );
      await tester.pumpWidget(
        RepaintBoundary(
          key: _boundary,
          child: ProviderScope(
            key: UniqueKey(),
            overrides: [
              dataDirProvider.overrideWithValue(dir.path),
              runningRendererProvider.overrideWithValue(Renderer.skia),
              ...appOverrides(),
              secretStoreProvider.overrideWithValue(EphemeralSecretStore()),
            ],
            child: const SshairyApp(),
          ),
        ),
      );
      await _until(tester, 'the host library', () => find.text('db-primary').evaluate().isNotEmpty);
      await _shot(tester, 'hosts-$lang-$mode');

      final container = ProviderScope.containerOf(tester.element(find.text('db-primary').first));
      final shells = container.read(localShellsProvider);
      final shell = shells.firstWhere((s) => s.name.contains('PowerShell'), orElse: () => shells.first);
      container.read(workspaceProvider.notifier).openLocal(shell);
      final view = find.byType(TerminalView).hitTestable();
      await _until(tester, 'the terminal', () => view.evaluate().isNotEmpty);
      Terminal terminal() => tester.widget<TerminalView>(view.first).terminal;
      await _until(tester, 'a prompt', () => terminal().buffer.getText().contains('>'));
      for (final command in [r'cd \', 'cls', 'ssh -V']) {
        terminal().textInput('$command\r');
        await tester.pump(const Duration(milliseconds: 600));
        await Future<void>.delayed(const Duration(milliseconds: 600));
      }
      await _until(tester, 'the command output', () => terminal().buffer.getText().contains('OpenSSH'));

      await tester.tap(find.byTooltip('Airy Agent'));
      await _until(tester, 'the Agent panel', () => find.byKey(const ValueKey('ai-agent-goal')).evaluate().isNotEmpty);
      await tester.enterText(
        find.byKey(const ValueKey('ai-agent-goal')),
        lang == 'zh' ? '把 gpu-box 移到 Staging 分组。' : 'Move gpu-box into the Staging group.',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('ai-agent-send')));
      final approve = find.text(lang == 'zh' ? '仅批准此次' : 'Approve once');
      final allow = find.byKey(const ValueKey('ai-host-allow'));
      await _until(tester, 'a prompt', () => allow.evaluate().isNotEmpty || approve.evaluate().isNotEmpty);
      if (allow.evaluate().isNotEmpty) {
        await _shot(tester, 'agent-host-$lang-$mode');
        await tester.tap(allow);
      }
      await _until(tester, 'the approval card', () => approve.evaluate().isNotEmpty);
      await _shot(tester, 'agent-approval-$lang-$mode');
      await tester.tap(find.text(lang == 'zh' ? '拒绝' : 'Reject'));
      await _until(
        tester,
        'the turn to end',
        () => find.text(lang == 'zh' ? '没有执行任何改动。' : 'Nothing was changed.').evaluate().isNotEmpty,
      );
    });
  }

  for (final (accent, name) in accents) {
    testWidgets('theme tile, $accent', skip: _shots == null, (tester) async {
      final dir = await Directory.systemTemp.createTemp('sshairy-readme-theme');
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 1));
        for (var i = 0; i < 20 && await dir.exists(); i++) {
          try {
            await dir.delete(recursive: true);
          } on FileSystemException {
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
        }
      });
      await File('${dir.path}/settings.json').writeAsString(
        jsonEncode({
          'locale': 'en',
          'importOffered': true,
          'themeMode': 'light',
          'accent': accent,
          'confirmQuit': false,
        }),
      );
      await File('${dir.path}/hosts.json').writeAsString(jsonEncode({'schemaVersion': 1, 'hosts': _hosts}));
      await tester.pumpWidget(
        RepaintBoundary(
          key: _boundary,
          child: ProviderScope(
            key: UniqueKey(),
            overrides: [
              dataDirProvider.overrideWithValue(dir.path),
              runningRendererProvider.overrideWithValue(Renderer.skia),
              ...appOverrides(),
              secretStoreProvider.overrideWithValue(EphemeralSecretStore()),
            ],
            child: const SshairyApp(),
          ),
        ),
      );
      await _until(tester, name, () => find.text('db-primary').evaluate().isNotEmpty);
      await _shot(tester, 'theme-$accent');
    });
  }
}

// Real app clicks + real SSH, with a local scripted model (docs/TESTING.md §2).
// Credentials must come only from inline SSHAIRY_TEST_TARGET / SSHAIRY_TEST_PASSWORD.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sshairy/features/ai/api.dart';
import 'package:sshairy/features/connections/api.dart';
import 'package:sshairy/features/forwarding/api.dart';
import 'package:sshairy/features/hosts/api.dart';
import 'package:sshairy/features/settings/api.dart';
import 'package:sshairy/features/terminal/api.dart';
import 'package:sshairy/features/workspace/api.dart';

import 'support/driver.dart';
import 'support/server.dart';

typedef _Args = Map<String, Object?> Function();

class _Step {
  _Step(this.tool, this.args, {this.check});
  final String tool;
  final _Args args;
  final FutureOr<void> Function(Object?)? check;
}

class _Script {
  List<_Step> steps = [];
  final results = <Object?>[];
  final seen = <String>{};
  Object? failure;
  var sent = 0;

  void start(List<_Step> value) {
    steps = value;
    results.clear();
    seen.clear();
    failure = null;
    sent = 0;
  }

  Future<void> respond(HttpRequest request) async {
    final response = request.response;
    try {
      final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
      expectSync(request.headers.value(HttpHeaders.authorizationHeader), isNull);
      for (final message in body['messages'] as List) {
        if (message['role'] != 'tool' || !seen.add(message['tool_call_id'] as String)) continue;
        final result = jsonDecode(message['content'] as String);
        final step = steps[results.length];
        results.add(result);
        if (step.check case final check?) {
          await check(result);
        } else {
          expectSync(
            result is Map && result.containsKey('error'),
            isFalse,
            reason: '${step.tool} must succeed; code=${result is Map ? result['error'] : null}',
          );
        }
      }
      final delta = <String, Object?>{};
      String finish;
      if (sent < steps.length && failure == null) {
        final step = steps[sent++];
        delta['tool_calls'] = [
          {
            'index': 0,
            'id': 'm4d_$sent',
            'type': 'function',
            'function': {'name': step.tool, 'arguments': jsonEncode(step.args())},
          },
        ];
        finish = 'tool_calls';
      } else {
        delta['content'] = 'Scenario complete.';
        finish = 'stop';
      }
      response.headers.contentType = ContentType('text', 'event-stream', charset: 'utf-8');
      response.write(
        'data: ${jsonEncode({
          'id': 'm4d',
          'choices': [
            {'index': 0, 'delta': delta, 'finish_reason': finish},
          ],
        })}\n\n',
      );
      response.write('data: [DONE]\n\n');
    } on Object catch (error) {
      failure = error;
      response.statusCode = 500;
    } finally {
      await response.close();
    }
  }
}

String _quote(String value) => "'${value.replaceAll("'", r"'\''")}'";

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('M4d tools run through visible approvals and real SSH then clean up', (t) async {
    t.testTextInput.register();
    final server = TestServer.fromEnvironment();
    final dir = await Directory.systemTemp.createTemp('sshairy-m4d-ui-');
    final endpoint = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final script = _Script();
    endpoint.listen(script.respond);
    await File('${dir.path}/settings.json').writeAsString(jsonEncode({'locale': 'en', 'importOffered': true}));
    await File('${dir.path}/ai.json').writeAsString(
      jsonEncode({
        'schemaVersion': 2,
        'enabled': true,
        'profile': {
          'protocol': 'openai',
          'endpoint': 'http://127.0.0.1:${endpoint.port}/v1',
          'model': 'scripted-m4d',
          'tools': true,
          'maxOutputTokens': 4096,
          'contextWindow': 256000,
        },
        'inlineEnabled': false,
        'completionEnabled': false,
      }),
    );
    await t.startApp(dir);
    final container = t.container;
    final host = server.host('m4d-server', const AuthPolicy(), label: 'M4d test');
    await container.read(hostsProvider.notifier).save(host);
    final runtime = container.read(agentRuntimeProvider);
    TransportLease? cleanup;
    String? owned;
    var approvals = 0, hostApprovals = 0, passwords = 0, trusts = 0;
    var rejectNext = false;

    Future<void> drive() async {
      final allowHost = find.byKey(const ValueKey('ai-host-allow'));
      final trust = inDialog(find.widgetWithText(TextButton, 'Trust once'));
      final passwordField = inDialog(find.byType(TextField));
      final approve = find.widgetWithText(FilledButton, 'Approve once');
      if (allowHost.evaluate().isNotEmpty) {
        hostApprovals++;
        await t.tapAndPump(allowHost);
      } else if (trust.evaluate().isNotEmpty) {
        trusts++;
        await t.tapAndPump(trust);
      } else if (passwordField.evaluate().isNotEmpty) {
        expectSync(passwords++, lessThan(3), reason: 'Avoid repeated authentication attempts');
        await t.answerPassword(server.password);
      } else if (approve.evaluate().isNotEmpty) {
        approvals++;
        if (rejectNext) {
          rejectNext = false;
          final reject = find.widgetWithText(TextButton, 'Reject');
          await t.ensureVisible(reject);
          await t.tapAndPump(reject);
        } else {
          await t.ensureVisible(approve);
          await t.tapAndPump(approve);
        }
      }
    }

    Future<void> scenario(String goal, List<_Step> steps, {String? expectedError}) async {
      script.start(steps);
      final input = find.byKey(const ValueKey('ai-agent-goal'));
      await t.enterText(input, goal);
      await t.pump();
      await t.tapAndPump(find.byKey(const ValueKey('ai-agent-send')));
      final deadline = DateTime.now().add(const Duration(seconds: 100));
      while (runtime.busy) {
        if (DateTime.now().isAfter(deadline)) fail('Scenario timed out: $goal');
        await drive();
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await t.pump();
      }
      expectSync(script.failure, isNull, reason: 'Script assertion for $goal');
      expectSync(runtime.error, expectedError, reason: goal);
      expectSync(script.results.length, expectedError == null ? steps.length : steps.length - 1, reason: goal);
      // session_open returns accepted while trust/authentication is still waiting for UI input.
      await t.pump();
    }

    Map<String, Object?> remote(String path) => {'hostId': host.id.value, 'path': path};
    try {
      await t.tapAndPump(find.byTooltip('Airy'));
      await scenario('Open the test server terminal.', [
        _Step('host_list', () => {}),
        _Step('session_open', () => {'hostId': host.id.value}),
      ]);
      final connectDeadline = DateTime.now().add(const Duration(seconds: 30));
      while (!container.read(terminalSessionsProvider).values.any((s) => s.status == SessionStatus.connected)) {
        final sessions = container.read(terminalSessionsProvider).values;
        final failed = sessions.where((s) => s.status == SessionStatus.failed).firstOrNull;
        if (failed != null || DateTime.now().isAfter(connectDeadline)) {
          final details = sessions.map((s) {
            final detail = s.error?.detail ?? '';
            final type = RegExp(r'\b[A-Za-z]*(?:Exception|Error)\b').firstMatch(detail)?.group(0);
            return '${s.status.name}/${s.error?.kind.name}/$type/timeout=${detail.toLowerCase().contains('timed out') || detail.toLowerCase().contains('timeout')}';
          }).toList();
          fail(
            'Real SSH terminal did not connect: $details; host=$hostApprovals trust=$trusts password=$passwords dialogs=${inDialog(find.byType(TextField)).evaluate().length}',
          );
        }
        await drive();
        await Future<void>.delayed(const Duration(milliseconds: 30));
        await t.pump(const Duration(milliseconds: 50));
      }
      cleanup = await container.read(connectionManagerProvider).acquire(host, ScriptedPrompts(server));
      final nonce = DateTime.now().microsecondsSinceEpoch;
      final setup = await cleanup.exec(
        'umask 077; mkdir -p "\$HOME/sshairy-test" && mkdir "\$HOME/sshairy-test/m4d-$nonce" && cd "\$HOME/sshairy-test/m4d-$nonce" && pwd -P',
      );
      expectSync(setup.exitCode, 0);
      owned = utf8.decode(setup.stdout).trim();
      final root = owned;
      expectSync(root.startsWith('/') && root.endsWith('/sshairy-test/m4d-$nonce'), isTrue);
      await cleanup.exec('printf "a\\000b" > ${_quote('$root/binary')}; truncate -s 262145 ${_quote('$root/large')}');

      int? settingsRevision;
      final beforeSettings = approvals;
      await scenario('Read the visible setting names and change copy-on-select with confirmation.', [
        _Step(
          'settings_get',
          () => {},
          check: (r) {
            final value = r as Map;
            settingsRevision = value['revision'] as int;
            expectSync((value['definitions'] as Map)['accent']['options'].first['label'], 'Ice Blue · Mint');
          },
        ),
        _Step('settings_patch', () => {'copyOnSelect': true, 'expectedRevision': settingsRevision!}),
      ]);
      expectSync(approvals - beforeSettings, 1);
      expectSync(container.read(settingsProvider).get(SettingKeys.copyOnSelect), isTrue);
      rejectNext = true;
      await scenario('Reject one setting change and preserve the current value.', [
        _Step('settings_get', () => {}, check: (r) => settingsRevision = (r as Map)['revision'] as int),
        _Step(
          'settings_patch',
          () => {'copyOnSelect': false, 'expectedRevision': settingsRevision!},
          check: (r) {
            expectSync((r as Map)['error'], 'denied');
          },
        ),
      ]);
      expectSync(rejectNext, isFalse);
      expectSync(container.read(settingsProvider).get(SettingKeys.copyOnSelect), isTrue);

      await scenario('Read the connected screen and command context.', [
        _Step('terminal_list', () => {}),
        _Step('terminal_history_read', () => {}),
        _Step('terminal_screen_read', () => {'maxLines': 40}),
      ]);
      final approvalBeforeFiles = approvals;
      String? originalSha256;
      await scenario('Create, read, rename and safely overwrite only the test text file.', [
        _Step('files_mkdir', () => remote('$root/copies')),
        _Step('files_write', () => {...remote('$root/text.txt'), 'text': 'hello 中文\n'}),
        _Step('files_list', () => remote(root)),
        _Step('files_stat', () => remote('$root/text.txt')),
        _Step(
          'files_read',
          () => remote('$root/text.txt'),
          check: (r) {
            final value = r as Map;
            expectSync(value['text'], 'hello 中文\n');
            originalSha256 = value['sha256'] as String;
          },
        ),
        _Step(
          'files_write',
          () => {...remote('$root/text.txt'), 'text': 'refused'},
          check: (r) => expectSync((r as Map)['error'], 'exists'),
        ),
        _Step(
          'files_write',
          () => {
            ...remote('$root/text.txt'),
            'text': 'replaced\n',
            'overwrite': true,
            'expectedSha256': originalSha256!,
          },
        ),
        _Step('files_rename', () => {'hostId': host.id.value, 'from': '$root/text.txt', 'to': '$root/renamed.txt'}),
        _Step('files_read', () => remote('$root/binary'), check: (r) => expectSync((r as Map)['error'], 'unsupported')),
        _Step('files_read', () => remote('$root/large'), check: (r) => expectSync((r as Map)['error'], 'unsupported')),
      ]);
      expectSync(approvals - approvalBeforeFiles, 10, reason: 'Confirm mode must ask before each file operation');
      await scenario('Copy the test file remotely and inspect the queue.', [
        _Step(
          'transfer_enqueue',
          () => {
            'fromHostId': host.id.value,
            'toHostId': host.id.value,
            'paths': ['$root/renamed.txt'],
            'targetDir': '$root/copies',
          },
        ),
        _Step('transfer_list', () => {}),
      ]);
      await t.untilTransfers(1);
      final copied = await cleanup.exec('cat -- ${_quote('$root/copies/renamed.txt')}');
      expectSync(utf8.decode(copied.stdout), 'replaced\n');

      final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = listener.port;
      await listener.close();
      const rule = 'm4d-loopback';
      await scenario('Save and start a loopback forwarding rule.', [
        _Step(
          'forwards_save',
          () => {
            'id': rule,
            'hostId': host.id.value,
            'kind': 'local',
            'listenPort': port,
            'destinationAddress': '127.0.0.1',
            'destinationPort': server.port,
          },
        ),
        _Step('forwards_start', () => {'id': rule, 'hostId': host.id.value}),
        _Step(
          'forwards_list',
          () => {},
          check: (r) async {
            expectSync(r, isA<List>());
            final socket = await Socket.connect(
              InternetAddress.loopbackIPv4,
              port,
              timeout: const Duration(seconds: 8),
            );
            try {
              final banner = await socket.first.timeout(const Duration(seconds: 8));
              expectSync(utf8.decode(banner), startsWith('SSH-'));
            } finally {
              socket.destroy();
            }
          },
        ),
        _Step('forwards_stop', () => {'id': rule}),
        _Step('forwards_delete', () => {'id': rule}),
      ]);
      expectSync(container.read(forwardsProvider), isEmpty);
      await expectLater(Socket.connect(InternetAddress.loopbackIPv4, port), throwsA(isA<SocketException>()));

      String? job;
      await scenario('Start, inspect and stop only a finite test job.', [
        _Step(
          'job_start',
          () => {'hostId': host.id.value, 'cwd': root, 'command': 'printf m4d-job; sleep 2'},
          check: (r) {
            job = (r as Map)['jobId'] as String;
          },
        ),
        _Step('job_read', () => {'jobId': job!}),
        _Step('job_status', () => {'jobId': job!}),
        _Step('job_stop', () => {'jobId': job!}),
      ]);
      final tab = container.read(workspaceProvider).activeTab!;
      await scenario('Rename and split the test terminal.', [
        _Step('workspace_rename', () => {'tabId': tab.id.value, 'title': 'M4d verified'}),
        _Step('workspace_split', () => {'tabId': tab.id.value, 'axis': 'horizontal'}),
        _Step('workspace_focus', () => {'tabId': tab.id.value}),
      ]);
      expectSync(container.read(workspaceProvider).activeTab!.layout.leaves.length, 2);
      await t.until(
        'second pane connected',
        () =>
            container.read(terminalSessionsProvider).values.where((s) => s.status == SessionStatus.connected).length ==
            2,
      );
      await scenario('Close only the additional test pane.', [
        _Step('session_close', () => {}),
      ], expectedError: 'scopeChanged');
      expectSync(container.read(workspaceProvider).activeTab!.layout.leaves.length, 1);
      await scenario('Delete only the test files through the approved tool.', [
        _Step('files_delete', () => remote('$root/renamed.txt')),
        _Step('files_delete', () => remote('$root/copies')),
      ]);
      // Deleting a saved host changes credential policy and can retire existing connection bindings.
      // Keep the metadata-only CRUD after all live-channel checks.
      String? disposableHost;
      await scenario('Create only a disposable saved host without connecting to it.', [
        _Step(
          'hosts_create',
          () => {
            'label': 'Disposable AI host',
            'address': '127.0.0.1',
            'port': 65535,
            'username': 'unused',
            'auth': 'password',
          },
          check: (r) {
            final dto = r as Map;
            expectSync(dto['error'], isNull, reason: 'Disposable host creation must return safe metadata');
            disposableHost = dto['id'] as String;
            expectSync(dto.containsKey('address') || dto.containsKey('username'), isFalse);
          },
        ),
      ]);
      await scenario('Rename the disposable saved host.', [
        _Step('host_list', () => {}),
        _Step('hosts_update', () => {'hostId': disposableHost!, 'label': 'Renamed disposable AI host'}),
      ]);
      await scenario('Move the disposable saved host.', [
        _Step(
          'hosts_move',
          () => {
            'hostIds': [disposableHost!],
            'group': 'M4d disposable',
          },
        ),
      ]);
      await scenario('Delete the disposable host and invalidate its permission.', [
        _Step('hosts_delete', () => {'hostId': disposableHost!}),
      ], expectedError: 'scopeChanged');
      expectSync(container.read(hostsProvider).any((h) => h.id.value == disposableHost), isFalse);
      expectSync(approvals, greaterThan(15));
      expectSync(hostApprovals, 2, reason: 'Server and disposable metadata target each require first-use consent');
      expectSync(passwords, 1);
      expectSync(t.takeException(), isNull);
      report(
        'm4dUiApprovals=$approvals hostApprovals=$hostApprovals passwordPrompts=$passwords realSsh=1 fileCopy=1 loopbackTraffic=1',
      );
    } finally {
      runtime.stop();
      for (final state in container.read(forwardsProvider)) {
        await container.read(forwardsProvider.notifier).stop(state.rule.id);
      }
      if (owned != null && cleanup != null) {
        final removed = await cleanup.exec('rm -rf -- ${_quote(owned)} && test ! -e ${_quote(owned)}');
        expectSync(removed.exitCode, 0, reason: 'Owned remote test directory must be removed');
        report('m4dRemoteCleanup=1');
      }
      cleanup?.release();
      await endpoint.close(force: true);
      await t.pumpWidget(const SizedBox.shrink());
      await t.pumpAndSettle();
      await dir.delete(recursive: true);
    }
  });
}

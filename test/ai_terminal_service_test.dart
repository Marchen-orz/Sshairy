import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/features/ai/application/configuration.dart';
import 'package:sshairy/features/ai/application/terminal_service.dart';
import 'package:sshairy/features/ai/domain/model.dart';
import 'package:sshairy/features/terminal/api.dart';
import 'package:sshairy/foundation/cancellation.dart';
import 'package:sshairy/foundation/ids.dart';

final _profile = ModelProfile(protocol: ModelProtocol.openai, endpoint: 'https://model.example/v1', model: 'test');
const _host = AiTerminalHost(HostId('web'), 'Web alias', 'route-v1');

class _Model implements ModelProvider {
  final requests = <ModelRequest>[];
  final cancellations = <CancellationToken>[];
  Stream<ModelEvent> Function()? answer;
  @override
  Stream<ModelEvent> stream(ModelRequest request, CancellationToken cancel) {
    requests.add(request);
    cancellations.add(cancel);
    return answer?.call() ??
        Stream.value(ModelMessageComplete(ModelMessage(ModelRole.assistant, text: '{"status":"abstain"}')));
  }

  @override
  void close() {}
  void json(Map<String, Object?> data) =>
      answer = () => Stream.value(ModelMessageComplete(ModelMessage(ModelRole.assistant, text: jsonEncode(data))));
}

TerminalAiContext _context({
  String draft = 'git sta',
  int generation = 1,
  int revision = 1,
  String? directory = '/srv/app',
  TerminalAiTarget target = const SshTerminalAiTarget(HostId('web')),
}) => TerminalAiContext(
  sessionId: const SessionId('session'),
  target: target,
  generation: generation,
  revision: revision,
  prompt: TerminalAiPrompt.recognized,
  draft: draft,
  directory: directory,
);

AiConfiguration _configuration({bool inline = true, bool completion = true, bool history = false, int revision = 1}) =>
    AiConfiguration(
      enabled: true,
      profile: _profile,
      inlineEnabled: inline,
      completionEnabled: completion,
      completionPosix: true,
      completionHosts: const {HostId('web'): 'route-v1'},
      completionHistory: history,
      terminalDestination: _profile.identity,
      revision: revision,
    );

void main() {
  late _Model model;
  late AiConfiguration config;
  late List<AiTerminalHost> hosts;
  late DateTime now;
  late AiTerminalService service;
  setUp(() {
    model = _Model();
    config = _configuration();
    hosts = [_host];
    now = DateTime.utc(2026, 11, 10, 12);
    service = AiTerminalService(model: model, configuration: () => config, hosts: () => hosts, now: () => now);
  });
  tearDown(() => service.dispose());

  test('disabled policy is inert; inline and completion need independent grants', () async {
    config = AiConfiguration(enabled: true, profile: _profile);
    expect(service.canGenerate(_context()), isFalse);
    expect(service.canComplete(_context()), isFalse);
    expect(await service.complete(_context(), const [], CancellationToken()), isNull);
    expect(model.requests, isEmpty);
    config = _configuration(completion: false);
    expect(service.canGenerate(_context()), isTrue);
    expect(service.canComplete(_context()), isFalse);
    hosts = [const AiTerminalHost(HostId('web'), 'Web alias', 'route-v2')];
    expect(service.canGenerate(_context()), isFalse);
    expect(service.canComplete(_context()), isFalse);
  });

  test('local inline uses its actual shell kind without SSH grant or executable', () async {
    config = AiConfiguration(
      enabled: true,
      profile: _profile,
      inlineEnabled: true,
      terminalDestination: _profile.identity,
    );
    final context = _context(target: const LocalTerminalAiTarget(LocalShellKind.pwsh), directory: r'C:\work');
    model.json({'status': 'command', 'command': 'Get-ChildItem'});
    final result = await service.generate(context, 'List files', CancellationToken());
    expect(result.command, 'Get-ChildItem');
    final request = model.requests.single;
    expect(request.tools, isEmpty);
    expect(request.profile.maxOutputTokens, 1024);
    expect(request.messages.single.text, contains('pwsh'));
    expect(request.messages.single.text, isNot(contains('executable')));
    expect(service.canComplete(context), isFalse);
  });

  test('inline publishes only complete strict JSON and rejects tool calls or control commands', () async {
    for (final data in [
      {'status': 'command', 'command': 'echo ok\nreboot'},
      {'status': 'command', 'command': 'echo ok', 'extra': true},
      {'status': 'clarify', 'command': 'echo ok', 'message': 'Why?'},
    ]) {
      model.json(data);
      await expectLater(service.generate(_context(), 'A task', CancellationToken()), throwsA(isA<ModelFailure>()));
    }
    model.answer = () => Stream.value(
      ModelMessageComplete(
        ModelMessage(
          ModelRole.assistant,
          text: '{"status":"command","command":"pwd"}',
          calls: [ModelCall('x', 'tool', {})],
        ),
      ),
    );
    await expectLater(service.generate(_context(), 'A task', CancellationToken()), throwsA(isA<ModelFailure>()));
    model.answer = () => Stream.value(const ModelTextDelta('{"status":"command"'));
    await expectLater(service.generate(_context(), 'A task', CancellationToken()), throwsA(isA<ModelFailure>()));
    model.json({'status': 'clarify', 'message': 'Which service?'});
    expect(
      (await service.generate(_context(), 'Restart a service', CancellationToken())).kind,
      TerminalAiGenerationKind.clarify,
    );
  });

  test('completion abstains locally for ambiguous input, secret markers, nested shells and unknown cwd', () async {
    for (final draft in [
      'g',
      'git ',
      'sudo cat /etc/shadow',
      'ssh host',
      'tmux attach',
      'curl --password value',
      'git status; reboot',
      ' echo ok',
    ]) {
      expect(service.canComplete(_context(draft: draft)), isFalse, reason: draft);
      expect(await service.complete(_context(draft: draft), const [], CancellationToken()), isNull);
    }
    expect(service.canComplete(_context(directory: null)), isFalse);
    expect(model.requests, isEmpty);
  });

  test('completion is a pure prefix and known static words can extend it', () async {
    model.json({'status': 'suggest', 'command': 'git status'});
    expect(await service.complete(_context(), const [], CancellationToken()), 'git status');
    expect(model.requests.single.tools, isEmpty);
    expect(model.requests.single.profile.maxOutputTokens, 256);
    now = now.add(const Duration(seconds: 2));
    model.json({'status': 'suggest', 'command': 'git stash'});
    expect(await service.complete(_context(revision: 2), const [], CancellationToken()), 'git stash');
    now = now.add(const Duration(seconds: 2));
    model.json({'status': 'suggest', 'command': 'git reset'});
    expect(await service.complete(_context(revision: 3), const [], CancellationToken()), isNull);
  });

  test('ungrounded entities are withheld and current-generation history is separately authorized', () async {
    final context = _context(draft: 'docker logs --tail 100 ');
    final records = [
      TerminalAiHistoryEntry(
        text: 'docker logs --tail 100 api',
        at: now.subtract(const Duration(seconds: 1)),
        generation: 1,
      ),
      TerminalAiHistoryEntry(
        text: 'docker logs --tail 100 old',
        at: now.subtract(const Duration(seconds: 2)),
        generation: 0,
      ),
      TerminalAiHistoryEntry(
        text: 'docker login --password synthetic-private',
        at: now.subtract(const Duration(seconds: 2)),
        generation: 1,
      ),
    ];
    model.json({'status': 'suggest', 'command': 'docker logs --tail 100 api'});
    expect(await service.complete(context, records, CancellationToken()), isNull);
    expect(model.requests.single.messages.single.text, isNot(contains('"history"')));
    config = _configuration(history: true, revision: 2);
    now = now.add(const Duration(seconds: 2));
    service.invalidate();
    expect(await service.complete(context, records, CancellationToken()), 'docker logs --tail 100 api');
    final payload = jsonDecode(model.requests.last.messages.single.text) as Map;
    expect(payload['history'], hasLength(1));
    expect(jsonEncode(payload), isNot(contains('synthetic-private')));
    expect(jsonEncode(payload), isNot(contains('old')));
  });

  test('global rate limit prevents duplicate, too frequent and eleventh minute requests', () async {
    model.json({'status': 'abstain'});
    for (var i = 0; i < 10; i++) {
      await service.complete(_context(revision: i), const [], CancellationToken());
      await service.complete(_context(revision: i), const [], CancellationToken());
      now = now.add(const Duration(seconds: 2));
    }
    expect(model.requests, hasLength(10));
    await service.complete(_context(revision: 11), const [], CancellationToken());
    expect(model.requests, hasLength(10));
    now = now.add(const Duration(minutes: 1));
    await service.complete(_context(revision: 12), const [], CancellationToken());
    expect(model.requests, hasLength(11));
  });

  test('explicit inline generation cancels an active completion without starting a second network lane', () async {
    final stream = StreamController<ModelEvent>();
    model.answer = () => stream.stream;
    final completing = service.complete(_context(), const [], CancellationToken());
    await Future<void>.delayed(Duration.zero);
    model.json({'status': 'command', 'command': 'pwd'});
    final result = await service.generate(_context(draft: ''), 'Show working directory', CancellationToken());
    expect(await completing, isNull);
    expect(model.cancellations.first.isCancelled, isTrue);
    expect(result.command, 'pwd');
    await stream.close();
  });

  test('latest inline intent wins when multiple callers wait for the same cancellation', () async {
    final cancelling = Completer<void>(), released = Completer<void>();
    final stream = StreamController<ModelEvent>(
      onCancel: () {
        if (!cancelling.isCompleted) cancelling.complete();
        return released.future;
      },
    );
    model.answer = () => stream.stream;
    final completing = service.complete(_context(), const [], CancellationToken());
    final first = service.generate(_context(), 'Earlier request', CancellationToken());
    final superseded = expectLater(first, throwsA(isA<ModelFailure>()));
    final latest = service.generate(_context(), 'Latest request', CancellationToken());
    await cancelling.future;
    expect(model.requests, hasLength(1));
    expect(await service.complete(_context(revision: 2), const [], CancellationToken()), isNull);
    model.json({'status': 'command', 'command': 'pwd'});
    released.complete();
    await superseded;
    expect(await completing, isNull);
    expect((await latest).command, 'pwd');
    expect(model.requests, hasLength(2));
    expect(model.requests.last.messages.single.text, contains('Latest request'));
    expect(model.cancellations.first.isCancelled, isTrue);
    await stream.close();
  });

  test('latest inline intent also supersedes an earlier intent before either reaches the model', () async {
    model.json({'status': 'command', 'command': 'pwd'});
    final first = service.generate(_context(), 'Earlier request', CancellationToken());
    final superseded = expectLater(first, throwsA(isA<ModelFailure>()));
    final latest = service.generate(_context(), 'Latest request', CancellationToken());
    expect(await service.complete(_context(), const [], CancellationToken()), isNull);
    await superseded;
    expect((await latest).command, 'pwd');
    expect(model.requests, hasLength(1));
    expect(model.requests.single.messages.single.text, contains('Latest request'));
  });

  test('configuration revocation cancels in-flight HTTP and does not publish its late response', () async {
    final stream = StreamController<ModelEvent>();
    model.answer = () => stream.stream;
    final request = service.generate(_context(), 'Show directory', CancellationToken());
    final failure = expectLater(request, throwsA(isA<ModelFailure>()));
    await Future<void>.delayed(Duration.zero);
    config = const AiConfiguration();
    service.invalidate();
    await failure;
    expect(model.cancellations.single.isCancelled, isTrue);
    stream.add(ModelMessageComplete(ModelMessage(ModelRole.assistant, text: '{"status":"command","command":"pwd"}')));
    await stream.close();
  });

  test('timeout closes an unresponsive provider and completion failure enforces cooldown', () async {
    service.dispose();
    service = AiTerminalService(
      model: model,
      configuration: () => config,
      hosts: () => hosts,
      now: () => now,
      completionTimeout: const Duration(milliseconds: 10),
    );
    final stream = StreamController<ModelEvent>();
    model.answer = () => stream.stream;
    expect(await service.complete(_context(), const [], CancellationToken()), isNull);
    expect(model.cancellations.single.isCancelled, isTrue);
    now = now.add(const Duration(seconds: 2));
    model.json({'status': 'abstain'});
    await service.complete(_context(revision: 2), const [], CancellationToken());
    expect(model.requests, hasLength(1));
    now = now.add(const Duration(seconds: 30));
    await service.complete(_context(revision: 3), const [], CancellationToken());
    expect(model.requests, hasLength(2));
    await stream.close();
  });
}

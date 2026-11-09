import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/features/terminal/adapters/completion_translations.dart';
import 'package:sshairy/features/terminal/domain/completion_translation.dart';
import 'package:sshairy/foundation/cancellation.dart';

void main() {
  late Directory directory;
  final services = <CompletionTranslations>[];

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('sshairy-completion-translations-');
  });

  tearDown(() async {
    for (final service in services) {
      service.dispose();
      await service.saved;
    }
    services.clear();
    await directory.delete(recursive: true);
  });

  CompletionTranslations service({
    CompletionTranslationEngine? engine,
    DateTime Function()? now,
    int maxConcurrent = 32,
    Duration interval = Duration.zero,
    Duration retryDelay = const Duration(minutes: 1),
    String identity = 'mymemory',
    String? path,
  }) {
    final value = CompletionTranslations(
      cacheDirectory: path ?? directory.path,
      engine: engine ?? _Engine(),
      now: now,
      maxConcurrent: maxConcurrent,
      interval: interval,
      retryDelay: retryDelay,
      cacheIdentity: identity,
    );
    services.add(value);
    return value;
  }

  File cacheFile([String? path]) =>
      File('${path ?? directory.path}${Platform.pathSeparator}completion-translations.json');

  Future<void> seed(List<Object?> entries, {String identity = 'mymemory'}) async {
    await cacheFile().writeAsString(jsonEncode({'version': 1, 'identity': identity, 'entries': entries}));
  }

  test('a fresh cache has no preset translations, requests, or file before a successful result', () async {
    final engine = _Engine();
    final translations = service(engine: engine);
    await translations.ready;
    for (final source in ['List files', 'Show help', 'Display version information']) {
      expect(translations.lookup(source, 'zh'), isNull);
      expect(translations.isPending(source, 'zh'), isFalse);
    }
    await translations.saved;
    expect(engine.calls, isEmpty);
    expect(await cacheFile().exists(), isFalse);
    expect(await directory.list().isEmpty, isTrue);
    expect(await translations.translate('List files', 'zh'), '译文');
    await translations.saved;
    expect(engine.calls.single.original, 'List files');
    expect((jsonDecode(await cacheFile().readAsString()) as Map)['entries'], [
      ['List files', 'zh-CN', '译文'],
    ]);
  });

  test('successful exact originals persist across restart and normalize Chinese only', () async {
    final engine = _Engine();
    final first = service(engine: engine);
    var changes = 0;
    first.addListener(() => changes++);
    expect(await first.translate('  List Files.  ', 'ZH_hans'), '译文');
    expect(engine.calls.single.original, '  List Files.  ');
    expect(engine.calls.single.target, 'zh-CN');
    expect(changes, 2);
    await first.saved;
    first.dispose();

    final restartedEngine = _Engine();
    final restarted = service(engine: restartedEngine);
    await restarted.ready;
    expect(restarted.lookup('  List Files.  ', 'zh_TW'), '译文');
    expect(restarted.isPending('  List Files.  ', 'zh_TW'), isFalse);
    expect(await restarted.translate('  List Files.  ', 'zh'), '译文');
    expect(restarted.isPending('  List Files.  ', 'zh'), isFalse);
    expect(restartedEngine.calls, isEmpty);
    for (final changed in ['List Files.', '  list Files.  ', '  List Files!  ']) {
      expect(restarted.lookup(changed, 'zh'), isNull);
    }
    expect(await restarted.translate('List Files.', 'zh'), '译文');
    expect(restartedEngine.calls.single.original, 'List Files.');
    expect(restarted.lookup('  List Files.  ', 'en'), isNull);
  });

  test('provider identity never reuses another engine cache', () async {
    final first = service(identity: 'mymemory');
    await first.translate('List files', 'zh');
    await first.saved;
    first.dispose();
    final other = service(identity: 'custom:https://translator.example/v1:model-a');
    await other.ready;
    expect(other.lookup('List files', 'zh'), isNull);
  });

  test('replacement waits for disposed pending or active flushes and keeps the latest identity', () async {
    for (final startSave in [false, true]) {
      final path = '${directory.path}${Platform.pathSeparator}${startSave ? 'active' : 'pending'}';
      await Directory(path).create();
      final first = service(path: path, identity: 'vendor:old');
      expect(await first.translate('First source', 'zh'), '译文');
      Future<void>? earlierSave;
      if (startSave) {
        earlierSave = first.saved;
        await Future<void>.delayed(Duration.zero);
      }
      expect(await first.translate('Last old source', 'zh'), '译文');
      first.dispose();
      var oldSaved = false;
      final previousSaved = first.saved.then<void>((_) {
        oldSaved = true;
      });
      final replacement = service(path: path, identity: 'vendor:new', engine: _Engine((_, _, _) async => '新译文'));
      await replacement.ready;
      expect(oldSaved, isTrue);
      final previous = jsonDecode(await cacheFile(path).readAsString()) as Map;
      expect(previous['identity'], 'vendor:old');
      expect(previous['entries'], [
        ['First source', 'zh-CN', '译文'],
        ['Last old source', 'zh-CN', '译文'],
      ]);
      expect(replacement.lookup('Last old source', 'zh'), isNull);
      expect(await replacement.translate('New source', 'zh'), '新译文');
      await Future.wait([previousSaved, replacement.saved, first.saved, ?earlierSave]);
      final latest = jsonDecode(await cacheFile(path).readAsString()) as Map;
      expect(latest['identity'], 'vendor:new');
      expect(latest['entries'], [
        ['New source', 'zh-CN', '新译文'],
      ]);
      replacement.dispose();
    }
  });

  test('unsupported languages and unsafe or oversized originals never reach the engine', () async {
    final engine = _Engine();
    final translations = service(engine: engine);
    for (final language in ['en', 'en-US', 'fr', '', 'zho', 'zz-zh']) {
      expect(await translations.translate('List files', language), isNull);
    }
    for (final original in [
      '',
      '   ',
      'two\nlines',
      'tab\ttext',
      'escape\x1btext',
      'control\x7f',
      'control\u0085',
      'bidi${String.fromCharCode(0x202e)}',
      'isolate${String.fromCharCode(0x2066)}',
      'separator${String.fromCharCode(0x2028)}',
      String.fromCharCode(0xd800),
      'x' * 501,
      '汉' * 167,
    ]) {
      expect(await translations.translate(original, 'zh'), isNull);
    }
    expect(engine.calls, isEmpty);
    expect(await translations.translate('é' * 250, 'zh'), '译文');
    expect(engine.calls.single.original, 'é' * 250);
  });

  test('duplicates share one flight and each waiter can cancel independently', () async {
    final pending = Completer<String?>();
    final engine = _Engine((_, _, _) => pending.future);
    final translations = service(engine: engine);
    final firstCancel = CancellationToken(), secondCancel = CancellationToken();
    final first = translations.translate('List files', 'zh', cancel: firstCancel);
    final second = translations.translate('List files', 'zh-CN', cancel: secondCancel);
    await _eventually(() => engine.calls.length == 1);
    firstCancel.cancel();
    expect(await first, isNull);
    expect(engine.calls.single.cancel.isCancelled, isFalse);
    pending.complete('列出文件');
    expect(await second, '列出文件');
    secondCancel.cancel();
    expect(translations.lookup('List files', 'zh'), '列出文件');
  });

  test('pending queries and notifications cover queued and active demand without new requests', () async {
    final pending = Completer<String?>();
    final engine = _Engine((_, _, _) => pending.future);
    final translations = service(engine: engine, maxConcurrent: 1);
    await translations.ready;
    for (final source in ['Active', 'Queued', '', 'two\nlines']) {
      expect(translations.isPending(source, 'zh'), isFalse);
      expect(translations.lookup(source, 'zh'), isNull);
    }
    expect(engine.calls, isEmpty);
    final statuses = <List<bool>>[];
    translations.addListener(() {
      statuses.add([translations.isPending('Active', 'ZH_hans'), translations.isPending('Queued', 'zh-CN')]);
    });
    final firstCancel = CancellationToken(), queuedCancel = CancellationToken();
    final active = translations.translate('Active', 'zh', cancel: firstCancel);
    final shared = translations.translate('Active', 'zh-CN');
    final queued = translations.translate('Queued', 'zh', cancel: queuedCancel);
    await _eventually(() => statuses.length == 2);
    expect(statuses, [
      [true, false],
      [true, true],
    ]);
    expect(translations.isPending('Active', 'en'), isFalse);
    expect(translations.isPending('active', 'zh'), isFalse);
    expect(translations.isPending('Queued', 'zh'), isTrue);
    firstCancel.cancel();
    expect(await active, isNull);
    expect(statuses.length, 2);
    expect(engine.calls.single.cancel.isCancelled, isFalse);
    queuedCancel.cancel();
    expect(await queued, isNull);
    expect(statuses.last, [true, false]);
    pending.complete('完成');
    expect(await shared, '完成');
    expect(statuses, [
      [true, false],
      [true, true],
      [true, false],
      [false, false],
    ]);
    expect(await translations.translate('Active', 'zh'), '完成');
    expect(translations.isPending('Active', 'zh'), isFalse);
    expect(statuses.length, 4);
    expect(engine.calls.length, 1);
  });

  test('cancelling one concurrent flight releases a slot and leaves another shared flight running', () async {
    final pending = {
      for (final source in ['Cancelled', 'Shared', 'Queued']) source: Completer<String?>(),
    };
    final engine = _Engine((source, _, _) => pending[source]!.future);
    final translations = service(engine: engine, maxConcurrent: 2);
    final cancel = CancellationToken(), sharedCancel = CancellationToken();
    final cancelled = translations.translate('Cancelled', 'zh', cancel: cancel);
    final shared = translations.translate('Shared', 'zh', cancel: sharedCancel);
    final retained = translations.translate('Shared', 'zh');
    final queued = translations.translate('Queued', 'zh');
    await _eventually(() => engine.calls.length == 2);
    cancel.cancel();
    expect(await cancelled, isNull);
    await _eventually(() => engine.calls.length == 3);
    expect(engine.calls.first.cancel.isCancelled, isTrue);
    expect(engine.calls[1].cancel.isCancelled, isFalse);
    expect(engine.calls.last.original, 'Queued');
    expect(translations.isPending('Cancelled', 'zh'), isFalse);
    expect(translations.isPending('Shared', 'zh'), isTrue);
    sharedCancel.cancel();
    expect(await shared, isNull);
    expect(engine.calls[1].cancel.isCancelled, isFalse);
    pending['Cancelled']!.complete('迟到');
    pending['Shared']!.complete('共享');
    pending['Queued']!.complete('排队');
    expect(await retained, '共享');
    expect(await queued, '排队');
    expect(translations.lookup('Cancelled', 'zh'), isNull);
    expect(translations.lookup('Shared', 'zh'), '共享');
  });

  test('last waiter aborts its flight and a late response cannot enter the cache', () async {
    final pending = Completer<String?>();
    final engine = _Engine((_, _, _) => pending.future);
    final translations = service(engine: engine);
    final cancel = CancellationToken();
    final result = translations.translate('List files', 'zh', cancel: cancel);
    await _eventually(() => engine.calls.isNotEmpty);
    cancel.cancel();
    expect(await result, isNull);
    expect(engine.calls.single.cancel.isCancelled, isTrue);
    pending.complete('迟到译文');
    await _settle();
    expect(translations.lookup('List files', 'zh'), isNull);
  });

  test('already cancelled and cancelled queued work do not start requests', () async {
    final pending = Completer<String?>();
    final engine = _Engine((_, _, _) => pending.future);
    final translations = service(engine: engine, maxConcurrent: 1);
    final cancelled = CancellationToken()..cancel();
    expect(await translations.translate('Never start', 'zh', cancel: cancelled), isNull);
    final active = translations.translate('Active', 'zh');
    await _eventually(() => engine.calls.isNotEmpty);
    final queuedCancel = CancellationToken();
    final queued = translations.translate('Queued', 'zh', cancel: queuedCancel);
    await _settle();
    queuedCancel.cancel();
    expect(await queued, isNull);
    pending.complete('完成');
    expect(await active, '完成');
    await _settle();
    expect(engine.calls.length, 1);
  });

  test('concurrency rejects limits outside one to 32', () {
    for (final limit in [-1, 0, 33]) {
      expect(() => service(maxConcurrent: limit), throwsArgumentError);
    }
  });

  test('default starts all 32 visible requests concurrently and bounds the queue at 32', () async {
    final pending = Completer<String?>();
    final engine = _Engine((_, _, _) => pending.future);
    final translations = CompletionTranslations(cacheDirectory: directory.path, engine: engine);
    services.add(translations);
    final active = [for (var i = 0; i < 32; i++) translations.translate('Visible $i', 'zh')];
    await _eventually(() => engine.calls.length == 32);
    expect(engine.calls.every((call) => !call.cancel.isCancelled), isTrue);
    final queued = [for (var i = 0; i < 32; i++) translations.translate('Queued $i', 'zh')];
    expect(await translations.translate('Queue overflow', 'zh'), isNull);
    expect(engine.calls.length, 32);
    expect(translations.isPending('Visible 31', 'zh'), isTrue);
    expect(translations.isPending('Queued 31', 'zh'), isTrue);
    expect(translations.isPending('Queue overflow', 'zh'), isFalse);
    translations.dispose();
    expect(await Future.wait([...active, ...queued]), everyElement(isNull));
    expect(engine.calls.every((call) => call.cancel.isCancelled), isTrue);
    expect(translations.isPending('Visible 31', 'zh'), isFalse);
    expect(translations.isPending('Queued 31', 'zh'), isFalse);
    pending.complete('迟到');
    await _settle();
    expect(engine.disposed, isTrue);
  });

  test('configured concurrency starts queued work as each active request finishes', () async {
    final pending = {
      for (final source in ['First', 'Second', 'Third', 'Fourth']) source: Completer<String?>(),
    };
    final engine = _Engine((source, _, _) => pending[source]!.future);
    final translations = service(engine: engine, maxConcurrent: 2);
    final results = {for (final source in pending.keys) source: translations.translate(source, 'zh')};
    await _eventually(() => engine.calls.length == 2);
    expect(engine.calls.map((call) => call.original), ['First', 'Second']);
    pending['Second']!.complete('第二');
    expect(await results['Second'], '第二');
    await _eventually(() => engine.calls.length == 3);
    expect(engine.calls.last.original, 'Third');
    expect(translations.isPending('First', 'zh'), isTrue);
    expect(translations.isPending('Fourth', 'zh'), isTrue);
    pending['First']!.complete('第一');
    expect(await results['First'], '第一');
    await _eventually(() => engine.calls.length == 4);
    expect(engine.calls.last.original, 'Fourth');
    pending['Third']!.complete('第三');
    pending['Fourth']!.complete('第四');
    expect(await results['Third'], '第三');
    expect(await results['Fourth'], '第四');
    expect(pending.keys.every((source) => !translations.isPending(source, 'zh')), isTrue);
  });

  test('a shared job accepts at most 32 waiters without duplicating requests', () async {
    final pending = Completer<String?>();
    final engine = _Engine((_, _, _) => pending.future);
    final translations = service(engine: engine);
    final waiters = [for (var i = 0; i < 32; i++) translations.translate('Shared', 'zh')];
    expect(await translations.translate('Shared', 'zh'), isNull);
    expect(engine.calls.length, 1);
    pending.complete('共享');
    expect(await Future.wait(waiters), everyElement('共享'));
  });

  test('requests retain the configured start interval', () async {
    final engine = _Engine();
    final translations = service(engine: engine, interval: const Duration(milliseconds: 25));
    final first = translations.translate('First', 'zh');
    final second = translations.translate('Second', 'zh');
    expect(await first, '译文');
    expect(engine.calls.length, 1);
    expect(await second, '译文');
    expect(engine.calls[1].started.difference(engine.calls[0].started).inMilliseconds, greaterThanOrEqualTo(20));
  });

  test('failure applies a service cooldown and drops pending rebuild demands', () async {
    var now = DateTime.utc(2026, 11, 9);
    final pending = Completer<String?>();
    final engine = _Engine((_, _, _) => pending.future);
    final translations = service(engine: engine, now: () => now, maxConcurrent: 1);
    final failed = translations.translate('Unavailable', 'zh');
    await _eventually(() => engine.calls.isNotEmpty);
    final queued = translations.translate('Other description', 'zh');
    await _settle();
    pending.completeError(const CompletionTranslationFailure());
    expect(await failed, isNull);
    expect(await queued, isNull);
    expect(await translations.translate('Unavailable', 'zh'), isNull);
    expect(await translations.translate('New rebuild', 'zh'), isNull);
    expect(engine.calls.length, 1);
    expect(await cacheFile().exists(), isFalse);
    now = now.add(const Duration(minutes: 1));
    engine.handler = (_, _, _) async => '恢复';
    expect(await translations.translate('Unavailable', 'zh'), '恢复');
    expect(engine.calls.length, 2);
  });

  test('one concurrent failure drops queued work and preserves successful unrelated flights', () async {
    final pending = {
      for (final source in ['Failed', 'Survives', 'Queued']) source: Completer<String?>(),
    };
    final engine = _Engine((source, _, _) => source == 'Done' ? Future.value('已完成') : pending[source]!.future);
    final translations = service(engine: engine, maxConcurrent: 2);
    expect(await translations.translate('Done', 'zh'), '已完成');
    final failed = translations.translate('Failed', 'zh');
    final survives = translations.translate('Survives', 'zh');
    final queued = translations.translate('Queued', 'zh');
    await _eventually(() => engine.calls.length == 3);
    pending['Failed']!.completeError(const CompletionTranslationFailure());
    expect(await failed, isNull);
    expect(await queued, isNull);
    expect(translations.isPending('Failed', 'zh'), isFalse);
    expect(translations.isPending('Queued', 'zh'), isFalse);
    expect(translations.isPending('Survives', 'zh'), isTrue);
    expect(engine.calls.singleWhere((call) => call.original == 'Survives').cancel.isCancelled, isFalse);
    pending['Survives']!.complete('仍然完成');
    expect(await survives, '仍然完成');
    expect(translations.lookup('Done', 'zh'), '已完成');
    expect(translations.lookup('Survives', 'zh'), '仍然完成');
    expect(translations.lookup('Failed', 'zh'), isNull);
    expect(await translations.translate('Not during cooldown', 'zh'), isNull);
    expect(engine.calls.length, 3);
    await translations.saved;
    final entries = (jsonDecode(await cacheFile().readAsString()) as Map)['entries'];
    expect(entries, [
      ['Done', 'zh-CN', '已完成'],
      ['Survives', 'zh-CN', '仍然完成'],
    ]);
  });

  test('a later concurrent network failure cannot shorten a quota cooldown', () async {
    var now = DateTime.utc(2026, 11, 9);
    final pending = {
      for (final source in ['Quota', 'Network']) source: Completer<String?>(),
    };
    final engine = _Engine((source, _, _) => pending[source]!.future);
    final translations = service(engine: engine, now: () => now);
    final quota = translations.translate('Quota', 'zh');
    final network = translations.translate('Network', 'zh');
    await _eventually(() => engine.calls.length == 2);
    pending['Quota']!.completeError(const CompletionTranslationFailure(quotaExceeded: true));
    expect(await quota, isNull);
    now = now.add(const Duration(minutes: 1));
    pending['Network']!.completeError(const CompletionTranslationFailure());
    expect(await network, isNull);
    now = now.add(const Duration(minutes: 58));
    expect(await translations.translate('Still blocked', 'zh'), isNull);
    expect(engine.calls.length, 2);
    now = now.add(const Duration(minutes: 1));
    engine.handler = (_, _, _) async => '恢复';
    expect(await translations.translate('Recovered', 'zh'), '恢复');
    expect(engine.calls.length, 3);
  });

  test('quota failure pauses all online work for at least an hour and is never cached', () async {
    var now = DateTime.utc(2026, 11, 9);
    final engine = _Engine((_, _, _) async => throw const CompletionTranslationFailure(quotaExceeded: true));
    final translations = service(engine: engine, now: () => now, retryDelay: const Duration(milliseconds: 1));
    expect(await translations.translate('Quota', 'zh'), isNull);
    now = now.add(const Duration(minutes: 59));
    expect(await translations.translate('Different source', 'zh'), isNull);
    expect(engine.calls.length, 1);
    await translations.saved;
    expect(await cacheFile().exists(), isFalse);
    now = now.add(const Duration(minutes: 1));
    engine.handler = (_, _, _) async => '恢复';
    expect(await translations.translate('Quota', 'zh'), '恢复');
    expect(engine.calls.length, 2);
  });

  test('only bounded plain translations are cached; punctuation and Unicode remain exact', () async {
    for (final invalid in [
      '',
      ' ',
      'a\nb',
      'a\rb',
      'a\tb',
      'a\x00b',
      'a${String.fromCharCode(0x202e)}b',
      'a${String.fromCharCode(0x2069)}b',
      'a${String.fromCharCode(0x2029)}b',
      'x' * 2049,
      String.fromCharCode(0xd800),
    ]) {
      final engine = _Engine((_, _, _) async => invalid);
      final translations = service(engine: engine, retryDelay: Duration.zero);
      expect(await translations.translate('Description', 'zh'), isNull);
      expect(translations.lookup('Description', 'zh'), isNull);
      translations.dispose();
    }
    const translated = '列出“文件” — café、目录（全部）；保留 / 与 +。';
    final translations = service(engine: _Engine((_, _, _) async => translated));
    expect(await translations.translate('Description', 'zh'), translated);
    expect(translations.lookup('Description', 'zh'), translated);
  });

  test('entry and serialized byte budgets evict old cache entries', () async {
    await seed([
      for (var i = 0; i < 4100; i++) ['Description $i', 'zh-CN', '说明 $i'],
    ]);
    final entries = service();
    await entries.ready;
    expect(entries.lookup('Description 0', 'zh'), isNull);
    expect(entries.lookup('Description 4099', 'zh'), '说明 4099');
    await entries.saved;
    final stored = jsonDecode(await cacheFile().readAsString()) as Map;
    expect((stored['entries'] as List).length, 4096);
    entries.dispose();

    await seed([
      for (var i = 0; i < 420; i++) ['Description $i', 'zh-CN', '字' * 2048],
    ]);
    final bytes = service();
    await bytes.ready;
    expect(bytes.lookup('Description 0', 'zh'), isNull);
    expect(bytes.lookup('Description 419', 'zh'), '字' * 2048);
    await bytes.saved;
    expect(await cacheFile().length(), lessThanOrEqualTo(2 * 1024 * 1024));
  });

  test('lookup refreshes eviction order and successful writes replace atomically', () async {
    await seed([
      for (var i = 0; i < 4096; i++) ['Description $i', 'zh-CN', '说明 $i'],
    ]);
    final translations = service();
    await translations.ready;
    expect(translations.lookup('Description 0', 'zh'), '说明 0');
    expect(await translations.translate('Newest', 'zh'), '译文');
    expect(translations.lookup('Description 1', 'zh'), isNull);
    expect(translations.lookup('Description 0', 'zh'), '说明 0');
    await translations.saved;
    expect((jsonDecode(await cacheFile().readAsString()) as Map)['entries'], hasLength(4096));
    expect(await directory.list().map((entry) => entry.path).toList(), [cacheFile().path]);
    expect(await translations.translate('Newer', 'zh'), '译文');
    await translations.saved;
    expect((jsonDecode(await cacheFile().readAsString()) as Map)['entries'], hasLength(4096));
  });

  test('corrupt, wrong schema, oversized, and partially invalid caches fall back safely', () async {
    for (final content in [
      '{broken',
      '[]',
      jsonEncode({'version': 9, 'identity': 'mymemory', 'entries': []}),
      ' ' * (3 * 1024 * 1024 + 1),
    ]) {
      await cacheFile().writeAsString(content);
      final translations = service();
      await translations.ready;
      expect(translations.lookup('Description', 'zh'), isNull);
      expect(await translations.translate('Description', 'zh'), '译文');
      await translations.saved;
      translations.dispose();
    }
    await seed([
      ['Good', 'zh-CN', '正确'],
      ['Bad', 'en', 'Wrong target'],
      ['Control', 'zh-CN', 'a\nb'],
      ['Wrong length'],
      ['Not a string', 'zh-CN', 1],
      'not an entry',
    ]);
    final translations = service();
    await translations.ready;
    expect(translations.lookup('Good', 'zh'), '正确');
    expect(translations.lookup('Bad', 'zh'), isNull);
    expect(translations.lookup('Control', 'zh'), isNull);
  });

  test('unwritable cache paths never prevent in-memory results or delete other data', () async {
    final blocked = Directory('${directory.path}${Platform.pathSeparator}blocked');
    await blocked.create();
    final marker = File('${blocked.path}${Platform.pathSeparator}keep.txt');
    await marker.writeAsString('keep');
    final target = Directory('${blocked.path}${Platform.pathSeparator}completion-translations.json');
    await target.create();
    final translations = service(path: blocked.path);
    expect(await translations.translate('Description', 'zh'), '译文');
    await translations.saved;
    expect(translations.lookup('Description', 'zh'), '译文');
    expect(await target.exists(), isTrue);
    expect(await marker.readAsString(), 'keep');
    expect(await blocked.list().length, 2);

    final regular = File('${directory.path}${Platform.pathSeparator}regular-file');
    await regular.writeAsString('keep');
    final other = service(path: regular.path);
    expect(await other.translate('Other', 'zh'), '译文');
    await other.saved;
    expect(await regular.readAsString(), 'keep');
  });

  test('cache symlinks and symlink directory ancestors are not written', () async {
    final outside = await Directory.systemTemp.createTemp('sshairy-completion-link-target-');
    try {
      final target = File('${outside.path}${Platform.pathSeparator}cache.json');
      await target.writeAsString('keep');
      final link = Link(cacheFile().path);
      try {
        await link.create(target.path);
      } on FileSystemException {
        markTestSkipped('This Windows account cannot create symbolic links.');
        return;
      }
      final translations = service();
      expect(await translations.translate('Description', 'zh'), '译文');
      await translations.saved;
      expect(await target.readAsString(), 'keep');
      expect(await FileSystemEntity.type(link.path, followLinks: false), FileSystemEntityType.link);

      final folderLink = Link('${directory.path}${Platform.pathSeparator}linked-directory');
      await folderLink.create(outside.path);
      final linked = service(path: '${folderLink.path}${Platform.pathSeparator}nested');
      expect(await linked.translate('Other', 'zh'), '译文');
      await linked.saved;
      expect(await Directory('${outside.path}${Platform.pathSeparator}nested').exists(), isFalse);
    } finally {
      await outside.delete(recursive: true);
    }
  });

  test('dispose aborts all waiters, closes engine, suppresses notifications, and flushes success', () async {
    final pending = Completer<String?>();
    final engine = _Engine();
    final translations = service(engine: engine);
    await translations.translate('Cached', 'zh');
    engine.handler = (_, _, _) => pending.future;
    var notifications = 0;
    translations.addListener(() => notifications++);
    final active = translations.translate('Active', 'zh');
    final other = translations.translate('Other active', 'zh');
    await _eventually(() => engine.calls.length == 3);
    expect(notifications, 2);
    notifications = 0;
    translations.dispose();
    translations.dispose();
    expect(await active, isNull);
    expect(await other, isNull);
    expect(engine.calls.skip(1).every((call) => call.cancel.isCancelled), isTrue);
    expect(engine.disposed, isTrue);
    pending.complete('迟到');
    await _settle();
    expect(notifications, 0);
    expect(await translations.translate('After dispose', 'zh'), isNull);
    await translations.saved;
    final entries = (jsonDecode(await cacheFile().readAsString()) as Map)['entries'] as List;
    expect(entries, [
      ['Cached', 'zh-CN', '译文'],
    ]);
  });

  group('fixed MyMemory HTTP boundary', () {
    test('uses exact escaped original and fixed HTTPS query with redirects disabled', () async {
      const original = 'Use + & / ? = # % “file”';
      final response = _Response.json({
        'responseStatus': 200,
        'responseData': {'translatedText': '使用“文件”'},
        'matches': [
          {'translation': 'never prefer matches'},
        ],
      });
      final request = _Request(response);
      final client = _Client(request);
      final engine = MyMemoryCompletionTranslationEngine(createClient: () => client);
      addTearDown(engine.dispose);
      expect(await engine.translate(original, 'zh-CN', CancellationToken()), '使用“文件”');
      expect(client.uri!.scheme, 'https');
      expect(client.uri!.host, 'api.mymemory.translated.net');
      expect(client.uri!.path, '/get');
      expect(client.uri!.queryParameters, {'q': original, 'langpair': 'en|zh-CN', 'mt': '1'});
      expect(client.uri!.userInfo, isEmpty);
      expect(client.uri!.fragment, isEmpty);
      expect(request.followRedirects, isFalse);
      expect(request.maxRedirects, 0);
      expect(client.forceClosed, isTrue);
    });

    test('optional email is sent only as the exact encoded de parameter', () async {
      const email = 'desktop+ssh@example.com';
      final client = _Client(
        _Request(
          _Response.json({
            'responseStatus': 200,
            'responseData': {'translatedText': '说明'},
          }),
        ),
      );
      final engine = MyMemoryCompletionTranslationEngine(createClient: () => client, email: email);
      addTearDown(engine.dispose);
      expect(await engine.translate('Description', 'zh-CN', CancellationToken()), '说明');
      expect(client.uri!.queryParameters, {'q': 'Description', 'langpair': 'en|zh-CN', 'mt': '1', 'de': email});
      expect(client.uri!.host, 'api.mymemory.translated.net');
      expect(client.uri!.scheme, 'https');
      expect(client.uri!.userInfo, isEmpty);
      for (final invalid in ['bad email', 'person@example.com\n', 'person@example.com&key=x']) {
        expect(() => MyMemoryCompletionTranslationEngine(email: invalid), throwsArgumentError);
      }
    });

    test('direct engine callers cannot bypass target and input restrictions', () async {
      var clients = 0;
      final engine = MyMemoryCompletionTranslationEngine(
        createClient: () {
          clients++;
          throw StateError('Must not create client');
        },
      );
      addTearDown(engine.dispose);
      expect(await engine.translate('Description', 'en', CancellationToken()), isNull);
      expect(await engine.translate('Description\nsecret', 'zh-CN', CancellationToken()), isNull);
      expect(await engine.translate('x' * 501, 'zh-CN', CancellationToken()), isNull);
      expect(await engine.translate('Description', 'zh-CN', CancellationToken()..cancel()), isNull);
      expect(clients, 0);
    });

    test('rejects non-success HTTP or JSON status and never reads matches as a result', () async {
      final responses = [
        _Response.json({
          'responseStatus': 200,
          'responseData': {'translatedText': '错误'},
        }, status: 301),
        _Response.json({
          'responseStatus': 200,
          'responseData': {'translatedText': '错误'},
        }, status: 500),
        _Response.json({
          'responseStatus': 403,
          'responseData': {'translatedText': '错误'},
        }),
        _Response.json({
          'responseData': {'translatedText': '错误'},
        }),
        _Response.json({
          'responseStatus': 200,
          'responseData': {'translatedText': 123},
        }),
        _Response.json({
          'responseStatus': 200,
          'matches': [
            {'translation': '错误'},
          ],
        }),
        _Response.json({
          'responseStatus': 200,
          'responseData': {'translatedText': 'a\nb'},
        }),
        _Response.json({
          'responseStatus': 200,
          'responseData': {'translatedText': 'a${String.fromCharCode(0x202e)}b'},
        }),
        _Response.json({
          'responseStatus': 200,
          'responseData': {'translatedText': '字' * 2049},
        }),
        _Response(Stream.value(utf8.encode('{broken'))),
        _Response(Stream.value([0xff])),
      ];
      for (final response in responses) {
        final request = _Request(response);
        final client = _Client(request);
        final engine = MyMemoryCompletionTranslationEngine(createClient: () => client);
        await expectLater(
          engine.translate('Description', 'zh-CN', CancellationToken()),
          throwsA(isA<CompletionTranslationFailure>().having((failure) => failure.quotaExceeded, 'quota', isFalse)),
        );
        expect(request.aborted, isTrue);
        expect(client.forceClosed, isTrue);
        engine.dispose();
      }
    });

    test('HTTP 429, JSON 429, and quotaExceeded have typed quota failures', () async {
      for (final response in [
        _Response.json({}, status: 429),
        _Response.json({'responseStatus': 429}),
        _Response.json({'responseStatus': '429'}),
        _Response.json({
          'responseStatus': 200,
          'quotaExceeded': true,
          'responseData': {'translatedText': 'Quota warning'},
        }),
      ]) {
        final engine = MyMemoryCompletionTranslationEngine(createClient: () => _Client(_Request(response)));
        await expectLater(
          engine.translate('Description', 'zh-CN', CancellationToken()),
          throwsA(isA<CompletionTranslationFailure>().having((failure) => failure.quotaExceeded, 'quota', isTrue)),
        );
        engine.dispose();
      }
    });

    test('response length and streaming bytes are bounded at 32 KiB', () async {
      var cancelled = false;
      final controller = StreamController<List<int>>(onCancel: () => cancelled = true);
      final streamed = _Response(controller.stream);
      final request = _Request(streamed);
      final client = _Client(request);
      final engine = MyMemoryCompletionTranslationEngine(createClient: () => client);
      final failure = expectLater(
        engine.translate('Description', 'zh-CN', CancellationToken()),
        throwsA(isA<CompletionTranslationFailure>()),
      );
      await _eventually(() => controller.hasListener);
      controller.add(List.filled(16 * 1024, 32));
      controller.add(List.filled(16 * 1024 + 1, 32));
      await failure;
      expect(cancelled, isTrue);
      expect(request.aborted, isTrue);
      expect(client.forceClosed, isTrue);
      await controller.close();
      engine.dispose();

      final advertised = _Response(const Stream<List<int>>.empty(), contentLength: 32 * 1024 + 1);
      final other = MyMemoryCompletionTranslationEngine(createClient: () => _Client(_Request(advertised)));
      await expectLater(
        other.translate('Description', 'zh-CN', CancellationToken()),
        throwsA(isA<CompletionTranslationFailure>()),
      );
      other.dispose();
    });

    test('timeout aborts request and cancels the response stream while reading', () async {
      var cancelled = false;
      final controller = StreamController<List<int>>(onCancel: () => cancelled = true);
      final request = _Request(_Response(controller.stream));
      final client = _Client(request);
      final engine = MyMemoryCompletionTranslationEngine(
        createClient: () => client,
        timeout: const Duration(milliseconds: 20),
      );
      await expectLater(
        engine.translate('Description', 'zh-CN', CancellationToken()),
        throwsA(isA<CompletionTranslationFailure>()),
      );
      expect(request.aborted, isTrue);
      expect(cancelled, isTrue);
      expect(client.forceClosed, isTrue);
      await controller.close();
      engine.dispose();
    });

    test('timeout before headers aborts a resolved request and closes the client', () async {
      final request = _Request(_Response.json({}))..pending = Completer<HttpClientResponse>();
      final client = _Client(request);
      final engine = MyMemoryCompletionTranslationEngine(
        createClient: () => client,
        timeout: const Duration(milliseconds: 20),
      );
      await expectLater(
        engine.translate('Description', 'zh-CN', CancellationToken()),
        throwsA(isA<CompletionTranslationFailure>()),
      );
      expect(request.aborted, isTrue);
      expect(client.forceClosed, isTrue);
      request.pending!.complete(request.response);
      await _settle();
      engine.dispose();
    });

    test('timeout during getUrl closes the client and aborts a late opened request', () async {
      final request = _Request(_Response.json({}));
      final client = _Client(request)..pending = Completer<HttpClientRequest>();
      final engine = MyMemoryCompletionTranslationEngine(
        createClient: () => client,
        timeout: const Duration(milliseconds: 20),
      );
      await expectLater(
        engine.translate('Description', 'zh-CN', CancellationToken()),
        throwsA(isA<CompletionTranslationFailure>()),
      );
      expect(client.forceClosed, isTrue);
      client.pending!.complete(request);
      await _settle();
      expect(request.aborted, isTrue);
      engine.dispose();
    });

    test('last waiter cancellation aborts HTTP while another waiter remains independent', () async {
      var cancelled = false;
      final controller = StreamController<List<int>>(onCancel: () => cancelled = true);
      final request = _Request(_Response(controller.stream));
      final client = _Client(request);
      final engine = MyMemoryCompletionTranslationEngine(createClient: () => client);
      final translations = service(engine: engine);
      final firstCancel = CancellationToken(), secondCancel = CancellationToken();
      final first = translations.translate('Description', 'zh', cancel: firstCancel);
      final second = translations.translate('Description', 'zh-CN', cancel: secondCancel);
      await _eventually(() => controller.hasListener);
      firstCancel.cancel();
      expect(await first, isNull);
      expect(request.aborted, isFalse);
      expect(cancelled, isFalse);
      secondCancel.cancel();
      expect(await second, isNull);
      await _settle();
      expect(request.aborted, isTrue);
      expect(cancelled, isTrue);
      expect(client.forceClosed, isTrue);
      await controller.close();
    });

    test('engine dispose force closes active HTTP and cancels its stream', () async {
      var cancelled = false;
      final controller = StreamController<List<int>>(onCancel: () => cancelled = true);
      final request = _Request(_Response(controller.stream));
      final client = _Client(request);
      final engine = MyMemoryCompletionTranslationEngine(createClient: () => client);
      final result = engine.translate('Description', 'zh-CN', CancellationToken());
      await _eventually(() => controller.hasListener);
      engine.dispose();
      engine.dispose();
      expect(await result, isNull);
      expect(request.aborted, isTrue);
      expect(cancelled, isTrue);
      expect(client.forceClosed, isTrue);
      expect(await engine.translate('After', 'zh-CN', CancellationToken()), isNull);
      await controller.close();
    });
  });
}

typedef _Handler = Future<String?> Function(String original, String target, CancellationToken cancel);

class _Call {
  _Call(this.original, this.target, this.cancel) : started = DateTime.now();
  final String original, target;
  final CancellationToken cancel;
  final DateTime started;
}

class _Engine implements CompletionTranslationEngine {
  _Engine([_Handler? handler]) : handler = handler ?? ((_, _, _) async => '译文');
  _Handler handler;
  final calls = <_Call>[];
  bool disposed = false;

  @override
  Future<String?> translate(String original, String target, CancellationToken cancel) {
    calls.add(_Call(original, target, cancel));
    return handler(original, target, cancel);
  }

  @override
  void dispose() => disposed = true;
}

class _Client implements HttpClient {
  _Client(this.request);
  final _Request request;
  Uri? uri;
  bool forceClosed = false;
  Completer<HttpClientRequest>? pending;

  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    uri = url;
    final opening = pending;
    if (opening != null) return opening.future;
    return request;
  }

  @override
  void close({bool force = false}) => forceClosed = force;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Request implements HttpClientRequest {
  _Request(this.response);
  final HttpClientResponse response;
  bool aborted = false;
  Completer<HttpClientResponse>? pending;

  @override
  bool followRedirects = true;
  @override
  int maxRedirects = 5;

  @override
  Future<HttpClientResponse> close() async {
    final closing = pending;
    if (closing != null) return closing.future;
    return response;
  }

  @override
  void abort([Object? exception, StackTrace? stackTrace]) => aborted = true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Response extends Stream<List<int>> implements HttpClientResponse {
  _Response(this.stream, {this.statusCode = 200, this.contentLength = -1});

  factory _Response.json(Object data, {int status = 200}) =>
      _Response(Stream.value(utf8.encode(jsonEncode(data))), statusCode: status);

  final Stream<List<int>> stream;
  @override
  final int statusCode;
  @override
  final int contentLength;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => stream.listen(onData, onError: onError, onDone: onDone, cancelOnError: cancelOnError);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _settle() async {
  for (var i = 0; i < 4; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Future<void> _eventually(bool Function() condition) async {
  for (var i = 0; i < 100; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  expect(condition(), isTrue, reason: 'asynchronous translation did not reach the expected state');
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/features/capabilities/api.dart';
import 'package:sshairy/features/snippets/api.dart';
import 'package:sshairy/features/terminal/domain/insertion.dart';
import 'package:sshairy/foundation/cancellation.dart';
import 'package:sshairy/foundation/data_dir.dart';
import 'package:sshairy/foundation/result.dart';

void main() {
  test('insertion confirmation policy covers execution and control characters', () {
    bool needs(String text, {bool run = false, bool multiline = false}) =>
        insertNeedsConfirmation(text, run: run, confirmMultiline: multiline);
    expect(needs('echo hello'), isFalse);
    expect(needs('echo hello', run: true), isTrue);
    expect(needs('one\ntwo'), isFalse);
    expect(needs('one\ntwo', multiline: true), isTrue);
    for (final c in [0, 3, 13, 27, 127, 155]) {
      expect(needs('text${String.fromCharCode(c)}'), isTrue);
    }
    expect(const InsertPreview('h', '\x1b[31m\r\x7f', run: false).visibleText, '^[[31m^M^?');
  });

  test('approval never sends after cancellation or changed shell', () async {
    for (final cancelled in [false, true]) {
      final gate = Completer<bool>();
      final token = CancellationToken();
      var current = true;
      var sent = 0;
      final pending = approveInsertion(
        preview: const InsertPreview('u@h', 'echo hello', run: true),
        confirmMultiline: false,
        current: () => current,
        send: () => sent++,
        confirm: (_) => gate.future,
        cancel: token,
      );
      if (cancelled) {
        token.cancel();
      } else {
        current = false;
      }
      gate.complete(true);
      expect(await pending, cancelled ? InsertResult.cancelled : InsertResult.stale);
      expect(sent, 0);
    }
  });

  test('approval rejects missing UI and rejected or unavailable targets', () async {
    var sent = 0;
    Future<InsertResult> attempt({bool available = true, ConfirmInsert? confirm}) => approveInsertion(
      preview: const InsertPreview('u@h', 'echo hello', run: true),
      confirmMultiline: true,
      current: () => available,
      send: () => sent++,
      confirm: confirm,
    );
    expect(await attempt(), InsertResult.rejected);
    expect(await attempt(confirm: (_) async => false), InsertResult.rejected);
    expect(await attempt(available: false, confirm: (_) async => true), InsertResult.unavailable);
    expect(await attempt(confirm: (_) async => true), InsertResult.sent);
    expect(sent, 1);
  });

  group('snippet persistence', () {
    late Directory dir;
    late ProviderContainer container;
    late Snippets snippets;
    Snippet snippet(String id, [String text = 'echo hello']) => Snippet(id: id, label: id, text: text, tags: ['shell']);
    setUp(() {
      dir = Directory.systemTemp.createTempSync('sshairy-snippets-');
      container = ProviderContainer(overrides: [dataDirProvider.overrideWithValue(dir.path)]);
      snippets = container.read(snippetsProvider.notifier);
    });
    tearDown(() async {
      await snippets.saved;
      container.dispose();
      await dir.delete(recursive: true);
    });

    test('queued writes preserve order, update in place and survive reload', () async {
      await Future.wait([
        snippets.save(snippet('a')),
        snippets.save(snippet('b')),
        snippets.save(snippet('a', 'updated')),
      ]);
      expect(container.read(snippetsProvider).map((s) => s.id), ['a', 'b']);
      final restored = ProviderContainer(overrides: [dataDirProvider.overrideWithValue(dir.path)]);
      addTearDown(restored.dispose);
      expect(restored.read(snippetsProvider).first.text, 'updated');
      expect(restored.read(snippetsProvider).first.matches('SHELL updated'), isTrue);
      await snippets.delete('a');
      expect(container.read(snippetsProvider).single.id, 'b');
      final json = jsonDecode(File('${dir.path}/snippets.json').readAsStringSync()) as Map;
      expect((json['snippets'] as List).single['id'], 'b');
    });

    test('invalid and failed writes leave published state unchanged, queue recovers', () async {
      await snippets.save(snippet('a'));
      await expectLater(snippets.save(snippet('bad', '界' * 22000)), throwsArgumentError);
      final blocker = Directory('${dir.path}/snippets.json.tmp')..createSync();
      await expectLater(snippets.save(snippet('b')), throwsA(isA<FileSystemException>()));
      expect(container.read(snippetsProvider).single.id, 'a');
      blocker.deleteSync();
      await snippets.save(snippet('b'));
      expect(container.read(snippetsProvider).map((s) => s.id), ['a', 'b']);
    });

    test('agent cannot access snippets or trigger terminal input', () async {
      final dispatcher = CapabilityDispatcher(container.read(Provider((ref) => snippetCapabilities(ref))));
      for (final capability in dispatcher.all) {
        expect(
          await dispatcher.dispatch(capability.id, {}, RequestContext(Origin.agent)),
          isA<Err<Object?>>().having((r) => r.error.code, 'code', 'notExposed'),
        );
      }
      expect(
        await dispatcher.dispatch('snippet.save', {
          'id': 'a',
          'label': 'test',
          'text': 'echo test',
        }, RequestContext(Origin.ui)),
        isA<Ok<Object?>>(),
      );
      expect(await snippets.insert('a'), InsertResult.unavailable);
      expect(
        await dispatcher.dispatch('snippet.save', {
          'id': 'bad',
          'label': 'bad',
          'text': 'x',
          'tags': [2],
        }, RequestContext(Origin.ui)),
        isA<Err<Object?>>(),
      );
    });
  });
}

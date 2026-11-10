import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/features/ai/application/output_store.dart';
import 'package:sshairy/foundation/ids.dart';

const _host = HostId('host-a');

String? _read(
  OutputStore store,
  StoredOutput output, {
  String owner = 'turn-a',
  HostId host = _host,
  String destination = 'model-a',
  int revision = 7,
}) => store.read(output.id, owner: owner, host: host, destination: destination, revision: revision);

void main() {
  test('raw output stays local until the exact selected projection is shared', () {
    final store = OutputStore();
    final output = store.create('turn-a', _host, 'model-a', 7);
    store.append(output, false, Uint8List.fromList(utf8.encode('visible\nprivate-token\n')));
    store.append(output, true, Uint8List.fromList(utf8.encode('stderr-private')));

    expect(output.stdout, 'visible\nprivate-token\n');
    expect(output.stderr, 'stderr-private');
    expect(_read(store, output), isNull);
    store.share(output, 'visible');
    expect(_read(store, output), 'visible');
    expect(_read(store, output), isNot(contains('private')));
  });

  test('shared handles cannot cross owner, host, destination or grant revision', () {
    final store = OutputStore();
    final output = store.create('turn-a', _host, 'model-a', 7);
    store.share(output, 'approved excerpt');
    expect(_read(store, output), 'approved excerpt');
    expect(_read(store, output, owner: 'turn-b'), isNull);
    expect(_read(store, output, host: const HostId('host-b')), isNull);
    expect(_read(store, output, destination: 'model-b'), isNull);
    expect(_read(store, output, revision: 8), isNull);
    expect(store.read('fabricated', owner: 'turn-a', host: _host, destination: 'model-a', revision: 7), isNull);
  });

  test('per-execution and global byte budgets still account for all drained output', () {
    final store = OutputStore(itemLimit: 6, totalLimit: 10);
    final first = store.create('turn-a', _host, 'model-a', 7);
    store.append(first, false, Uint8List.fromList([1, 2, 3, 4]));
    store.append(first, true, Uint8List.fromList([5, 6, 7, 8]));
    final second = store.create('turn-a', _host, 'model-a', 7);
    store.append(second, false, Uint8List.fromList([9, 10, 11, 12, 13, 14]));
    // A producer keeps delivering bytes after both caps; the store must not grow or stop draining it.
    for (var i = 0; i < 100; i++) {
      store.append(first, false, Uint8List(100));
      store.append(second, true, Uint8List(100));
    }
    expect(first.length, 6);
    expect(second.length, 4);
    expect(store.length, 10);
    expect(first.dropped, 10002);
    expect(second.dropped, 10002);
    expect(first.truncated, isTrue);
    expect(second.truncated, isTrue);
  });

  test('retained bytes belong to the store rather than the network packet', () {
    final store = OutputStore();
    final output = store.create('turn-a', _host, 'model-a', 7);
    final packet = Uint8List.fromList(utf8.encode('original'));
    store.append(output, false, packet);
    packet.fillRange(0, packet.length, 0);
    expect(output.stdout, 'original');
  });

  test('expired and cleared handles do not revive through reads or late appends', () {
    final store = OutputStore(ttl: Duration.zero);
    final expired = store.create('turn-a', _host, 'model-a', 7);
    store.append(expired, false, Uint8List.fromList([65]));
    store.share(expired, 'A');
    expect(_read(store, expired), isNull);
    store.append(expired, false, Uint8List(100));
    expect(store.length, 0);
    expect(store.count, 0);

    final active = OutputStore();
    final cleared = active.create('turn-a', _host, 'model-a', 7);
    active.share(cleared, 'A');
    active.clear();
    active.append(cleared, false, Uint8List(100));
    expect(_read(active, cleared), isNull);
    expect(active.length, 0);
    expect(() => active.share(cleared, 'restored'), throwsArgumentError);
  });

  test('sharing limits count UTF-8 bytes and never truncate the accepted projection', () {
    final store = OutputStore();
    final output = store.create('turn-a', _host, 'model-a', 7);
    final accepted = List.filled(2730, '中').join();
    expect(utf8.encode(accepted), hasLength(8190));
    store.share(output, accepted);
    expect(_read(store, output), accepted);
    expect(() => store.share(output, '$accepted中'), throwsArgumentError);
    expect(_read(store, output), accepted);
  });

  test('local excerpts bound rendering and preserve both output streams', () {
    final store = OutputStore();
    final output = store.create('turn-a', _host, 'model-a', 7);
    store.append(output, false, Uint8List.fromList(utf8.encode(List.filled(20000, '中').join())));
    store.append(output, true, Uint8List.fromList(utf8.encode('error: ${List.filled(20000, '文').join()}')));
    final excerpt = output.excerpt;
    expect(utf8.encode(excerpt).length, lessThanOrEqualTo(8192));
    expect(excerpt, contains('[stderr]'));
    expect(excerpt, contains('error:'));
    expect(excerpt, isNot(contains('�')));
    expect(_read(store, output), isNull);
  });
}

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/app/composition.dart';
import 'package:sshairy/features/capabilities/api.dart';
import 'package:sshairy/features/credentials/application/credential_access.dart' show secretStoreProvider;
import 'package:sshairy/features/hosts/api.dart';
import 'package:sshairy/foundation/data_dir.dart';
import 'package:sshairy/foundation/result.dart';

import 'keys_test.dart' show MemorySecrets;

void main() {
  late Directory dir;
  late ProviderContainer container;
  late CapabilityDispatcher dispatcher;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('sshairy-group-order-capability-');
    container = ProviderContainer(
      overrides: [
        dataDirProvider.overrideWithValue(dir.path),
        secretStoreProvider.overrideWithValue(MemorySecrets()),
        ...appOverrides(),
      ],
    );
    dispatcher = container.read(capabilityDispatcherProvider);
  });

  tearDown(() async {
    await container.read(hostsProvider.notifier).saved.then((_) {}, onError: (Object _) {});
    container.dispose();
    await dir.delete(recursive: true);
  });

  Future<Result<Object?>> call(String id, [Map<String, Object?> args = const {}]) =>
      dispatcher.dispatch(id, args, RequestContext(Origin.palette));

  Future<List<Map>> listed(String id, [Map<String, Object?> args = const {}]) async {
    final result = await call(id, args);
    expect(result, isA<Ok<Object?>>(), reason: '$id: ${result is Err ? result.error : ''}');
    return ((result as Ok<Object?>).value as List).cast<Map>();
  }

  Future<String> create(String path) async {
    final result = await call('group.create', {'path': path});
    expect(result, isA<Ok<Object?>>(), reason: '${result is Err ? result.error : ''}');
    return ((result as Ok<Object?>).value as Map)['id']! as String;
  }

  Future<void> refused(Map<String, Object?> args, String code, [String? detail]) async {
    final result = await call('group.reorder', args);
    expect(result, isA<Err<Object?>>(), reason: '$args');
    final error = (result as Err<Object?>).error;
    expect(error.code, code, reason: error.detail);
    if (detail != null) expect(error.detail, detail);
  }

  Future<List<String>> paths() async => [for (final g in await listed('group.list')) g['path']! as String];

  test('group.reorder drops before a sibling or last and answers with the siblings in their new order', () async {
    final a = await create('a');
    final b = await create('b');
    final c = await create('c');
    await create('a/x');
    expect(await paths(), ['a', 'a/x', 'b', 'c']);

    final first = await listed('group.reorder', {'groupId': c, 'beforeId': a});
    expect([for (final g in first) g['path']], ['c', 'a', 'b']);
    expect(await paths(), ['c', 'a', 'a/x', 'b']);

    final last = await listed('group.reorder', {'groupId': c, 'beforeId': null});
    expect([for (final g in last) g['id']], [a, b, c]);
    expect(await paths(), ['a', 'a/x', 'b', 'c']);

    final inner = await listed('group.list');
    final x = inner.firstWhere((g) => g['path'] == 'a/x')['id']! as String;
    final y = await create('a/y');
    expect(
      [
        for (final g in await listed('group.reorder', {'groupId': y, 'beforeId': x})) g['path'],
      ],
      ['a/y', 'a/x'],
    );
    expect(await paths(), ['a', 'a/y', 'a/x', 'b', 'c']);
  });

  test('a drop that changes nothing succeeds and writes nothing', () async {
    final a = await create('a');
    final b = await create('b');
    final revision = container.read(hostsProvider.notifier).revision;

    expect(
      [
        for (final g in await listed('group.reorder', {'groupId': a, 'beforeId': b})) g['id'],
      ],
      [a, b],
    );
    expect(
      [
        for (final g in await listed('group.reorder', {'groupId': b, 'beforeId': null})) g['id'],
      ],
      [a, b],
    );
    expect(
      [
        for (final g in await listed('group.reorder', {'groupId': b, 'beforeId': b})) g['id'],
      ],
      [a, b],
    );
    expect(container.read(hostsProvider.notifier).revision, revision);
  });

  test('refusals leave the order alone and name the argument', () async {
    final a = await create('a');
    final b = await create('b');
    final x = await create('a/x');
    final revision = container.read(hostsProvider.notifier).revision;

    await refused({'groupId': 'nope', 'beforeId': a}, 'notFound', 'group');
    await refused({'groupId': a, 'beforeId': 'nope'}, 'notFound', 'beforeId');
    await refused({'groupId': a, 'beforeId': x}, 'invalidArgument', 'beforeId');
    await refused({'groupId': x, 'beforeId': b}, 'invalidArgument', 'beforeId');
    await refused({'groupId': a}, 'invalidArgument', 'beforeId');
    await refused({'beforeId': a}, 'invalidArgument');
    await refused({'groupId': a, 'beforeId': 3}, 'invalidArgument');
    await refused({'groupId': 7, 'beforeId': null}, 'invalidArgument');
    expect(container.read(hostsProvider.notifier).revision, revision);
    expect(await paths(), ['a', 'a/x', 'b']);
  });

  test('group.list follows the display order, and a group created later goes last once ordered', () async {
    final a = await create('a');
    await create('b');
    final c = await create('c');
    await listed('group.reorder', {'groupId': c, 'beforeId': a});
    await create('aa');
    expect(await paths(), ['c', 'a', 'b', 'aa']);
  });

  test('moving a group under another parent puts it last there', () async {
    await create('a');
    final x = await create('a/x');
    await create('a/y');
    final z = await create('a/z');
    final m = await create('m');
    await listed('group.reorder', {'groupId': z, 'beforeId': x});
    expect(await paths(), ['a', 'a/z', 'a/x', 'a/y', 'm']);

    expect(await call('group.update', {'groupId': m, 'path': 'a/m'}), isA<Ok<Object?>>());
    expect(await paths(), ['a', 'a/z', 'a/x', 'a/y', 'a/m']);
  });

  test('the agent cannot reach it until a later review exposes it', () async {
    final result = await dispatcher.dispatch('group.reorder', {}, RequestContext(Origin.agent));
    expect((result as Err<Object?>).error.code, 'notExposed');
  });
}

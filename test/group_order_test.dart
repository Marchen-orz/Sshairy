import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/features/credentials/application/credential_access.dart' show secretStoreProvider;
import 'package:sshairy/features/hosts/api.dart';
import 'package:sshairy/foundation/data_dir.dart';
import 'package:sshairy/foundation/ids.dart';
import 'package:sshairy/foundation/json_file.dart';

import 'keys_test.dart' show MemorySecrets;

HostGroup _group(String id, {String? parent, int order = 0, ConnectionOverrides? defaults}) =>
    HostGroup(id: id, name: id, parentId: parent, order: order, defaults: defaults ?? const ConnectionOverrides());

List<String> _ids(Iterable<HostGroup> groups) => [for (final g in groups) g.id];

Map<String, int> _orders(HostLibrary library) => {for (final g in library.groups) g.id: g.order};

void main() {
  group('display order', () {
    test('groups nobody has ordered stay alphabetical, each parent directly above its children', () {
      final library = HostLibrary(
        groups: [
          _group('b'),
          _group('a-b'),
          _group('a'),
          _group('z', parent: 'a'),
          _group('m', parent: 'a'),
        ],
      );
      expect(library.groupPaths, ['a', 'a/m', 'a/z', 'a-b', 'b']);
      expect(_ids(library.groupChildren(null)), ['a', 'a-b', 'b']);
      expect(_ids(library.groupChildren('a')), ['m', 'z']);
    });

    test('order wins over the name, and equal orders fall back to the name', () {
      final library = HostLibrary(
        groups: [_group('a', order: 2), _group('b', order: 0), _group('c', order: 1), _group('d', order: 1)],
      );
      expect(_ids(library.orderedGroups), ['b', 'c', 'd', 'a']);
    });

    test('order only compares siblings: a late root still carries its subgroups with it', () {
      final library = HostLibrary(
        groups: [
          _group('a', order: 1),
          _group('x', parent: 'a', order: 5),
          _group('b', order: 0),
          _group('y', parent: 'b'),
        ],
      );
      expect(library.groupPaths, ['b', 'b/y', 'a', 'a/x']);
    });
  });

  group('withGroupBefore', () {
    final defaults = ConnectionOverrides(port: OverrideValue.value(2200));
    const host = Host(id: HostId('h'), label: 'h', address: 'h.example', username: 'u', group: 'b', groupId: 'b');
    final library = HostLibrary(
      hosts: [host],
      groups: [
        _group('a'),
        _group('b', defaults: defaults),
        _group('c'),
        _group('x', parent: 'a'),
        _group('y', parent: 'a'),
      ],
    ).normalized();

    test('drops before a sibling and renumbers only that sibling set', () {
      final next = library.withGroupBefore('c', 'a');
      expect(_ids(next.groupChildren(null)), ['c', 'a', 'b']);
      expect(_orders(next), {'c': 0, 'a': 1, 'b': 2, 'x': 0, 'y': 0});
      expect(next.groups.map((g) => g.id), library.groups.map((g) => g.id), reason: 'storage order is kept');
      expect(next.groups.map((g) => (g.name, g.parentId)), library.groups.map((g) => (g.name, g.parentId)));
      expect(next.groupById('b')!.defaults, same(defaults));
      expect(next.hosts.single, same(library.hosts.single));
      expect(next.groupPaths, ['c', 'a', 'a/x', 'a/y', 'b']);
    });

    test('a null target puts it last, among the subgroups too', () {
      final top = library.withGroupBefore('a', null);
      expect(_ids(top.groupChildren(null)), ['b', 'c', 'a']);
      expect(top.groupPaths, ['b', 'c', 'a', 'a/x', 'a/y']);

      final inner = library.withGroupBefore('x', null);
      expect(_ids(inner.groupChildren('a')), ['y', 'x']);
      expect(_orders(inner), {'a': 0, 'b': 0, 'c': 0, 'y': 0, 'x': 1}, reason: 'the top level is not touched');
    });

    test('moving to the position it already has changes nothing', () {
      expect(library.withGroupBefore('a', 'b'), same(library));
      expect(library.withGroupBefore('c', null), same(library));
      expect(library.withGroupBefore('b', 'b'), same(library));
      final ordered = library.withGroupBefore('c', 'a');
      expect(ordered.withGroupBefore('a', 'b'), same(ordered));
    });

    test('repeated drops keep a dense 0..n-1 sequence', () {
      var next = library.withGroupBefore('c', 'a').withGroupBefore('b', 'c').withGroupBefore('c', null);
      expect(_ids(next.groupChildren(null)), ['b', 'a', 'c']);
      expect([for (final g in next.groupChildren(null)) g.order], [0, 1, 2]);
      next = next.withGroupBefore('a', 'b');
      expect(_ids(next.groupChildren(null)), ['a', 'b', 'c']);
      expect([for (final g in next.groupChildren(null)) g.order], [0, 1, 2]);
    });

    test('a missing group, a missing target and another parent are refused', () {
      expect(() => library.withGroupBefore('nope', 'a'), throwsArgumentError);
      expect(() => library.withGroupBefore('a', 'nope'), throwsArgumentError);
      expect(() => library.withGroupBefore('x', 'a'), throwsArgumentError, reason: 'x lives under a');
      expect(() => library.withGroupBefore('a', 'x'), throwsArgumentError);
      expect(() => library.withGroupBefore('x', 'b'), throwsArgumentError);
    });
  });

  group('order after other changes', () {
    HostLibrary ordered() => HostLibrary(groups: [_group('a', order: 1), _group('b', order: 0), _group('c', order: 2)]);

    test('a new group goes last once siblings are ordered, and sorts by name while none is', () {
      final (manual, id) = ordered().withGroupPath('d', newGroupId: () => 'd');
      expect(id, 'd');
      expect(_ids(manual.groupChildren(null)), ['b', 'a', 'c', 'd']);

      final (plain, _) = HostLibrary(groups: [_group('b'), _group('c')]).withGroupPath('a', newGroupId: () => 'a');
      expect(_ids(plain.groupChildren(null)), ['a', 'b', 'c']);

      final (nested, _) = ordered().withGroupPath('b/new', newGroupId: () => 'new');
      expect(nested.groupById('new')!.order, 0);
    });

    test('a group that gets a new parent goes last there; a rename keeps its place', () {
      final library = HostLibrary(
        groups: [
          _group('a'),
          _group('x', parent: 'a', order: 0),
          _group('y', parent: 'a', order: 1),
          _group('m', order: 7),
        ],
      );
      final renamed = library.withGroupMoved('x', 'a/xx');
      expect(_ids(renamed.groupChildren('a')), ['x', 'y']);

      final moved = library.withGroupMoved('m', 'a/m');
      expect(_ids(moved.groupChildren('a')), ['x', 'y', 'm']);
      expect(moved.groupById('m')!.order, 2);
    });

    test('dissolving a group puts its subgroups in its place once anyone has ordered them', () {
      final library = HostLibrary(
        groups: [
          _group('a', order: 0),
          _group('g', order: 1),
          _group('c', order: 2),
          _group('p', parent: 'g', order: 1),
          _group('q', parent: 'g', order: 0),
        ],
      );
      final next = library.withoutGroup('g');
      expect(_ids(next.groupChildren(null)), ['a', 'q', 'p', 'c']);
      expect(_orders(next), {'a': 0, 'q': 1, 'p': 2, 'c': 3});
      expect(next.groupById('q')!.parentId, isNull);
    });

    test('dissolving leaves the stored orders alone when nothing was ever ordered', () {
      final library = HostLibrary(
        groups: [
          _group('a'),
          _group('g'),
          _group('p', parent: 'g'),
        ],
      );
      final next = library.withoutGroup('g');
      expect(_orders(next), {'a': 0, 'p': 0});
      expect(next.groupPaths, ['a', 'p']);
    });
  });

  group('HostsNotifier.reorderGroup', () {
    late Directory dir;
    late ProviderContainer container;
    late HostsNotifier hosts;

    ProviderContainer open() {
      final opened = ProviderContainer(
        overrides: [
          dataDirProvider.overrideWithValue(dir.path),
          secretStoreProvider.overrideWithValue(MemorySecrets()),
        ],
      );
      addTearDown(opened.dispose);
      return opened;
    }

    Map<String, dynamic> persisted() => (jsonDecode(File('${dir.path}/hosts.json').readAsStringSync()) as Map).cast();

    late String a, b, c, inner;

    setUp(() async {
      dir = Directory.systemTemp.createTempSync('sshairy-group-order-');
      container = open();
      hosts = container.read(hostsProvider.notifier);
      await hosts.saveDefaults(
        ConnectionOverrides(
          port: OverrideValue.value(2200),
          authentication: OverrideValue.value(Authentication.inline('root', const AuthPolicy())),
        ),
      );
      a = await hosts.createGroup('a', defaults: ConnectionOverrides(port: OverrideValue.value(2300)));
      b = await hosts.createGroup('b');
      c = await hosts.createGroup('c');
      inner = await hosts.createGroup('a/inner');
      await hosts.save(
        const Host(
          id: HostId('h'),
          label: 'h',
          address: 'h.example',
          username: 'placeholder',
          group: 'a/inner',
          overrides: ConnectionOverrides(),
        ),
      );
    });

    tearDown(() async {
      await hosts.saved;
      container.dispose();
      await dir.delete(recursive: true);
    });

    test('is one write that renumbers siblings and survives a restart', () async {
      final before = persisted();
      final revision = hosts.revision;
      await hosts.reorderGroup(c, a);

      expect(hosts.revision, revision + 1);
      expect(hosts.library.groupPaths, ['c', 'a', 'a/inner', 'b']);
      final after = persisted();
      expect(after['hosts'], before['hosts']);
      expect(after['defaults'], before['defaults']);
      final stored = {for (final g in after['groups'] as List) (g as Map)['id']: g};
      expect(
        [
          for (final id in [c, a, b]) (stored[id] as Map)['order'],
        ],
        [0, 1, 2],
      );
      expect((stored[inner] as Map)['order'], 0);
      expect(
        (stored[a] as Map)['defaults'],
        ((before['groups'] as List).firstWhere((g) => (g as Map)['id'] == a) as Map)['defaults'],
      );

      await hosts.saved;
      final reopened = open().read(hostsProvider.notifier);
      expect(reopened.library.groupPaths, ['c', 'a', 'a/inner', 'b']);
      expect(reopened.byId(const HostId('h'))!.port, 2300, reason: 'the host still inherits from its group');
    });

    test('a drop that changes nothing writes nothing', () async {
      final revision = hosts.revision;
      final before = persisted();
      await hosts.reorderGroup(a, b);
      await hosts.reorderGroup(c, null);
      await hosts.reorderGroup(b, b);
      expect(hosts.revision, revision);
      expect(persisted(), before);
    });

    test('another parent, a missing group or a missing target is refused and nothing is published', () async {
      final revision = hosts.revision;
      final before = persisted();
      await expectLater(hosts.reorderGroup(inner, b), throwsArgumentError);
      await expectLater(hosts.reorderGroup(b, inner), throwsArgumentError);
      await expectLater(hosts.reorderGroup('nope', a), throwsArgumentError);
      await expectLater(hosts.reorderGroup(a, 'nope'), throwsArgumentError);
      expect(hosts.revision, revision);
      expect(persisted(), before);
      expect(hosts.library.groupPaths, ['a', 'a/inner', 'b', 'c']);
    });

    test('a stale revision is refused and the order stays as it was', () async {
      final stale = hosts.revision;
      await hosts.addGroup('later');
      final before = persisted();

      await expectLater(
        hosts.reorderGroup(c, a, expectedRevision: stale),
        throwsA(isA<JsonFileError>().having((e) => e.kind, 'kind', JsonFileFailure.conflict)),
      );
      expect(hosts.library.groupPaths, ['a', 'a/inner', 'b', 'c', 'later']);
      expect(persisted(), before);

      await hosts.reorderGroup(c, a, expectedRevision: hosts.revision);
      expect(hosts.library.groupPaths, ['c', 'a', 'a/inner', 'b', 'later']);
    });

    test('a reorder queued behind other edits applies to the groups as they are by then', () async {
      final rename = hosts.renameGroup('b', 'bb');
      final move = hosts.reorderGroup(c, b);
      final add = hosts.addGroup('d');
      await Future.wait([rename, move, add]);
      expect(hosts.library.groupPaths, ['a', 'a/inner', 'c', 'bb', 'd']);
    });
  });
}

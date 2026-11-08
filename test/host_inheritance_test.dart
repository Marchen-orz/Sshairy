import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/app/composition.dart';
import 'package:sshairy/features/connections/api.dart';
import 'package:sshairy/features/credentials/api.dart';
import 'package:sshairy/features/credentials/application/credential_access.dart' show secretStoreProvider;
import 'package:sshairy/features/hosts/api.dart';
import 'package:sshairy/foundation/data_dir.dart';
import 'package:sshairy/foundation/ids.dart';
import 'package:sshairy/foundation/json_file.dart';

import 'connection_manager_test.dart' show FakeTransport, NoPrompts;
import 'keys_test.dart' show MemorySecrets;

const _password = AuthPolicy();

ConnectionOverrides _with({
  OverrideValue<int> port = const OverrideValue.inherit(),
  OverrideValue<Authentication> authentication = const OverrideValue.inherit(),
  OverrideValue<HostId> jump = const OverrideValue.inherit(),
}) => ConnectionOverrides(port: port, authentication: authentication, jump: jump);

ConnectionOverrides _login(String user, [AuthPolicy policy = _password]) =>
    _with(authentication: OverrideValue.value(Authentication.inline(user, policy)));

/// A host whose settings are all inherited: only its address names it.
Host _inheriting(String id, {String group = ''}) => Host(
  id: HostId(id),
  label: id,
  address: '$id.example',
  username: 'placeholder',
  group: group,
  overrides: const ConnectionOverrides(),
);

void main() {
  late Directory dir;
  late ProviderContainer container;
  late HostsNotifier hosts;

  Map<String, dynamic> persisted() => (jsonDecode(File('${dir.path}/hosts.json').readAsStringSync()) as Map).cast();

  ProviderContainer open() {
    final opened = ProviderContainer(
      overrides: [
        dataDirProvider.overrideWithValue(dir.path),
        secretStoreProvider.overrideWithValue(MemorySecrets()),
        ...appOverrides(),
      ],
    );
    addTearDown(opened.dispose);
    return opened;
  }

  setUp(() {
    dir = Directory.systemTemp.createTempSync('sshairy-inheritance-');
    container = open();
    hosts = container.read(hostsProvider.notifier);
  });

  tearDown(() async {
    // A refused write is reported by `saved` until the next one lands; these tests inspect it directly.
    await hosts.saved.then((_) {}, onError: (Object _) {});
    container.dispose();
    await dir.delete(recursive: true);
  });

  Future<String> makeGroup(String path) async {
    await hosts.addGroup(path);
    return hosts.library.groupIdFor(path)!;
  }

  group('persistence', () {
    test('a schema 1 file is read as schema 2 and only replaced by a protected save', () async {
      container.dispose();
      final v1 = jsonEncode({
        'schemaVersion': 1,
        'hosts': [
          {'id': 'a', 'label': 'a', 'address': 'a.example', 'port': 2222, 'username': 'root', 'group': 'prod/web'},
        ],
      });
      File('${dir.path}/hosts.json').writeAsStringSync(v1);
      container = open();
      hosts = container.read(hostsProvider.notifier);

      expect(hosts.library.groupPaths, ['prod', 'prod/web']);
      expect(hosts.byId(const HostId('a'))!.group, 'prod/web');
      expect(hosts.byId(const HostId('a'))!.port, 2222);
      expect(File('${dir.path}/hosts.json').readAsStringSync(), v1, reason: 'reading must not rewrite the file');

      await hosts.saveDefaults(_with(port: const OverrideValue.value(2200)));

      expect(persisted()['schemaVersion'], 2);
      expect((persisted()['hosts'] as List).single['port'], 2222, reason: 'a migrated host keeps its own port');
      expect(
        Directory('${dir.path}/backups').listSync().whereType<File>().map((f) => f.readAsStringSync()),
        contains(v1),
      );
    });

    test('a newer or damaged file enters the configuration gate instead of becoming an empty library', () async {
      container.dispose();
      File('${dir.path}/hosts.json').writeAsStringSync('{"schemaVersion":3,"hosts":[]}');
      container = open();
      expect(() => container.read(hostsProvider), throwsA(anything));
      expect(File('${dir.path}/hosts.json').readAsStringSync(), '{"schemaVersion":3,"hosts":[]}');
    });

    test('a stale revision is refused and nothing is published', () async {
      final id = await makeGroup('prod');
      final stale = hosts.revision;
      await hosts.saveDefaults(_with(port: const OverrideValue.value(2200)));
      final before = persisted();
      await expectLater(
        hosts.saveGroup(hosts.library.groupById(id)!.copyWith(name: 'live'), expectedRevision: stale),
        throwsA(isA<JsonFileError>().having((e) => e.kind, 'kind', JsonFileFailure.conflict)),
      );
      expect(hosts.library.groupPaths, ['prod']);
      expect(persisted(), before);
    });

    test('a failed write publishes no group, identity or default change', () async {
      await hosts.save(const Host(id: HostId('h'), label: 'h', address: 'h.example', username: 'root', group: 'prod'));
      final before = persisted();
      final library = hosts.library;
      final block = File('${dir.path}/backups')..writeAsStringSync('blocked');
      final prod = library.groupById(library.groupIdFor('prod'))!;
      final changes = <Future<void> Function()>[
        () => hosts.saveGroup(prod.copyWith(defaults: _with(port: const OverrideValue.value(2300)))),
        () => hosts.addGroup('other'),
        () => hosts.renameGroup('prod', 'live'),
        () => hosts.deleteGroup(prod.id),
        () => hosts.saveIdentity(const HostIdentity(id: 'i', label: 'ops', username: 'ops', policy: _password)),
        () => hosts.saveDefaults(_login('someone')),
      ];
      for (final change in changes) {
        await expectLater(change(), throwsA(isA<JsonFileError>()));
      }
      expect(identical(hosts.library, library), isTrue);
      expect(persisted(), before);
      block.deleteSync();
      await hosts.addGroup('other');
      expect(hosts.library.groupPaths, ['other', 'prod']);
    });
  });

  group('groups and defaults', () {
    test('hosts follow group and global changes while migrated or explicit hosts do not', () async {
      await hosts.saveDefaults(_login('root'));
      await hosts.save(_inheriting('plain', group: 'lab'));
      await hosts.save(
        Host(id: const HostId('own'), label: 'own', address: 'own.example', username: 'u', port: 2022, group: 'lab'),
      );
      final lab = hosts.library.groupById(hosts.library.groupIdFor('lab'))!;

      await hosts.saveGroup(lab.copyWith(defaults: _with(port: const OverrideValue.value(2201))));
      expect(hosts.byId(const HostId('plain'))!.port, 2201);
      expect(hosts.byId(const HostId('own'))!.port, 2022);
      expect(container.read(hostsProvider).firstWhere((h) => h.id.value == 'plain').port, 2201);
      expect(
        container.read(hostLibraryProvider).resolve(hosts.byId(const HostId('plain'))!).sources['port'],
        startsWith('group:'),
      );
      final stored = (persisted()['hosts'] as List).cast<Map>().firstWhere((h) => h['id'] == 'plain');
      expect(stored['port'], 2201, reason: 'what is stored is what the host resolves to');

      await hosts.saveDefaults(
        _with(
          port: const OverrideValue.value(2300),
          authentication: const OverrideValue.value(Authentication.inline('root', _password)),
        ),
      );
      expect(hosts.byId(const HostId('plain'))!.port, 2201, reason: 'the group still wins over global');
      await hosts.deleteGroup(lab.id);
      expect(hosts.byId(const HostId('plain'))!.port, 2300, reason: 'dissolving drops the group defaults');
      expect(hosts.byId(const HostId('plain'))!.group, '');
      expect(hosts.byId(const HostId('own'))!.port, 2022);
    });

    test('renaming into an existing group is refused; dissolving keeps hosts and subgroups', () async {
      await hosts.saveDefaults(_login('root'));
      await hosts.save(_inheriting('a', group: 'prod/web'));
      await hosts.save(_inheriting('b', group: 'live'));
      await expectLater(hosts.renameGroup('prod', 'live'), throwsArgumentError);
      expect(hosts.library.groupPaths, ['live', 'prod', 'prod/web']);
      await hosts.renameGroup('prod', 'edge/prod');
      expect(hosts.byId(const HostId('a'))!.group, 'edge/prod/web');
      await hosts.renameGroup('edge/prod', '');
      expect(hosts.byId(const HostId('a'))!.group, 'edge/web');
      expect(hosts.library.groupPaths, ['edge', 'edge/web', 'live']);
    });

    test('a login that no layer provides is refused', () async {
      await expectLater(hosts.save(_inheriting('h')), throwsArgumentError);
      expect(hosts.byId(const HostId('h')), isNull);
      expect(File('${dir.path}/hosts.json').existsSync(), isFalse);
    });
  });

  group('moving hosts', () {
    const a = HostId('a'), b = HostId('b'), c = HostId('c');

    void reopen() {
      container.dispose();
      container = open();
      hosts = container.read(hostsProvider.notifier);
    }

    Map storedHost(String id) => (persisted()['hosts'] as List).cast<Map>().firstWhere((h) => h['id'] == id);

    /// a inherits its port and carries metadata, b has its own port, c stays elsewhere; returns the id of `dst`.
    Future<String> seed() async {
      await hosts.saveDefaults(_login('root'));
      await hosts.save(
        const Host(
          id: a,
          label: 'Alpha',
          address: 'a.example',
          username: 'placeholder',
          group: 'src',
          tags: ['web'],
          pinned: true,
          overrides: ConnectionOverrides(),
        ),
      );
      await hosts.save(
        _inheriting('b', group: 'src').copyWith(overrides: () => _with(port: const OverrideValue.value(2022))),
      );
      await hosts.save(_inheriting('c', group: 'other'));
      await hosts.touch(a);
      final dst = await makeGroup('dst');
      await hosts.saveGroup(
        hosts.library.groupById(dst)!.copyWith(defaults: _with(port: const OverrideValue.value(2201))),
      );
      return dst;
    }

    test('a single host, a batch and ungrouping are one write each and keep overrides and metadata', () async {
      final dst = await seed();
      final used = hosts.byId(a)!.lastUsed;
      expect(used, isNotNull);

      var revision = hosts.revision;
      await hosts.moveToGroup([a], dst);
      expect(hosts.revision, revision + 1);
      expect((hosts.byId(a)!.group, hosts.byId(a)!.groupId, hosts.byId(a)!.port), ('dst', dst, 2201));
      expect(hosts.byId(b)!.group, 'src');

      revision = hosts.revision;
      await hosts.moveToGroup([a, b, b], dst);
      expect(hosts.revision, revision + 1);
      expect(hosts.byId(b)!.group, 'dst');
      expect(hosts.byId(b)!.port, 2022, reason: 'an own port is not replaced by the new group');
      expect(hosts.byId(c)!.group, 'other');
      expect(container.read(hostsProvider).where((h) => h.group == 'dst').map((h) => h.id), [a, b]);
      expect(hosts.byId(a)!.overrides!.port.mode, OverrideMode.inherit);
      expect(hosts.byId(b)!.overrides!.port.value, 2022);
      expect(
        (hosts.byId(a)!.label, hosts.byId(a)!.pinned, hosts.byId(a)!.lastUsed, hosts.byId(a)!.tags.join()),
        ('Alpha', true, used, 'web'),
      );

      revision = hosts.revision;
      await hosts.moveToGroup([a, b], dst);
      expect(hosts.revision, revision, reason: 'hosts already there are not written again');

      reopen();
      expect((hosts.byId(a)!.group, hosts.byId(a)!.groupId, hosts.byId(a)!.port), ('dst', dst, 2201));
      expect((hosts.byId(b)!.group, hosts.byId(b)!.port), ('dst', 2022));

      revision = hosts.revision;
      await hosts.moveToGroup([a, b], null);
      expect(hosts.revision, revision + 1);
      for (final id in [a, b]) {
        expect((hosts.byId(id)!.group, hosts.byId(id)!.groupId), ('', null));
        expect(storedHost(id.value).containsKey('groupId'), isFalse);
        expect(storedHost(id.value).containsKey('group'), isFalse);
      }
      expect(hosts.byId(a)!.port, 22, reason: 'back to the global value');
      expect(hosts.byId(c)!.group, 'other');
      expect(hosts.library.groupPaths, ['dst', 'other', 'src'], reason: 'emptied groups stay');

      reopen();
      expect((hosts.byId(a)!.group, hosts.byId(a)!.groupId, hosts.byId(a)!.port), ('', null, 22));
      expect(hosts.byId(b)!.overrides!.port.value, 2022);
      expect(hosts.byId(a)!.pinned, isTrue);
      expect(hosts.byId(a)!.lastUsed!.isAtSameMomentAs(used!), isTrue);
    });

    test('a missing group or host refuses the whole batch, also when it vanishes while the move is queued', () async {
      final dst = await seed();
      final before = persisted();
      final library = hosts.library;
      final revision = hosts.revision;

      await expectLater(hosts.moveToGroup([a, b], 'gone'), throwsArgumentError);
      await expectLater(hosts.moveToGroup([], 'gone'), throwsArgumentError);
      await expectLater(hosts.moveToGroup([a, const HostId('ghost'), b], dst), throwsArgumentError);
      expect(identical(hosts.library, library), isTrue);
      expect(persisted(), before);
      expect(hosts.revision, revision);

      final removal = hosts.deleteGroup(dst);
      final toGone = expectLater(hosts.moveToGroup([a, b], dst), throwsArgumentError);
      await removal;
      await toGone;
      expect((hosts.byId(a)!.group, hosts.byId(b)!.group), ('src', 'src'));

      final other = await makeGroup('elsewhere');
      final deleted = hosts.delete(hosts.byId(b)!);
      final withGone = expectLater(hosts.moveToGroup([a, b], other), throwsArgumentError);
      await deleted;
      await withGone;
      expect(hosts.byId(a)!.group, 'src');
    });

    test('a move that leaves any host with a broken route or no login refuses the whole batch', () async {
      await hosts.saveDefaults(_login('root'));
      const jump = HostId('jump'), x = HostId('x');
      await hosts.save(_inheriting('jump'));
      await hosts.save(_inheriting('x', group: 'src'));
      final lab = await makeGroup('lab');
      await hosts.saveGroup(
        hosts.library.groupById(lab)!.copyWith(defaults: _with(jump: const OverrideValue.value(jump))),
      );
      final before = persisted();

      await expectLater(
        hosts.moveToGroup([x, jump], lab),
        throwsArgumentError,
        reason: 'jump would route through itself',
      );
      expect(hosts.byId(x)!.group, 'src');
      expect(persisted(), before);

      await hosts.moveToGroup([x], lab);
      expect(hosts.byId(x)!.jumpHostId, jump, reason: 'the host follows the jump of its new group');
    });

    test('ungrouping refuses when the group was the only source of a host login', () async {
      final lab = await makeGroup('lab');
      await hosts.saveGroup(hosts.library.groupById(lab)!.copyWith(defaults: _login('ops')));
      await hosts.save(_inheriting('x', group: 'lab'));
      await hosts.save(const Host(id: HostId('y'), label: 'y', address: 'y.example', username: 'u', group: 'lab'));
      final before = persisted();

      await expectLater(hosts.moveToGroup([const HostId('y'), const HostId('x')], null), throwsArgumentError);
      expect(hosts.byId(const HostId('y'))!.group, 'lab');
      expect(persisted(), before);

      await hosts.moveToGroup([const HostId('y')], null);
      expect(hosts.byId(const HostId('y'))!.group, '');
    });

    test('a stale revision is refused and nothing moves', () async {
      final dst = await seed();
      final stale = hosts.revision;
      await hosts.addGroup('later');
      final before = persisted();

      await expectLater(
        hosts.moveToGroup([a], dst, expectedRevision: stale),
        throwsA(isA<JsonFileError>().having((e) => e.kind, 'kind', JsonFileFailure.conflict)),
      );
      expect(hosts.byId(a)!.group, 'src');
      expect(persisted(), before);

      await hosts.moveToGroup([a], dst, expectedRevision: hosts.revision);
      expect(hosts.byId(a)!.group, 'dst');
    });

    test('a move queued behind other edits applies to the hosts as they are by then', () async {
      final dst = await seed();
      final pin = hosts.setPinned(hosts.byId(b)!, true);
      final touch = hosts.touch(b);
      final move = hosts.moveToGroup([a, b], dst);
      final unpin = hosts.setPinned(hosts.byId(a)!, false);
      await Future.wait([pin, touch, move, unpin]);

      expect((hosts.byId(a)!.group, hosts.byId(b)!.group), ('dst', 'dst'));
      expect((hosts.byId(a)!.pinned, hosts.byId(b)!.pinned), (false, true));
      expect(hosts.byId(b)!.lastUsed, isNotNull);
      expect(hosts.byId(a)!.lastUsed, isNotNull);
    });
  });

  group('jump hosts', () {
    test('a host used as a jump host cannot be deleted, and can once the reference is gone', () async {
      await hosts.saveDefaults(_login('root'));
      await hosts.save(_inheriting('bastion'));
      await hosts.save(
        _inheriting('inner').copyWith(overrides: () => _with(jump: const OverrideValue.value(HostId('bastion')))),
      );

      await expectLater(
        hosts.delete(hosts.byId(const HostId('bastion'))!),
        throwsA(isA<HostInUse>().having((e) => e.references, 'references', ['inner'])),
      );
      expect(hosts.byId(const HostId('bastion')), isNotNull);

      await hosts.save(hosts.byId(const HostId('inner'))!.copyWith(overrides: () => const ConnectionOverrides()));
      await hosts.delete(hosts.byId(const HostId('bastion'))!);
      expect(hosts.byId(const HostId('bastion')), isNull);
    });
  });

  group('identities and keys', () {
    test('an identity in use cannot be removed, and each save raises its revision', () async {
      await hosts.saveIdentity(const HostIdentity(id: 'i1', label: 'ops', username: 'ops', policy: _password));
      await hosts.saveIdentity(const HostIdentity(id: 'i1', label: 'ops', username: 'operator', policy: _password));
      expect(hosts.library.identityById('i1')!.revision, 1);

      await hosts.save(
        Host(
          id: const HostId('h'),
          label: 'h',
          address: 'h.example',
          username: 'x',
          overrides: _with(authentication: const OverrideValue.value(Authentication.identity('i1'))),
        ),
      );
      expect(hosts.byId(const HostId('h'))!.username, 'operator');
      await expectLater(hosts.deleteIdentity('i1'), throwsA(isA<IdentityInUse>()));
      expect(hosts.library.identityById('i1'), isNotNull);

      await hosts.saveIdentity(const HostIdentity(id: 'i1', label: 'ops', username: 'renamed', policy: _password));
      expect(hosts.byId(const HostId('h'))!.username, 'renamed', reason: 'hosts see an edited identity at once');
      await hosts.save(_inheriting('h').copyWith(overrides: () => _login('own')));
      await hosts.deleteIdentity('i1');
      expect(hosts.library.identities, isEmpty);
    });

    test(
      'a key that an identity, group, default or host uses cannot be deleted; a missing key cannot be used',
      () async {
        final keys = container.read(keysProvider.notifier);
        final key = await keys.generate('work');
        final using = AuthPolicy(methods: const [AuthKind.key], keyId: key.id);
        await expectLater(
          hosts.saveIdentity(
            HostIdentity(
              id: 'i',
              label: 'missing',
              username: 'u',
              policy: const AuthPolicy(methods: [AuthKind.key], keyId: 'gone'),
            ),
          ),
          throwsStateError,
        );
        expect(hosts.library.identities, isEmpty);

        await hosts.saveIdentity(HostIdentity(id: 'i', label: 'ops', username: 'u', policy: using));
        await expectLater(keys.delete(key), throwsA(isA<KeyInUse>().having((e) => e.hosts, 'hosts', ['ops'])));

        await hosts.deleteIdentity('i');
        await hosts.saveDefaults(_login('root', using));
        await expectLater(keys.delete(key), throwsA(isA<KeyInUse>().having((e) => e.hosts, 'hosts', ['global'])));

        await hosts.saveDefaults(_login('root'));
        final lab = await makeGroup('lab');
        await hosts.saveGroup(hosts.library.groupById(lab)!.copyWith(defaults: _login('g', using)));
        await expectLater(keys.delete(key), throwsA(isA<KeyInUse>().having((e) => e.hosts, 'hosts', ['lab'])));

        await hosts.saveGroup(hosts.library.groupById(lab)!.copyWith(defaults: const ConnectionOverrides()));
        await hosts.save(_inheriting('h').copyWith(overrides: () => _login('h', using)));
        await expectLater(keys.delete(key), throwsA(isA<KeyInUse>().having((e) => e.hosts, 'hosts', ['h'])));

        await hosts.delete(hosts.byId(const HostId('h'))!);
        await keys.delete(key);
        expect(keys.byId(key.id), isNull);
      },
    );
  });

  group('routes', () {
    test('a saved host is resolved with its whole jump chain before dialing, from the current library', () async {
      final routes = <List<Host>>[];
      final manager = ConnectionManager.routed(
        (route, _, _) async {
          routes.add(route);
          return FakeTransport();
        },
        hosts.byId,
        park: Duration.zero,
      );
      addTearDown(manager.closeAll);

      await hosts.saveDefaults(_login('root'));
      await hosts.save(_inheriting('jump'));
      await hosts.save(_inheriting('target', group: 'lab'));
      final lab = hosts.library.groupById(hosts.library.groupIdFor('lab'))!;
      await hosts.saveGroup(
        lab.copyWith(
          defaults: _with(port: const OverrideValue.value(2200), jump: const OverrideValue.value(HostId('jump'))),
        ),
      );

      const stale = Host(id: HostId('target'), label: 'old', address: 'old.example', username: 'old');
      final first = await manager.acquire(stale, NoPrompts());
      expect(routes.single.map((h) => (h.id.value, h.address, h.port, h.username)), [
        ('target', 'target.example', 2200, 'root'),
        ('jump', 'jump.example', 22, 'root'),
      ]);

      await hosts.saveGroup(
        lab.copyWith(
          defaults: _with(port: const OverrideValue.value(2201), jump: const OverrideValue.value(HostId('jump'))),
        ),
      );
      final second = await manager.acquire(stale, NoPrompts());
      expect(second.reused, isFalse, reason: 'a changed effective port must not share the old transport');
      expect(routes.last.first.port, 2201);
      expect(first.lost, isFalse, reason: 'editing never closes a live connection');
      first.release();
      second.release();
    });

    test('an edit may not break a route, but a route that was already broken does not block other saves', () async {
      container.dispose();
      File('${dir.path}/hosts.json').writeAsStringSync(
        jsonEncode({
          'schemaVersion': 1,
          'hosts': [
            {'id': 'gone', 'label': 'gone', 'address': 'g.example', 'username': 'u', 'jumpHostId': 'deleted'},
            {'id': 'fine', 'label': 'fine', 'address': 'f.example', 'username': 'u'},
          ],
        }),
      );
      container = open();
      hosts = container.read(hostsProvider.notifier);

      await hosts.touch(const HostId('fine'));
      await hosts.setPinned(hosts.byId(const HostId('gone'))!, true);
      await hosts.saveDefaults(_with(port: const OverrideValue.value(2200)));
      await hosts.save(hosts.byId(const HostId('gone'))!.copyWith(label: 'renamed'));

      final broken = hosts
          .byId(const HostId('fine'))!
          .copyWith(overrides: () => _with(jump: const OverrideValue.value(HostId('nowhere'))));
      await expectLater(hosts.save(broken), throwsArgumentError);
      final loop = hosts
          .byId(const HostId('fine'))!
          .copyWith(overrides: () => _with(jump: const OverrideValue.value(HostId('fine'))));
      await expectLater(hosts.save(loop), throwsArgumentError);
      expect(hosts.byId(const HostId('fine'))!.jumpHostId, isNull);
    });
  });
}

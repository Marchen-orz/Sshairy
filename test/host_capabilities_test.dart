import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/app/composition.dart';
import 'package:sshairy/features/capabilities/api.dart';
import 'package:sshairy/features/credentials/application/credential_access.dart' show secretStoreProvider;
import 'package:sshairy/features/hosts/api.dart';
import 'package:sshairy/foundation/data_dir.dart';
import 'package:sshairy/foundation/ids.dart';
import 'package:sshairy/foundation/result.dart';

import 'keys_test.dart' show MemorySecrets;

void main() {
  late Directory dir;
  late ProviderContainer container;
  late CapabilityDispatcher dispatcher;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('sshairy-host-capabilities-');
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

  Future<Map<String, Object?>> ok(String id, [Map<String, Object?> args = const {}]) async {
    final result = await call(id, args);
    expect(result, isA<Ok<Object?>>(), reason: '$id: ${result is Err ? result.error : ''}');
    return ((result as Ok<Object?>).value as Map).cast();
  }

  Future<void> refused(String id, Map<String, Object?> args, String code) async {
    final result = await call(id, args);
    expect(result, isA<Err<Object?>>(), reason: id);
    expect((result as Err<Object?>).error.code, code, reason: '${result.error}');
  }

  Host stored(String id) => container.read(hostsProvider.notifier).byId(HostId(id))!;

  for (final action in ['update', 'move', 'delete']) {
    test('queued host.$action cannot overwrite an earlier UI save', () async {
      final created = await ok('host.create', {'address': 'a.example', 'username': 'user', 'label': 'before'});
      final id = created['id']! as String;
      final hosts = container.read(hostsProvider.notifier);
      final ui = hosts.save(stored(id).copyWith(label: 'new UI value'));
      final cap = dispatcher['host.$action']!;
      final pending = cap.invoke({
        if (action != 'move') 'hostId': id,
        if (action == 'update') 'label': 'stale Agent value',
        if (action == 'move') ...{
          'hostIds': [id],
          'group': 'must-not-exist',
        },
      }, RequestContext(Origin.agent));
      await ui;
      final result = await pending;
      expect(result, isA<Err<Object?>>().having((e) => e.error.code, 'code', 'conflict'));
      expect(stored(id).label, 'new UI value');
      expect(stored(id).group, isEmpty);
      expect(hosts.library.groupIdFor('must-not-exist'), isNull);
    });
  }

  group('groups and defaults', () {
    test('a host created in a group follows it, and an update that does not name a field keeps it inherited', () async {
      await ok('hostDefaults.update', {
        'username': 'root',
        'methods': ['password'],
        'port': 2200,
      });
      final group = await ok('group.create', {'path': 'lab', 'port': 2300, 'jumpHostId': '', 'legacy': true});
      expect(group['inherit'], ['login', 'proxy']);
      expect(group['jumpHostId'], '', reason: 'a disabled jump host reads back as an empty id');

      final created = await ok('host.create', {'address': 'a.example', 'group': 'lab'});
      final id = created['id']! as String;
      expect((created['port'], created['username'], created['group'], created['legacy']), (2300, 'root', 'lab', true));
      expect(created['inherit'], ['port', 'login', 'jump', 'proxy', 'legacy']);

      await ok('host.update', {'hostId': id, 'label': 'renamed', 'pinned': true});
      await ok('group.update', {'groupId': group['id'], 'port': 2400});
      expect(stored(id).port, 2400, reason: 'a rename must not freeze what the host inherits');
      expect(stored(id).label, 'renamed');

      await ok('host.update', {'hostId': id, 'port': 2022});
      await ok('group.update', {'groupId': group['id'], 'port': 2500});
      expect(stored(id).port, 2022);
      final back = await ok('host.update', {
        'hostId': id,
        'inherit': ['port'],
      });
      expect(back['port'], 2500);
      expect(back['inherit'], contains('port'));
    });

    test('groups can be listed, moved, given defaults again and dissolved without losing hosts', () async {
      await ok('hostDefaults.update', {'username': 'root'});
      final prod = await ok('group.create', {'path': 'prod/web', 'port': 2201});
      await ok('host.create', {'address': 'h.example', 'group': 'prod/web'});

      final listed = ((await call('group.list') as Ok<Object?>).value as List).cast<Map>();
      expect(listed.map((g) => g['path']), unorderedEquals(['prod', 'prod/web']));

      final moved = await ok('group.update', {'groupId': prod['id'], 'path': 'edge/web'});
      expect(moved['path'], 'edge/web');
      expect(moved['port'], 2201, reason: 'moving keeps the defaults');
      expect(container.read(hostsProvider).single.group, 'edge/web');

      await refused('group.create', {'path': 'edge/web'}, 'invalidArgument');
      await refused('group.update', {'groupId': 'nope'}, 'notFound');

      expect(await call('group.delete', {'groupId': prod['id']}), isA<Ok<Object?>>());
      expect(container.read(hostsProvider).single.group, 'edge');
      expect(container.read(hostsProvider).single.port, 22, reason: 'dissolving drops the group defaults');
    });

    test('a host that others route through is refused by host.delete with inUse', () async {
      await ok('hostDefaults.update', {'username': 'root'});
      final bastion = await ok('host.create', {'address': 'b.example'});
      final inner = await ok('host.create', {'address': 'i.example', 'jumpHostId': bastion['id']});
      await refused('host.delete', {'hostId': bastion['id']}, 'inUse');
      expect(container.read(hostsProvider), hasLength(2));

      await ok('host.update', {'hostId': inner['id'], 'jumpHostId': ''});
      expect(await call('host.delete', {'hostId': bastion['id']}), isA<Ok<Object?>>());
    });

    test('a host cannot be created while no layer provides a login', () async {
      await refused('host.create', {'address': 'a.example'}, 'invalidArgument');
      expect(container.read(hostsProvider), isEmpty);
    });
  });

  group('moving hosts', () {
    Future<List<Map>> moved(Map<String, Object?> args) async {
      final result = await call('host.move', args);
      expect(result, isA<Ok<Object?>>(), reason: result is Err ? '${result.error}' : '');
      return ((result as Ok<Object?>).value as List).cast<Map>();
    }

    test('host.move takes one or many hosts into a group or out of every group', () async {
      await ok('hostDefaults.update', {'username': 'root'});
      final lab = await ok('group.create', {'path': 'lab', 'port': 2300});
      final a = await ok('host.create', {'address': 'a.example', 'port': 2022});
      final b = await ok('host.create', {'address': 'b.example', 'group': 'other', 'pinned': true});

      final both = await moved({
        'hostIds': [a['id'], b['id'], a['id']],
        'groupId': lab['id'],
      });
      expect(both.map((h) => h['id']), [a['id'], b['id']]);
      expect(both.map((h) => h['group']), ['lab', 'lab']);
      expect(both.map((h) => h['groupId']), [lab['id'], lab['id']]);
      expect((stored(a['id']! as String).port, stored(b['id']! as String).port), (2022, 2300));
      expect(stored(b['id']! as String).pinned, isTrue);

      final out = await moved({
        'hostIds': [a['id']],
        'groupId': null,
      });
      expect((out.single['group'], out.single.containsKey('groupId')), ('', false));
      expect(stored(a['id']! as String).groupId, isNull);

      await moved({
        'hostIds': [b['id']],
      });
      expect((stored(b['id']! as String).group, stored(b['id']! as String).groupId), ('', null));
    });

    test('bad arguments, absent hosts or groups and broken routes are refused without changing anything', () async {
      await ok('hostDefaults.update', {'username': 'root'});
      final lab = await ok('group.create', {'path': 'lab'});
      final a = await ok('host.create', {'address': 'a.example'});
      final bastion = await ok('host.create', {'address': 'b.example'});
      final jumpy = await ok('group.create', {'path': 'jumpy', 'jumpHostId': bastion['id']});
      final before = container.read(hostsProvider.notifier).revision;

      await refused('host.move', {}, 'invalidArgument');
      await refused('host.move', {'hostIds': []}, 'invalidArgument');
      await refused('host.move', {'hostIds': a['id']}, 'invalidArgument');
      await refused('host.move', {
        'hostIds': [1],
      }, 'invalidArgument');
      await refused('host.move', {
        'hostIds': [''],
      }, 'invalidArgument');
      await refused('host.move', {
        'hostIds': [a['id']],
        'groupId': 7,
      }, 'invalidArgument');
      await refused('host.move', {
        'hostIds': [a['id']],
        'groupId': 'nope',
      }, 'notFound');
      await refused('host.move', {
        'hostIds': [a['id'], 'ghost'],
        'groupId': lab['id'],
      }, 'notFound');
      await refused('host.move', {
        'hostIds': [a['id'], bastion['id']],
        'groupId': jumpy['id'],
      }, 'invalidArgument');

      expect(container.read(hostsProvider.notifier).revision, before);
      expect((stored(a['id']! as String).group, stored(bastion['id']! as String).group), ('', ''));
    });
  });

  group('identities', () {
    test('an identity can be created, used by hosts, edited, and only deleted once nothing uses it', () async {
      final identity = await ok('identity.create', {'label': 'ops', 'username': 'ops'});
      final id = identity['id']! as String;
      expect(identity['revision'], 0);

      final host = await ok('host.create', {'address': 'a.example', 'identityId': id});
      expect((host['username'], host['identityId']), ('ops', id));
      await refused('identity.delete', {'identityId': id}, 'inUse');

      final edited = await ok('identity.update', {'identityId': id, 'username': 'operator'});
      expect((edited['username'], edited['revision']), ('operator', 1));
      expect(edited['usedBy'], ['a.example']);
      expect(stored(host['id']! as String).username, 'operator');

      await ok('host.update', {'hostId': host['id'], 'username': 'own'});
      expect(await call('identity.delete', {'identityId': id}), isA<Ok<Object?>>());
      expect(((await call('identity.list') as Ok<Object?>).value as List), isEmpty);
    });

    test('an identity excludes inline login fields and must exist', () async {
      await ok('hostDefaults.update', {'username': 'root'});
      final identity = await ok('identity.create', {'label': 'ops', 'username': 'ops'});
      await refused('host.create', {
        'address': 'a.example',
        'identityId': identity['id'],
        'username': 'also',
      }, 'invalidArgument');
      await refused('host.create', {'address': 'a.example', 'identityId': 'missing'}, 'notFound');
      await refused('identity.create', {'label': '', 'username': 'u'}, 'invalidArgument');
      await refused('identity.update', {'identityId': 'missing'}, 'notFound');
    });
  });

  group('validation', () {
    test('conflicting, unknown and dangling arguments are refused without changing anything', () async {
      await ok('hostDefaults.update', {'username': 'root'});
      final host = await ok('host.create', {'address': 'a.example'});
      final id = host['id']! as String;
      final before = container.read(hostsProvider.notifier).revision;

      await refused('host.update', {
        'hostId': id,
        'port': 2200,
        'inherit': ['port'],
      }, 'invalidArgument');
      await refused('host.update', {
        'hostId': id,
        'inherit': ['colour'],
      }, 'invalidArgument');
      await refused('host.update', {'hostId': id, 'jumpHostId': 'missing'}, 'invalidArgument');
      await refused('host.update', {'hostId': id, 'jumpHostId': id}, 'invalidArgument');
      await refused('host.update', {'hostId': id, 'port': 70000}, 'invalidArgument');
      await refused('host.update', {
        'hostId': id,
        'methods': ['password', 'key'],
      }, 'invalidArgument');
      await refused('host.update', {
        'hostId': id,
        'methods': ['key'],
      }, 'invalidArgument');
      await refused('host.update', {'hostId': id, 'auth': 'key', 'keyId': 'missing'}, 'notFound');
      await refused('host.update', {
        'hostId': id,
        'auth': 'password',
        'methods': ['password'],
      }, 'invalidArgument');
      await refused('host.update', {
        'hostId': id,
        'proxy': {'kind': 'ftp', 'address': 'p', 'port': 1},
      }, 'invalidArgument');
      await refused('host.update', {'hostId': 'missing'}, 'notFound');
      expect(container.read(hostsProvider.notifier).revision, before);
    });

    test('key then password with interaction off is stored and read back without a key path', () async {
      final host = await ok('host.create', {
        'address': 'a.example',
        'username': 'root',
        'methods': ['key', 'password'],
        'keyPath': '~/.ssh/id_ed25519',
        'allowInteractive': false,
      });
      expect(host['methods'], ['key', 'password']);
      expect(host['allowInteractive'], false);
      expect(host.containsKey('keyPath'), isFalse, reason: 'key paths stay out of capability results');
      final policy = stored(host['id']! as String).policy;
      expect(policy.methods, [AuthKind.key, AuthKind.password]);
      expect((policy.keyPath, policy.allowInteractive), ('~/.ssh/id_ed25519', false));

      final back = await ok('host.update', {'hostId': host['id'], 'auth': 'password'});
      expect(back['methods'], ['password']);
      expect(stored(host['id']! as String).policy.keyPath, isNull);
    });

    test('only reviewed host tools are exposed to the agent', () async {
      for (final id in ['host.create', 'host.update', 'host.move', 'host.delete']) {
        final result = await dispatcher.dispatch(id, {}, RequestContext(Origin.agent));
        expect((result as Err<Object?>).error.code, 'unauthorized', reason: id);
      }
      for (final id in [
        'group.create',
        'group.update',
        'group.delete',
        'identity.create',
        'identity.update',
        'identity.delete',
        'hostDefaults.update',
        'hostDefaults.get',
        'group.list',
        'identity.list',
        'host.list',
        'host.deleteMany',
      ]) {
        final result = await dispatcher.dispatch(id, {}, RequestContext(Origin.agent));
        expect((result as Err<Object?>).error.code, 'notExposed', reason: id);
      }
    });

    test('the agent gets host metadata without endpoints or login fields', () async {
      final result = await dispatcher.dispatch('host.create', {
        'address': 'a.example',
        'username': 'root',
        'label': 'web',
      }, RequestContext(Origin.agent, authority: _Allow()));
      final host = (result as Ok<Object?>).value! as Map<String, Object?>;
      expect(host['label'], 'web');
      expect(host['id'], isNotNull);
      for (final key in ['address', 'username', 'auth', 'methods', 'proxy', 'identityId', 'keyPath', 'jumpHostId']) {
        expect(host.containsKey(key), isFalse, reason: key);
      }
    });
  });
}

class _Allow implements AgentAuthority {
  @override
  Future<Result<void>> authorize(Capability capability, Map<String, Object?> args, RequestContext context) async =>
      const Ok(null);

  @override
  Future<Result<void>> revalidate(Capability capability, Map<String, Object?> args, RequestContext context) async =>
      const Ok(null);
}

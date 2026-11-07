import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/features/hosts/api.dart';
import 'package:sshairy/foundation/ids.dart';

const _password = AuthPolicy();
const _key = AuthPolicy(methods: [AuthKind.key], keyId: 'k1');

Authentication _login(String user, [AuthPolicy policy = _password]) => Authentication.inline(user, policy);

/// A host that owns nothing but the overrides it is given; its top-level fields are placeholders.
Host _host(String id, {String? group, ConnectionOverrides overrides = const ConnectionOverrides()}) => Host(
  id: HostId(id),
  label: id,
  address: '$id.example',
  username: 'placeholder',
  groupId: group,
  overrides: overrides,
);

HostGroup _group(String id, {String? parent, ConnectionOverrides defaults = const ConnectionOverrides()}) =>
    HostGroup(id: id, name: id, parentId: parent, defaults: defaults);

ConnectionOverrides _with({
  OverrideValue<int> port = const OverrideValue.inherit(),
  OverrideValue<Authentication> authentication = const OverrideValue.inherit(),
  OverrideValue<HostId> jump = const OverrideValue.inherit(),
  OverrideValue<Proxy> proxy = const OverrideValue.inherit(),
  OverrideValue<bool> legacy = const OverrideValue.inherit(),
}) => ConnectionOverrides(port: port, authentication: authentication, jump: jump, proxy: proxy, legacy: legacy);

ConnectionOverrides _rootLogin([String user = 'root']) => _with(authentication: OverrideValue.value(_login(user)));

void main() {
  group('resolution', () {
    test('every field has three states: inherit, disabled and value', () {
      const bastion = HostId('bastion');
      const proxy = Proxy(ProxyKind.socks5, 'proxy.example', 1080);
      final library = HostLibrary(
        defaults: _with(
          port: const OverrideValue.value(2200),
          authentication: OverrideValue.value(_login('root')),
          jump: const OverrideValue.value(bastion),
          proxy: const OverrideValue.value(proxy),
          legacy: const OverrideValue.value(true),
        ),
        groups: [
          _group(
            'lab',
            defaults: _with(jump: const OverrideValue.disabled(), legacy: const OverrideValue.value(false)),
          ),
        ],
        hosts: [
          _host('bastion', overrides: _with(jump: const OverrideValue.disabled())),
          _host('inherits'),
          _host('lab-host', group: 'lab'),
          _host(
            'lab-legacy',
            group: 'lab',
            overrides: _with(legacy: const OverrideValue.value(true)),
          ),
        ],
      );

      final inherits = library.resolve(library.hostById(const HostId('inherits'))!);
      expect(inherits.host.port, 2200);
      expect(inherits.host.jumpHostId, bastion);
      expect(inherits.host.proxy?.key, proxy.key);
      expect(inherits.host.legacy, isTrue);
      expect(inherits.sources, {
        'port': 'global',
        'authentication': 'global',
        'jump': 'global',
        'proxy': 'global',
        'legacy': 'global',
      });

      final lab = library.resolve(library.hostById(const HostId('lab-host'))!);
      expect(lab.host.jumpHostId, isNull, reason: 'disabled means an explicit direct route');
      expect(lab.sources['jump'], 'group:lab');
      expect(lab.host.port, 2200, reason: 'disabling one field leaves the others inherited');
      expect(lab.host.legacy, isFalse);
      expect(lab.sources['legacy'], 'group:lab');

      final legacy = library.resolve(library.hostById(const HostId('lab-legacy'))!);
      expect(legacy.host.legacy, isTrue);
      expect(legacy.sources['legacy'], 'host');
      expect(library.resolve(library.hostById(const HostId('bastion'))!).host.jumpHostId, isNull);
    });

    test('values apply in order: built-in, global, root group, child group, host', () {
      ConnectionOverrides port(int value) => _with(port: OverrideValue.value(value));
      HostLibrary library({
        ConnectionOverrides? global,
        ConnectionOverrides root = const ConnectionOverrides(),
        ConnectionOverrides sub = const ConnectionOverrides(),
        ConnectionOverrides own = const ConnectionOverrides(),
      }) => HostLibrary(
        defaults: global ?? _rootLogin(),
        groups: [
          _group('root', defaults: root),
          _group('child', parent: 'root', defaults: sub),
        ],
        hosts: [_host('h', group: 'child', overrides: own)],
      );
      (int, String) port0(HostLibrary l) {
        final resolved = l.resolve(l.hosts.single);
        return (resolved.host.port, resolved.sources['port']!);
      }

      expect(port0(library()), (22, ''));
      final global = _with(port: const OverrideValue.value(2200), authentication: OverrideValue.value(_login('root')));
      expect(port0(library(global: global)), (2200, 'global'));
      expect(port0(library(global: global, root: port(2201))), (2201, 'group:root'));
      expect(port0(library(global: global, root: port(2201), sub: port(2202))), (2202, 'group:child'));
      expect(port0(library(global: global, root: port(2201), sub: port(2202), own: port(2203))), (2203, 'host'));
    });

    test('a login is replaced as a unit and never merged with another layer', () {
      final library = HostLibrary(
        defaults: _with(authentication: OverrideValue.value(_login('root'))),
        identities: const [
          HostIdentity(
            id: 'i1',
            label: 'alice',
            username: 'alice',
            policy: AuthPolicy(methods: [AuthKind.key, AuthKind.password], keyId: 'k2'),
          ),
        ],
        groups: [
          _group('ops', defaults: _with(authentication: OverrideValue.value(_login('deploy', _key)))),
          _group('shared', defaults: _with(authentication: const OverrideValue.value(Authentication.identity('i1')))),
        ],
        hosts: [
          _host('deploy', group: 'ops'),
          _host(
            'own',
            group: 'ops',
            overrides: _with(authentication: OverrideValue.value(_login('ops'))),
          ),
          _host('alice', group: 'shared'),
        ],
      );
      Host resolved(String id) => library.resolve(library.hostById(HostId(id))!).host;

      expect((resolved('deploy').username, resolved('deploy').policy.keyId), ('deploy', 'k1'));
      final own = resolved('own');
      expect(own.username, 'ops');
      expect(own.policy.methods, [AuthKind.password]);
      expect(
        (own.policy.keyId, own.policy.keyPath),
        (null, null),
        reason: 'the group key must not leak into a password login',
      );
      final alice = resolved('alice');
      expect((alice.username, alice.policy.keyId), ('alice', 'k2'));
      expect(alice.policy.methods, [AuthKind.key, AuthKind.password]);
      expect(library.resolve(library.hostById(const HostId('alice'))!).sources['authentication'], 'group:shared');
    });

    test('what a host would inherit can be asked without the host', () {
      final library = HostLibrary(
        defaults: _with(port: const OverrideValue.value(2200)),
        groups: [_group('a', defaults: _with(port: const OverrideValue.value(2201)))],
      );
      expect(library.resolveConnection('a', null).port, 2201);
      expect(library.resolveConnection('a', null).sources['port'], 'group:a');
      expect(library.resolveConnection(null, null).port, 2200);
      expect(HostLibrary().resolveConnection(null, null).port, 22);
      expect(HostLibrary().resolveConnection(null, null).authentication, isNull);
    });
  });

  group('validation', () {
    final ok = _rootLogin();
    test('invalid libraries are rejected', () {
      final invalid = <String, HostLibrary>{
        'group cycle': HostLibrary(
          defaults: ok,
          groups: [
            _group('a', parent: 'b'),
            _group('b', parent: 'a'),
          ],
        ),
        'missing parent': HostLibrary(
          defaults: ok,
          groups: [_group('a', parent: 'missing')],
        ),
        'duplicate path': HostLibrary(
          defaults: ok,
          groups: [
            _group('a'),
            HostGroup(id: 'a2', name: 'a'),
          ],
        ),
        'slash in name': HostLibrary(
          defaults: ok,
          groups: [HostGroup(id: 'a', name: 'x/y')],
        ),
        'padded name': HostLibrary(
          defaults: ok,
          groups: [HostGroup(id: 'a', name: ' x')],
        ),
        'missing identity': HostLibrary(
          defaults: _with(authentication: const OverrideValue.value(Authentication.identity('none'))),
        ),
        'disabled port': HostLibrary(defaults: _with(port: const OverrideValue.disabled())),
        'disabled authentication': HostLibrary(defaults: _with(authentication: const OverrideValue.disabled())),
        'disabled legacy': HostLibrary(defaults: _with(legacy: const OverrideValue.disabled())),
        'port zero': HostLibrary(defaults: _with(port: const OverrideValue.value(0))),
        'port too high': HostLibrary(
          groups: [_group('a', defaults: _with(port: const OverrideValue.value(65536)))],
          defaults: ok,
        ),
        'no login anywhere': HostLibrary(hosts: [_host('h')]),
        'password then key': HostLibrary(
          defaults: _with(
            authentication: OverrideValue.value(
              _login('u', const AuthPolicy(methods: [AuthKind.password, AuthKind.key], keyId: 'k')),
            ),
          ),
        ),
        'no methods': HostLibrary(
          defaults: _with(authentication: OverrideValue.value(_login('u', const AuthPolicy(methods: [])))),
        ),
        'key without key': HostLibrary(
          defaults: _with(authentication: OverrideValue.value(_login('u', const AuthPolicy(methods: [AuthKind.key])))),
        ),
        'two keys': HostLibrary(
          defaults: _with(
            authentication: OverrideValue.value(
              _login('u', const AuthPolicy(methods: [AuthKind.key], keyId: 'k', keyPath: '~/k')),
            ),
          ),
        ),
        'key with password-only': HostLibrary(
          defaults: _with(authentication: OverrideValue.value(_login('u', const AuthPolicy(keyId: 'k')))),
        ),
        'empty username': HostLibrary(defaults: _with(authentication: OverrideValue.value(_login('')))),
        'bad identity': HostLibrary(
          defaults: ok,
          identities: const [HostIdentity(id: 'i', label: 'x', username: '', policy: _password)],
        ),
        'bad proxy': HostLibrary(
          defaults: _with(
            authentication: OverrideValue.value(_login('u')),
            proxy: const OverrideValue.value(Proxy(ProxyKind.socks5, 'bad host', 1080)),
          ),
        ),
        'duplicate host': HostLibrary(defaults: ok, hosts: [_host('h'), _host('h')]),
        'self jump': HostLibrary(
          defaults: ok,
          hosts: [_host('h', overrides: _with(jump: const OverrideValue.value(HostId('h'))))],
        ),
        'invalid host': HostLibrary(
          defaults: ok,
          hosts: [
            Host(
              id: const HostId('h'),
              label: '',
              address: 'bad host',
              username: 'u',
              overrides: const ConnectionOverrides(),
            ),
          ],
        ),
      };
      for (final MapEntry(:key, :value) in invalid.entries) {
        expect(value.validate, throwsA(anything), reason: key);
      }
      expect(HostLibrary(defaults: ok, hosts: [_host('h')]).validate, returnsNormally);
    });

    test('route problems are reported per host and do not make the library invalid', () {
      ConnectionOverrides via(String jump) => _with(jump: OverrideValue.value(HostId(jump)));
      Host link(int i) => i == 8 ? _host('c8') : _host('c$i', overrides: via('c${i + 1}'));
      final library = HostLibrary(
        defaults: ok,
        hosts: [
          _host('fine'),
          _host('gone', overrides: via('deleted')),
          _host('x', overrides: via('y')),
          _host('y', overrides: via('x')),
          _host('short', overrides: via('fine')),
          for (var i = 0; i < 9; i++) link(i),
        ],
      );
      library.validate();
      expect(library.routeProblems().map((id) => id.value).toSet(), {'gone', 'x', 'y', 'c0'});
    });
  });

  group('editing', () {
    test('a host goes to the group its path names, creating each group once', () {
      var ids = 0;
      String next() => 'g${ids++}';
      final base = HostLibrary(defaults: _rootLogin());
      final first = base.withHost(
        Host(id: const HostId('a'), label: 'a', address: 'a', username: 'u', group: 'prod/web'),
        newGroupId: next,
      );
      final second = first.withHost(
        Host(id: const HostId('b'), label: 'b', address: 'b', username: 'u', group: 'prod'),
        newGroupId: next,
      );
      expect(second.groups.map((g) => g.id), ['g0', 'g1']);
      expect(second.hostById(const HostId('a'))!.groupId, 'g1');
      expect(second.hostById(const HostId('b'))!.groupId, 'g0');
      expect(second.groupPaths, ['prod', 'prod/web']);
      final loose = second.withHost(
        Host(id: const HostId('c'), label: 'c', address: 'c', username: 'u'),
        newGroupId: next,
      );
      expect(loose.hostById(const HostId('c'))!.groupId, isNull);
      expect(loose.groups, hasLength(2));
    });

    test('a host without overrides keeps every setting it carries as explicit values', () {
      final library = HostLibrary(defaults: _with(port: const OverrideValue.value(2200))).withHost(
        Host(id: const HostId('a'), label: 'a', address: 'a', username: 'u', port: 22, auth: AuthKind.key, keyId: 'k1'),
      );
      library.validate();
      final stored = library.hostById(const HostId('a'))!;
      expect(stored.overrides!.port.mode, OverrideMode.value);
      expect(library.resolve(stored).host.port, 22, reason: 'the global default must not take over');
      expect(library.resolve(stored).host.policy.keyId, 'k1');
    });

    test('groups are moved, merged names are refused, and dissolving keeps members', () {
      var library = HostLibrary(
        defaults: _rootLogin(),
        groups: [
          _group('prod', defaults: _with(port: const OverrideValue.value(2201))),
          _group('web', parent: 'prod'),
          _group('db', parent: 'prod'),
          _group('stage'),
        ],
        hosts: [
          _host('w', group: 'web'),
          _host('p', group: 'prod'),
        ],
      );
      library = library.normalized();
      expect(library.hostById(const HostId('w'))!.group, 'prod/web');
      expect(library.hostById(const HostId('w'))!.port, 2201);

      final moved = library.withGroupMoved('web', 'stage/edge/web').normalized();
      moved.validate();
      expect(moved.hostById(const HostId('w'))!.group, 'stage/edge/web');
      expect(moved.hostById(const HostId('w'))!.port, 22, reason: 'moving leaves the old group defaults behind');
      expect(() => library.withGroupMoved('web', 'prod/db').validate(), throwsArgumentError);
      expect(() => library.withGroupMoved('prod', 'prod/web/prod').validate(), throwsArgumentError);

      final dissolved = library.withoutGroup('prod').normalized();
      dissolved.validate();
      expect(dissolved.groupPaths, ['db', 'stage', 'web']);
      expect(dissolved.hostById(const HostId('w'))!.group, 'web');
      expect(dissolved.hostById(const HostId('p'))!.groupId, isNull);
      expect(dissolved.hostById(const HostId('w'))!.port, 22, reason: 'the group defaults are discarded');
      expect(() => library.withGroup(library.groupById('db')!.copyWith(name: 'web')).validate(), throwsArgumentError);
    });

    test('keys and identities in use are found on every layer', () {
      const identity = HostIdentity(id: 'i1', label: 'alice', username: 'alice', policy: _key);
      final library = HostLibrary(
        defaults: _with(authentication: OverrideValue.value(_login('root', _key))),
        identities: [identity],
        groups: [_group('g', defaults: _with(authentication: OverrideValue.value(_login('g', _key))))],
        hosts: [
          _host(
            'h',
            group: 'g',
            overrides: _with(authentication: OverrideValue.value(_login('h', _key))),
          ),
          _host('idh', overrides: _with(authentication: const OverrideValue.value(Authentication.identity('i1')))),
        ],
      );
      expect(library.keyIds, {'k1'});
      expect(library.keyReferences('k1'), ['alice', 'global', 'g', 'h']);
      expect(library.keyReferences('other'), isEmpty);
      expect(library.identityReferences('i1'), ['idh']);
      expect(
        () => library.withoutIdentity('i1'),
        throwsA(isA<IdentityInUse>().having((e) => e.references, 'references', ['idh'])),
      );
      final free = library.copyWith(hosts: library.hosts.where((h) => h.id.value != 'idh'));
      expect(free.withoutIdentity('i1').identities, isEmpty);
    });
  });

  group('schema 1', () {
    final v1 = {
      'schemaVersion': 1,
      'hosts': [
        {
          'id': 'a',
          'label': 'a',
          'address': 'a.example',
          'port': 2222,
          'username': 'root',
          'auth': 'key',
          'keyPath': '~/id',
          'group': 'prod/web',
          'jumpHostId': 'b',
          'legacy': true,
        },
        {
          'id': 'b',
          'label': 'b',
          'address': 'b.example',
          'username': 'jump',
          'group': 'prod',
          'proxy': {'kind': 'socks5', 'address': 'p', 'port': 1080},
        },
        {'id': 'c', 'label': 'c', 'address': 'c.example', 'username': 'u', 'keyId': 'stale', 'keyPath': '~/both'},
      ],
    };

    test('migrates paths to stable groups and freezes every host setting as an explicit value', () {
      final migrated = HostLibrary.migrateV1(jsonDecode(jsonEncode(v1)) as Map<String, dynamic>);
      final again = HostLibrary.migrateV1(jsonDecode(jsonEncode(v1)) as Map<String, dynamic>);
      expect(jsonEncode(again), jsonEncode(migrated), reason: 'migration is a pure function');
      final library = HostLibrary.fromJson(migrated)..validate();
      expect(library.groups.map((g) => (g.id, library.groupPath(g.id))), [
        ('legacy-group-0', 'prod'),
        ('legacy-group-1', 'prod/web'),
      ]);
      final a = library.resolve(library.hostById(const HostId('a'))!).host;
      expect(
        (a.port, a.username, a.group, a.jumpHostId, a.legacy),
        (2222, 'root', 'prod/web', const HostId('b'), true),
      );
      expect((a.auth, a.keyPath, a.keyId), (AuthKind.key, '~/id', null));
      final b = library.resolve(library.hostById(const HostId('b'))!).host;
      expect((b.port, b.proxy?.key, b.jumpHostId, b.group), (22, 'socks5://@p:1080', null, 'prod'));
      final c = library.resolve(library.hostById(const HostId('c'))!).host;
      expect((c.auth, c.keyId), (AuthKind.password, null), reason: 'a password host keeps no stray key');

      final changed = library.withDefaults(
        _with(port: const OverrideValue.value(2200), legacy: const OverrideValue.value(true)),
      );
      for (final id in ['a', 'b', 'c']) {
        final before = library.resolve(library.hostById(HostId(id))!).host;
        final after = changed.resolve(changed.hostById(HostId(id))!).host;
        expect(
          (after.port, after.legacy),
          (before.port, before.legacy),
          reason: 'new defaults must not reach migrated host $id',
        );
      }
      expect(
        jsonEncode(
          HostLibrary.fromJson(jsonDecode(jsonEncode(library.toJson())) as Map<String, dynamic>).normalized().toJson(),
        ),
        jsonEncode(library.toJson()),
      );
    });
  });
}

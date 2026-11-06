import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/features/hosts/domain/host.dart';
import 'package:sshairy/foundation/ids.dart';

void main() {
  group('parseQuickConnect', () {
    test('accepts the documented forms', () {
      expect(parseQuickConnect('ubuntu@example.com')?.target, 'ubuntu@example.com');
      expect(parseQuickConnect(' root@10.0.0.1:2222 ')?.port, 2222);
      expect(parseQuickConnect('ssh -p 2200 a@b')?.port, 2200);
      expect(parseQuickConnect('ssh a@b')?.address, 'b');
      expect(parseQuickConnect('a@[::1]:2222')?.address, '::1');
    });

    test('rejects anything else', () {
      for (final input in ['', 'example.com', 'a@b:0', 'a@b:70000', 'ssh -p 22 a@b:22', 'ssh -p x a@b', 'a@b c']) {
        expect(parseQuickConnect(input), isNull, reason: input);
      }
    });

    test('quick-connect hosts are transient', () {
      expect(parseQuickConnect('a@b')!.transient, isTrue);
    });
  });

  test('Host survives a JSON round trip', () {
    const host = Host(
      id: HostId('x'),
      label: 'web',
      address: 'h',
      port: 2222,
      username: 'u',
      auth: AuthKind.key,
      keyPath: '~/k',
    );
    final copy = Host.fromJson(host.toJson());
    expect(copy.toJson(), host.toJson());
    expect(copy.passwordRef.storageKey, 'host/x/password');

    final full = Host.fromJson({
      ...host.toJson(),
      'keyId': 'k1',
      'group': ' prod / /web ',
      'tags': ['a', 3, 'b'],
      'pinned': true,
      'lastUsed': '2026-11-06T08:00:00Z',
    });
    expect(full.group, 'prod/web');
    expect(full.tags, ['a', 'b'], reason: 'values of the wrong type are dropped');
    expect(Host.fromJson(full.toJson()).toJson(), full.toJson());
    expect(host.toJson().keys, isNot(contains('group')), reason: 'empty fields stay out of hosts.json');
  });

  Host h(String label, {String group = '', bool pinned = false, int? used, List<String> tags = const []}) => Host(
    id: HostId(label),
    label: label,
    address: '$label.example',
    username: 'u',
    group: group,
    pinned: pinned,
    tags: tags,
    lastUsed: used == null ? null : DateTime.utc(2026, 1, 1, used),
  );

  test('pinned hosts lead; then recent use or name', () {
    final hosts = [h('b', used: 1), h('a'), h('c', used: 3), h('d', pinned: true)];
    expect(sortHosts(hosts).map((x) => x.label), ['d', 'a', 'b', 'c']);
    expect(sortHosts(hosts, recent: true).map((x) => x.label), ['d', 'c', 'b', 'a'], reason: 'never used goes last');
  });

  test('groups nest by path and search covers groups and tags', () {
    final hosts = [
      h('web', group: 'prod/web', tags: ['nginx']),
      h('db', group: 'prod'),
      h('dev', group: 'production'),
    ];
    expect(allGroups(hosts), ['prod', 'prod/web', 'production']);
    expect(
      [
        for (final x in hosts)
          if (inGroup(x, 'prod')) x.label,
      ],
      ['web', 'db'],
      reason: 'prefix is not enough',
    );
    expect(hostMatches(hosts[0], 'NGINX web'), isTrue);
    expect(hostMatches(hosts[0], 'nginx db'), isFalse, reason: 'every word must match');
    expect(parseTags('a, b  a,,c'), ['a', 'b', 'c']);
  });
}

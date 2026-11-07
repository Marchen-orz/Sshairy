import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/features/connections/api.dart';
import 'package:sshairy/features/connections/application/route.dart';
import 'package:sshairy/features/connections/domain/known_keys.dart';
import 'package:sshairy/features/connections/domain/prompts.dart';
import 'package:sshairy/features/hosts/api.dart';
import 'package:sshairy/foundation/ids.dart';

import 'connection_manager_test.dart' show FakeTransport, NoPrompts;

Host host(String id, {String? jump, String address = 'example.com', Proxy? proxy, bool legacy = false}) => Host(
  id: HostId(id),
  label: id,
  address: address,
  username: 'u',
  jumpHostId: jump == null ? null : HostId(jump),
  proxy: proxy,
  legacy: legacy,
);

void main() {
  test('resolve the whole route before dialing; reject missing, cyclic and overlong routes', () {
    final hosts = [host('a', jump: 'b'), host('b', jump: 'c'), host('c')];
    Host? lookup(HostId id) => hosts.where((h) => h.id == id).firstOrNull;
    expect(resolveRoute(hosts.first, lookup).map((h) => h.id.value), ['a', 'b', 'c']);
    expect(
      () => resolveRoute(host('a', jump: 'missing'), lookup),
      throwsA(isA<ConnectError>().having((e) => e.detail, 'detail', routeMissing)),
    );
    hosts[2] = host('c', jump: 'a');
    expect(
      () => resolveRoute(hosts.first, lookup),
      throwsA(isA<ConnectError>().having((e) => e.detail, 'detail', routeLoop)),
    );
    final chain = [for (var i = 0; i < 9; i++) host('$i', jump: i == 8 ? null : '${i + 1}')];
    expect(
      () => resolveRoute(chain.first, (id) => chain.firstWhere((h) => h.id == id)),
      throwsA(isA<ConnectError>().having((e) => e.detail, 'detail', routeTooLong)),
    );
  });

  test('editing an intermediate jump prevents reuse and does not mutate a live route', () async {
    var jump = host('jump');
    final target = host('target', jump: 'jump');
    final snapshots = <List<Host>>[];
    final manager = ConnectionManager.routed(
      (route, _, _) async {
        snapshots.add(route);
        return FakeTransport();
      },
      (id) => id == jump.id ? jump : null,
      park: Duration.zero,
    );
    addTearDown(manager.closeAll);
    final first = await manager.acquire(target, NoPrompts());
    final shared = await manager.acquire(target, NoPrompts());
    expect(shared.reused, isTrue);
    jump = host('jump', address: 'changed.example');
    final changed = await manager.acquire(target, NoPrompts());
    expect(changed.reused, isFalse);
    expect(snapshots, hasLength(2));
    expect(snapshots.first.last.address, 'example.com');
    expect(snapshots.last.last.address, 'changed.example');
    first.release();
    shared.release();
    changed.release();
  });

  test('proxy identity and algorithm policy distinguish pool keys and round-trip', () {
    final plain = host('a');
    final proxied = host('a', proxy: const Proxy(ProxyKind.http, 'proxy', 8080, username: 'u'), legacy: true);
    expect(ConnectionManager.keyOf(plain), isNot(ConnectionManager.keyOf(proxied)));
    final restored = Host.fromJson(proxied.toJson());
    expect(ConnectionManager.keyOf(restored), ConnectionManager.keyOf(proxied));
    expect(restored.copyWith(pinned: true).proxy?.key, proxied.proxy?.key);
  });

  test('RSA signature aliases retain old trust and cannot bypass a changed key', () {
    final keys = KnownKeys({
      'h:22': {'rsa-sha2-512': 'old'},
    });
    expect(keys.check('h:22', 'ssh-rsa', 'old'), isA<KeyTrusted>());
    expect(keys.check('h:22', 'rsa-sha2-256', 'changed'), isA<KeyChanged>());
    keys.entries['h:22']!['ssh-rsa'] = 'different';
    expect(keys.check('h:22', 'rsa-sha2-512', 'old'), isA<KeyChanged>());
    keys.trust('h:22', 'rsa-sha2-256', 'new');
    expect(keys.entries['h:22'], {'ssh-rsa': 'new'});
  });
}

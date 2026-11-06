import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/features/credentials/adapters/secure_store.dart';
import 'package:sshairy/features/credentials/application/credential_access.dart' show secretStoreProvider;
import 'package:sshairy/features/hosts/api.dart';
import 'package:sshairy/foundation/data_dir.dart';
import 'package:sshairy/foundation/ids.dart';
import 'package:sshairy/foundation/json_file.dart';
import 'package:sshairy/foundation/secret.dart';

class _Secrets extends SecretStore {
  final deleted = <SecretRef>[];
  final values = <SecretRef, Secret>{};
  @override
  Future<Secret?> read(SecretRef ref) async => values[ref];
  @override
  Future<void> write(SecretRef ref, Secret value) async => values[ref] = value;
  Completer<void>? gate;
  bool fail = false;

  @override
  Future<void> delete(SecretRef ref) async {
    deleted.add(ref);
    await gate?.future;
    if (fail) throw StateError('secure store unavailable');
  }
}

void main() {
  late Directory dir;
  late ProviderContainer container;
  late HostsNotifier hosts;
  late _Secrets secrets;
  const original = Host(
    id: HostId('one'),
    label: 'one',
    address: 'host.example',
    username: 'u',
    group: 'prod/web',
    proxy: Proxy(ProxyKind.socks5, 'proxy.example', 1080),
  );

  Host changed(Map<String, dynamic> patch) => Host.fromJson({...original.toJson(), ...patch});

  List<dynamic> persisted() =>
      (jsonDecode(File('${dir.path}/hosts.json').readAsStringSync()) as Map<String, dynamic>)['hosts'] as List<dynamic>;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('sshairy-hosts-');
    secrets = _Secrets();
    container = ProviderContainer(
      overrides: [dataDirProvider.overrideWithValue(dir.path), secretStoreProvider.overrideWithValue(secrets)],
    );
    hosts = container.read(hostsProvider.notifier);
  });

  tearDown(() async {
    await hosts.saved;
    container.dispose();
    await dir.delete(recursive: true);
  });

  test('invalid host or proxy never publishes, persists, or clears credentials', () async {
    await hosts.save(original);
    final before = File('${dir.path}/hosts.json').readAsStringSync();
    for (final patch in <Map<String, dynamic>>[
      {'id': ''},
      {'address': 'bad host'},
      {'username': ''},
      {'port': 0},
      {'port': 65536},
      {'jumpHostId': 'one'},
      {
        'proxy': {'kind': 'http', 'address': 'p', 'port': 80, 'username': 'bad:user'},
      },
      {
        'proxy': {'kind': 'socks5', 'address': 'bad\nhost', 'port': 1080},
      },
      {
        'proxy': {'kind': 'socks5', 'address': 'p', 'port': 0},
      },
    ]) {
      await expectLater(hosts.save(changed(patch)), throwsArgumentError);
    }
    expect(hosts.byId(original.id)!.toJson(), original.toJson());
    expect(File('${dir.path}/hosts.json').readAsStringSync(), before);
    expect(secrets.deleted, isEmpty);
  });

  test('proxy changes commit before cleanup and use a different credential reference', () async {
    await hosts.save(original);
    for (final patch in <Map<String, dynamic>>[
      {'kind': 'http'},
      {'address': 'other.example'},
      {'port': 1081},
      {'username': 'other'},
    ]) {
      secrets.deleted.clear();
      secrets.gate = Completer<void>();
      final next = changed({
        'proxy': {...original.proxy!.toJson(), ...patch},
      });
      final saving = hosts.save(next);
      for (var i = 0; i < 100 && secrets.deleted.lastOrNull != original.proxyRef; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(secrets.deleted.last, original.proxyRef);
      expect(next.proxyRef, isNot(original.proxyRef));
      expect(hosts.byId(original.id)!.proxy!.toJson(), next.proxy!.toJson());
      expect((persisted().single as Map)['proxy'], next.proxy!.toJson());
      secrets.gate!.complete();
      await saving;
      secrets.gate = null;
      expect(hosts.byId(original.id)!.proxy!.toJson(), next.proxy!.toJson());
      await hosts.save(original);
    }
  });

  test('failed proxy cleanup retains the committed new route and queue recovers', () async {
    await hosts.save(original);
    secrets.fail = true;
    await expectLater(hosts.save(changed({'proxy': null})), throwsStateError);
    expect(hosts.byId(original.id)!.proxy, isNull);
    expect((persisted().single as Map)['proxy'], isNull);
    secrets.fail = false;
    await hosts.save(changed({'proxy': null}));
    expect(hosts.byId(original.id)!.proxy, isNull);
  });

  test('unrelated updates do not clear proxy credentials', () async {
    await hosts.save(original);
    await hosts.save(original.copyWith(label: 'renamed'));
    await hosts.setPinned(original, true);
    await hosts.touch(original.id);
    await hosts.renameGroup('prod', 'live');
    final current = hosts.byId(original.id)!;
    expect(current.label, 'renamed');
    expect(current.group, 'live/web');
    expect(current.pinned, isTrue);
    expect(current.lastUsed, isNotNull);
    expect(secrets.deleted, isEmpty);
  });

  test('failed disk writes do not publish any mutation or delete secrets', () async {
    await hosts.save(original);
    final block = File('${dir.path}/backups')..writeAsStringSync('blocked');
    await expectLater(hosts.save(original.copyWith(label: 'lost')), throwsA(isA<JsonFileError>()));
    await expectLater(hosts.setPinned(original, true), throwsA(isA<JsonFileError>()));
    await expectLater(hosts.touch(original.id), throwsA(isA<JsonFileError>()));
    await expectLater(hosts.renameGroup('prod', 'lost'), throwsA(isA<JsonFileError>()));
    await expectLater(hosts.delete(original), throwsA(isA<JsonFileError>()));
    expect(hosts.byId(original.id)!.toJson(), original.toJson());
    expect(persisted().single, original.toJson());
    expect(secrets.deleted, isEmpty);
    block.deleteSync();
    await hosts.save(original.copyWith(label: 'recovered'));
    expect(hosts.byId(original.id)!.label, 'recovered');
  });

  test('queued metadata changes use latest route, group, and label', () async {
    await hosts.save(original);
    final next = changed({'address': 'new.example', 'label': 'new'});
    await Future.wait([
      hosts.save(next),
      hosts.renameGroup('prod', 'live'),
      hosts.setPinned(original, true),
      hosts.touch(original.id),
    ]);
    final current = hosts.byId(original.id)!;
    expect(current.address, 'new.example');
    expect(current.label, 'new');
    expect(current.group, 'live/web');
    expect(current.pinned, isTrue);
    expect(current.lastUsed, isNotNull);
    expect(persisted().single, current.toJson());
  });

  test('late pin and touch cannot resurrect a deleted host', () async {
    await hosts.save(original);
    await Future.wait([hosts.delete(original), hosts.setPinned(original, true), hosts.touch(original.id)]);
    expect(container.read(hostsProvider), isEmpty);
    expect(persisted(), isEmpty);
    expect(secrets.deleted, [original.passwordRef, original.passphraseRef, original.proxyRef]);
  });

  test('deletion publishes before credential cleanup and failure does not restore metadata', () async {
    await hosts.save(original);
    secrets.fail = true;
    await expectLater(hosts.delete(original), throwsStateError);
    expect(container.read(hostsProvider), isEmpty);
    expect(persisted(), isEmpty);
    secrets.fail = false;
    await hosts.save(original.copyWith(id: const HostId('two')));
    expect(container.read(hostsProvider).single.id, const HostId('two'));
  });
}

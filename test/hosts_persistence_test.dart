import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/features/credentials/adapters/secure_store.dart';
import 'package:sshairy/features/credentials/api.dart' show hostPasswordImportProvider;
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
    values.remove(ref);
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
    final stored = hosts.byId(original.id)!.toJson();
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
    expect(hosts.byId(original.id)!.toJson(), stored);
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
    final expectedCommit = hosts.revision + 1;
    await expectLater(
      hosts.saveWithRevision(changed({'proxy': null}), expectedRevision: hosts.revision),
      throwsA(isA<HostProxyCleanupFailure>().having((e) => e.committedRevision, 'committedRevision', expectedCommit)),
    );
    expect(hosts.byId(original.id)!.proxy, isNull);
    expect((persisted().single as Map)['proxy'], isNull);
    secrets.fail = false;
    await hosts.saveWithRevision(changed({'proxy': null}), expectedRevision: hosts.revision);
    expect(hosts.byId(original.id)!.proxy, isNull);
    expect(secrets.deleted, [original.proxyRef, original.proxyRef], reason: 'the failed reference is retried');
  });

  test('retry never removes a proxy reference that has become active again', () async {
    await hosts.save(original);
    secrets.fail = true;
    await expectLater(hosts.save(changed({'proxy': null})), throwsA(isA<HostProxyCleanupFailure>()));
    secrets.fail = false;
    await hosts.save(original);
    await hosts.saveWithRevision(hosts.byId(original.id)!, expectedRevision: hosts.revision);
    expect(secrets.deleted, [original.proxyRef], reason: 'restoring the proxy makes its credential active again');
  });

  test('a save returns its own committed revision despite a queued later edit', () async {
    await hosts.save(original);
    final revision = hosts.revision;
    secrets.gate = Completer<void>();
    final saving = hosts.saveWithRevision(changed({'proxy': null}), expectedRevision: revision);
    for (var i = 0; i < 100 && secrets.deleted.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(secrets.deleted, [original.proxyRef]);
    final later = hosts.save(changed({'proxy': null, 'label': 'later'}));
    secrets.gate!.complete();
    final committed = await saving;
    await later;
    expect(committed, revision + 1);
    expect(hosts.revision, revision + 2);
    await expectLater(
      hosts.saveWithRevision(changed({'proxy': null}), expectedRevision: committed),
      throwsA(isA<JsonFileError>().having((e) => e.kind, 'kind', JsonFileFailure.conflict)),
    );
    expect(hosts.byId(original.id)!.label, 'later');
    // JsonFile.idle retains a rejected write until a successful write clears it.
    await hosts.save(hosts.byId(original.id)!);
  });

  test('unrelated password import succeeds while pending proxy cleanup still fails', () async {
    await hosts.save(original);
    secrets.values[original.passwordRef] = const Secret('existing-password');
    secrets.values[original.proxyRef] = const Secret('old-proxy-password');
    secrets.fail = true;
    await expectLater(hosts.save(changed({'proxy': null})), throwsA(isA<HostProxyCleanupFailure>()));
    const imported = Host(id: HostId('imported'), label: 'imported', address: 'imported.example', username: 'u');
    var importedPasswords = 0;
    await hosts
        .importDrafts(
          [imported],
          expectedRevision: hosts.revision,
          aroundCommit: (commit) async {
            importedPasswords = await container.read(hostPasswordImportProvider).importMissing({
              imported.id: const Secret('imported-password'),
              original.id: const Secret('must-not-replace'),
            }, commit);
          },
        )
        .timeout(const Duration(seconds: 5));
    expect(importedPasswords, 1);
    expect(hosts.byId(imported.id), isNotNull);
    expect(secrets.values[imported.passwordRef]?.reveal(), 'imported-password');
    expect(secrets.values[original.passwordRef]?.reveal(), 'existing-password');
    expect(secrets.values[original.proxyRef]?.reveal(), 'old-proxy-password');
    expect(secrets.deleted, [original.proxyRef], reason: 'an unrelated import never retries another host cleanup');
    secrets.fail = false;
    await hosts.saveWithRevision(hosts.byId(original.id)!, expectedRevision: hosts.revision);
    expect(secrets.deleted, [original.proxyRef, original.proxyRef]);
    expect(secrets.values[original.proxyRef], isNull);
    expect(secrets.values[imported.passwordRef]?.reveal(), 'imported-password');
  });

  test('saving a different host does not retry another host pending proxy cleanup', () async {
    await hosts.save(original);
    secrets.values[original.passwordRef] = const Secret('existing-password');
    secrets.values[original.proxyRef] = const Secret('old-proxy-password');
    secrets.fail = true;
    await expectLater(hosts.save(changed({'proxy': null})), throwsA(isA<HostProxyCleanupFailure>()));
    const imported = Host(id: HostId('imported'), label: 'imported', address: 'imported.example', username: 'u');
    await hosts
        .importDrafts(
          [imported],
          expectedRevision: hosts.revision,
          aroundCommit: (commit) async {
            await container.read(hostPasswordImportProvider).importMissing({
              imported.id: const Secret('imported-password'),
            }, commit);
          },
        )
        .timeout(const Duration(seconds: 5));
    await hosts.save(imported.copyWith(label: 'unrelated edit'));
    await hosts.saveWithRevision(hosts.byId(imported.id)!, expectedRevision: hosts.revision);
    expect(hosts.byId(imported.id), isNotNull);
    expect(secrets.values[imported.passwordRef]?.reveal(), 'imported-password');
    expect(secrets.values[original.passwordRef]?.reveal(), 'existing-password');
    expect(secrets.values[original.proxyRef]?.reveal(), 'old-proxy-password');
    expect(secrets.deleted, [original.proxyRef]);
    secrets.fail = false;
    await hosts.save(hosts.byId(original.id)!);
    expect(secrets.values[original.proxyRef], isNull);
    expect(secrets.values[imported.passwordRef]?.reveal(), 'imported-password');
  });

  test('an import metadata conflict rolls back only its new password before pending cleanup resumes', () async {
    await hosts.save(original);
    secrets.values[original.passwordRef] = const Secret('existing-password');
    secrets.values[original.proxyRef] = const Secret('old-proxy-password');
    secrets.fail = true;
    await expectLater(hosts.save(changed({'proxy': null})), throwsA(isA<HostProxyCleanupFailure>()));
    final staleRevision = hosts.revision;
    secrets.fail = false;
    await hosts.save(hosts.byId(original.id)!.copyWith(label: 'later'));
    const imported = Host(id: HostId('imported'), label: 'imported', address: 'imported.example', username: 'u');
    await expectLater(
      hosts
          .importDrafts(
            [imported],
            expectedRevision: staleRevision,
            aroundCommit: (commit) async {
              await container.read(hostPasswordImportProvider).importMissing({
                imported.id: const Secret('imported-password'),
                original.id: const Secret('must-not-replace'),
              }, commit);
            },
          )
          .timeout(const Duration(seconds: 5)),
      throwsA(isA<JsonFileError>().having((e) => e.kind, 'kind', JsonFileFailure.conflict)),
    );
    expect(hosts.byId(imported.id), isNull);
    expect(secrets.values[imported.passwordRef], isNull);
    expect(secrets.values[original.passwordRef]?.reveal(), 'existing-password');
    expect(secrets.deleted, [original.proxyRef, original.proxyRef, imported.passwordRef]);
    await hosts.save(hosts.byId(original.id)!);
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
    final stored = hosts.byId(original.id)!.toJson();
    final block = File('${dir.path}/backups')..writeAsStringSync('blocked');
    await expectLater(hosts.save(original.copyWith(label: 'lost')), throwsA(isA<JsonFileError>()));
    await expectLater(hosts.setPinned(original, true), throwsA(isA<JsonFileError>()));
    await expectLater(hosts.touch(original.id), throwsA(isA<JsonFileError>()));
    await expectLater(hosts.renameGroup('prod', 'lost'), throwsA(isA<JsonFileError>()));
    await expectLater(hosts.delete(original), throwsA(isA<JsonFileError>()));
    expect(hosts.byId(original.id)!.toJson(), stored);
    expect(persisted().single, stored);
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

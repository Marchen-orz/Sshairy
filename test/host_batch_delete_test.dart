import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/app/composition.dart';
import 'package:sshairy/features/capabilities/api.dart';
import 'package:sshairy/features/credentials/api.dart';
import 'package:sshairy/features/credentials/application/credential_access.dart' show secretStoreProvider;
import 'package:sshairy/features/hosts/api.dart';
import 'package:sshairy/foundation/data_dir.dart';
import 'package:sshairy/foundation/ids.dart';
import 'package:sshairy/foundation/json_file.dart';
import 'package:sshairy/foundation/result.dart';

import 'keys_test.dart' show MemorySecrets;

class _Cleanup implements HostCredentialCleanup {
  final removed = <HostId>[];
  HostId? failFor;
  @override
  Future<void> clearHost(HostId id, String proxyIdentity) async {
    removed.add(id);
    if (id == failFor) throw StateError('simulated credential store failure');
  }

  @override
  Future<void> clearProxy(HostId id, String proxyIdentity) async {}
}

void main() {
  late Directory data;
  late ProviderContainer container;
  late HostsNotifier hosts;
  late _Cleanup cleanup;

  setUp(() {
    data = Directory.systemTemp.createTempSync('sshairy-delete-batch-');
    cleanup = _Cleanup();
    container = ProviderContainer(
      overrides: [
        ...appOverrides(),
        dataDirProvider.overrideWithValue(data.path),
        secretStoreProvider.overrideWithValue(MemorySecrets()),
        hostCredentialCleanupProvider.overrideWithValue(cleanup),
      ],
    );
    hosts = container.read(hostsProvider.notifier);
  });
  tearDown(() async {
    await hosts.saved.then((_) {}, onError: (Object _) {});
    container.dispose();
    await data.delete(recursive: true);
  });

  Future<void> seed() async {
    for (final name in ['a', 'b', 'c']) {
      await hosts.save(Host(id: HostId(name), label: name, address: '$name.example', username: 'u'));
    }
  }

  test('batch delete writes once, persists, and cleans each selected host exactly once', () async {
    await seed();
    final before = hosts.revision;
    await hosts.deleteMany([const HostId('a'), const HostId('b'), const HostId('a')]);
    expect(hosts.revision, before + 1);
    expect(container.read(hostsProvider).map((h) => h.id.value), ['c']);
    expect(cleanup.removed.map((id) => id.value), ['a', 'b']);
    final reopened = ProviderContainer(overrides: [dataDirProvider.overrideWithValue(data.path)]);
    expect(reopened.read(hostsProvider).map((h) => h.id.value), ['c']);
    reopened.dispose();
  });

  test('external jump references refuse the entire selection; internal references may be removed together', () async {
    await seed();
    final a = hosts.byId(const HostId('a'))!;
    await hosts.save(
      hosts
          .byId(const HostId('b'))!
          .copyWith(overrides: () => explicitConnection(hosts.byId(const HostId('b'))!).copyWithJump(a.id)),
    );
    final before = File('${data.path}/hosts.json').readAsStringSync();
    await expectLater(hosts.deleteMany([const HostId('c'), a.id]), throwsA(isA<HostInUse>()));
    expect(File('${data.path}/hosts.json').readAsStringSync(), before);
    expect(cleanup.removed, isEmpty);
    await hosts.deleteMany([a.id, const HostId('b')]);
    expect(container.read(hostsProvider).map((h) => h.id.value), ['c']);
  });

  test('group and global jump references still protect selected hosts', () async {
    await seed();
    await hosts.addGroup('Team');
    await hosts.saveGroup(
      hosts.library.groups.single.copyWith(defaults: const ConnectionOverrides(jump: OverrideValue.value(HostId('a')))),
    );
    await expectLater(hosts.deleteMany([const HostId('a'), const HostId('c')]), throwsA(isA<HostInUse>()));
    expect(container.read(hostsProvider), hasLength(3));
    expect(cleanup.removed, isEmpty);
    await hosts.saveGroup(hosts.library.groups.single.copyWith(defaults: const ConnectionOverrides()));
    await hosts.saveDefaults(const ConnectionOverrides(jump: OverrideValue.value(HostId('a'))));
    await expectLater(hosts.deleteMany([const HostId('a'), const HostId('c')]), throwsA(isA<HostInUse>()));
    expect(container.read(hostsProvider), hasLength(3));
    expect(cleanup.removed, isEmpty);
  });

  test('a failed metadata write leaves the whole selection and its credentials untouched', () async {
    await seed();
    final file = File('${data.path}/hosts.json');
    final contents = file.readAsStringSync();
    file.deleteSync();
    final blocked = Directory(file.path)..createSync();
    try {
      await expectLater(hosts.deleteMany([const HostId('a'), const HostId('b')]), throwsA(isA<JsonFileError>()));
      expect(container.read(hostsProvider), hasLength(3));
      expect(cleanup.removed, isEmpty);
    } finally {
      blocked.deleteSync(recursive: true);
      file.writeAsStringSync(contents);
    }
  });

  test('missing IDs and stale confirmation revisions cause no partial removal or credential cleanup', () async {
    await seed();
    final revision = hosts.revision;
    await expectLater(hosts.deleteMany([const HostId('a'), const HostId('missing')]), throwsArgumentError);
    await hosts.setPinned(hosts.byId(const HostId('c'))!, true);
    await expectLater(
      hosts.deleteMany([const HostId('a'), const HostId('b')], expectedRevision: revision),
      throwsA(isA<JsonFileError>().having((e) => e.kind, 'kind', JsonFileFailure.conflict)),
    );
    expect(container.read(hostsProvider), hasLength(3));
    expect(cleanup.removed, isEmpty);
  });

  test('credential cleanup failure reports committed deletion and still tries the other hosts', () async {
    await seed();
    cleanup.failFor = const HostId('a');
    await expectLater(
      hosts.deleteMany([const HostId('a'), const HostId('b')]),
      throwsA(isA<HostDeleteCleanupFailure>()),
    );
    expect(container.read(hostsProvider).map((h) => h.id.value), ['c']);
    expect(cleanup.removed.map((id) => id.value), ['a', 'b']);
  });

  test('batch capability validates input and remains unavailable to agents', () async {
    await seed();
    final dispatcher = container.read(capabilityDispatcherProvider);
    final result = await dispatcher.dispatch('host.deleteMany', {
      'hostIds': ['a', 'b'],
    }, RequestContext(Origin.ui));
    expect(result, isA<Ok<Object?>>());
    expect(container.read(hostsProvider).map((h) => h.id.value), ['c']);
    final refused = await dispatcher.dispatch('host.deleteMany', {'hostIds': []}, RequestContext(Origin.ui));
    expect(refused, isA<Err<Object?>>());
    final agent = await dispatcher.dispatch('host.deleteMany', {
      'hostIds': ['c'],
    }, RequestContext(Origin.agent));
    expect(agent, isA<Err<Object?>>());
  });
}

extension on ConnectionOverrides {
  ConnectionOverrides copyWithJump(HostId id) => ConnectionOverrides(
    port: port,
    authentication: authentication,
    jump: OverrideValue.value(id),
    proxy: proxy,
    legacy: legacy,
  );
}

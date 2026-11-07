import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/features/credentials/adapters/secure_store.dart';
import 'package:sshairy/features/credentials/api.dart';
import 'package:sshairy/features/credentials/application/credential_access.dart' show secretStoreProvider;
import 'package:sshairy/foundation/ids.dart';
import 'package:sshairy/foundation/json_file.dart';
import 'package:sshairy/foundation/secret.dart';

class _Store extends SecretStore {
  final values = <SecretRef, String>{};
  final writes = <SecretRef>[];
  final deletes = <SecretRef>[];
  SecretRef? failWrite;
  final failDelete = <SecretRef>{};
  var failRead = false;

  @override
  Future<Secret?> read(SecretRef ref) async {
    if (failRead) throw StateError('synthetic sensitive store error');
    final value = values[ref];
    return value == null ? null : Secret(value);
  }

  @override
  Future<void> write(SecretRef ref, Secret value) async {
    writes.add(ref);
    values[ref] = value.reveal();
    if (ref == failWrite) throw StateError('synthetic sensitive store error');
  }

  @override
  Future<void> delete(SecretRef ref) async {
    deletes.add(ref);
    if (failDelete.contains(ref)) throw StateError('synthetic sensitive store error');
    values.remove(ref);
  }
}

void main() {
  const a = HostId('a'), b = HostId('b'), saved = HostId('saved');
  final aRef = SecretRef.hostPassword(a), bRef = SecretRef.hostPassword(b), savedRef = SecretRef.hostPassword(saved);
  late _Store store;
  late ProviderContainer container;
  late HostPasswordImport importer;
  late ConnectionCredentials access;

  setUp(() {
    store = _Store();
    container = ProviderContainer(overrides: [secretStoreProvider.overrideWithValue(store)]);
    importer = container.read(hostPasswordImportProvider);
    access = container.read(connectionCredentialsProvider);
  });
  tearDown(() => container.dispose());

  test('fills only missing passwords before committing without invalidating first saves', () async {
    store.values[savedRef] = 'existing';
    var committed = false;
    final count = await importer.importMissing(
      {saved: const Secret('source replacement'), a: const Secret('import a'), b: const Secret('import b')},
      () async {
        expect(store.values, {savedRef: 'existing', aRef: 'import a', bRef: 'import b'});
        committed = true;
      },
    );
    expect(count, 2);
    expect(committed, isTrue);
    expect(store.writes, [aRef, bRef]);
    expect(store.deletes, isEmpty);
    expect(access.revision, 0);
  });

  test('a metadata conflict rolls back additions and preserves its typed error and saved password', () async {
    store.values[savedRef] = 'existing';
    const conflict = JsonFileError(JsonFileFailure.conflict, 'synthetic-vault.json');
    await expectLater(
      importer.importMissing({a: const Secret('import a'), saved: const Secret('source')}, () async => throw conflict),
      throwsA(same(conflict)),
    );
    expect(store.values, {savedRef: 'existing'});
    expect(store.deletes, [aRef]);
    expect(access.revision, 1);
    await access.remember(aRef, const Secret('later'));
    expect((await access.read(aRef))!.reveal(), 'later', reason: 'a failed import does not poison the queue');
  });

  test('a write which saves then throws is itself rolled back and never commits metadata', () async {
    store.values[savedRef] = 'existing';
    store.failWrite = bRef;
    var committed = false;
    await expectLater(
      importer.importMissing({a: const Secret('import a'), b: const Secret('import b')}, () async => committed = true),
      throwsA(isA<CredentialImportFailure>().having((e) => e.rollbackIncomplete, 'rollbackIncomplete', isFalse)),
    );
    expect(committed, isFalse);
    expect(store.values, {savedRef: 'existing'});
    expect(store.deletes, [bRef, aRef]);
    expect(access.revision, 2);
  });

  test('rollback attempts every new reference and reports incomplete cleanup without store details', () async {
    store.failDelete.add(bRef);
    Object? failure;
    try {
      await importer.importMissing({a: const Secret('import a'), b: const Secret('import b')}, () async {
        throw StateError('synthetic sensitive callback error');
      });
    } on Object catch (error) {
      failure = error;
    }
    expect(failure, isA<CredentialImportFailure>().having((e) => e.rollbackIncomplete, 'rollbackIncomplete', isTrue));
    expect('$failure', isNot(contains('sensitive')));
    expect('$failure', isNot(contains('import a')));
    expect(store.deletes, [bRef, aRef]);
    expect(store.values, {bRef: 'import b'});
    expect(access.revision, 2);
  });

  test('store read errors are sanitized and do not commit', () async {
    store.failRead = true;
    var committed = false;
    await expectLater(
      importer.importMissing({a: const Secret('import a')}, () async => committed = true),
      throwsA(isA<CredentialImportFailure>().having((e) => '$e', 'safe error', isNot(contains('sensitive')))),
    );
    expect(committed, isFalse);
    expect(store.writes, isEmpty);
    expect(store.deletes, isEmpty);
  });

  test('remember, read and host cleanup wait until a failed import has finished rollback', () async {
    store.values[savedRef] = 'old saved';
    final entered = Completer<void>(), release = Completer<void>();
    final importing = importer.importMissing({a: const Secret('import a')}, () async {
      entered.complete();
      await release.future;
      throw const JsonFileError(JsonFileFailure.conflict, 'synthetic-vault.json');
    });
    final rejected = expectLater(importing, throwsA(isA<JsonFileError>()));
    await entered.future;
    var remembered = false, read = false, cleaned = false;
    final remembering = access.remember(aRef, const Secret('manual')).then((_) => remembered = true);
    final reading = access.read(aRef).then((value) {
      read = true;
      return value;
    });
    final cleaning = container
        .read(hostCredentialCleanupProvider)
        .clearHost(saved, 'proxy')
        .then((_) => cleaned = true);
    await Future<void>.delayed(Duration.zero);
    expect((remembered, read, cleaned), (false, false, false));
    expect(store.values, {savedRef: 'old saved', aRef: 'import a'});
    expect(store.deletes, isEmpty);

    release.complete();
    await rejected;
    await remembering;
    expect((await reading)!.reveal(), 'manual');
    await cleaning;
    expect(store.values, {aRef: 'manual'}, reason: 'rollback cannot remove the subsequent manual save');
    expect((remembered, read, cleaned), (true, true, true));
    expect(store.deletes, [aRef, savedRef, SecretRef.hostPassphrase(saved), SecretRef.hostProxy(saved, 'proxy')]);
  });

  test('an empty password set still commits once and proxy cleanup is queued', () async {
    final entered = Completer<void>(), release = Completer<void>();
    final proxyRef = SecretRef.hostProxy(saved, 'proxy');
    store.values[proxyRef] = 'proxy password';
    var commits = 0;
    final importing = importer.importMissing({}, () async {
      commits++;
      entered.complete();
      await release.future;
    });
    await entered.future;
    final cleaning = container.read(hostCredentialCleanupProvider).clearProxy(saved, 'proxy');
    await Future<void>.delayed(Duration.zero);
    expect(store.values[proxyRef], 'proxy password');
    release.complete();
    expect(await importing, 0);
    await cleaning;
    expect(commits, 1);
    expect(store.values, isEmpty);
  });
}

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/features/credentials/adapters/secure_store.dart';
import 'package:sshairy/features/credentials/api.dart';
import 'package:sshairy/features/credentials/application/credential_access.dart' show secretStoreProvider;
import 'package:sshairy/foundation/ids.dart';
import 'package:sshairy/foundation/secret.dart';

class _FakeSecretStore extends SecretStore {
  final values = <SecretRef, Secret>{};
  final reads = <SecretRef>[];
  final writes = <SecretRef>[];
  final deletes = <SecretRef>[];
  Object? readError, writeError, deleteError;

  @override
  Future<Secret?> read(SecretRef ref) async {
    reads.add(ref);
    if (readError case final Object error) throw error;
    return values[ref];
  }

  @override
  Future<void> write(SecretRef ref, Secret value) async {
    writes.add(ref);
    if (writeError case final Object error) throw error;
    values[ref] = value;
  }

  @override
  Future<void> delete(SecretRef ref) async {
    deletes.add(ref);
    if (deleteError case final Object error) throw error;
    values.remove(ref);
  }
}

void main() {
  const identity = 'deepl:https://api.deepl.com/v2/translate';
  const otherIdentity = 'deepl:https://api-free.deepl.com/v2/translate';
  late _FakeSecretStore store;
  late ProviderContainer container;
  late TranslationCredentials credentials;

  setUp(() {
    store = _FakeSecretStore();
    container = ProviderContainer(overrides: [secretStoreProvider.overrideWithValue(store)]);
    credentials = container.read(translationCredentialsProvider);
  });
  tearDown(() => container.dispose());

  test('translation references encode the whole public identity in their own namespace', () {
    const publicIdentity = 'provider:https://example.test/v1/翻译?format=a/b&region=eu';
    final ref = SecretRef.translation(publicIdentity);
    expect(ref.storageKey, 'translation/${Uri.encodeComponent(publicIdentity)}/apiKey');
    expect(ref, SecretRef.translation(publicIdentity));
    expect(ref.hashCode, SecretRef.translation(publicIdentity).hashCode);
    expect(SecretRef.translation('a/b'), isNot(SecretRef.translation('a%2Fb')));
    expect(SecretRef.translation('x' * 2048).storageKey, 'translation/${'x' * 2048}/apiKey');
  });

  test('invalid identities are rejected by every port operation before accessing storage', () async {
    final invalid = [
      '',
      '   ',
      'x' * 2049,
      for (final code in [0, 9, 10, 13, 31, 127, 128, 159]) 'endpoint${String.fromCharCode(code)}',
    ];
    for (final value in invalid) {
      expect(() => SecretRef.translation(value), throwsArgumentError);
      await expectLater(credentials.has(value), throwsArgumentError);
      await expectLater(credentials.save(value, const Secret('synthetic-key')), throwsArgumentError);
      await expectLater(credentials.read(value), throwsArgumentError);
      await expectLater(credentials.clear(value), throwsArgumentError);
    }
    expect(store.reads, isEmpty);
    expect(store.writes, isEmpty);
    expect(store.deletes, isEmpty);
  });

  test('has exposes only presence, reads are fresh and absent values stay null', () async {
    expect(await credentials.has(identity), isFalse);
    expect(await credentials.read(identity), isNull);
    const first = Secret('synthetic-first-key');
    await credentials.save(identity, first);
    expect(await credentials.has(identity), isTrue);
    expect(await credentials.read(identity), same(first));
    await credentials.save(identity, const Secret('synthetic-replacement-key'));
    expect((await credentials.read(identity))!.reveal(), 'synthetic-replacement-key');
    expect(store.values.keys, [SecretRef.translation(identity)]);
    expect('$first', 'Secret(***)');
  });

  test('save and clear only address their translation identity and do not invalidate SSH', () async {
    const host = HostId('saved-host');
    final hostRef = SecretRef.hostPassword(host), keyRef = SecretRef.privateKey('saved-key');
    store.values[hostRef] = const Secret('synthetic-host-password');
    store.values[keyRef] = const Secret('synthetic-private-key');
    final connection = container.read(connectionCredentialsProvider);
    final revision = connection.revision;
    await credentials.save(identity, const Secret('synthetic-key'));
    await credentials.save(otherIdentity, const Secret('synthetic-other-key'));
    await credentials.save(identity, const Secret('synthetic-replacement-key'));
    await credentials.clear(identity);
    await credentials.clear(identity);
    expect(await credentials.has(identity), isFalse);
    expect((await credentials.read(otherIdentity))!.reveal(), 'synthetic-other-key');
    expect(store.values[hostRef]!.reveal(), 'synthetic-host-password');
    expect(store.values[keyRef]!.reveal(), 'synthetic-private-key');
    expect(store.deletes, [SecretRef.translation(identity), SecretRef.translation(identity)]);
    expect(connection.revision, revision);
  });

  test('keys reject blank input, controls and values over 8192 without leaking validation input', () async {
    final invalid = [
      '',
      '   ',
      'x' * 8193,
      for (final code in [0, 9, 10, 13, 31, 127, 128, 159]) 'synthetic-private-marker${String.fromCharCode(code)}injection',
    ];
    for (final value in invalid) {
      await expectLater(
        credentials.save(identity, Secret(value)),
        throwsA(isA<ArgumentError>().having((e) => '$e', 'safe error', isNot(contains('synthetic-private-marker')))),
      );
    }
    expect(store.reads, isEmpty);
    expect(store.writes, isEmpty);
    expect(store.values, isEmpty);
    final largest = 'x' * 8192;
    await credentials.save(identity, Secret(largest));
    expect((await credentials.read(identity))!.reveal(), largest);
  });

  test('read rejects invalid stored headers without leaking their value', () async {
    final ref = SecretRef.translation(identity);
    for (final value in ['', '   ', 'x' * 8193, 'synthetic-private-marker\r\nAuthorization: injected']) {
      store.values[ref] = Secret(value);
      expect(await credentials.has(identity), isTrue);
      await expectLater(
        credentials.read(identity),
        throwsA(isA<ArgumentError>().having((e) => '$e', 'safe error', isNot(contains('synthetic-private-marker')))),
      );
      expect(store.values[ref]!.reveal(), value, reason: 'invalid storage is not silently overwritten or deleted');
    }
    expect(store.writes, isEmpty);
    expect(store.deletes, isEmpty);
    await credentials.save(identity, const Secret('synthetic-valid-key'));
    expect((await credentials.read(identity))!.reveal(), 'synthetic-valid-key');
  });

  test('translation operations share the import and SSH credential queue', () async {
    final entered = Completer<void>(), release = Completer<void>();
    final importing = container.read(hostPasswordImportProvider).importMissing({}, () async {
      entered.complete();
      await release.future;
    });
    await entered.future;
    var saved = false, checked = false, read = false, cleared = false, remembered = false;
    final saving = credentials.save(identity, const Secret('synthetic-key')).then((_) => saved = true);
    final checking = credentials.has(identity).then((value) {
      checked = true;
      return value;
    });
    final reading = credentials.read(identity).then((value) {
      read = true;
      return value;
    });
    final clearing = credentials.clear(identity).then((_) => cleared = true);
    final hostRef = SecretRef.hostPassword(const HostId('later-host'));
    final remembering = container
        .read(connectionCredentialsProvider)
        .remember(hostRef, const Secret('synthetic-host-password'))
        .then((_) => remembered = true);
    await Future<void>.delayed(Duration.zero);
    expect((saved, checked, read, cleared, remembered), (false, false, false, false, false));
    expect(store.reads, isEmpty);
    expect(store.writes, isEmpty);
    expect(store.deletes, isEmpty);

    release.complete();
    expect(await importing, 0);
    await saving;
    expect(await checking, isTrue);
    expect((await reading)!.reveal(), 'synthetic-key');
    await clearing;
    await remembering;
    expect((saved, checked, read, cleared, remembered), (true, true, true, true, true));
    expect(store.writes, [SecretRef.translation(identity), hostRef]);
    expect(store.values.keys, [hostRef]);
  });

  test('store failures propagate and do not poison later queued operations', () async {
    final failure = StateError('synthetic store unavailable');
    store.readError = failure;
    await expectLater(credentials.has(identity), throwsA(same(failure)));
    await expectLater(credentials.read(identity), throwsA(same(failure)));
    store.readError = null;
    expect(await credentials.has(identity), isFalse);
    store.writeError = failure;
    await expectLater(credentials.save(identity, const Secret('synthetic-key')), throwsA(same(failure)));
    expect(store.values, isEmpty);
    store.writeError = null;
    await credentials.save(identity, const Secret('synthetic-key'));
    store.deleteError = failure;
    await expectLater(credentials.clear(identity), throwsA(same(failure)));
    expect((await credentials.read(identity))!.reveal(), 'synthetic-key');
    store.deleteError = null;
    await credentials.clear(identity);
    expect(await credentials.read(identity), isNull);
  });
}

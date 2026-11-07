import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/app/composition.dart';
import 'package:sshairy/features/credentials/api.dart';
import 'package:sshairy/features/credentials/application/credential_access.dart' show secretStoreProvider;
import 'package:sshairy/features/hosts/adapters/finalshell_login.dart';
import 'package:sshairy/features/hosts/adapters/host_import_files.dart';
import 'package:sshairy/features/hosts/api.dart';
import 'package:sshairy/features/hosts/application/host_import.dart';
import 'package:sshairy/features/hosts/domain/host_import.dart';
import 'package:sshairy/foundation/data_dir.dart';
import 'package:sshairy/foundation/ids.dart';
import 'package:sshairy/foundation/json_file.dart';

import 'keys_test.dart' show MemorySecrets;

// Artificial fixtures encrypted independently with PyCryptodome DES, never real account credentials.
const _encoded = 'AwsWISw3Qk2PudUQ9dh27AOgGBzot4CKoBfdJqXqTi0=';
const _password = 'synthetic-login-42';

class _Files extends HostImportFiles {
  const _Files(this.root);
  final String root;
  @override
  Future<ImportRead?> readDefault(ImportFormat format) => read(format, root);
}

void main() {
  test('legacy passwords decode ASCII, Unicode, negative header bytes and full padding blocks', () {
    expect(decodeFinalShellPassword(_encoded)?.reveal(), _password);
    expect(decodeFinalShellPassword('/4D+/fz7+vmc2DnGU7IBNtfnylLgJ50GWGRG2yKMmyw=')?.reveal(), '合成密码-测试');
    expect(decodeFinalShellPassword('AAECAwQFBgeWsEf/czfdFz67ikkWR7/z')?.reveal(), 'eight888');
    expect(decodeFinalShellPassword(_encoded).toString(), 'Secret(***)');
    for (final value in ['', 'plaintext', 'not base64!', base64.encode(List.filled(16, 0)), _encoded.substring(1)]) {
      expect(decodeFinalShellPassword(value), isNull);
    }
  });

  group('local migration', () {
    late Directory temp, source, data;
    late ProviderContainer container;
    late MemorySecrets secrets;
    late HostImport importer;
    late HostsNotifier hosts;

    File write({String address = 'example.invalid', Map<String, Object?> extra = const {}}) =>
        File('${source.path}/one_connect_config.json')..writeAsStringSync(
          jsonEncode({
            'name': 'synthetic',
            'host': address,
            'user_name': 'tester',
            'port': 22,
            'authentication_type': 1,
            'password': _encoded,
            ...extra,
          }),
        );

    setUp(() {
      temp = Directory.systemTemp.createTempSync('sshairy-login-');
      source = Directory('${temp.path}/source')..createSync();
      data = Directory('${temp.path}/data')..createSync();
      secrets = MemorySecrets();
      container = ProviderContainer(
        overrides: [
          dataDirProvider.overrideWithValue(data.path),
          secretStoreProvider.overrideWithValue(secrets),
          ...appOverrides(),
        ],
      );
      hosts = container.read(hostsProvider.notifier);
      importer = HostImport(
        hosts,
        () => container.read(hostsProvider),
        files: _Files(source.path),
        passwords: container.read(hostPasswordImportProvider),
      );
      write();
    });
    tearDown(() {
      container.dispose();
      temp.deleteSync(recursive: true);
    });

    Future<ImportPreview> preview() async => (await importer.fromSoftware(ImportFormat.finalshell))!;

    test('preview has status only; commit stores password separately from host JSON', () async {
      final p = await preview();
      expect(p.passwords, {p.config.hosts.single.key});
      expect(secrets.values, isEmpty);
      expect(await importer.commit(p, p.passwords), 1);
      final host = container.read(hostsProvider).single;
      expect(secrets.values[SecretRef.hostPassword(host.id)], _password);
      for (final file in data.listSync(recursive: true).whereType<File>()) {
        final text = latin1.decode(file.readAsBytesSync());
        expect(text, isNot(contains(_password)));
        expect(text, isNot(contains(_encoded)));
      }
    });

    test('login opt-out imports metadata without storing passwords', () async {
      final p = await preview();
      expect(await importer.commit(p, p.passwords, login: false), 1);
      expect(container.read(hostsProvider), hasLength(1));
      expect(secrets.values, isEmpty);
    });

    test('reimport fills an existing host without duplication or metadata edits; preserves saved password', () async {
      const saved = Host(id: HostId('existing'), label: 'my label', address: 'example.invalid', username: 'tester');
      await hosts.save(saved);
      final p = await preview();
      expect(p.plan.drafts.single.existing?.id, saved.id);
      expect(p.canSelect(p.plan.drafts.single), isTrue);
      expect(p.canSelect(p.plan.drafts.single, login: false), isFalse);
      expect(await importer.commit(p, p.passwords), 1);
      expect(container.read(hostsProvider).single.label, 'my label');
      expect(secrets.values[SecretRef.hostPassword(saved.id)], _password);
      secrets.values[SecretRef.hostPassword(saved.id)] = 'synthetic-manual-password';
      final again = await preview();
      await importer.commit(again, again.passwords);
      expect(container.read(hostsProvider), hasLength(1));
      expect(secrets.values[SecretRef.hostPassword(saved.id)], 'synthetic-manual-password');
    });

    test('preview conflict rolls back new passwords and keeps the edited host library', () async {
      final p = await preview();
      await hosts.save(const Host(id: HostId('other'), label: 'other', address: 'other.invalid', username: 'u'));
      await expectLater(importer.commit(p, p.passwords), throwsA(isA<JsonFileError>()));
      expect(secrets.values, isEmpty);
      expect(container.read(hostsProvider).single.id, const HostId('other'));
    });

    test('source endpoint changed after preview is rejected before writing credentials', () async {
      final p = await preview();
      write(address: 'changed.invalid');
      await expectLater(importer.commit(p, p.passwords), throwsA(isA<ImportSourceChanged>()));
      expect(secrets.values, isEmpty);
      expect(container.read(hostsProvider), isEmpty);
    });

    test('key references and unsupported password encodings remain metadata-only', () async {
      write(extra: {'secret_key_id': 'synthetic-key'});
      expect((await preview()).passwords, isEmpty);
      write(extra: {'authentication_type': 2});
      expect((await preview()).passwords, isEmpty);
      write(extra: {'password': 'new-unsupported-format'});
      final p = await preview();
      expect(p.passwords, isEmpty);
      await importer.commit(p, {p.plan.drafts.single.key});
      expect(secrets.values, isEmpty);
      expect(container.read(hostsProvider), hasLength(1));
    });

    test('a key-authenticated existing host is not selected for a password-only migration', () async {
      await hosts.save(
        const Host(
          id: HostId('key'),
          label: 'key',
          address: 'example.invalid',
          username: 'tester',
          auth: AuthKind.key,
          keyPath: '/synthetic/key',
        ),
      );
      final p = await preview();
      expect(p.canSelect(p.plan.drafts.single), isFalse);
      expect(await importer.commit(p, p.passwords), 0);
      expect(secrets.values, isEmpty);
    });

    test('an existing host behind a proxy cannot receive a direct-source password', () async {
      await hosts.save(
        const Host(
          id: HostId('proxied'),
          label: 'other environment',
          address: 'example.invalid',
          username: 'tester',
          proxy: Proxy(ProxyKind.socks5, 'proxy.invalid', 1080),
        ),
      );
      final p = await preview();
      expect(p.canSelect(p.plan.drafts.single), isFalse);
      expect(await importer.commit(p, p.passwords), 0);
      expect(secrets.values, isEmpty);
    });

    test('UTF-16 BOM connection metadata and password use the same text decoder', () async {
      final file = write();
      final text = file.readAsStringSync();
      file.writeAsBytesSync([
        0xff,
        0xfe,
        for (final unit in text.codeUnits) ...[unit & 0xff, unit >> 8],
      ]);
      final p = await preview();
      expect(p.passwords, {p.plan.drafts.single.key});
      await importer.commit(p, p.passwords);
      expect(secrets.values.values.single, _password);
    });

    test('relative source files cannot escape the selected directory', () async {
      final config = parseFinalShell([
        ImportText('../one_connect_config.json', File('${source.path}/one_connect_config.json').readAsStringSync()),
      ], defaultUser: 'tester');
      expect(await const FinalShellLogin().load(source.path, config.hosts), isEmpty);
      await expectLater(
        const FinalShellLogin().load(source.path, config.hosts, strict: true),
        throwsA(isA<ImportSourceChanged>()),
      );
    });
  });
}

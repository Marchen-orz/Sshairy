import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/features/connections/adapters/host_key_codec.dart';
import 'package:sshairy/features/connections/adapters/known_hosts_file.dart';
import 'package:sshairy/features/connections/application/host_trust.dart';
import 'package:sshairy/foundation/json_file.dart';
import 'package:sshairy/features/connections/application/known_hosts_import.dart';
import 'package:sshairy/features/connections/domain/known_hosts.dart';
import 'package:sshairy/features/connections/domain/prompts.dart';
import 'package:sshairy/foundation/result.dart';

// Public keys and hashed names as ssh-keygen wrote them (ssh-keygen -lf for the fingerprints, ssh-keygen -H for
// the names of example.org and [example.org]:2222).
const ed = 'AAAAC3NzaC1lZDI1NTE5AAAAIAYa2uucL0J6SJLcOW8tcB74Z3jTe19zadFgu97Iz/V+';
const edFp = 'SHA256:BcOA1e/c6N/nOjjNppHjb6NakRUZxtGklHFoRcaHwgI';
const ecdsa =
    'AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBKZm0vr5Q2Le9iLohyXqNdIofWD0+ys7lyP7zsc7/ktiTFbIYmJYTUbt1AMUCkLSOTWZCRbEGy1iJtOpmzNRLxo=';
const ecdsaFp = 'SHA256:tgJ9iBaR2ssQWPRY8tcCj0QyXY2boMmGgVJ4rcDG1h4';
const rsa =
    'AAAAB3NzaC1yc2EAAAADAQABAAABAQDd7qejZCFffQx1bhUo/KZEwmVgbq6eP3tMN++NWCVWd8TU3KuoZnkxwQiTFT8/76wq/gmMtdkobd4s05o63+tes5+nkvpWCDiqwE7wLkLilN5QWIkgj497DOUHTweArgev3YLq+UCocuOZsX/sw55oIzBvogoVetKSbLHD8GdTqnpeAsEF8oCUI9RaEuIdAENj9GNvCm4hWm+GNWGQGPHhe7V3sJqq5u0yDS6U/cls1eK8oX1wQO8BnYYp6qnfeqrHp7qCeItoYI+frv9KrlAXb9N0IJKFzcdFf7OPLoi+MyBE38viFeMFhV0zXGrNKRtYCvOmhB1N9k6ck6tSZJ0L';
const rsaFp = 'SHA256:iU6UTAUidWiQ8B0lqxEtZVZAudCjqiOhcJjBPSDbrf8';
const hashed22 = '|1|6nYpi5ghFy5SQkdHjyc9G+hSsBk=|5Ctjl+1ehJtF8ppl2axWtUlJrBw=';
const hashed2222 = '|1|5B03Y9zsBwsi8aOAnv6teWV8UAs=|hl7ZtUyXPYwK2v9nYhSdD0F5kJY=';

Uint8List _s(List<int> bytes) =>
    Uint8List.fromList([...(ByteData(4)..setUint32(0, bytes.length)).buffer.asUint8List(), ...bytes]);
Uint8List _t(String text) => _s(utf8.encode(text));
String _b64(List<Uint8List> parts) => base64.encode([for (final p in parts) ...p]);

/// A well-formed Ed25519 key that differs with [seed].
String _ed(int seed) => _b64([_t('ssh-ed25519'), _s(List.filled(32, seed))]);

String _fp(String data) => HostKeyCodec.inspect('ssh-ed25519', data)!.fingerprint;

class _Save implements ConnectPrompts {
  @override
  Future<TrustChoice> hostKey(HostKeyPrompt prompt) async => TrustChoice.save;
  @override
  Future<SecretAnswer?> secret(SecretRequest request) async => null;
}

void main() {
  group('parser', () {
    test('plain names, ports and aliases', () {
      final file = parseKnownHosts(
        'Host.Example.org,10.0.0.5 ssh-ed25519 $ed\n[box.example.org]:2222 ssh-rsa $rsa comment\n',
      );
      expect(file.issues, isEmpty);
      expect(
        [for (final n in file.records[0].names) (n as PlainName).endpoint],
        ['host.example.org:22', '10.0.0.5:22'],
      );
      expect((file.records[1].names.single as PlainName).endpoint, 'box.example.org:2222');
      expect(file.records[1].keyType, 'ssh-rsa');
      expect(file.records[1].line, 2);
    });

    test('IPv6 with and without brackets, tabs, CRLF and a byte order mark', () {
      final file = parseKnownHosts('\uFEFF::1\tssh-ed25519\t$ed\r\n[fe80::2]:2200 ssh-ed25519 $ed\r\n');
      expect(file.issues, isEmpty);
      expect((file.records[0].names.single as PlainName).endpoint, '[::1]:22');
      expect((file.records[1].names.single as PlainName).endpoint, '[fe80::2]:2200');
    });

    test('comments and blank lines are not reported', () {
      final file = parseKnownHosts('# a comment\n\n   \n  # indented\n');
      expect(file.records, isEmpty);
      expect(file.issues, isEmpty);
    });

    test('markers are reported and never become records', () {
      final file = parseKnownHosts(
        '@revoked h ssh-ed25519 $ed\n@cert-authority *.example.org ssh-ed25519 $ed\n@other h ssh-ed25519 $ed\n',
      );
      expect(file.records, isEmpty);
      expect(
        [for (final i in file.issues) (i.line, i.kind, i.detail)],
        [
          (1, KnownHostsIssue.marker, '@revoked'),
          (2, KnownHostsIssue.marker, '@cert-authority'),
          (3, KnownHostsIssue.marker, '@other'),
        ],
      );
    });

    test('wildcards are reported but a literal alias on the same line is kept', () {
      final file = parseKnownHosts('*.example.org,host.example.org,10.0.?.1 ssh-ed25519 $ed\n');
      expect(
        [for (final i in file.issues) (i.kind, i.detail)],
        [(KnownHostsIssue.wildcard, '*.example.org'), (KnownHostsIssue.wildcard, '10.0.?.1')],
      );
      expect((file.records.single.names.single as PlainName).endpoint, 'host.example.org:22');
    });

    test('a negated pattern makes the whole line unsupported', () {
      final file = parseKnownHosts('a.example.org,!b.example.org ssh-ed25519 $ed\n');
      expect(file.records, isEmpty);
      expect(file.issues.single.kind, KnownHostsIssue.negation);
    });

    test('unsupported key types, including SSH-1 lines, are reported', () {
      final file = parseKnownHosts('a ssh-dss AAAA\nb sk-ssh-ed25519@openssh.com AAAA\nc 2048 65537 12345\n');
      expect(file.records, isEmpty);
      expect(
        [for (final i in file.issues) (i.kind, i.detail)],
        [
          (KnownHostsIssue.keyType, 'ssh-dss'),
          (KnownHostsIssue.keyType, 'sk-ssh-ed25519@openssh.com'),
          (KnownHostsIssue.keyType, '2048'),
        ],
      );
    });

    test('malformed lines are reported with their number', () {
      final file = parseKnownHosts(
        'only-host\n'
        'h:99999x ssh-ed25519 $ed\n'
        '[h]:0 ssh-ed25519 $ed\n'
        '[h]:70000 ssh-ed25519 $ed\n'
        'abc:22 ssh-ed25519 $ed\n'
        'a,,b ssh-ed25519 $ed\n'
        '|1|AAAA|BBBB ssh-ed25519 $ed\n'
        '|2|6nYpi5ghFy5SQkdHjyc9G+hSsBk=|5Ctjl+1ehJtF8ppl2axWtUlJrBw= ssh-ed25519 $ed\n'
        '${'x' * 40000} ssh-ed25519 $ed\n',
      );
      expect(file.records, isEmpty);
      expect(
        [for (final i in file.issues) (i.line, i.kind)],
        [for (var n = 1; n <= 9; n++) (n, KnownHostsIssue.malformed)],
      );
    });

    test('hashed names carry salt and hash', () {
      final name = parseKnownHosts('$hashed22 ssh-ed25519 $ed\n').records.single.names.single as HashedName;
      expect(name.salt, hasLength(20));
      expect(name.hash, hasLength(20));
    });
  });

  group('host keys', () {
    test('fingerprints match ssh-keygen', () {
      expect(HostKeyCodec.inspect('ssh-ed25519', ed), (type: 'ssh-ed25519', fingerprint: edFp));
      expect(HostKeyCodec.inspect('ecdsa-sha2-nistp256', ecdsa), (type: 'ecdsa-sha2-nistp256', fingerprint: ecdsaFp));
      expect(HostKeyCodec.inspect('ssh-rsa', rsa), (type: 'ssh-rsa', fingerprint: rsaFp));
    });

    test('a key of another type than the line says is refused', () {
      expect(HostKeyCodec.inspect('ssh-rsa', ed), isNull);
      expect(HostKeyCodec.inspect('ssh-ed25519', rsa), isNull);
      expect(HostKeyCodec.inspect('ecdsa-sha2-nistp384', ecdsa), isNull);
    });

    test('malformed key data is refused', () {
      final blob = base64.decode(ed);
      expect(HostKeyCodec.inspect('ssh-ed25519', ''), isNull);
      expect(HostKeyCodec.inspect('ssh-ed25519', 'not base64!'), isNull);
      expect(HostKeyCodec.inspect('ssh-ed25519', base64.encode([...blob, 0])), isNull, reason: 'trailing bytes');
      expect(
        HostKeyCodec.inspect('ssh-ed25519', base64.encode(blob.sublist(0, blob.length - 1))),
        isNull,
        reason: 'truncated',
      );
      expect(
        HostKeyCodec.inspect('ecdsa-sha2-nistp256', ecdsa.substring(0, ecdsa.length - 1)),
        isNull,
        reason: 'unpadded',
      );
      expect(HostKeyCodec.inspect('ssh-ed25519', _b64([_t('ssh-ed25519'), _s(List.filled(31, 1))])), isNull);
      expect(HostKeyCodec.inspect('ssh-ed25519', base64.encode(List.filled(20000, 1))), isNull);
    });

    test('the ECDSA curve and point must agree with the key type', () {
      final point = Uint8List.fromList([4, ...List.filled(64, 7)]);
      expect(
        HostKeyCodec.inspect('ecdsa-sha2-nistp256', _b64([_t('ecdsa-sha2-nistp256'), _t('nistp256'), _s(point)])),
        isNotNull,
      );
      expect(
        HostKeyCodec.inspect('ecdsa-sha2-nistp256', _b64([_t('ecdsa-sha2-nistp256'), _t('nistp384'), _s(point)])),
        isNull,
      );
      expect(
        HostKeyCodec.inspect(
          'ecdsa-sha2-nistp256',
          _b64([_t('ecdsa-sha2-nistp256'), _t('nistp256'), _s(point.sublist(1))]),
        ),
        isNull,
      );
      expect(
        HostKeyCodec.inspect(
          'ecdsa-sha2-nistp256',
          _b64([
            _t('ecdsa-sha2-nistp256'),
            _t('nistp256'),
            _s([2, ...point.skip(1)]),
          ]),
        ),
        isNull,
      );
    });

    test('RSA numbers must be positive and sized', () {
      Uint8List n(int first) => _s([first, ...List.filled(255, 1)]);
      expect(
        HostKeyCodec.inspect(
          'ssh-rsa',
          _b64([
            _t('ssh-rsa'),
            _s([1, 0, 1]),
            n(0x7f),
          ]),
        ),
        isNotNull,
      );
      expect(
        HostKeyCodec.inspect(
          'ssh-rsa',
          _b64([
            _t('ssh-rsa'),
            _s([1, 0, 1]),
            n(0x80),
          ]),
        ),
        isNull,
        reason: 'negative',
      );
      expect(HostKeyCodec.inspect('ssh-rsa', _b64([_t('ssh-rsa'), _s([]), n(0x7f)])), isNull);
      expect(
        HostKeyCodec.inspect(
          'ssh-rsa',
          _b64([
            _t('ssh-rsa'),
            n(0x7f),
            _s([1, 0, 1]),
          ]),
        ),
        isNull,
        reason: 'exponent larger than modulus',
      );
    });

    test('hashed names are recognised only for the host they were made from', () {
      final one = parseKnownHosts('$hashed22 ssh-ed25519 $ed\n').records.single.names.single as HashedName;
      final two = parseKnownHosts('$hashed2222 ssh-ed25519 $ed\n').records.single.names.single as HashedName;
      expect(HashedHostMatcher.matches(one.salt, one.hash, HashedHostMatcher.nameFor('example.org', 22)), isTrue);
      expect(HashedHostMatcher.matches(one.salt, one.hash, HashedHostMatcher.nameFor('example.org', 2222)), isFalse);
      expect(HashedHostMatcher.matches(one.salt, one.hash, HashedHostMatcher.nameFor('example.com', 22)), isFalse);
      expect(HashedHostMatcher.matches(two.salt, two.hash, HashedHostMatcher.nameFor('example.org', 2222)), isTrue);
      expect(HashedHostMatcher.matches(two.salt, two.hash, HashedHostMatcher.nameFor('example.org', 22)), isFalse);
    });
  });

  group('file', () {
    late Directory dir;
    setUp(() async => dir = await Directory.systemTemp.createTemp('sshairy-kh-'));
    tearDown(() => dir.delete(recursive: true));

    test('reads text, refuses a file over the cap, reports a missing one', () async {
      final small = File('${dir.path}/known_hosts')..writeAsStringSync('h ssh-ed25519 $ed\n');
      expect(((await readKnownHosts(small.path)) as Ok<String>).value, startsWith('h ssh-ed25519'));
      final big = File('${dir.path}/big')..writeAsBytesSync(Uint8List(knownHostsMaxBytes + 1));
      expect(((await readKnownHosts(big.path)) as Err<String>).error.code, 'knownHostsTooLarge');
      expect(((await readKnownHosts('${dir.path}/missing')) as Err<String>).error.code, 'knownHostsUnreadable');
    });
  });

  group('import', () {
    late Directory dir;
    late HostTrustService trust;

    KnownHostsImport importer([List<SavedEndpoint> saved = const []]) => KnownHostsImport(trust, () => saved);

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('sshairy-kh-');
      trust = HostTrustService(dir.path);
    });
    tearDown(() => dir.delete(recursive: true));

    test('previews new, known and conflicting keys, then adds only the new ones', () async {
      await trust.importKeys({
        'same.example.org:22': {'ssh-ed25519': edFp},
        'changed.example.org:22': {'ssh-ed25519': 'SHA256:saved'},
      });
      final use = importer();
      final preview = await use.preview(
        '# servers\n'
        'new.example.org,10.0.0.5 ssh-ed25519 $ed\n'
        'same.example.org ssh-ed25519 $ed\n'
        'changed.example.org ssh-ed25519 $ed\n'
        '[box.example.org]:2222 ecdsa-sha2-nistp256 $ecdsa\n'
        '@revoked old.example.org ssh-ed25519 $ed\n'
        '*.wild.example.org ssh-ed25519 $ed\n',
      );
      expect(
        [for (final a in preview.additions) a.endpoint],
        ['10.0.0.5:22', 'box.example.org:2222', 'new.example.org:22'],
      );
      expect([for (final a in preview.alreadyTrusted) a.endpoint], ['same.example.org:22']);
      expect(
        [for (final c in preview.conflicts) (c.endpoint, c.saved, c.fingerprint)],
        [('changed.example.org:22', 'SHA256:saved', edFp)],
      );
      expect(
        [for (final i in preview.issues) (i.line, i.kind)],
        [(6, KnownHostsIssue.marker), (7, KnownHostsIssue.wildcard)],
      );
      expect(
        trust.entries.keys,
        unorderedEquals(['same.example.org:22', 'changed.example.org:22']),
        reason: 'preview saves nothing',
      );

      final result = await use.commit(preview);
      expect((result.added, result.alreadyTrusted), (3, 0));
      expect(result.conflicts, isEmpty);
      expect(trust.entries['new.example.org:22'], {'ssh-ed25519': edFp});
      expect(trust.entries['10.0.0.5:22'], {'ssh-ed25519': edFp});
      expect(trust.entries['box.example.org:2222'], {'ecdsa-sha2-nistp256': ecdsaFp});
      expect(trust.entries['changed.example.org:22'], {
        'ssh-ed25519': 'SHA256:saved',
      }, reason: 'a saved key is never replaced');
      expect(HostTrustService(dir.path).entries, trust.entries, reason: 'persisted');
    });

    test('a file that disagrees with itself takes neither key; a repeated key is taken once', () async {
      final other = _ed(2);
      final preview = await importer().preview(
        'a ssh-ed25519 $ed\na ssh-ed25519 $other\nb ssh-ed25519 $ed\nb ssh-ed25519 $ed\n',
      );
      expect(
        [for (final c in preview.conflicts) (c.endpoint, c.line, c.saved)],
        [('a:22', 1, null), ('a:22', 2, null)],
      );
      expect([for (final a in preview.additions) (a.endpoint, a.line)], [('b:22', 3)]);
    });

    test('an RSA key matches a saved one under any signature name', () async {
      await trust.importKeys({
        'r:22': {'rsa-sha2-512': rsaFp},
        's:22': {'ssh-rsa': 'SHA256:other'},
      });
      final preview = await importer().preview('r ssh-rsa $rsa\ns ssh-rsa $rsa\n');
      expect([for (final a in preview.alreadyTrusted) a.endpoint], ['r:22']);
      expect([for (final c in preview.conflicts) (c.endpoint, c.saved)], [('s:22', 'SHA256:other')]);
    });

    test('a key of another type is new next to a saved one', () async {
      await trust.importKeys({
        'h:22': {'ssh-ed25519': edFp},
      });
      final preview = await importer().preview('h ssh-rsa $rsa\n');
      expect([for (final a in preview.additions) (a.endpoint, a.type)], [('h:22', 'ssh-rsa')]);
      await importer().commit(preview);
      expect(trust.entries['h:22'], {'ssh-ed25519': edFp, 'ssh-rsa': rsaFp});
    });

    test('hashed names import only for saved hosts', () async {
      final text = '$hashed22 ssh-ed25519 $ed\n$hashed2222 ssh-ed25519 $ed\n';
      final none = await importer().preview(text);
      expect(none.additions, isEmpty);
      expect(
        [for (final i in none.issues) (i.line, i.kind)],
        [(1, KnownHostsIssue.hashedUnmatched), (2, KnownHostsIssue.hashedUnmatched)],
      );

      final some = await importer([(address: 'Example.ORG', port: 22), (address: 'other.org', port: 2222)])
          .preview(text);
      expect([for (final a in some.additions) a.endpoint], ['example.org:22']);
      expect([for (final i in some.issues) i.line], [2]);

      final both = await importer([(address: 'example.org', port: 22), (address: 'example.org', port: 2222)])
          .preview(text);
      expect([for (final a in both.additions) a.endpoint], ['example.org:22', 'example.org:2222']);
    });

    test('keys that do not match their declared type are reported, not imported', () async {
      final preview = await importer().preview('a ssh-rsa $ed\nb ssh-ed25519 ${ed.substring(0, 20)}\n');
      expect(preview.additions, isEmpty);
      expect(
        [for (final i in preview.issues) (i.line, i.kind)],
        [(1, KnownHostsIssue.badKey), (2, KnownHostsIssue.badKey)],
      );
    });

    test('a key saved after the preview is kept, and reported', () async {
      final use = importer();
      final preview = await use.preview('h ssh-ed25519 $ed\nk ssh-ed25519 $ed\n');
      await trust.importKeys({
        'h:22': {'ssh-ed25519': 'SHA256:later'},
        'k:22': {'ssh-ed25519': edFp},
      });
      final result = await use.commit(preview);
      expect((result.added, result.alreadyTrusted), (0, 1));
      expect([for (final c in result.conflicts) (c.endpoint, c.saved)], [('h:22', 'SHA256:later')]);
      expect(trust.entries['h:22'], {'ssh-ed25519': 'SHA256:later'});
    });
  });

  test('forgetting an endpoint invalidates an outstanding trust choice', () async {
    final dir = await Directory.systemTemp.createTemp('sshairy-stale-trust-');
    addTearDown(() => dir.delete(recursive: true));
    final trust = HostTrustService(dir.path);
    final prompts = _DelayedChoice();
    final verifying = trust.verify('h', 22, 'ssh-ed25519', edFp, prompts);
    await trust.forget('h:22');
    prompts.choice.complete(TrustChoice.save);
    expect(await verifying, isFalse);
    expect(trust.entries, isEmpty);
  });

  group('trust service', () {
    late Directory dir;
    setUp(() async => dir = await Directory.systemTemp.createTemp('sshairy-trust-'));
    tearDown(() => dir.delete(recursive: true));

    test('queued changes all land, in order, and are what a restart reads', () async {
      final trust = HostTrustService(dir.path);
      await Future.wait([
        for (var i = 0; i < 20; i++)
          trust.importKeys({
            'h$i:22': {'ssh-ed25519': _fp(_ed(i + 1))},
          }),
        trust.verify('v', 22, 'ssh-ed25519', edFp, _Save()),
        trust.forget('h3:22'),
        trust.importKeys({
          'h4:22': {'ssh-ed25519': 'SHA256:conflict'},
        }),
      ]);
      expect(trust.entries.keys, hasLength(20));
      expect(trust.entries.containsKey('h3:22'), isFalse);
      expect(trust.entries['v:22'], {'ssh-ed25519': edFp});
      expect(trust.entries['h4:22'], {'ssh-ed25519': _fp(_ed(5))});
      expect(HostTrustService(dir.path).entries, trust.entries);
    });

    test('a failed write leaves the visible state as it was', () async {
      final trust = HostTrustService('${dir.path}/gone');
      await expectLater(
        trust.importKeys({
          'h:22': {'ssh-ed25519': edFp},
        }),
        throwsA(isA<JsonFileError>()),
      );
      expect(trust.entries, isEmpty);
      Directory('${dir.path}/gone').createSync();
      expect(
        (await trust.importKeys({
          'h:22': {'ssh-ed25519': edFp},
        })).added,
        1,
        reason: 'the queue goes on after a failure',
      );
    });

    test('nothing is written when nothing is new', () async {
      final trust = HostTrustService(dir.path);
      final result = await trust.importKeys({
        'h:22': {'ssh-ed25519': edFp},
      });
      final file = File('${dir.path}/trust.json');
      final stamp = file.lastModifiedSync();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final again = await trust.importKeys({
        'h:22': {'ssh-ed25519': edFp},
      });
      expect((result.added, again.added, again.alreadyTrusted), (1, 0, 1));
      expect(file.lastModifiedSync(), stamp);
    });
  });
}

class _DelayedChoice implements ConnectPrompts {
  final choice = Completer<TrustChoice>();
  @override
  Future<TrustChoice> hostKey(HostKeyPrompt prompt) => choice.future;
  @override
  Future<SecretAnswer?> secret(SecretRequest request) async => null;
}

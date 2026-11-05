import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/features/connections/domain/known_keys.dart';

void main() {
  const endpoint = 'h:22';

  test('unknown key reports saved keys of other types', () {
    final keys = KnownKeys();
    expect((keys.check(endpoint, 'ed25519', 'A') as KeyUnknown).others, isEmpty);
    keys.trust(endpoint, 'rsa', 'R');
    expect((keys.check(endpoint, 'ed25519', 'A') as KeyUnknown).others, {'rsa': 'R'});
  });

  test('a saved key is trusted only with the same fingerprint', () {
    final keys = KnownKeys()..trust(endpoint, 'ed25519', 'A');
    expect(keys.check(endpoint, 'ed25519', 'A'), isA<KeyTrusted>());
    expect((keys.check(endpoint, 'ed25519', 'B') as KeyChanged).saved, 'A');
  });

  test('trust is per port', () {
    final keys = KnownKeys()..trust(KnownKeys.endpoint('H', 22), 'ed25519', 'A');
    expect(keys.check(KnownKeys.endpoint('h', 22), 'ed25519', 'A'), isA<KeyTrusted>());
    expect(keys.check(KnownKeys.endpoint('h', 2222), 'ed25519', 'A'), isA<KeyUnknown>());
  });

  test('IPv6 endpoints are bracketed', () {
    expect(KnownKeys.endpoint('::1', 22), '[::1]:22');
  });
}

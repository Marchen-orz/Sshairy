import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/features/settings/api.dart';

void main() {
  test('translation configs round-trip exact public fields', () {
    for (final config in [
      const TranslationConfig(),
      const TranslationConfig(myMemoryEmail: 'translator+desktop@example.com'),
      const TranslationConfig(provider: TranslationProvider.deepL, deepLFree: false),
      const TranslationConfig(provider: TranslationProvider.google),
      const TranslationConfig(provider: TranslationProvider.microsoft, region: 'eastus'),
      const TranslationConfig(
        provider: TranslationProvider.openAi,
        endpoint: 'https://example.com/v1',
        model: 'gpt-4.1-mini',
      ),
    ]) {
      expect(config.isValid, isTrue);
      expect(TranslationConfig.fromJson(config.toJson()).toJson(), config.toJson());
    }
    final defaults = const TranslationConfig().toJson();
    for (final invalid in [
      null,
      <String, Object?>{},
      {...defaults, 'key': 'secret'},
      {...defaults}..remove('region'),
      {...defaults, 'provider': 'other'},
      {...defaults, 'deepLFree': 'true'},
      {...defaults, 'endpoint': 'https://custom.example'},
      {...defaults, 'region': 'eastus'},
    ]) {
      expect(() => TranslationConfig.fromJson(invalid), throwsFormatException, reason: '$invalid');
    }
  });

  test('optional MyMemory email validates and old configurations load without it', () {
    final legacy = const TranslationConfig().toJson()..remove('myMemoryEmail');
    expect(TranslationConfig.fromJson(legacy).myMemoryEmail, isEmpty);
    for (final email in ['', 'person@example.com', 'desktop+ssh@example.co.uk', '${'x' * 64}@example.com']) {
      expect(TranslationConfig.validMyMemoryEmail(email), isTrue, reason: email);
      expect(TranslationConfig(myMemoryEmail: email).isValid, isTrue);
    }
    for (final email in [
      'no-domain',
      '@example.com',
      'a@',
      'a@localhost',
      'a@@example.com',
      ' a@example.com',
      'a@example.com\n',
      'a\u0000@example.com',
      '.a@example.com',
      'a.@example.com',
      'a..b@example.com',
      'a@-example.com',
      'a@example-.com',
      'a@ex_ample.com',
      'a@example..com',
      '中文@example.com',
      '${'x' * 65}@example.com',
      'a@${'x' * 64}.com',
    ]) {
      expect(TranslationConfig.validMyMemoryEmail(email), isFalse, reason: email);
      expect(() => TranslationConfig.fromJson({...legacy, 'myMemoryEmail': email}), throwsFormatException);
    }
    expect(TranslationConfig.validMyMemoryEmail('${'x' * 64}@${'d' * 63}.${'e' * 63}.${'f' * 62}'), isFalse);
    expect(() => TranslationConfig.fromJson({...legacy, 'myMemoryEmail': null}), throwsFormatException);
    for (final provider in TranslationProvider.values.where((p) => p != TranslationProvider.myMemory)) {
      expect(TranslationConfig(provider: provider, myMemoryEmail: 'person@example.com').isValid, isFalse);
    }
    expect(
      const TranslationConfig(myMemoryEmail: 'person@example.com').credentialId,
      const TranslationConfig().credentialId,
    );
  });

  test('custom endpoints require HTTPS except exact loopback HTTP', () {
    for (final endpoint in [
      'https://example.com/v1',
      'https://example.com:8443/v1',
      'https://example.com/中文',
      'http://localhost:8080/v1',
      'http://127.0.0.1:8080/v1',
      'http://[::1]:8080/v1',
    ]) {
      expect(TranslationConfig.validEndpoint(endpoint), isTrue, reason: endpoint);
    }
    for (final endpoint in [
      '',
      'http://example.com/v1',
      'http://localhost.example/v1',
      'http://127.0.0.2/v1',
      'http://[::ffff:127.0.0.1]/v1',
      'ftp://localhost/v1',
      'https:///v1',
      'https://user:password@example.com/v1',
      'https://@example.com/v1',
      'https://example.com/v1?key=secret',
      'https://example.com/v1?',
      'https://example.com/v1#fragment',
      'https://example.com/v1#',
      ' https://example.com/v1',
      'https://example.com/v1\n',
      'https://example.com/\u0085v1',
      'https://example.com/${String.fromCharCode(0x200b)}v1',
      'https://example.com/${String.fromCharCode(0x202e)}v1',
      'https://example.com/%0d%0a',
      'https://example.com/%C2%85',
      'https://example.com/%E2%80%8B',
      'https://example.com/%5cpath',
      r'https://example.com\path',
      'https://example.com/%zz',
      'https://example.com/%',
      'https://example.com/%FF',
      'https://example.com:0/v1',
      'https://example.com:65536/v1',
    ]) {
      expect(TranslationConfig.validEndpoint(endpoint), isFalse, reason: endpoint);
    }
  });

  test('canonical credential identities fit secure-storage bounds after URL expansion', () {
    const base = 'https://example.com/';
    final accepted = '$base${'x' * (2048 - 'openAi:'.length - base.length)}';
    expect(TranslationConfig.validEndpoint(accepted), isTrue);
    expect(
      TranslationConfig(provider: TranslationProvider.openAi, endpoint: accepted, model: 'x').credentialId.length,
      2048,
    );
    expect(TranslationConfig.validEndpoint('${accepted}x'), isFalse);
    expect(TranslationConfig.validEndpoint('$base${'中' * 230}'), isFalse);
  });

  test('credential identities bind the canonical endpoint and provider options', () {
    const first = TranslationConfig(
      provider: TranslationProvider.openAi,
      endpoint: 'https://EXAMPLE.com:443/a/../v1/',
      model: 'first',
    );
    const equivalent = TranslationConfig(
      provider: TranslationProvider.openAi,
      endpoint: 'https://example.com/v1',
      model: 'second',
    );
    expect(first.canonicalEndpoint, 'https://example.com/v1');
    expect(first.credentialId, equivalent.credentialId);
    for (final endpoint in ['https://other.example/v1', 'https://example.com/v2', 'https://example.com:8443/v1']) {
      expect(
        TranslationConfig(provider: TranslationProvider.openAi, endpoint: endpoint, model: 'first').credentialId,
        isNot(first.credentialId),
      );
    }
    expect(
      const TranslationConfig(provider: TranslationProvider.deepL).credentialId,
      isNot(const TranslationConfig(provider: TranslationProvider.deepL, deepLFree: false).credentialId),
    );
    expect(
      const TranslationConfig(provider: TranslationProvider.microsoft).credentialId,
      isNot(const TranslationConfig(provider: TranslationProvider.microsoft, region: 'eastus').credentialId),
    );
  });

  test('model and region inputs are bounded and provider-specific', () {
    expect(TranslationConfig.validModel('org/model:v1.2_3-4'), isTrue);
    expect(TranslationConfig.validModel('x' * 128), isTrue);
    expect(TranslationConfig.validModel('x' * 129), isFalse);
    expect(TranslationConfig.validModel('has spaces'), isFalse);
    expect(TranslationConfig.validModel('model\n'), isFalse);
    expect(TranslationConfig.validModel(''), isFalse);
    expect(TranslationConfig.validRegion(''), isTrue);
    expect(TranslationConfig.validRegion('east-us2'), isTrue);
    expect(TranslationConfig.validRegion('EASTUS'), isFalse);
    expect(TranslationConfig.validRegion('eastus\n'), isFalse);
    expect(TranslationConfig.validRegion('x' * 65), isFalse);
    expect(const TranslationConfig(provider: TranslationProvider.google, model: 'unused').isValid, isFalse);
  });
}

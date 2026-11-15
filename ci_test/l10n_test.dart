import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> _arb(String name) =>
    jsonDecode(File('lib/l10n/$name.arb').readAsStringSync()) as Map<String, Object?>;

/// Both locales must expose the same messages; the generated getters would otherwise differ
/// between languages or fall back to the template.
void main() {
  test('zh and en ARB files declare the same messages', () {
    final en = _arb('app_en');
    final zh = _arb('app_zh');
    final enKeys = en.keys.where((key) => !key.startsWith('@')).toSet();
    final zhKeys = zh.keys.where((key) => !key.startsWith('@')).toSet();
    expect(zhKeys.difference(enKeys), isEmpty, reason: 'zh-only messages');
    expect(enKeys.difference(zhKeys), isEmpty, reason: 'missing zh messages');
    for (final key in enKeys) {
      final value = zh[key];
      expect(value, isA<String>(), reason: key);
      expect((value! as String).trim(), isNotEmpty, reason: key);
    }
  });

  test('the template metadata does not describe unknown messages', () {
    final en = _arb('app_en');
    for (final key in en.keys.where((key) => key.startsWith('@') && key != '@@locale')) {
      expect(en.containsKey(key.substring(1)), isTrue, reason: key);
    }
  });
}

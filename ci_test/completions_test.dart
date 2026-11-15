import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The completion database is generated once and shipped verbatim; a stale manifest would
/// silently disable commands or ship unreferenced megabytes.
void main() {
  test('every completion spec is referenced and every reference exists', () {
    final manifest = jsonDecode(File('assets/completions/manifest.json').readAsStringSync()) as Map<String, Object?>;
    final files = Directory('assets/completions/specs')
        .listSync()
        .whereType<File>()
        .map((file) => file.uri.pathSegments.last)
        .toSet();
    final referenced = <String>{};
    for (final group in ['commands', 'nested']) {
      final entries = manifest[group]! as Map<String, Object?>;
      for (final value in entries.values) {
        if (value is String && value.endsWith('.json')) {
          referenced.add(value.split('/').last);
        }
      }
    }
    expect(referenced.difference(files), isEmpty, reason: 'manifest references missing specs');
    expect(files.difference(referenced), isEmpty, reason: 'unreferenced specs');
    expect((manifest['stats']! as Map<String, Object?>)['assets'], files.length);
  });

  test('the imported database keeps its upstream license', () {
    final license = File('assets/completions/LICENSE');
    expect(license.existsSync(), isTrue);
    expect(license.readAsStringSync(), isNotEmpty);
  });
}

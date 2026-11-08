import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/features/terminal/adapters/completion_specs.dart';
import 'package:sshairy/features/terminal/domain/spec_completion.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('every packaged static specification decodes and every indexed asset exists', () {
    final index = jsonDecode(File('assets/completions/manifest.json').readAsStringSync()) as Map;
    final paths = <String>{
      ...Map<String, String>.from(index['commands']).values,
      ...Map<String, String>.from(index['nested']).values,
    };
    expect((index['commands'] as Map).length, greaterThan(700));
    expect(paths.length, greaterThan(1000));
    final invalid = <String>[];
    for (final path in paths) {
      final file = File(path);
      expect(file.existsSync(), isTrue, reason: path);
      try {
        CompletionSpec.fromJson(jsonDecode(file.readAsStringSync()));
      } on Object catch (error) {
        invalid.add('$path: $error');
      }
    }
    expect(invalid, isEmpty);
  });

  test('packaged common tools provide complete option lists and nested subcommands', () async {
    final specs = CompletionSpecs();
    for (final draft in ['git commit -', 'tmux ', 'docker run -', 'curl -', 'ssh -', 'kubectl get -']) {
      final value = await specs.complete(draft);
      expect(value.available, isTrue, reason: draft);
      expect(value.result.suggestions.length, greaterThan(8), reason: draft);
      for (final item in value.result.suggestions.where((item) => item.isAppendOnly)) {
        expect(item.applyTo(draft).startsWith(draft), isTrue);
      }
    }
    final nested = await specs.complete('aws s3 cp -');
    expect(nested.result.suggestions.map((item) => item.display), contains('--recursive'));
    final paths = await specs.complete('cat ');
    expect(paths.result.path, isNotNull);
  });
}

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

  test('packaged filesystem tools request paths even before the first name is typed', () async {
    final specs = CompletionSpecs();
    for (final (draft, foldersOnly) in <(String, bool)>[
      ('cd ', true),
      ('cd "', true),
      ("cd '", true),
      ('ls ', false),
      ('ls -la ', false),
      ('cat ', false),
      ('cp ', false),
      ('cp first.txt ', false),
      ('mv first.txt ', false),
      ('rm -rf ', false),
      ('sudo cd ', true),
      ('sudo -u root cat ', false),
      ('tar --file=', false),
      ('tar -f ', false),
      ('tar -x --file=', false),
      ('tar --extract --file=', false),
      ('tar -xzf ', false),
      ('tar -czf ', false),
      ('tar c -f ', false),
      ('tar -x -C ', true),
      ('ssh -i ', false),
      ('ssh -F ', false),
      ('scp -i ', false),
      ('scp -F ', false),
    ]) {
      final completed = await specs.complete(draft);
      final request = completed.result.path;
      expect(completed.available, isTrue, reason: draft);
      expect(request, isNotNull, reason: draft);
      expect(request!.typedPrefix, '', reason: draft);
      expect(request.foldersOnly, foldersOnly, reason: draft);
      final suggestions = request.resolve(const [
        CompletionPathEntry('My Docs', isDirectory: true),
        CompletionPathEntry("it's \$5.tar"),
      ]);
      expect(suggestions, isNotEmpty, reason: draft);
      for (final suggestion in suggestions) {
        expect(suggestion.isAppendOnly, isTrue, reason: draft);
        expect(suggestion.applyTo(draft), '$draft${suggestion.suffix}', reason: draft);
        expect(CompletionContext.parse(suggestion.applyTo(draft)).current.value, suggestion.value, reason: draft);
      }
    }
    expect((await specs.complete('cd folder ')).result.path, isNull);
  });

  test('packaged untyped args only browse explicit paths and preserve attached prefixes', () async {
    final specs = CompletionSpecs();
    for (final (draft, typed, head) in <(String, String, String)>[
      ('scp ./My', './My', ''),
      ('scp host:/tmp/a ./My', './My', ''),
      ('ssh -I./My', './My', '-I'),
      ('tar -xzf./My', './My', '-xzf'),
      ('tar -x --file="./My', './My', '--file='),
      ('tar --file=./My', './My', '--file='),
    ]) {
      final request = (await specs.complete(draft)).result.path;
      expect(request, isNotNull, reason: draft);
      expect(request!.typedPrefix, typed, reason: draft);
      expect(request.tokenPrefix, head, reason: draft);
      final suggestion = request.resolve(const [CompletionPathEntry('My Archive.tar')]).single;
      expect(suggestion.isAppendOnly, isTrue, reason: draft);
      expect(suggestion.applyTo(draft), '$draft${suggestion.suffix}', reason: draft);
      expect(CompletionContext.parse(suggestion.applyTo(draft)).current.value, '$head./My Archive.tar', reason: draft);
    }
    for (final draft in [
      'ssh ',
      'ssh -p ',
      'ssh -l ',
      'sudo -u ',
      'git switch ',
      'docker exec ',
      'scp ',
      'scp host:/tmp/',
      'scp scp://host/tmp/',
      'tar -xzf archive.tar ',
      'tar --unknown ./',
      'cat > ',
    ]) {
      expect((await specs.complete(draft)).result.path, isNull, reason: draft);
    }
  });

  test('wrapped command names share root descriptions and browsing metadata', () async {
    final specs = CompletionSpecs();
    final git = (await specs.complete('sudo gi')).result.suggestions.singleWhere((item) => item.value == 'git');
    expect(git.kind, SpecSuggestionKind.command);
    expect(git.canBrowse, isTrue);
    expect(git.description, isNotEmpty);
    final cd = (await specs.complete('sudo c')).result.suggestions.singleWhere((item) => item.value == 'cd');
    expect(cd.canBrowse, isTrue);
    final dd = (await specs.complete('sudo d')).result.suggestions.singleWhere((item) => item.value == 'dd');
    expect(dd.canBrowse, isFalse);
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

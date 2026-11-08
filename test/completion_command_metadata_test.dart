import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/features/terminal/domain/command_assistance.dart';
import 'package:sshairy/features/terminal/domain/completion_command_metadata.dart';
import 'package:sshairy/features/terminal/domain/completion_spec.dart';
import 'package:sshairy/features/terminal/presentation/completion_descriptions.dart';

void main() {
  test('root metadata matches every packaged command and alias without loading nested specs', () {
    final manifest = jsonDecode(File('assets/completions/manifest.json').readAsStringSync()) as Map;
    final commands = Map<String, String>.from(manifest['commands']);
    expect(commands.length, greaterThan(700));
    for (final command in commands.entries) {
      final spec = CompletionSpec.fromJson(jsonDecode(File(command.value).readAsStringSync()));
      final metadata = completionCommandMetadata(command.key);
      expect(metadata, isNotNull, reason: command.key);
      expect(metadata!.description, spec.description, reason: command.key);
      expect(metadata.canBrowse, spec.canBrowse || spec.names.contains('cd'), reason: command.key);
    }
  });

  test('leaf roots keep their description but do not advertise a next level', () {
    final metadata = completionCommandMetadata('php')!;
    expect(metadata.description, isNotEmpty);
    expect(metadata.canBrowse, isFalse);
    expect(completionCommandMetadata('mask')!.description, isNull);
    expect(completionCommandMetadata('mask')!.canBrowse, isFalse);
    expect(completionCommandMetadata('dd')!.canBrowse, isFalse);
    expect(completionCommandMetadata('export')!.canBrowse, isFalse);
    expect(completionCommandMetadata('defaultbrowser')!.canBrowse, isFalse);
    expect(completionCommandMetadata('git')!.canBrowse, isTrue);
    expect(completionCommandMetadata('ls')!.canBrowse, isTrue);
    expect(completionCommandMetadata('cd')!.canBrowse, isTrue);
  });

  test('aliases receive the same root metadata and unknown commands have no hints', () {
    final manifest = jsonDecode(File('assets/completions/manifest.json').readAsStringSync()) as Map;
    final commands = Map<String, String>.from(manifest['commands']);
    final firstByPath = <String, String>{};
    var aliases = 0;
    for (final command in commands.entries) {
      final first = firstByPath[command.value];
      if (first == null) {
        firstByPath[command.value] = command.key;
      } else {
        aliases++;
        final metadata = completionCommandMetadata(command.key)!;
        final canonical = completionCommandMetadata(first)!;
        expect(metadata.description, canonical.description, reason: command.key);
        expect(metadata.canBrowse, canonical.canBrowse, reason: command.key);
      }
    }
    expect(aliases, greaterThan(0));
    expect(completionCommandMetadata('not-a-packaged-command'), isNull);
    expect(completionCommandMetadata('GIT'), isNull);
    expect(completionCommandMetadata('git status'), isNull);
  });

  test('root explanations use the same offline locale translation as other candidates', () {
    final metadata = completionCommandMetadata('git')!;
    final candidate = CommandCandidate(
      'git',
      source: CommandCandidateSource.builtin,
      kind: CommandKind.command,
      detail: metadata.description,
    );
    expect(translatedCompletionDescription('zh', candidate), '分布式版本控制工具');
    expect(translatedCompletionDescription('en', candidate), 'Distributed version control system');
  });
}

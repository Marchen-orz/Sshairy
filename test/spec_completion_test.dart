import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/features/terminal/domain/spec_completion.dart';

CompletionSpec spec(String json) => CompletionSpec.fromJson(jsonDecode(json));

CompletionContext parse(String draft) => CompletionContext.parse(draft);

SpecCompletionResult complete(CompletionSpec? s, String draft, {SpecCompletionConfig? config}) =>
    completeSpec(s, draft, config: config ?? const SpecCompletionConfig());

List<String> values(SpecCompletionResult r) => [for (final s in r.suggestions) s.value];

List<String> labels(SpecCompletionResult r) => [for (final s in r.suggestions) s.display];

// Small specs written for these tests, in the shape of docs/COMPLETION_SPECS.md.
final git = spec(r'''
{
  "name": "git",
  "options": [
    {"name": "-C", "args": {"name": "path", "template": "folders"}, "isRepeatable": true},
    {"name": "--no-pager", "isPersistent": true},
    {"name": "--version"}
  ],
  "subcommands": [
    {"name": "checkout", "description": "Switch branches",
     "options": [{"name": "-b", "args": {"name": "branch"}}],
     "args": {"name": "branch", "isOptional": true, "suggestions": ["main", "develop"]}},
    {"name": ["commit", "ci"], "description": "Record changes",
     "options": [
       {"name": ["-m", "--message"], "args": {"name": "msg"}, "isRepeatable": true},
       {"name": ["-a", "--all"]},
       {"name": "--amend"},
       {"name": ["-v", "--verbose"], "exclusiveOn": ["--quiet"]},
       {"name": ["-q", "--quiet"], "exclusiveOn": ["--verbose"]}
     ]},
    {"name": "remote", "subcommands": [
       {"name": "add", "args": [{"name": "name"}, {"name": "url"}]},
       {"name": "remove", "args": {"name": "name"}},
       {"name": "show"}
     ]},
    {"name": "add", "options": [{"name": ["-A", "--all"]}, {"name": "-p"}],
     "args": {"name": "pathspec", "isVariadic": true, "template": "filepaths"}}
  ]
}''');

final docker = spec(r'''
{
  "name": "docker",
  "options": [
    {"name": ["-H", "--host"], "args": {"name": "host"}, "isPersistent": true},
    {"name": ["-D", "--debug"]}
  ],
  "subcommands": [
    {"name": "compose",
     "options": [
       {"name": ["-f", "--file"], "args": {"name": "file", "template": "filepaths"},
        "isPersistent": true, "isRepeatable": true},
       {"name": ["-p", "--project-name"], "args": {"name": "name"}, "isPersistent": true}
     ],
     "subcommands": [
       {"name": "up", "options": [{"name": ["-d", "--detach"]}, {"name": "--build"}],
        "args": {"name": "service", "isOptional": true, "isVariadic": true,
                 "suggestions": [{"name": "web", "description": "frontend"}, "db"]}},
       {"name": "down", "options": [{"name": "--volumes"}]}
     ]},
    {"name": "ps"}
  ]
}''');

final curl = spec(r'''
{
  "name": "curl",
  "options": [
    {"name": ["-o", "--output"], "args": {"name": "file", "template": "filepaths"}},
    {"name": ["-X", "--request"], "args": {"name": "method", "suggestions": ["GET", "POST", "PUT", "DELETE"]}},
    {"name": ["-H", "--header"], "args": {"name": "header"}, "isRepeatable": true},
    {"name": ["-L", "--location"]},
    {"name": ["-s", "--silent"]},
    {"name": ["-k", "--insecure"]},
    {"name": ["-I", "--head"]}
  ],
  "args": {"name": "url", "isVariadic": true}
}''');

final tar = spec(r'''
{
  "name": "tar",
  "options": [
    {"name": "-x"}, {"name": "-c"}, {"name": "-z"}, {"name": "-v"},
    {"name": ["-f", "--file"], "args": {"name": "archive", "template": "filepaths"}},
    {"name": ["-C", "--directory"], "args": {"name": "dir", "template": "folders"}}
  ],
  "args": {"name": "member", "isVariadic": true, "template": "filepaths"}
}''');

final mk = spec(r'''
{
  "name": "mk",
  "options": [
    {"name": "--color", "requiresSeparator": true,
     "args": {"name": "when", "suggestions": ["always", "never", "auto"]}},
    {"name": "--jobs", "args": {"name": "n"}}
  ]
}''');

final finder = spec(r'''
{
  "name": "find",
  "parserDirectives": {"flagsArePosixNoncompliant": true},
  "options": [
    {"name": "-name", "args": {"name": "pattern"}},
    {"name": "-type", "args": {"name": "t", "suggestions": ["f", "d"]}},
    {"name": "-print"}
  ],
  "args": {"name": "path", "isVariadic": true, "template": "folders"}
}''');

final run = spec(r'''
{
  "name": "run",
  "parserDirectives": {"optionsMustPrecedeArguments": true},
  "options": [{"name": "-v"}],
  "args": {"name": "cmd", "isVariadic": true, "suggestions": ["x"]}
}''');

final cd = spec(r'{"name": "cd", "args": {"name": "dir", "isOptional": true, "template": "folders"}}');

final cat = spec(r'{"name": "cat", "args": {"name": "file", "isVariadic": true, "template": "filepaths"}}');

final say = spec(r'''{"name": "say", "args": {"name": "w", "isVariadic": true, "suggestions": ["it's", "a b"]}}''');

final sudo = spec(r'''
{
  "name": "sudo",
  "options": [{"name": ["-u", "--user"], "args": {"name": "user"}}, {"name": "-E"}],
  "args": {"name": "command", "isCommand": true}
}''');

void main() {
  group('parser', () {
    test('splits words and keeps the raw range of the last one', () {
      const draft = 'git commit -m "hello world" --am';
      final c = parse(draft);
      expect(c.supported, isTrue);
      expect([for (final w in c.words) w.value], ['git', 'commit', '-m', 'hello world']);
      final quoted = c.words.last;
      expect(quoted.raw, '"hello world"');
      expect(quoted.start, draft.indexOf('"'));
      expect(quoted.end, draft.indexOf('" --') + 1);
      expect(c.current.raw, '--am');
      expect(c.current.start, draft.indexOf('--am'));
      expect((c.replaceStart, c.replaceEnd), (draft.indexOf('--am'), draft.length));
      expect(c.quote, CompletionQuote.none);
    });

    test('an empty last word after a space, and an empty draft', () {
      final c = parse('git ');
      expect([for (final w in c.words) w.value], ['git']);
      expect(c.current.raw, '');
      expect((c.current.start, c.current.end), (4, 4));
      final empty = parse('');
      expect(empty.words, isEmpty);
      expect(empty.current.start, 0);
      expect(empty.supported, isTrue);
    });

    test('escapes, quotes and mixed quoting', () {
      expect(parse(r'cat My\ File.txt').current.value, 'My File.txt');
      expect(parse(r'cat My\ File.txt').current.raw, r'My\ File.txt');
      expect(parse("echo 'a \"b\" c'").current.value, 'a "b" c');
      expect(parse(r'echo "a\"b\\c\d"').current.value, r'a"b\c\d');
      expect(parse('echo a"b c"d').current.value, 'ab cd');
      final words = parse("echo '' x").words;
      expect(words[1].raw, "''");
      expect(words[1].value, '');
      expect(parse('git\tcommit').words.single.value, 'git');
    });

    test('open quotes belong to the last word', () {
      final d = parse('cd "My Do');
      expect((d.current.value, d.current.raw, d.quote), ('My Do', '"My Do', CompletionQuote.double));
      expect(parse("cd 'My Do").quote, CompletionQuote.single);
      final closed = parse('cd "My Do"');
      expect((closed.current.raw, closed.quote), ('"My Do"', CompletionQuote.none));
    });

    test('maps value offsets back to raw offsets', () {
      final t = parse('--file="my doc').current;
      expect(t.value, '--file=my doc');
      expect(t.rawOffsetAfter(0), 0);
      expect(t.rawOffsetAfter(7), 7);
      expect(t.rawOffsetAfter(8), 9);
      expect(t.rawOffsetAfter(99), t.raw.length);
      expect(parse(r'a\ b').current.rawOffsetAfter(2), 3);
    });

    test('whatever the shell would expand, chain or redirect is unsupported', () {
      const cases = {
        'git commit && git ch': CompletionIssue.operator,
        'git add a | b': CompletionIssue.operator,
        'git add a > b': CompletionIssue.operator,
        'git add a; x': CompletionIssue.operator,
        'git add a &': CompletionIssue.operator,
        r'git add $HOME/': CompletionIssue.substitution,
        'git add `ls`': CompletionIssue.substitution,
        r'git add "a$b"': CompletionIssue.substitution,
        'git add *.dart': CompletionIssue.expansion,
        'git add a?': CompletionIssue.expansion,
        'git add {a,b}': CompletionIssue.expansion,
        'git add [ab]': CompletionIssue.expansion,
        'git add !!': CompletionIssue.expansion,
        'git add "a!"': CompletionIssue.expansion,
        'git add # c': CompletionIssue.expansion,
        'git add foo\\': CompletionIssue.danglingEscape,
        'git add "a\\': CompletionIssue.danglingEscape,
        'git commit\n': CompletionIssue.control,
        'git add \u0000': CompletionIssue.control,
        'git add \u007f': CompletionIssue.control,
      };
      cases.forEach((draft, issue) {
        final c = parse(draft);
        expect(c.issue, issue, reason: draft);
        expect(c.supported, isFalse, reason: draft);
        expect(c.words, isEmpty, reason: draft);
      });
      expect(parse('a' * 5000).issue, CompletionIssue.tooLong);
    });

    test('quoted and escaped syntax is plain text', () {
      for (final draft in [
        r"git add '$HOME'",
        "git add 'a|b'",
        "git add '*'",
        'git add "a b"',
        'git add a#b',
        'git add ~/x',
        r'git add a\$b',
        r'git add a\*',
        'git add --file=a:b,c@d%e+f',
      ]) {
        expect(parse(draft).supported, isTrue, reason: draft);
      }
    });

    test('encodes a suffix for the quote state it is appended in', () {
      expect(encodeShellSuffix('a b', CompletionQuote.none), r'a\ b');
      expect(encodeShellSuffix(r'$x&y', CompletionQuote.none), r'\$x\&y');
      expect(encodeShellSuffix('文 档', CompletionQuote.none), r'文\ 档');
      expect(encodeShellSuffix('~x', CompletionQuote.none, atWordStart: true), r'\~x');
      expect(encodeShellSuffix('~x', CompletionQuote.none), '~x');
      expect(encodeShellSuffix('#x', CompletionQuote.none, atWordStart: true), r'\#x');
      expect(encodeShellSuffix(r'a"b$c`d\e!f', CompletionQuote.double), r'a\"b\$c\`d\\e"\!"f');
      expect(encodeShellSuffix("it's", CompletionQuote.single), r"it'\''s");
      expect(encodeShellSuffix('x', CompletionQuote.double, close: true), 'x"');
      expect(encodeShellSuffix('x', CompletionQuote.single, close: true), "x'");
      expect(encodeShellSuffix('x', CompletionQuote.none, close: true), 'x');
      expect(encodeShellWord('a b', CompletionQuote.double), '"a b"');
      expect(encodeShellWord('a b', CompletionQuote.none), r'a\ b');
      expect(completionValueValid('a b'), isTrue);
      expect(completionValueValid('a\nb'), isFalse);
      expect(completionValueValid(''), isFalse);
    });
  });

  group('spec json', () {
    test('names, aliases, args as object or list, static choices, templates', () {
      final s = CompletionSpec.fromJson({
        'name': ['tool', 't'],
        'description': 'd',
        'args': {
          'name': 'x',
          'suggestions': [
            'a',
            {
              'name': ['b', 'c'],
              'description': 'bc',
            },
            {'name': 'd', 'insertValue': 'dd{cursor}'},
            {'name': 'h', 'hidden': true},
          ],
          'template': ['filepaths', 'history', 'help'],
        },
        'options': [
          {
            'name': ['-v', '--verbose'],
            'args': [
              {'name': 'a'},
              {'name': 'b', 'isOptional': true},
            ],
          },
        ],
        'icon': 'ignored',
        'generators': <String, Object?>{},
      });
      expect(s.names, ['tool', 't']);
      expect(s.name, 'tool');
      final arg = s.args.single;
      expect([for (final c in arg.choices) c.value], ['a', 'b', 'c', 'd']);
      expect(arg.choices[1].description, 'bc');
      expect(arg.choices.last.insertValue, 'dd');
      expect(arg.templates, {CompletionTemplate.filepaths, CompletionTemplate.history});
      final option = s.options.single;
      expect(option.names, ['-v', '--verbose']);
      expect(option.args, hasLength(2));
      expect(option.args[1].isOptional, isTrue);
    });

    test('option flags', () {
      CompletionOption option(Map<String, Object?> json) => CompletionOption.fromJson({'name': '-x', ...json});
      expect(option({}).maxUses, 1);
      expect(option({'isRepeatable': false}).maxUses, 1);
      expect(option({'isRepeatable': true}).maxUses, isNull);
      expect(option({'isRepeatable': 3}).maxUses, 3);
      expect(option({}).separator, isNull);
      expect(option({'requiresSeparator': true}).separator, '=');
      expect(option({'requiresSeparator': ':'}).separator, ':');
      expect(option({'requiresEquals': true}).separator, '=');
      final o = option({
        'isPersistent': true,
        'isRequired': true,
        'exclusiveOn': ['-a'],
        'dependsOn': ['-b', '-c'],
        'hidden': true,
        'priority': 80,
      });
      expect(o.isPersistent, isTrue);
      expect(o.isRequired, isTrue);
      expect(o.exclusiveOn, ['-a']);
      expect(o.dependsOn, ['-b', '-c']);
      expect(o.hidden, isTrue);
      expect(o.priority, 80);
    });

    test('parser directives and loadSpec', () {
      final s = CompletionSpec.fromJson({
        'name': 'f',
        'parserDirectives': {
          'flagsArePosixNoncompliant': true,
          'optionArgSeparators': [':', '='],
        },
        'loadSpec': 'f/more',
      });
      expect(s.directives.flagsArePosixNoncompliant, isTrue);
      expect(s.directives.optionsMustPrecedeArguments, isFalse);
      expect(s.directives.optionArgSeparators, [':', '=']);
      expect(s.loadSpec, 'f/more');
      expect(s.hasContent, isFalse);
      final single = CompletionSpec.fromJson({
        'name': 'g',
        'parserDirectives': {'optionArgSeparators': ':'},
      });
      expect(single.directives.optionArgSeparators, [':']);
      expect(CompletionSpec.fromJson({'name': 'h'}).directives.optionArgSeparators, ['=']);
    });

    test('a loaded spec is merged after the node itself', () {
      final base = CompletionSpec(
        ['aws'],
        loadSpec: 'aws/ec2',
        subcommands: [
          const CompletionSpec(['own']),
        ],
      );
      final merged = base.withLoaded(
        const CompletionSpec(
          ['ec2'],
          description: 'compute',
          subcommands: [
            CompletionSpec(['run']),
          ],
          options: [
            CompletionOption(['-v']),
          ],
        ),
      );
      expect([for (final s in merged.subcommands) s.name], ['own', 'run']);
      expect(merged.names, ['aws']);
      expect(merged.description, 'compute');
      expect(merged.options, hasLength(1));
      expect(merged.loadSpec, isNull);
    });

    test('bad data is a FormatException, never a half-read spec', () {
      expect(() => CompletionSpec.fromJson(5), throwsFormatException);
      expect(() => CompletionSpec.fromJson({'name': 5}), throwsFormatException);
      expect(() => CompletionSpec.fromJson({'name': ''}), throwsFormatException);
      expect(
        CompletionSpec.fromJson({
          'name': 'x',
          'options': [
            {'name': 'v'},
          ],
        }).options,
        isEmpty,
      );
      expect(
        () => CompletionSpec.fromJson({
          'name': 'x',
          'options': {'name': '-v'},
        }),
        throwsFormatException,
      );
      expect(
        () => CompletionSpec.fromJson({
          'name': 'x',
          'args': {'isOptional': 'yes'},
        }),
        throwsFormatException,
      );
      expect(CompletionSpec.tryParse({'description': 'no name'}), isNull);
      expect(CompletionSpec.tryParse('nope'), isNull);
      expect(CompletionSpec.tryParse({'name': 'ok'}), isNotNull);
      Object? deep = {'name': 'leaf'};
      for (var i = 0; i < 40; i++) {
        deep = {
          'name': 'n$i',
          'subcommands': [deep],
        };
      }
      expect(CompletionSpec.tryParse(deep), isNull);
    });
  });

  group('subcommands and options', () {
    test('git: a nested subcommand with its replacement range', () {
      final r = complete(git, 'git re');
      expect(values(r), ['remote']);
      final s = r.suggestions.single;
      expect(
        (s.kind, s.display, s.replaceStart, s.replaceEnd, s.replacement, s.suffix, s.appendSpace),
        (SpecSuggestionKind.subcommand, 'remote', 4, 6, 'remote', 'mote', true),
      );
      expect(s.isAppendOnly, isTrue);
      expect(s.applyTo('git re'), 'git remote');
      expect(values(complete(git, 'git remote ')), ['add', 'remove', 'show']);
      expect(values(complete(git, 'git remote a')), ['add']);
      expect(complete(git, 'git remote add ').isEmpty, isTrue);
    });

    test('git: canonical names for an empty word, aliases once typing', () {
      expect(values(complete(git, 'git ')), ['checkout', 'commit', 'remote', 'add']);
      expect(values(complete(git, 'git c')), ['checkout', 'commit', 'ci']);
      expect(values(complete(git, 'git ci')), isEmpty);
      expect(complete(git, 'git checkout').suggestions, isEmpty);
    });

    test('git: aliases resolve; only the node and persistent ancestor options apply', () {
      final r = complete(git, 'git ci -');
      expect(values(r), [
        '-m',
        '--message',
        '-a',
        '--all',
        '--amend',
        '-v',
        '--verbose',
        '-q',
        '--quiet',
        '--no-pager',
      ]);
      expect(r.suggestions.every((s) => s.kind == SpecSuggestionKind.option), isTrue);
      expect(values(complete(git, 'git ci --me')), ['--message']);
    });

    test('options are not offered for an empty word unless asked', () {
      expect(complete(git, 'git commit ').isEmpty, isTrue);
      final r = complete(git, 'git commit ', config: const SpecCompletionConfig(includeOptionsForEmptyToken: true));
      expect(values(r), ['-m', '-a', '--amend', '-v', '-q', '--no-pager']);
    });

    test('a flag is not offered again unless repeatable', () {
      expect(values(complete(git, 'git commit -a -')), [
        '-m',
        '--message',
        '--amend',
        '-v',
        '--verbose',
        '-q',
        '--quiet',
        '--no-pager',
      ]);
      expect(values(complete(git, 'git commit -m one -')), containsAll(['-m', '--message', '-a']));
      expect(values(complete(git, 'git commit --all -')), isNot(contains('-a')));
      expect(values(complete(git, 'git commit --all -')), isNot(contains('--all')));
    });

    test('exclusiveOn removes the other option', () {
      expect(values(complete(git, 'git commit -v -')), ['-m', '--message', '-a', '--all', '--amend', '--no-pager']);
    });

    test('dependsOn needs the other option first', () {
      final d = spec(r'''
      {"name": "d", "options": [{"name": "--base"}, {"name": "--extra", "dependsOn": ["--base"]}]}''');
      expect(values(complete(d, 'd -')), ['--base']);
      expect(values(complete(d, 'd --base -')), ['--extra']);
    });

    test('isRepeatable with a number is a limit', () {
      final r2 = spec(r'{"name": "r2", "options": [{"name": "-n", "isRepeatable": 2}]}');
      expect(values(complete(r2, 'r2 -')), ['-n']);
      expect(values(complete(r2, 'r2 -n -')), ['-n']);
      expect(values(complete(r2, 'r2 -n -n -')), isEmpty);
    });

    test('a persistent option keeps its use count below the node that declared it', () {
      expect(values(complete(git, 'git --no-pager commit --am')), ['--amend']);
      expect(values(complete(git, 'git --no-pager commit --no')), isEmpty);
      expect(values(complete(git, 'git commit --no')), ['--no-pager']);
    });

    test('an option value is consumed before the subcommand is looked for', () {
      expect(values(complete(git, 'git -C /tmp re')), ['remote']);
      final r = complete(git, 'git -C ');
      expect(r.suggestions, isEmpty);
      expect(r.path?.foldersOnly, isTrue);
    });

    test('docker compose: persistent options of every ancestor', () {
      expect(values(complete(docker, 'docker compose up -')), [
        '-d',
        '--detach',
        '--build',
        '-f',
        '--file',
        '-p',
        '--project-name',
        '-H',
        '--host',
      ]);
      expect(values(complete(docker, 'docker compose -f dc.yml up -')), containsAll(['-f', '--file', '--detach']));
      expect(values(complete(docker, 'docker -H tcp://x compose do')), ['down']);
      expect(values(complete(docker, 'docker compose ')), ['up', 'down']);
      expect(values(complete(docker, 'docker compose down --')), ['--volumes', '--file', '--project-name', '--host']);
    });

    test('docker compose: variadic positionals keep offering their suggestions', () {
      final r = complete(docker, 'docker compose up ');
      expect(values(r), ['web', 'db']);
      expect(r.suggestions.first.description, 'frontend');
      expect(r.suggestions.first.kind, SpecSuggestionKind.argument);
      expect(values(complete(docker, 'docker compose up web ')), ['web', 'db']);
      expect(values(complete(docker, 'docker compose up w')), ['web']);
    });

    test('an unknown subcommand, or past the positionals, suggests nothing', () {
      expect(complete(docker, 'docker nope ').isEmpty, isTrue);
      expect(complete(docker, 'docker nope -').isEmpty, isTrue);
      expect(complete(docker, 'docker ps ').isEmpty, isTrue);
      expect(complete(git, 'git remote add origin https://x ').isEmpty, isTrue);
      expect(complete(git, 'git remote remove a ').isEmpty, isTrue);
      expect(complete(git, 'git remote show ').isEmpty, isTrue);
    });

    test('an unknown option makes the next word uncertain; known forms stay certain', () {
      expect(values(complete(git, 'git checkout ')), ['main', 'develop']);
      expect(complete(git, 'git checkout --bogus ').isEmpty, isTrue);
      expect(complete(git, 'git checkout -z ').isEmpty, isTrue);
      expect(values(complete(git, 'git checkout --bogus=1 ')), ['main', 'develop']);
      expect(values(complete(git, 'git checkout -5 ')), ['main', 'develop']);
      expect(values(complete(git, 'git checkout --bogus --')), ['--no-pager']);
    });

    test('priority orders suggestions, required options come first, hidden ones stay out', () {
      final ranked = spec(r'''
      {"name": "r", "subcommands": [
        {"name": "low", "priority": 10}, {"name": "mid"}, {"name": "high", "priority": 90},
        {"name": "same"}, {"name": "secret", "hidden": true}],
       "additionalSuggestions": ["extra"],
       "options": [{"name": "--a"}, {"name": "--b", "isRequired": true},
                   {"name": "--c", "priority": 99}, {"name": "--z", "hidden": true}]}''');
      expect(values(complete(ranked, 'r ')), ['high', 'mid', 'same', 'extra', 'low']);
      expect(values(complete(ranked, 'r s')), ['same']);
      expect(values(complete(ranked, 'r -')), ['--b', '--c', '--a']);
      expect(complete(ranked, 'r secret ').isEmpty, isTrue);
    });

    test('display name and insert value of a spec', () {
      final s = spec(
        r'''
      {"name": "p", "subcommands": [{"name": "build", "displayName": "build (all)", "insertValue": "build -a{cursor}"}]}''',
      );
      final r = complete(s, 'p b');
      final x = r.suggestions.single;
      expect((x.value, x.display, x.suffix), ('build -a', 'build (all)', r'uild\ -a'));
      expect(x.replacement, 'build\\ -a');
    });
  });

  group('option values', () {
    test('short bundles: the last letter that takes a value waits for the next word', () {
      final r = complete(tar, 'tar -xzf ');
      expect(r.suggestions, isEmpty);
      expect(r.path?.foldersOnly, isFalse);
      expect(r.path?.tokenStart, 9);
      final after = complete(tar, 'tar -xzf a.tar ');
      expect(after.path?.typedPrefix, '');
      expect(after.path?.foldersOnly, isFalse);
      expect(complete(tar, 'tar -xzf a.tar -').suggestions.isNotEmpty, isTrue);
    });

    test('attached values: -Ipath and bundles', () {
      final p = complete(tar, 'tar -xzfarchive.t').path!;
      expect((p.typedPrefix, p.tokenStart, p.valueStart, p.tokenEnd), ('archive.t', 4, 8, 17));
      final dir = complete(tar, 'tar -C/tm').path!;
      expect((dir.typedPrefix, dir.foldersOnly, dir.valueStart), ('/tm', true, 6));
      expect(values(complete(curl, 'curl -XP')), ['-XPOST', '-XPUT']);
      expect(labels(complete(curl, 'curl -XP')), ['POST', 'PUT']);
    });

    test('option=value: a path after the separator', () {
      final p = complete(tar, 'tar --file=').path!;
      expect((p.typedPrefix, p.tokenValue, p.valueStart, p.tokenStart, p.tokenEnd), ('', '--file=', 11, 4, 11));
      final typed = complete(tar, 'tar --file=ba').path!;
      expect((typed.typedPrefix, typed.tokenPrefix, typed.valueStart), ('ba', '--file=', 11));
      final quoted = complete(tar, 'tar --file="my b').path!;
      expect((quoted.typedPrefix, quoted.valueStart, quoted.quote), ('my b', 11, CompletionQuote.double));
    });

    test('requiresSeparator: the name carries the = and the value must be attached', () {
      final name = complete(mk, 'mk --co').suggestions.single;
      expect((name.value, name.display, name.suffix, name.appendSpace), ('--color=', '--color=', 'lor=', false));
      final r = complete(mk, 'mk --color=a');
      expect(values(r), ['--color=always', '--color=auto']);
      expect(labels(r), ['always', 'auto']);
      expect(r.suggestions.first.suffix, 'lways');
      expect(r.suggestions.first.applyTo('mk --color=a'), 'mk --color=always');
      expect(complete(mk, 'mk --color ').isEmpty, isTrue);
      expect(complete(mk, 'mk --jobs ').isEmpty, isTrue);
    });

    test('curl: flag names, values of -X, bundles of flags', () {
      expect(values(complete(curl, 'curl --req')), ['--request']);
      expect(values(complete(curl, 'curl -X ')), ['GET', 'POST', 'PUT', 'DELETE']);
      expect(values(complete(curl, 'curl -X P')), ['POST', 'PUT']);
      expect(values(complete(curl, 'curl -s')), ['-so', '-sX', '-sH', '-sL', '-sk', '-sI']);
      expect(values(complete(curl, 'curl -L -')), isNot(contains('--location')));
      expect(values(complete(curl, 'curl -H a -H b -')), containsAll(['-H', '--header']));
      expect(values(complete(curl, 'curl https://x -o out -')), isNot(contains('--output')));
    });

    test('tar: the bundle of known flags can be extended', () {
      expect(values(complete(tar, 'tar -xz')), ['-xzc', '-xzv', '-xzf', '-xzC']);
      expect(complete(tar, 'tar -xzf').suggestions, isEmpty);
    });

    test('flagsArePosixNoncompliant: -name is one option', () {
      expect(values(complete(finder, 'find -na')), ['-name']);
      expect(values(complete(finder, 'find . -type ')), ['f', 'd']);
      expect(values(complete(finder, 'find . -n')), ['-name']);
    });

    test('optionsMustPrecedeArguments: later dashed words are arguments', () {
      expect(values(complete(run, 'run -')), ['-v']);
      expect(complete(run, 'run a -').isEmpty, isTrue);
      expect(values(complete(run, 'run a ')), ['x']);
    });

    test('script arguments get nothing', () {
      final sh = spec(r'''{"name": "sh", "options": [{"name": "-c", "args": {"name": "s", "isScript": true}}]}''');
      expect(complete(sh, 'sh -c ').isEmpty, isTrue);
      expect(complete(sh, 'sh -c ./x').isEmpty, isTrue);
    });

    test('-- ends options', () {
      final dashes = complete(git, 'git add -- -');
      expect(dashes.suggestions, isEmpty);
      expect(dashes.path?.typedPrefix, '-');
      final options = complete(git, 'git add -');
      expect(values(options), ['-A', '--all', '-p', '--no-pager']);
      expect(options.path, isNull);
      expect(values(complete(git, 'git add a -')), ['-A', '--all', '-p', '--no-pager']);
    });
  });

  group('paths', () {
    test('cd wants folders; past its argument nothing is asked', () {
      final p = complete(cd, 'cd ').path!;
      expect((p.typedPrefix, p.foldersOnly, p.tokenStart, p.tokenEnd, p.valueStart), ('', true, 3, 3, 3));
      expect(p.quote, CompletionQuote.none);
      expect((p.directory, p.namePrefix), ('', ''));
      expect(complete(cd, 'cd src ').path, isNull);
      expect(complete(cd, 'cd src ').isEmpty, isTrue);
    });

    test('directory and name prefix of what is typed', () {
      PathCompletionRequest request(String draft) => complete(cd, draft).path!;
      expect((request('cd ~/pro').directory, request('cd ~/pro').namePrefix), ('~/', 'pro'));
      expect((request('cd src/ma').directory, request('cd src/ma').namePrefix), ('src/', 'ma'));
      expect((request('cd /').directory, request('cd /').namePrefix), ('/', ''));
      expect((request('cd /etc/ng').directory, request('cd /etc/ng').namePrefix), ('/etc/', 'ng'));
      expect((request('cd ~').directory, request('cd ~').namePrefix), ('~/', ''));
      expect((request('cd ../..').directory, request('cd ../..').namePrefix), ('../', '..'));
      expect((request('cd ..').directory, request('cd ..').namePrefix), ('', '..'));
      final quoted = request('cd "My Do');
      expect(
        (quoted.typedPrefix, quoted.quote, quoted.tokenStart, quoted.valueStart),
        ('My Do', CompletionQuote.double, 3, 3),
      );
      expect(complete(cd, "cd 'My Do").path?.quote, CompletionQuote.single);
      expect(complete(cd, r'cd My\ Do').path?.typedPrefix, 'My Do');
      expect(complete(cd, 'cd ~us').path, isNull);
    });

    test('folders are offered with / and no space, one level at a time', () {
      final request = complete(cd, 'cd ~/pro').path!;
      final r = request.resolve(const [
        CompletionPathEntry('projects', isDirectory: true),
        CompletionPathEntry('profile.txt'),
        CompletionPathEntry('.secret', isDirectory: true),
        CompletionPathEntry('docs', isDirectory: true),
      ]);
      expect(r, hasLength(1));
      final s = r.single;
      expect(
        (s.value, s.display, s.kind, s.suffix, s.replacement, s.appendSpace),
        ('~/projects/', 'projects/', SpecSuggestionKind.folder, 'jects/', '~/projects/', false),
      );
      expect((s.replaceStart, s.replaceEnd), (3, 8));
      expect(s.applyTo('cd ~/pro'), 'cd ~/projects/');
      expect(complete(cd, 'cd ~/projects/').path!.directory, '~/projects/');
    });

    test('names with spaces are escaped, or kept inside the open quote', () {
      const entries = [
        CompletionPathEntry('My Notes 2.txt'),
        CompletionPathEntry('My Notes.txt'),
        CompletionPathEntry('Myth.txt'),
        CompletionPathEntry('Other'),
      ];
      final r = complete(cat, 'cat My').path!.resolve(entries);
      expect([for (final s in r) s.value], ['My Notes 2.txt', 'My Notes.txt', 'Myth.txt']);
      expect(r[0].suffix, r'\ Notes\ 2.txt');
      expect(r[0].replacement, r'My\ Notes\ 2.txt');
      expect(r[2].suffix, 'th.txt');
      expect(r.every((s) => s.kind == SpecSuggestionKind.file && s.appendSpace), isTrue);

      final inQuote = complete(cat, 'cat "My N').path!.resolve(entries);
      expect([for (final s in inQuote) s.value], ['My Notes 2.txt', 'My Notes.txt']);
      expect(inQuote[1].suffix, 'otes.txt"');
      expect(inQuote[1].replacement, '"My Notes.txt"');
      expect(inQuote[1].applyTo('cat "My N'), 'cat "My Notes.txt"');

      final folder = complete(cat, 'cat "My').path!.resolve(const [CompletionPathEntry('My Dir', isDirectory: true)]);
      expect(folder.single.replacement, '"My Dir/');
      expect(folder.single.appendSpace, isFalse);
    });

    test('dotfiles only for a dot prefix; .. is offered', () {
      const entries = [
        CompletionPathEntry('.git', isDirectory: true),
        CompletionPathEntry('src', isDirectory: true),
        CompletionPathEntry('.ssh', isDirectory: true),
      ];
      expect([for (final s in complete(cd, 'cd ').path!.resolve(entries)) s.value], ['src/']);
      expect([for (final s in complete(cd, 'cd .').path!.resolve(entries)) s.value], ['../', '.git/', '.ssh/']);
      expect([for (final s in complete(cd, 'cd .s').path!.resolve(entries)) s.value], ['.ssh/']);
      expect([for (final s in complete(cd, 'cd ../..').path!.resolve(const [])) s.value], ['../../']);
    });

    test('names that look like options or tildes are made safe, bad names are dropped', () {
      final r = complete(cat, 'cat ').path!.resolve(const [
        CompletionPathEntry('-rf'),
        CompletionPathEntry('a.txt'),
        CompletionPathEntry('~backup'),
        CompletionPathEntry('bad\nname'),
        CompletionPathEntry('a/b'),
        CompletionPathEntry('.'),
        CompletionPathEntry('..'),
        CompletionPathEntry('a.txt'),
      ]);
      expect([for (final s in r) s.value], ['./-rf', 'a.txt', '~backup']);
      expect(r[2].suffix, r'\~backup');
      final home = complete(cd, 'cd ~').path!.resolve(const [CompletionPathEntry('a', isDirectory: true)]);
      expect((home.single.value, home.single.suffix), ('~/a/', '/a/'));
    });

    test('--file=path joins the path to what precedes it', () {
      final r = complete(tar, 'tar --file=~/ba').path!.resolve(const [CompletionPathEntry('backup.tar')]);
      final s = r.single;
      expect((s.value, s.display, s.suffix), ('--file=~/backup.tar', 'backup.tar', 'ckup.tar'));
      expect(s.applyTo('tar --file=~/ba'), 'tar --file=~/backup.tar');
    });

    test('at most 200 entries, or the limit given', () {
      final many = [for (var i = 0; i < 300; i++) CompletionPathEntry('f${i.toString().padLeft(3, '0')}')];
      final request = complete(cat, 'cat ').path!;
      expect(request.resolve(many), hasLength(200));
      expect(request.resolve(many, limit: 5), hasLength(5));
      expect(request.resolve(many).first.value, 'f000');
    });
  });

  group('unknown commands', () {
    test('explicit paths ask for a listing', () {
      final p = complete(null, './scr').path!;
      expect((p.typedPrefix, p.foldersOnly, p.tokenStart), ('./scr', false, 0));
      expect(complete(null, 'foo ../x').path?.typedPrefix, '../x');
      expect(complete(null, 'foo ~/x').path?.typedPrefix, '~/x');
      expect(complete(null, 'foo /et').path?.typedPrefix, '/et');
      expect(complete(null, 'foo ~').path?.directory, '~/');
      expect(complete(null, 'foo -x ~/y').path?.typedPrefix, '~/y');
    });

    test('a plain argument word is a path when nothing about the line is uncertain', () {
      expect(complete(null, 'foo bar').path?.typedPrefix, 'bar');
      expect(complete(null, 'foo -x bar').path, isNull);
      expect(complete(null, 'foo ').path, isNull);
      expect(complete(null, 'foo -').path, isNull);
      expect(complete(null, 'foo').path, isNull);
      expect(complete(null, 'foo ~us').path, isNull);
      expect(complete(null, 'foo bar').suggestions, isEmpty);
    });

    test('a spec of another command is no spec', () {
      expect(complete(git, 'hg ./x').path?.typedPrefix, './x');
      expect(complete(git, 'hg com').path?.typedPrefix, 'com');
    });

    test('unsupported syntax gives nothing, with the reason', () {
      for (final draft in [r'foo $HOME/x', 'foo ./a | ./b', 'foo *.c', 'foo `x`']) {
        final r = complete(null, draft);
        expect(r.isEmpty, isTrue, reason: draft);
        expect(r.context.supported, isFalse, reason: draft);
      }
      final r = complete(git, 'git commit && ch');
      expect(r.isEmpty, isTrue);
      expect(r.context.issue, CompletionIssue.operator);
      expect(complete(git, 'git add "a b').path?.typedPrefix, 'a b');
    });
  });

  group('quoting of suggestions', () {
    test('a suggestion appended in a quote closes it', () {
      final inDouble = complete(git, 'git "chec').suggestions.single;
      expect((inDouble.value, inDouble.suffix, inDouble.replacement), ('checkout', 'kout"', '"checkout"'));
      expect(inDouble.applyTo('git "chec'), 'git "checkout"');
      final inSingle = complete(git, "git 'rem").suggestions.single;
      expect((inSingle.suffix, inSingle.applyTo("git 'rem")), ("ote'", "git 'remote'"));
    });

    test('values with spaces and quotes are escaped for the state they are inserted in', () {
      expect(complete(say, 'say a').suggestions.single.suffix, r'\ b');
      expect(complete(say, 'say "a').suggestions.single.suffix, ' b"');
      expect(complete(say, 'say it').suggestions.single.suffix, r"\'s");
      expect(complete(say, "say 'it").suggestions.single.suffix, r"'\''s'");
      expect(complete(say, "say 'it").suggestions.single.replacement, r"'it'\''s'");
      expect([for (final s in complete(say, 'say ').suggestions) s.suffix], [r"it\'s", r'a\ b']);
    });

    test('an insertValue that does not extend the typed text is a rewrite, not a suffix', () {
      final ins = spec(r'''
      {"name": "ins", "args": {"name": "x", "suggestions": [
        {"name": "latest", "insertValue": "v1.0-latest", "description": "d"}]}}''');
      final s = complete(ins, 'ins la').suggestions.single;
      expect(
        (s.value, s.display, s.description, s.suffix, s.isAppendOnly),
        ('v1.0-latest', 'latest', 'd', null, false),
      );
      expect(s.replacement, 'v1.0-latest');
      expect(s.applyTo('ins la'), 'ins v1.0-latest');
      expect(complete(ins, 'ins "la').suggestions.single.replacement, '"v1.0-latest"');
      expect(complete(ins, 'ins ').suggestions.single.suffix, 'v1.0-latest');
    });

    test('the shell reads every applied suggestion as exactly the word it promised', () {
      final drafts = <(CompletionSpec, String)>[
        (git, 'git '),
        (git, 'git c'),
        (git, 'git commit -'),
        (git, 'git "chec'),
        (git, "git 'rem"),
        (tar, 'tar -xz'),
        (curl, 'curl -s'),
        (curl, 'curl -XP'),
        (docker, 'docker compose up -'),
        (docker, 'docker compose up '),
        (mk, 'mk --co'),
        (mk, 'mk --color=a'),
        (say, 'say '),
        (say, 'say a'),
        (say, 'say "a'),
        (say, "say 'it"),
        (say, 'say it'),
      ];
      for (final (s, draft) in drafts) {
        final r = complete(s, draft);
        expect(r.suggestions, isNotEmpty, reason: draft);
        for (final x in r.suggestions) {
          expect((x.replaceStart, x.replaceEnd), (r.context.current.start, draft.length), reason: draft);
          expect(x.isAppendOnly, isTrue, reason: '$draft ${x.value}');
          expect(x.replacement, r.context.current.raw + x.suffix!, reason: '$draft ${x.value}');
          expect(x.applyTo(draft), draft + x.suffix!, reason: '$draft ${x.value}');
          expect(parse(x.applyTo(draft)).current.value, x.value, reason: '$draft ${x.value}');
        }
      }
      const entries = [
        CompletionPathEntry('My Notes.txt'),
        CompletionPathEntry(r'''it's $5 & "more"'''),
        CompletionPathEntry('文档', isDirectory: true),
      ];
      for (final draft in ['cat M', 'cat "M', "cat 'M", 'cat ', 'cat "', "cat '"]) {
        final request = complete(cat, draft).path!;
        for (final x in request.resolve(entries)) {
          expect(x.applyTo(draft), draft + x.suffix!, reason: '$draft ${x.value}');
          expect(parse(x.applyTo(draft)).current.value, x.value, reason: '$draft ${x.value}');
        }
      }
    });
  });

  group('wrappers and loaded specs', () {
    final wrap = SpecCompletionConfig(
      command: (name) => name == 'git' ? git : null,
      commands: const [
        CompletionChoice('git', description: 'vcs'),
        CompletionChoice('ls'),
      ],
    );

    test('the command after sudo is completed from its own spec', () {
      final r = complete(sudo, 'sudo ', config: wrap);
      expect(values(r), ['git', 'ls']);
      expect(r.suggestions.first.kind, SpecSuggestionKind.command);
      expect(r.suggestions.first.description, 'vcs');
      expect(values(complete(sudo, 'sudo g', config: wrap)), ['git']);
      expect(values(complete(sudo, 'sudo git re', config: wrap)), ['remote']);
      expect(values(complete(sudo, 'sudo -u root git commit --am', config: wrap)), ['--amend']);
      expect(values(complete(sudo, 'sudo -E ', config: wrap)), ['git', 'ls']);
      expect(values(complete(sudo, 'sudo git commit -a -', config: wrap)), isNot(contains('-a')));
      expect(values(complete(sudo, 'sudo -', config: wrap)), ['-u', '--user', '-E']);
    });

    test('an unknown command after sudo falls back to paths and reports what was missing', () {
      final r = complete(sudo, 'sudo mystery ./sc', config: wrap);
      expect(r.path?.typedPrefix, './sc');
      expect(r.missingCommand, 'mystery');
      expect(r.suggestions, isEmpty);
      expect(complete(sudo, 'sudo mystery fo', config: wrap).path?.typedPrefix, 'fo');
      expect(complete(sudo, 'sudo mystery -x fo', config: wrap).path, isNull);
      expect(complete(sudo, 'sudo ./sc', config: wrap).path?.typedPrefix, './sc');
      expect(complete(sudo, 'sudo mystery ').isEmpty, isTrue);
    });

    final cloud = spec(r'''
    {"name": "cloud", "subcommands": [{"name": "ec2", "loadSpec": "cloud/ec2"}, {"name": "s3"}]}''');
    final ec2 = spec(r'''
    {"name": "ec2", "subcommands": [{"name": "run"}, {"name": "stop"}],
     "options": [{"name": "--region", "isPersistent": true,
                  "args": {"name": "r", "suggestions": ["eu", "us"]}}]}''');
    final load = SpecCompletionConfig(nested: (key) => key == 'cloud/ec2' ? ec2 : null);

    test('a loadSpec target is merged when supplied, and reported when it is not', () {
      final missing = complete(cloud, 'cloud ec2 ');
      expect(missing.isEmpty, isTrue);
      expect(missing.missingNested, 'cloud/ec2');
      expect(values(complete(cloud, 'cloud ec2 ', config: load)), ['run', 'stop']);
      expect(complete(cloud, 'cloud ec2 ', config: load).missingNested, isNull);
      expect(values(complete(cloud, 'cloud ec2 run --re', config: load)), ['--region']);
      expect(values(complete(cloud, 'cloud ec2 --region ', config: load)), ['eu', 'us']);
      final listing = complete(cloud, 'cloud ');
      expect(values(listing), ['ec2', 's3']);
      expect(listing.missingNested, isNull);
    });

    test('a root that is only a reference needs its target', () {
      final root = CompletionSpec(['x'], loadSpec: 'x/all');
      final r = complete(root, 'x ');
      expect(r.isEmpty, isTrue);
      expect(r.missingNested, 'x/all');
      final loaded = complete(
        root,
        'x ',
        config: SpecCompletionConfig(
          nested: (_) => const CompletionSpec(
            ['x'],
            subcommands: [
              CompletionSpec(['go']),
            ],
          ),
        ),
      );
      expect(values(loaded), ['go']);
    });
  });

  group('limits', () {
    final big = CompletionSpec(
      ['big'],
      subcommands: [
        for (var i = 0; i < 500; i++) CompletionSpec(['sub$i']),
      ],
    );

    test('the whole candidate set up to 200, not eight', () {
      final r = complete(big, 'big s');
      expect(r.suggestions, hasLength(200));
      expect(r.truncated, isTrue);
      expect(r.suggestions.first.value, 'sub0');
      final few = complete(big, 'big sub49');
      expect(values(few), [for (var i = 0; i < 10; i++) 'sub49$i']);
      expect(few.truncated, isFalse);
    });

    test('the limit is configurable', () {
      final r = complete(big, 'big ', config: const SpecCompletionConfig(limit: 3));
      expect(values(r), ['sub0', 'sub1', 'sub2']);
      expect(r.truncated, isTrue);
    });

    test('values are not repeated', () {
      final twice = spec(r'''{"name": "t", "args": {"name": "a", "suggestions": ["x", "x", {"name": ["x", "y"]}]}}''');
      expect(values(complete(twice, 't ')), ['x', 'y']);
    });
  });
}

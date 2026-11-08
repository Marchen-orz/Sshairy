import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/features/terminal/domain/command_assistance.dart';
import 'package:sshairy/features/terminal/domain/command_catalog.dart';

List<String> words(String line) => [for (final s in catalogSuggestions(line)) s.display];
List<String> texts(String line) => [for (final s in catalogSuggestions(line)) s.text];

CommandCandidate candidate(String text, CommandCandidateSource source, {String? shown}) =>
    CommandCandidate(text, source: source, displayText: shown);

void main() {
  group('catalog', () {
    test('knows a broad set of common roots', () {
      final names = catalogCommandNames();
      expect(names.length, greaterThanOrEqualTo(60));
      expect(names.toSet(), hasLength(names.length));
      expect(
        names,
        containsAll([
          'ls',
          'grep',
          'find',
          'tar',
          'curl',
          'ssh',
          'scp',
          'rsync',
          'tmux',
          'git',
          'docker',
          'kubectl',
          'systemctl',
          'journalctl',
          'apt',
          'dnf',
        ]),
      );
      expect(words('l'), ['ls', 'less', 'ln', 'lsof', 'lsblk']);
      final tmux = catalogSuggestions('tm').single;
      expect(
        (tmux.text, tmux.display, tmux.kind, tmux.description),
        ('tmux', 'tmux', CommandKind.command, CommandDescription.toolTmux),
      );
    });

    test('tmux offers subcommands for an empty token, abbreviations and options', () {
      expect(words('tmux ').length, greaterThan(8));
      expect(words('tmux '), containsAll(['attach', 'new', 'ls']));
      expect(catalogSuggestions('tmux ').every((s) => s.kind == CommandKind.subcommand), isTrue);
      expect(texts('tmux a'), ['tmux attach']);
      expect(words('tmux attach-s'), ['attach-session']);
      expect(words('tmux a '), ['-t', '-d', '-r']);
      expect(words('tmux attach -'), ['-t', '-d', '-r']);
      expect(words('tmux new -s work -'), ['-d', '-As', '-n', '-c']);
      expect(catalogSuggestions('tmux new -s '), isEmpty);
    });

    test('git subcommands and their options', () {
      expect(words('git s').first, 'status');
      expect(words('git st'), ['status', 'stash']);
      expect(words('git ').length, greaterThan(8));
      expect(words('git commit -'), containsAll(['-m', '--amend']));
      expect(words('git commit -a'), ['-am']);
      expect(words('git stash '), containsAll(['pop', 'apply', 'list']));
      expect(words('git stash p'), ['pop', 'push']);
      expect(words('git -C /tmp st'), ['status', 'stash']);
      expect(words('git log --oneline -'), isNot(contains('--oneline')));
      expect(words('git config --global user.'), ['user.name', 'user.email']);
      expect(catalogSuggestions('git commit -m '), isEmpty);
      expect(catalogSuggestions('git branch -d '), isEmpty);
    });

    test('docker and compose options, value choices and inherited options', () {
      expect(words('docker compose '), containsAll(['up', 'down', 'logs']));
      expect(words('docker compose up -'), ['-d', '--build', '-f', '-p']);
      expect(words('docker compose -f x.yml up -'), ['-d', '--build', '-p']);
      expect(words('docker run --r'), ['--rm', '--restart']);
      expect(words('docker run -').length, greaterThan(8));
      expect(words('docker run --restart '), ['always', 'unless-stopped', 'on-failure', 'no']);
      expect(words('docker run --network '), ['host', 'bridge', 'none']);
      expect(catalogSuggestions('docker run -p '), isEmpty);
      final choice = catalogSuggestions('docker run --network ').first;
      expect(choice.kind, CommandKind.argument);
      expect(choice.text, 'docker run --network host');
    });

    test('kubectl shared options are understood before and after the verb', () {
      expect(words('kubectl get ').take(8), [
        'pods',
        'deployments',
        'services',
        'nodes',
        'namespaces',
        'configmaps',
        'secrets',
        'ingress',
      ]);
      expect(words('kubectl get p'), ['pods', 'pvc']);
      expect(words('kubectl -n kube-system get po'), ['pods']);
      expect(words('kubectl get pods -o '), ['wide', 'yaml', 'json', 'name']);
      expect(words('kubectl get pods -'), containsAll(['-o', '-n', '--namespace']));
      expect(catalogSuggestions('kubectl get pods p'), isEmpty);
    });

    test('systemd, journal and sudo', () {
      expect(words('systemctl status ').take(3), ['ssh', 'sshd', 'nginx']);
      expect(words('systemctl status ssh'), ['sshd']);
      expect(words('systemctl --user status ng'), ['nginx']);
      expect(words('systemctl list-units -t '), ['service', 'timer', 'socket', 'mount', 'target']);
      expect(words('sudo systemctl st'), ['status', 'start', 'stop']);
      expect(texts('sudo systemctl st').first, 'sudo systemctl status');
      expect(words('sudo sys'), ['systemctl']);
      expect(words('sudo -u root sys'), ['systemctl']);
      expect(catalogSuggestions('sudo '), isEmpty);
      expect(words('journalctl -p '), ['err', 'warning', 'info', 'notice', 'crit', 'alert', 'emerg', 'debug']);
      expect(words('journalctl -u ssh -'), containsAll(['-f', '-n']));
      expect(words('journalctl -u ssh -'), isNot(contains('-u')));
    });

    test('package managers resolve aliases', () {
      expect(words('apt in'), ['install']);
      expect(words('apt install -'), ['--no-install-recommends', '-y']);
      expect(words('apt-get '), [
        'update',
        'upgrade',
        'dist-upgrade',
        'install',
        'remove',
        'search',
        'autoremove',
        'clean',
      ]);
      expect(words('dnf up'), ['upgrade']);
      expect(words('dnf upd'), ['update']);
      expect(words('dnf update '), ['-y']);
    });

    test('network and file tools', () {
      expect(words('ssh -'), containsAll(['-p', '-i', '-L']));
      expect(words('ssh -p 2222 -'), containsAll(['-i', '-L']));
      expect(words('ssh -p 2222 -'), isNot(contains('-p')));
      expect(catalogSuggestions('ssh -p '), isEmpty);
      expect(catalogSuggestions('ssh user@host '), isEmpty);
      expect(words('curl -X '), ['GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'HEAD']);
      expect(words('ls -l'), ['-la', '-lh']);
      expect(words('ps a'), ['aux']);
      expect(words('chmod +'), ['+x']);
      expect(words('find . -type '), ['f', 'd', 'l']);
      expect(words('find . -na'), ['-name']);
      expect(words('tar x'), ['xzf', 'xf', 'xvf']);
      expect(words('tar -c'), ['-czf', '-cf']);
      expect(catalogSuggestions('tar -czf a.tgz x'), isEmpty);
      expect(catalogSuggestions('tar -czf a.tgz '), isEmpty);
    });

    test('an exact word has nothing left to complete', () {
      expect(catalogSuggestions('git status'), isEmpty);
      expect(words('ls'), ['lsof', 'lsblk']);
    });

    test('quoting, expansion, pipes, chaining, controls and non-ASCII yield nothing', () {
      const risky = [
        'git commit -m "x" --a',
        "git commit -m 'x' --a",
        r'git s\ ',
        'echo `ls` l',
        r'ls $(pwd) -',
        r'echo $HOME gi',
        'git s | gre',
        'git status; git s',
        'git s && git s',
        'ls > out gi',
        'ls < in -',
        'ls *.txt -',
        'ls ? -',
        'ls [a] -',
        'ls {a,b} -',
        'ls !x -',
        'ls #x -',
        'git s\n',
        'git s\t',
        'git s\u0000',
        'git s\u001b',
        'git 状',
        ' git s',
        '',
        ' ',
      ];
      expect(catalogSuggestions('git s'), isNotEmpty);
      for (final line in risky) {
        expect(catalogSuggestions(line), isEmpty, reason: line);
      }
    });

    test('uncertain syntax yields nothing instead of a guess', () {
      const uncertain = [
        'git foo s',
        'git --paginate s',
        'git log -- s',
        'docker --tlsverify ps ',
        'FOO=1 git s',
        './deploy.sh s',
        'ls -Z ',
        'sudo -s sys',
        'cd /var/l',
        'kubectl get pods --namespace=x ',
      ];
      for (final line in uncertain) {
        expect(catalogSuggestions(line), isEmpty, reason: line);
      }
    });

    test('destructive spellings are never suggested', () {
      const forbidden = {'-rf', '-fr', '--hard', '--delete', '-delete', '--force', '-k', '--insecure'};
      for (final line in ['rm -', 'git reset --', 'rsync --', 'find . -', 'git push -', 'curl -', 'docker rm -']) {
        expect(words(line).where(forbidden.contains), isEmpty, reason: line);
      }
      expect(words('git reset --'), ['--soft', '--mixed']);
    });

    test('every suggestion in the catalog extends its draft, stays one line and is bounded', () {
      var probes = 0;
      final queue = [for (final name in catalogCommandNames()) (name, 0)];
      while (queue.isNotEmpty) {
        final (line, depth) = queue.removeLast();
        for (final probe in ['$line ', '$line -']) {
          probes++;
          final found = catalogSuggestions(probe);
          expect(found.length, lessThanOrEqualTo(commandCandidateLimit), reason: probe);
          expect(found.map((s) => s.text).toSet(), hasLength(found.length), reason: probe);
          for (final s in found) {
            expect(s.text.startsWith(probe), isTrue, reason: '$probe -> ${s.text}');
            expect(s.text.length, greaterThan(probe.length), reason: probe);
            expect(s.display, isNotEmpty, reason: probe);
            expect(s.text.endsWith(s.display), isTrue, reason: '$probe -> ${s.text}');
            expect(commandIsSingleLine(s.text), isTrue, reason: s.text);
            expect(s.text.contains(RegExp(r'[^A-Za-z0-9._+/:@,%=~ -]')), isFalse, reason: s.text);
            if (s.kind == CommandKind.subcommand && depth < 3 && probe.endsWith(' ')) queue.add((s.text, depth + 1));
          }
        }
      }
      expect(probes, greaterThan(400));
    });
  });

  group('candidates', () {
    test('catalog candidates carry kind, display word and description', () {
      final history = CommandHistory();
      final tmux = localCommandCandidates('tmux a', history).single;
      expect(tmux.text, 'tmux attach');
      expect(tmux.displayText, 'attach');
      expect(tmux.kind, CommandKind.subcommand);
      expect(tmux.source, CommandCandidateSource.builtin);
      final root = localCommandCandidates('tm', history).single;
      expect((root.kind, root.description), (CommandKind.command, CommandDescription.toolTmux));
      const whole = CommandCandidate('git status');
      expect((whole.kind, whole.displayText, whole.description), (CommandKind.line, null, null));
    });

    test('history comes first but leaves room for the catalog', () {
      final history = CommandHistory();
      for (var i = 1; i <= 7; i++) {
        history.remember('git commit $i');
      }
      final mixed = localCommandCandidates('git c', history);
      expect(mixed.map((c) => c.source), [
        ...List.filled(7, CommandCandidateSource.history),
        ...List.filled(5, CommandCandidateSource.builtin),
      ]);
      expect(mixed.take(2).map((c) => c.text), ['git commit 7', 'git commit 6']);
      expect(mixed.skip(7).take(3).map((c) => c.text), ['git commit', 'git checkout', 'git clone']);

      for (var i = 1; i <= 9; i++) {
        history.remember('echo $i');
      }
      final onlyHistory = localCommandCandidates('echo ', history);
      expect(onlyHistory, hasLength(9));
      expect(onlyHistory.every((c) => c.source == CommandCandidateSource.history), isTrue);
    });

    test('history that already holds a catalog line is not repeated', () {
      final history = CommandHistory()..remember('git status');
      final found = localCommandCandidates('git s', history);
      expect(found.first.source, CommandCandidateSource.history);
      expect(found.where((c) => c.text == 'git status'), hasLength(1));
    });

    test('provider candidates must extend the draft and describe what they insert', () {
      const draft = 'git s';
      expect(commandCandidateValid(const CommandCandidate('git status', displayText: 'status'), draft), isTrue);
      expect(commandCandidateValid(const CommandCandidate('git status'), draft), isTrue);
      expect(commandCandidateValid(const CommandCandidate('git status', displayText: 'tus'), draft), isFalse);
      expect(commandCandidateValid(const CommandCandidate('git status', displayText: 'ls'), draft), isFalse);
      expect(commandCandidateValid(const CommandCandidate('git status', displayText: 'status\n'), draft), isFalse);
      expect(commandCandidateValid(const CommandCandidate('ls'), draft), isFalse);
      expect(commandCandidateValid(const CommandCandidate('git s\nrm -rf /'), draft), isFalse);
    });

    test('merge keeps history before ai and other providers without duplicates', () {
      const draft = 'git s';
      final local = [
        candidate('git status', CommandCandidateSource.history),
        candidate('git stash', CommandCandidateSource.builtin),
      ];
      final merged = mergeCommandCandidates(draft, local, [
        candidate('git switch main', CommandCandidateSource.provider),
        candidate('git show', CommandCandidateSource.ai),
        candidate('git status', CommandCandidateSource.ai),
        candidate('git s', CommandCandidateSource.ai),
        candidate('ls', CommandCandidateSource.ai),
        candidate('git s\n', CommandCandidateSource.ai),
        candidate('git sync', CommandCandidateSource.ai, shown: 'rm -rf /'),
        candidate('git status', CommandCandidateSource.provider),
      ]);
      expect(merged.map((c) => c.text), ['git status', 'git show', 'git stash', 'git switch main']);
      expect(merged.first.source, CommandCandidateSource.history);
    });

    test('total cap is separate from visible rows and history keeps its own budget', () {
      final history = [for (var i = 0; i < 80; i++) candidate('git status $i', CommandCandidateSource.history)];
      final local = [for (var i = 0; i < 220; i++) candidate('git stash $i', CommandCandidateSource.builtin)];
      final ai = [for (var i = 0; i < 20; i++) candidate('git show $i', CommandCandidateSource.ai)];
      final merged = mergeCommandCandidates('git s', [...history, ...local], ai);
      expect(merged, hasLength(commandCandidateLimit));
      expect(merged.take(50).every((c) => c.source == CommandCandidateSource.history), isTrue);
      expect(merged.skip(50).take(20).every((c) => c.source == CommandCandidateSource.ai), isTrue);
      expect(merged.skip(70).every((c) => c.source == CommandCandidateSource.builtin), isTrue);
      expect(mergeCommandCandidates('git s', local.take(8).toList(), ai.take(3)), hasLength(11));
    });
  });
}

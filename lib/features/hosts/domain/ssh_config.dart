const sshConfigMaxBytes = 1 << 20;
const sshConfigMaxFiles = 32;
const sshConfigMaxIncludeDepth = 4;
const sshConfigMaxHosts = 512;
const sshConfigMaxBlocks = 4096;

enum SshConfigIssueKind {
  malformed,
  unsupported,
  match,
  pattern,
  includeOutside,
  includeLimit,
  includeMissing,
  includeCycle,
  incomplete,
  proxyCommand,
  invalid,
  jump,
  jumpCycle,
  ambiguous,
  identity,
  extraIdentity,
  hostLimit,
}

class SshConfigLine {
  const SshConfigLine(this.file, this.number, this.text);

  final String file, text;
  final int number;
}

class SshConfigIssue {
  const SshConfigIssue(this.kind, this.file, this.line, [this.option = '']);

  final SshConfigIssueKind kind;
  final String file, option;
  final int line;
}

class SshConfigInput {
  const SshConfigInput(this.lines, {this.issues = const [], this.complete = true});

  final List<SshConfigLine> lines;
  final List<SshConfigIssue> issues;
  final bool complete;
}

class SshConfigDirective {
  const SshConfigDirective(this.keyword, this.arguments);

  final String keyword;
  final List<String> arguments;
}

/// Tokenizes config values, not a shell command. Quotes and comments are syntax only; nothing is evaluated.
SshConfigDirective? sshConfigDirective(String line) {
  final text = line.trim();
  if (text.isEmpty || text.startsWith('#')) return null;
  final match = RegExp(r'^([a-zA-Z][a-zA-Z0-9]*)\s*(?:=\s*)?(.*)$').firstMatch(text);
  if (match == null) throw const FormatException('directive');
  final value = match[2]!;
  final args = <String>[];
  var token = StringBuffer();
  String? quote;
  var started = false;
  for (var i = 0; i < value.length; i++) {
    final c = value[i];
    if (c == r'\' && i + 1 < value.length) {
      final next = value[i + 1];
      if (next == r'\' || next == '"' || next == "'" || (quote == null && (next.trim().isEmpty || next == '#'))) {
        token.write(next);
        started = true;
        i++;
        continue;
      }
    }
    if (quote != null) {
      if (c == quote) {
        quote = null;
      } else {
        token.write(c);
      }
      started = true;
    } else if (c == '"' || c == "'") {
      quote = c;
      started = true;
    } else if (c == '#') {
      break;
    } else if (c.trim().isEmpty) {
      if (started) {
        args.add(token.toString());
        token = StringBuffer();
        started = false;
      }
    } else {
      token.write(c);
      started = true;
    }
  }
  if (quote != null) throw const FormatException('quote');
  if (started) args.add(token.toString());
  if (args.isEmpty) throw const FormatException('value');
  return SshConfigDirective(match[1]!.toLowerCase(), args);
}

bool sshConfigPatternMatches(String pattern, String alias) {
  final expression = StringBuffer('^');
  for (final c in pattern.split('')) {
    expression.write(switch (c) {
      '*' => '.*',
      '?' => '.',
      _ => RegExp.escape(c),
    });
  }
  expression.write(r'$');
  return RegExp(expression.toString(), caseSensitive: false).hasMatch(alias);
}

bool _matches(List<String> patterns, String alias) {
  var matched = false;
  for (final pattern in patterns) {
    final negated = pattern.startsWith('!');
    if (!sshConfigPatternMatches(negated ? pattern.substring(1) : pattern, alias)) continue;
    if (negated) return false;
    matched = true;
  }
  return matched;
}

class SshConfigHost {
  const SshConfigHost({
    required this.alias,
    required this.address,
    required this.username,
    required this.port,
    required this.file,
    required this.line,
    this.keyPath,
    this.jumps = const [],
    this.issues = const [],
  });

  final String alias, address, username, file;
  final int port, line;
  final String? keyPath;
  final List<String> jumps;
  final List<SshConfigIssue> issues;
  bool get blocked => issues.isNotEmpty;
}

class SshConfig {
  const SshConfig(this.hosts, this.issues, {required this.complete});

  final List<SshConfigHost> hosts;
  final List<SshConfigIssue> issues;
  final bool complete;
}

class _Block {
  _Block(this.patterns);
  final List<String> patterns;
  final values = <String, ({SshConfigLine line, List<String> args})>{};
  final problems = <SshConfigIssue>[];
}

/// Supports only the documented subset and OpenSSH's first matching value rule.
SshConfig parseSshConfig(SshConfigInput input, {required String defaultUser, required String home}) {
  final issues = [...input.issues];
  final aliases = <String, SshConfigLine>{};
  final aliasKeys = <String>{};
  var complete = input.complete;
  final blocks = <_Block>[];
  var block = _Block(const ['*']);
  blocks.add(block);
  var inMatch = false;
  for (final line in input.lines) {
    SshConfigDirective? directive;
    try {
      directive = sshConfigDirective(line.text);
    } on FormatException {
      final issue = SshConfigIssue(SshConfigIssueKind.malformed, line.file, line.number);
      issues.add(issue);
      if (!inMatch) block.problems.add(issue);
      continue;
    }
    if (directive == null) continue;
    final key = directive.keyword, args = directive.arguments;
    SshConfigIssue issue(SshConfigIssueKind kind) => SshConfigIssue(kind, line.file, line.number, key);
    if (key == 'host') {
      if (blocks.length >= sshConfigMaxBlocks) {
        issues.add(issue(SshConfigIssueKind.hostLimit));
        complete = false;
        break;
      }
      inMatch = false;
      block = _Block(args);
      blocks.add(block);
      for (final alias in args) {
        if (alias.startsWith('!') || alias.contains('*') || alias.contains('?')) {
          issues.add(issue(SshConfigIssueKind.pattern));
        } else if (alias.isNotEmpty && aliasKeys.add(alias.toLowerCase())) {
          if (aliases.length >= sshConfigMaxHosts) {
            issues.add(issue(SshConfigIssueKind.hostLimit));
            complete = false;
            break;
          }
          aliases[alias] = line;
        }
      }
      continue;
    }
    if (key == 'match') {
      inMatch = true;
      issues.add(issue(SshConfigIssueKind.match));
      continue;
    }
    if (inMatch) continue;
    if (key == 'include') {
      // Includes must be expanded by the bounded filesystem adapter first.
      final problem = issue(SshConfigIssueKind.incomplete);
      issues.add(problem);
      block.problems.add(problem);
      continue;
    }
    if (!const {'hostname', 'user', 'port', 'identityfile', 'proxyjump', 'proxycommand'}.contains(key)) {
      issues.add(issue(SshConfigIssueKind.unsupported));
      continue;
    }
    if (key != 'proxycommand' && args.length != 1) {
      final problem = issue(SshConfigIssueKind.malformed);
      issues.add(problem);
      block.problems.add(problem);
      continue;
    }
    if (key == 'identityfile' && block.values.containsKey(key)) {
      issues.add(issue(SshConfigIssueKind.extraIdentity));
    }
    block.values.putIfAbsent(key, () => (line: line, args: args));
  }

  final hosts = <SshConfigHost>[];
  for (final MapEntry(key: alias, value: origin) in aliases.entries) {
    final values = <String, ({SshConfigLine line, List<String> args})>{};
    final problems = <SshConfigIssue>[];
    for (final b in blocks) {
      if (!_matches(b.patterns, alias)) continue;
      problems.addAll(b.problems);
      for (final entry in b.values.entries) {
        if (entry.key == 'identityfile' && values.containsKey(entry.key)) {
          issues.add(
            SshConfigIssue(
              SshConfigIssueKind.extraIdentity,
              entry.value.line.file,
              entry.value.line.number,
              'identityfile',
            ),
          );
        }
        values.putIfAbsent(entry.key, () => entry.value);
      }
    }
    SshConfigIssue problem(SshConfigIssueKind kind, [String? key]) {
      final source = values[key]?.line ?? origin;
      return SshConfigIssue(kind, source.file, source.number, key ?? '');
    }

    var address = values['hostname']?.args.single ?? alias;
    address = address.replaceAll('%h', alias).replaceAll('%n', alias).replaceAll('%%', '%');
    final username = values['user']?.args.single ?? defaultUser;
    final port = int.tryParse(values['port']?.args.single ?? '22') ?? 0;
    bool valid(String value) => value.isNotEmpty && !RegExp(r'[\s\x00-\x1f\x7f%$]').hasMatch(value);
    if (!valid(address) || !valid(username) || port < 1 || port > 65535) {
      problems.add(problem(SshConfigIssueKind.invalid));
    }
    if (values['proxycommand'] case final command? when command.args.join(' ').toLowerCase() != 'none') {
      problems.add(problem(SshConfigIssueKind.proxyCommand, 'proxycommand'));
    }
    final jump = values['proxyjump']?.args.single;
    final jumps = jump == null || jump.toLowerCase() == 'none' ? <String>[] : jump.split(',');
    String? identity = values['identityfile']?.args.single;
    if (identity != null && identity.toLowerCase() == 'none') identity = null;
    if (identity != null) {
      if (identity == '~' || identity.startsWith('~/') || identity.startsWith(r'~\')) {
        identity = '$home${identity.substring(1)}';
      }
      final expanded = StringBuffer();
      var supported = !identity.startsWith('~') && !identity.contains(r'${');
      for (var i = 0; i < identity.length; i++) {
        if (identity[i] != '%') {
          expanded.write(identity[i]);
          continue;
        }
        if (++i == identity.length) {
          supported = false;
          break;
        }
        switch (identity[i]) {
          case '%':
            expanded.write('%');
          case 'h':
            expanded.write(address);
          case 'n':
            expanded.write(alias);
          case 'r':
            expanded.write(username);
          case 'd':
            expanded.write(home);
          default:
            supported = false;
        }
      }
      identity = expanded.toString();
      // Relative key references follow OpenSSH's home directory base, not the config file location.
      final absolute =
          identity.startsWith('/') || RegExp(r'^[a-zA-Z]:[/\\]').hasMatch(identity) || identity.startsWith(r'\\');
      if (!absolute) identity = '$home/$identity';
      if (!supported || home.isEmpty || identity.contains('\u0000')) {
        problems.add(problem(SshConfigIssueKind.identity, 'identityfile'));
      }
    }
    if (!complete) problems.add(problem(SshConfigIssueKind.incomplete));
    hosts.add(
      SshConfigHost(
        alias: alias,
        address: address,
        username: username,
        port: port,
        keyPath: identity,
        jumps: jumps,
        file: origin.file,
        line: origin.number,
        issues: problems,
      ),
    );
  }
  return SshConfig(hosts, issues, complete: complete);
}

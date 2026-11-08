enum CommandKind { line, command, subcommand, option, argument }

/// Short explanations of catalog entries; the terminal adapter maps each value to localized text.
enum CommandDescription {
  // tools
  toolCompose,
  toolTmux,
  tmuxAttach,
  tmuxNew,
  tmuxList,
  tmuxKillSession,
  tmuxKillServer,
  tmuxDetach,
  tmuxWindows,
  tmuxNewWindow,
  tmuxSplit,
  tmuxRename,
  tmuxHas,
  tmuxSource,
  tmuxBind,
  tmuxBreak,

  toolScreen,
  toolSystemctl,
  toolJournalctl,
  toolRsync,
  toolLsof,
  toolSs,
  toolJq,
  toolTcpdump,
  toolCrontab,
  toolWatch,
  toolHelm,
  // shared by many commands
  quiet,
  recursive,
  force,
  all,
  human,
  follow,
  lines,
  tail,
  since,
  background,
  label,
  port,
  identity,
  jumpHost,
  file,
  directory,
  outputFile,
  dryRun,
  assumeYes,
  namespace,
  target,
  user,
  reverse,
  ignoreCase,
  confirm,
  runInside,
  upgrade,
  refreshIndex,
  // files and text
  longList,
  parents,
  archive,
  invert,
  filesOnly,
  extendedRegex,
  maxDepth,
  makeExecutable,
  inPlace,
  extract,
  createArchive,
  listArchive,
  allProcesses,
  forceKill,
  // network
  localForward,
  remoteForward,
  dynamicForward,
  noCommand,
  followRedirects,
  headersOnly,
  method,
  listening,
  keyType,
  fingerprint,
  removeKnownHost,
  progressPartial,
  // services and logs
  unit,
  jumpEnd,
  thisBoot,
  priority,
  daemonReload,
  isActive,
  userScope,
  now,
  // git
  commitAll,
  amend,
  setUpstream,
  rebase,
  fastForwardOnly,
  newBranch,
  showCurrent,
  oneline,
  staged,
  prune,
  noFastForward,
  squash,
  continueOp,
  stashPop,
  includeUntracked,
  // containers
  runContainer,
  removeOnExit,
  volume,
  env,
  restartPolicy,
  composeUp,
  composeDown,
  allNamespaces,
  selector,
  outputFormat,
}

/// A suggestion for the token being typed; [text] is the whole line and always extends the draft.
class CatalogSuggestion {
  const CatalogSuggestion(this.text, this.display, this.kind, this.description);

  final String text, display;
  final CommandKind kind;
  final CommandDescription? description;
}

const _maxSuggestions = 8;

/// Only plain words and a few path/host characters. Quotes, expansions, pipes, redirects and chaining are never parsed.
final _plainLine = RegExp(r'^[A-Za-z0-9._+/:@,%=~ -]*$');

abstract class _Item {
  const _Item(this.name, this.description);

  final String name;
  final CommandDescription? description;

  List<String> get names => [name];
}

class _Cmd extends _Item {
  const _Cmd(
    String name, {
    CommandDescription? desc,
    this.aliases = const [],
    this.options = const [],
    this.shared = const [],
    this.subs = const [],
    this.args = const [],
    this.lead = const [],
    this.runs = false,
  }) : super(name, desc);

  /// Spellings the shell accepts besides [name]; they resolve but only show when [name] does not match.
  final List<String> aliases;

  /// Own options; [shared] options also apply to every subcommand below.
  final List<_Opt> options, shared;
  final List<_Cmd> subs;

  /// First operand choices, e.g. the resource kind of `kubectl get`.
  final List<_Arg> args;

  /// Old-style bundled flags (`tar xzf`, `ps aux`); valid only as the very first word, before any option.
  final List<_Arg> lead;

  /// The next word is another command (sudo, watch).
  final bool runs;

  @override
  List<String> get names => [name, ...aliases];
}

class _Opt extends _Item {
  const _Opt(super.name, [super.description]) : takesValue = false, choices = const [];

  /// The option consumes the next word; [choices] are suggested for it when known.
  const _Opt.value(super.name, [super.description, this.choices = const []]) : takesValue = true;

  final bool takesValue;
  final List<String> choices;
}

class _Arg extends _Item {
  const _Arg(super.name, [super.description]);
}

const _top = _Cmd('', runs: true);

List<_Cmd> _children(_Cmd node) => node.runs ? _roots : node.subs;

_Cmd? _child(_Cmd node, String word) {
  for (final c in _children(node)) {
    if (c.names.contains(word)) return c;
  }
  return null;
}

_Opt? _find(_Cmd node, List<_Opt> inherited, String name) {
  for (final o in [...node.options, ...node.shared, ...inherited]) {
    if (o.name == name) return o;
  }
  return null;
}

/// The command names the catalog knows, in suggestion order.
List<String> catalogCommandNames() => [for (final c in _roots) c.name];

/// Suggestions for the last word of [text], or none whenever the earlier words cannot be classified with certainty.
List<CatalogSuggestion> catalogSuggestions(String text) {
  if (text.isEmpty || text.startsWith(' ') || !_plainLine.hasMatch(text)) return const [];
  final words = text.split(' ');
  final partial = words.last;
  final done = [
    for (final w in words.take(words.length - 1))
      if (w.isNotEmpty) w,
  ];
  var node = _top;
  final inherited = <_Opt>[];
  var operands = 0, seen = 0;
  _Opt? waiting;
  var unsure = false;
  for (final word in done) {
    seen++;
    if (waiting != null) {
      waiting = null;
      continue;
    }
    unsure = false;
    if (word == '--') return const [];
    if (word.startsWith('-')) {
      final eq = word.indexOf('=');
      final known = _find(node, inherited, eq > 0 ? word.substring(0, eq) : word);
      if (known != null) {
        if (known.takesValue && eq < 0) waiting = known;
        continue;
      }
      if (operands == 0 && _children(node).isNotEmpty) return const [];
      if (eq > 0) continue;
      final last = word.startsWith('--') ? null : _find(node, inherited, '-${word[word.length - 1]}');
      if (last == null) {
        unsure = true;
      } else if (last.takesValue) {
        waiting = last;
      }
      continue;
    }
    if (operands == 0 && _children(node).isNotEmpty) {
      final next = _child(node, word);
      if (next == null) return const [];
      inherited.addAll(node.shared);
      node = next;
      seen = 0;
    } else {
      operands++;
    }
  }

  final prefix = text.substring(0, text.length - partial.length);
  final taken = <String>{};
  final commandKind = node.runs ? CommandKind.command : CommandKind.subcommand;
  List<CatalogSuggestion> pick(Iterable<_Item> items, [Set<String> skip = const {}]) {
    final out = <CatalogSuggestion>[];
    for (final item in items) {
      for (final candidate in item.names) {
        if (candidate.startsWith(partial) &&
            candidate != partial &&
            !skip.contains(candidate) &&
            taken.add(candidate)) {
          final kind = switch (item) {
            _Opt() => CommandKind.option,
            _Arg() => CommandKind.argument,
            _ => commandKind,
          };
          out.add(CatalogSuggestion('$prefix$candidate', candidate, kind, item.description));
          break;
        }
      }
      if (out.length == _maxSuggestions) break;
    }
    return out;
  }

  final options = [...node.options, ...node.shared, ...inherited];
  if (waiting != null) return pick([for (final c in waiting.choices) _Arg(c)]);
  if (partial.startsWith('-')) return pick(options, done.toSet());
  if (partial.isEmpty && unsure) return const [];
  final kids = _children(node);
  if (operands == 0 && kids.isNotEmpty) {
    if (partial.isEmpty && node.runs) return const [];
    return pick(kids);
  }
  if (operands == 0 && node.args.isNotEmpty) return pick(node.args);
  if (seen == 0) return pick(partial.isEmpty ? [...node.lead, ...options] : node.lead);
  return const [];
}

const _help = _Opt('--help');
const _version = _Opt('--version');
const _verbose = _Opt('-v');
const _quiet = _Opt('-q', CommandDescription.quiet);
const _recursive = _Opt('-r', CommandDescription.recursive);
const _recursiveUpper = _Opt('-R', CommandDescription.recursive);
const _force = _Opt('-f', CommandDescription.force);
const _all = _Opt('-a', CommandDescription.all);
const _human = _Opt('-h', CommandDescription.human);
const _follow = _Opt('-f', CommandDescription.follow);
const _yes = _Opt('-y', CommandDescription.assumeYes);
const _confirm = _Opt('-i', CommandDescription.confirm);
const _lines = _Opt.value('-n', CommandDescription.lines);
const _tail = _Opt.value('--tail', CommandDescription.tail);
const _since = _Opt.value('--since', CommandDescription.since);
const _fileValue = _Opt.value('-f', CommandDescription.file);
const _directoryValue = _Opt.value('-C', CommandDescription.directory);
const _user = _Opt.value('-u', CommandDescription.user);
const _dryRun = _Opt('--dry-run', CommandDescription.dryRun);
const _noPager = _Opt('--no-pager');
const _interactiveTty = _Opt('-it');
const _identity = _Opt.value('-i', CommandDescription.identity);
const _lowerPort = _Opt.value('-p', CommandDescription.port);
const _upperPort = _Opt.value('-P', CommandDescription.port);
const _jump = _Opt.value('-J', CommandDescription.jumpHost);

/// Resource kinds that `kubectl get/describe/delete/edit` accept first.
const _kinds = <_Arg>[
  _Arg('pods'),
  _Arg('deployments'),
  _Arg('services'),
  _Arg('nodes'),
  _Arg('namespaces'),
  _Arg('configmaps'),
  _Arg('secrets'),
  _Arg('ingress'),
  _Arg('events'),
  _Arg('jobs'),
  _Arg('cronjobs'),
  _Arg('statefulsets'),
  _Arg('daemonsets'),
  _Arg('pvc'),
];

/// Typical unit names; a missing one only means the suggestion is not useful on this server.
const _services = <_Arg>[
  _Arg('ssh'),
  _Arg('sshd'),
  _Arg('nginx'),
  _Arg('apache2'),
  _Arg('docker'),
  _Arg('cron'),
  _Arg('ufw'),
  _Arg('fail2ban'),
  _Arg('mysql'),
  _Arg('postgresql'),
];

const _systemctlSubs = <_Cmd>[
  _Cmd('status', args: _services, options: [_Opt('-l'), _lines]),
  _Cmd('start', args: _services),
  _Cmd('stop', args: _services),
  _Cmd('restart', args: _services),
  _Cmd('reload', args: _services),
  _Cmd('enable', args: _services, options: [_Opt('--now', CommandDescription.now)]),
  _Cmd('disable', args: _services, options: [_Opt('--now', CommandDescription.now)]),
  _Cmd('is-active', desc: CommandDescription.isActive, args: _services),
  _Cmd('is-enabled', args: _services),
  _Cmd(
    'list-units',
    options: [
      _Opt('--failed'),
      _Opt.value('-t', null, ['service', 'timer', 'socket', 'mount', 'target']),
    ],
  ),
  _Cmd('list-unit-files'),
  _Cmd('list-timers'),
  _Cmd('daemon-reload', desc: CommandDescription.daemonReload),
  _Cmd('show', args: _services),
  _Cmd('cat', args: _services),
  _Cmd('edit', args: _services),
  _Cmd('reset-failed'),
];

const _packageSubs = <_Cmd>[_Cmd('install'), _Cmd('remove'), _Cmd('search'), _Cmd('autoremove'), _Cmd('clean')];

const _dnfSubs = <_Cmd>[
  _Cmd('install'),
  _Cmd('upgrade', desc: CommandDescription.upgrade, aliases: ['update']),
  _Cmd('remove'),
  _Cmd('search'),
  _Cmd('info'),
  _Cmd('list', options: [_Opt('--installed')]),
  _Cmd('makecache', desc: CommandDescription.refreshIndex),
  _Cmd('check-update'),
  _Cmd('autoremove'),
  _Cmd('clean'),
  _Cmd('history'),
  _Cmd('repolist'),
];

const _pipSubs = <_Cmd>[
  _Cmd(
    'install',
    options: [
      _Opt.value('-r', CommandDescription.file),
      _Opt('-U', CommandDescription.upgrade),
      _Opt('--upgrade', CommandDescription.upgrade),
    ],
  ),
  _Cmd('uninstall', options: [_yes]),
  _Cmd('list'),
  _Cmd('freeze'),
  _Cmd('show'),
];

const _roots = <_Cmd>[
  _Cmd(
    'ls',
    options: [
      _Opt('-l', CommandDescription.longList),
      _Opt('-a', CommandDescription.all),
      _Opt('-la', CommandDescription.longList),
      _Opt('-lh', CommandDescription.longList),
      _human,
      _Opt('-t'),
      _Opt('-r', CommandDescription.reverse),
      _recursiveUpper,
      _Opt('-S'),
      _help,
    ],
  ),
  _Cmd('cd'),
  _Cmd('cat', options: [_Opt('-n')]),
  _Cmd('cp', options: [_recursive, _Opt('-a', CommandDescription.archive), _verbose, _confirm]),
  _Cmd('mv', options: [_verbose, _confirm, _force]),
  _Cmd('rm', options: [_recursive, _force, _confirm, _verbose]),
  _Cmd('mkdir', options: [_Opt('-p', CommandDescription.parents), _verbose]),
  _Cmd('touch'),
  _Cmd('less', options: [_Opt('-N'), _Opt('-S')]),
  _Cmd('head', options: [_lines]),
  _Cmd('tail', options: [_follow, _lines, _Opt('-F')]),
  _Cmd(
    'grep',
    options: [
      _recursive,
      _Opt('-i', CommandDescription.ignoreCase),
      _Opt('-n'),
      _Opt('-v', CommandDescription.invert),
      _Opt('-c'),
      _Opt('-l', CommandDescription.filesOnly),
      _Opt('-E', CommandDescription.extendedRegex),
      _Opt('-w'),
      _Opt('-o'),
      _Opt.value('-A'),
      _Opt.value('-B'),
      _Opt.value('-C'),
      _Opt.value('--include'),
      _Opt.value('--exclude-dir'),
    ],
  ),
  _Cmd(
    'find',
    options: [
      _Opt.value('-name'),
      _Opt.value('-iname', CommandDescription.ignoreCase),
      _Opt.value('-type', null, ['f', 'd', 'l']),
      _Opt.value('-mtime'),
      _Opt.value('-size'),
      _Opt.value('-maxdepth', CommandDescription.maxDepth),
      _Opt.value('-user'),
      _Opt.value('-perm'),
    ],
  ),
  _Cmd('ln', options: [_Opt('-s'), _force]),
  _Cmd(
    'chmod',
    args: [_Arg('+x', CommandDescription.makeExecutable), _Arg('755'), _Arg('644'), _Arg('600')],
    options: [_recursiveUpper],
  ),
  _Cmd('chown', options: [_recursiveUpper]),
  _Cmd('pwd'),
  _Cmd('rmdir'),
  _Cmd(
    'sed',
    options: [
      _Opt('-i', CommandDescription.inPlace),
      _Opt('-n'),
      _Opt('-E', CommandDescription.extendedRegex),
      _Opt.value('-e'),
    ],
  ),
  _Cmd('awk', options: [_Opt.value('-F')]),
  _Cmd('sort', options: [_Opt('-n'), _Opt('-r', CommandDescription.reverse), _Opt('-u'), _Opt.value('-k')]),
  _Cmd('uniq', options: [_Opt('-c')]),
  _Cmd('wc', options: [_Opt('-l'), _Opt('-w'), _Opt('-c')]),
  _Cmd('cut', options: [_Opt.value('-d'), _Opt.value('-f')]),
  _Cmd('diff', options: [_Opt('-u'), _recursive]),
  _Cmd('tree', options: [_Opt.value('-L', CommandDescription.maxDepth), _all, _human]),
  _Cmd('stat'),
  _Cmd('file'),
  _Cmd('which'),
  _Cmd('jq', desc: CommandDescription.toolJq, options: [_Opt('-r'), _Opt('-c')]),
  _Cmd(
    'du',
    options: [
      _Opt('-sh'),
      _Opt('-s'),
      _human,
      _Opt.value('-d', CommandDescription.maxDepth),
      _Opt.value('--max-depth', CommandDescription.maxDepth),
    ],
  ),
  _Cmd('df', options: [_human, _Opt('-T'), _Opt('-i')]),
  _Cmd('free', options: [_human, _Opt('-m'), _Opt('-g')]),
  _Cmd(
    'ps',
    lead: [_Arg('aux', CommandDescription.allProcesses)],
    options: [_Opt('-ef', CommandDescription.allProcesses), _Opt('-e'), _Opt('-f'), _user],
  ),
  _Cmd('top', options: [_user]),
  _Cmd('htop', options: [_user]),
  _Cmd('uptime'),
  _Cmd('uname', options: [_Opt('-a', CommandDescription.all), _Opt('-r')]),
  _Cmd('kill', options: [_Opt('-9', CommandDescription.forceKill), _Opt('-15')]),
  _Cmd('killall', options: [_Opt('-9', CommandDescription.forceKill)]),
  _Cmd('pkill', options: [_Opt('-9', CommandDescription.forceKill), _Opt('-f')]),
  _Cmd('lsof', desc: CommandDescription.toolLsof, options: [_Opt('-i'), _Opt.value('-p'), _user]),
  _Cmd('lsblk', options: [_Opt('-f')]),
  _Cmd('dmesg', options: [_Opt('-T', CommandDescription.human), _Opt('-w', CommandDescription.follow)]),
  _Cmd('date'),
  _Cmd('whoami'),
  _Cmd('id'),
  _Cmd('hostname', options: [_Opt('-I')]),
  _Cmd('mount'),
  _Cmd('umount'),
  _Cmd(
    'tar',
    lead: [
      _Arg('xzf', CommandDescription.extract),
      _Arg('czf', CommandDescription.createArchive),
      _Arg('xf', CommandDescription.extract),
      _Arg('cf', CommandDescription.createArchive),
      _Arg('tf', CommandDescription.listArchive),
      _Arg('xvf', CommandDescription.extract),
      _Arg('czvf', CommandDescription.createArchive),
    ],
    options: [
      _Opt.value('-xzf', CommandDescription.extract),
      _Opt.value('-czf', CommandDescription.createArchive),
      _Opt.value('-xf', CommandDescription.extract),
      _Opt.value('-cf', CommandDescription.createArchive),
      _Opt.value('-tf', CommandDescription.listArchive),
      _Opt('-x', CommandDescription.extract),
      _Opt('-c', CommandDescription.createArchive),
      _Opt('-t', CommandDescription.listArchive),
      _Opt('-z'),
      _verbose,
      _Opt.value('-f', CommandDescription.file),
      _directoryValue,
      _Opt.value('--exclude'),
    ],
  ),
  _Cmd('zip', options: [_recursive, _quiet]),
  _Cmd(
    'unzip',
    options: [_Opt.value('-d', CommandDescription.directory), _Opt('-l', CommandDescription.listArchive), _quiet],
  ),
  _Cmd('gzip', options: [_Opt('-d'), _Opt('-k')]),
  _Cmd(
    'ssh',
    options: [
      _lowerPort,
      _identity,
      _jump,
      _Opt.value('-L', CommandDescription.localForward),
      _Opt.value('-R', CommandDescription.remoteForward),
      _Opt.value('-D', CommandDescription.dynamicForward),
      _Opt('-N', CommandDescription.noCommand),
      _Opt('-t'),
      _Opt.value('-o'),
      _Opt.value('-l', CommandDescription.user),
      _verbose,
      _quiet,
    ],
  ),
  _Cmd('scp', options: [_upperPort, _recursive, _identity, _jump, _Opt('-C'), _quiet, _verbose]),
  _Cmd('sftp', options: [_upperPort, _identity, _jump]),
  _Cmd(
    'rsync',
    desc: CommandDescription.toolRsync,
    options: [
      _Opt('-a', CommandDescription.archive),
      _verbose,
      _Opt('-z'),
      _recursive,
      _human,
      _Opt('-P', CommandDescription.progressPartial),
      _Opt('-n', CommandDescription.dryRun),
      _dryRun,
      _Opt('--progress'),
      _Opt.value('--exclude'),
    ],
  ),
  _Cmd(
    'curl',
    options: [
      _Opt('-s', CommandDescription.quiet),
      _Opt('-L', CommandDescription.followRedirects),
      _Opt.value('-o', CommandDescription.outputFile),
      _Opt('-O'),
      _Opt('-I', CommandDescription.headersOnly),
      _Opt.value('-H'),
      _Opt.value('-X', CommandDescription.method, ['GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'HEAD']),
      _Opt.value('-d'),
      _verbose,
      _Opt('-f'),
      _Opt.value('--max-time'),
    ],
  ),
  _Cmd(
    'wget',
    options: [
      _Opt.value('-O', CommandDescription.outputFile),
      _Opt('-c'),
      _quiet,
      _Opt.value('-P', CommandDescription.directory),
    ],
  ),
  _Cmd('ping', options: [_Opt.value('-c')]),
  _Cmd(
    'ss',
    desc: CommandDescription.toolSs,
    options: [
      _Opt('-tulpn', CommandDescription.listening),
      _Opt('-tlnp', CommandDescription.listening),
      _Opt('-l', CommandDescription.listening),
      _Opt('-t'),
      _Opt('-u'),
      _Opt('-n'),
      _Opt('-p'),
      _all,
    ],
  ),
  _Cmd('netstat', options: [_Opt('-tulpn', CommandDescription.listening), _Opt('-tlnp', CommandDescription.listening)]),
  _Cmd(
    'ip',
    options: [_Opt('-br'), _Opt('-c')],
    subs: [
      _Cmd('addr', aliases: ['a', 'address']),
      _Cmd('link', aliases: ['l']),
      _Cmd('route', aliases: ['r']),
      _Cmd('neigh'),
    ],
  ),
  _Cmd(
    'tcpdump',
    desc: CommandDescription.toolTcpdump,
    options: [
      _Opt.value('-i'),
      _Opt('-n'),
      _Opt('-nn'),
      _Opt.value('-c'),
      _Opt.value('-w', CommandDescription.outputFile),
      _verbose,
    ],
  ),
  _Cmd(
    'ssh-keygen',
    options: [
      _Opt.value('-t', CommandDescription.keyType, ['ed25519', 'rsa', 'ecdsa']),
      _Opt.value('-b'),
      _Opt.value('-C'),
      _Opt.value('-f', CommandDescription.file),
      _Opt('-l', CommandDescription.fingerprint),
      _Opt.value('-R', CommandDescription.removeKnownHost),
    ],
  ),
  _Cmd('ssh-copy-id', options: [_identity, _lowerPort]),
  _Cmd('sudo', runs: true, options: [_user, _Opt('-i'), _Opt('-E')]),
  _Cmd('watch', desc: CommandDescription.toolWatch, runs: true, options: [_Opt.value('-n'), _Opt('-d')]),
  _Cmd('nohup', runs: true),
  _Cmd(
    'systemctl',
    desc: CommandDescription.toolSystemctl,
    shared: [_Opt('--user', CommandDescription.userScope), _noPager],
    subs: _systemctlSubs,
  ),
  _Cmd(
    'journalctl',
    desc: CommandDescription.toolJournalctl,
    options: [
      _Opt.value('-u', CommandDescription.unit),
      _follow,
      _lines,
      _Opt('-e', CommandDescription.jumpEnd),
      _Opt('-b', CommandDescription.thisBoot),
      _Opt.value('-p', CommandDescription.priority, [
        'err',
        'warning',
        'info',
        'notice',
        'crit',
        'alert',
        'emerg',
        'debug',
      ]),
      _Opt('-k'),
      _Opt.value('--since', CommandDescription.since, ['today', 'yesterday']),
      _Opt.value('--until'),
      _Opt('-r', CommandDescription.reverse),
      _noPager,
      _Opt('-xe', CommandDescription.jumpEnd),
    ],
  ),
  _Cmd('crontab', desc: CommandDescription.toolCrontab, options: [_Opt('-l'), _Opt('-e'), _user]),
  _Cmd(
    'git',
    options: [_directoryValue, _Opt.value('-c'), _Opt('--no-pager'), _version, _help],
    subs: [
      _Cmd('status', options: [_Opt('-s'), _Opt('-sb')]),
      _Cmd(
        'add',
        args: [_Arg('.')],
        options: [_Opt('-A', CommandDescription.all), _Opt('-p'), _Opt('-u'), _Opt('-n', CommandDescription.dryRun)],
      ),
      _Cmd(
        'commit',
        options: [
          _Opt.value('-m'),
          _Opt('-a', CommandDescription.commitAll),
          _Opt.value('-am', CommandDescription.commitAll),
          _Opt('--amend', CommandDescription.amend),
          _Opt('--no-edit'),
        ],
      ),
      _Cmd('push', options: [_Opt('-u', CommandDescription.setUpstream), _Opt('--tags'), _dryRun]),
      _Cmd(
        'pull',
        options: [
          _Opt('--rebase', CommandDescription.rebase),
          _Opt('--ff-only', CommandDescription.fastForwardOnly),
          _Opt('--autostash'),
        ],
      ),
      _Cmd('checkout', options: [_Opt.value('-b', CommandDescription.newBranch)]),
      _Cmd(
        'branch',
        options: [
          _all,
          _Opt('-r'),
          _Opt.value('-d'),
          _Opt.value('-m'),
          _Opt('-vv'),
          _Opt('--show-current', CommandDescription.showCurrent),
        ],
      ),
      _Cmd(
        'log',
        options: [
          _Opt('--oneline', CommandDescription.oneline),
          _Opt('--graph'),
          _Opt('--stat'),
          _Opt('-p'),
          _Opt.value('-n'),
          _Opt('--all', CommandDescription.all),
          _Opt.value('--author'),
          _Opt.value('--since', CommandDescription.since),
          _Opt('--decorate'),
        ],
      ),
      _Cmd(
        'diff',
        args: [_Arg('HEAD')],
        options: [_Opt('--staged', CommandDescription.staged), _Opt('--cached'), _Opt('--stat'), _Opt('--name-only')],
      ),
      _Cmd(
        'fetch',
        options: [_Opt('--all', CommandDescription.all), _Opt('--prune', CommandDescription.prune), _Opt('--tags')],
      ),
      _Cmd(
        'merge',
        options: [
          _Opt('--no-ff', CommandDescription.noFastForward),
          _Opt('--squash', CommandDescription.squash),
          _Opt('--ff-only', CommandDescription.fastForwardOnly),
          _Opt('--continue', CommandDescription.continueOp),
          _Opt('--abort'),
        ],
      ),
      _Cmd(
        'rebase',
        options: [
          _Opt('-i'),
          _Opt('--continue', CommandDescription.continueOp),
          _Opt('--abort'),
          _Opt('--skip'),
          _Opt('--autostash'),
        ],
      ),
      _Cmd(
        'stash',
        options: [_Opt('-u', CommandDescription.includeUntracked)],
        subs: [
          _Cmd('list'),
          _Cmd('pop', desc: CommandDescription.stashPop),
          _Cmd('apply'),
          _Cmd('drop'),
          _Cmd('show'),
          _Cmd('push', options: [_Opt('-u', CommandDescription.includeUntracked), _Opt.value('-m')]),
        ],
      ),
      _Cmd(
        'clone',
        options: [_Opt.value('--depth'), _Opt.value('-b'), _Opt.value('--branch'), _Opt('--recurse-submodules')],
      ),
      _Cmd('reset', args: [_Arg('HEAD~1'), _Arg('HEAD')], options: [_Opt('--soft'), _Opt('--mixed')]),
      _Cmd('switch', options: [_Opt.value('-c', CommandDescription.newBranch)]),
      _Cmd('restore', options: [_Opt('--staged', CommandDescription.staged)]),
      _Cmd(
        'remote',
        options: [_verbose],
        subs: [_Cmd('add'), _Cmd('remove'), _Cmd('rename'), _Cmd('set-url'), _Cmd('show'), _Cmd('prune')],
      ),
      _Cmd('tag', options: [_Opt('-l'), _Opt('-a'), _Opt.value('-d'), _Opt.value('-m')]),
      _Cmd('show', args: [_Arg('HEAD')], options: [_Opt('--stat'), _Opt('--name-only')]),
      _Cmd('cherry-pick', options: [_Opt('--continue', CommandDescription.continueOp), _Opt('--abort')]),
      _Cmd('init', options: [_Opt.value('-b')]),
      _Cmd(
        'config',
        args: [_Arg('user.name'), _Arg('user.email')],
        options: [_Opt('--global'), _Opt('--list'), _Opt('-l')],
      ),
      _Cmd(
        'submodule',
        subs: [
          _Cmd('update', options: [_Opt('--init'), _Opt('--recursive')]),
          _Cmd('init'),
          _Cmd('status'),
        ],
      ),
      _Cmd('revert', options: [_Opt('--continue', CommandDescription.continueOp), _Opt('--abort')]),
      _Cmd('reflog'),
      _Cmd('blame'),
    ],
  ),
  _Cmd(
    'docker',
    options: [_Opt.value('--context'), _version, _help],
    subs: [
      _Cmd('ps', options: [_all, _Opt('-q'), _Opt.value('--format')]),
      _Cmd('images', options: [_all, _Opt('-q')]),
      _Cmd(
        'run',
        desc: CommandDescription.runContainer,
        options: [
          _Opt('-d', CommandDescription.background),
          _interactiveTty,
          _Opt('--rm', CommandDescription.removeOnExit),
          _Opt.value('--name', CommandDescription.label),
          _lowerPort,
          _Opt.value('-v', CommandDescription.volume),
          _Opt.value('-e', CommandDescription.env),
          _Opt.value('--network', null, ['host', 'bridge', 'none']),
          _Opt.value('--restart', CommandDescription.restartPolicy, ['always', 'unless-stopped', 'on-failure', 'no']),
          _user,
        ],
      ),
      _Cmd('exec', desc: CommandDescription.runInside, options: [_interactiveTty, _Opt('-i'), _Opt('-t'), _user]),
      _Cmd('logs', options: [_follow, _tail, _since, _Opt('-t')]),
      _Cmd('build', args: [_Arg('.')], options: [_Opt.value('-t'), _fileValue, _Opt('--no-cache')]),
      _Cmd(
        'compose',
        desc: CommandDescription.toolCompose,
        shared: [_fileValue, _Opt.value('-p')],
        subs: [
          _Cmd(
            'up',
            desc: CommandDescription.composeUp,
            options: [_Opt('-d', CommandDescription.background), _Opt('--build')],
          ),
          _Cmd('down', desc: CommandDescription.composeDown, options: [_Opt('--remove-orphans')]),
          _Cmd('ps', options: [_all]),
          _Cmd('logs', options: [_follow, _tail, _since]),
          _Cmd('restart'),
          _Cmd('stop'),
          _Cmd('start'),
          _Cmd('pull'),
          _Cmd('build', options: [_Opt('--no-cache')]),
          _Cmd('exec', desc: CommandDescription.runInside),
          _Cmd('config'),
        ],
      ),
      _Cmd('stop'),
      _Cmd('start'),
      _Cmd('restart'),
      _Cmd('rm', options: [_force]),
      _Cmd('rmi', options: [_force]),
      _Cmd('pull'),
      _Cmd('push'),
      _Cmd('inspect'),
      _Cmd('stats', options: [_Opt('--no-stream')]),
      _Cmd('cp'),
      _Cmd('network', subs: [_Cmd('ls'), _Cmd('inspect'), _Cmd('create'), _Cmd('rm')]),
      _Cmd('volume', subs: [_Cmd('ls'), _Cmd('inspect'), _Cmd('create'), _Cmd('rm')]),
      _Cmd('system', subs: [_Cmd('df'), _Cmd('info')]),
      _Cmd('top'),
      _Cmd('tag'),
      _Cmd('info'),
      _Cmd('version'),
    ],
  ),
  _Cmd(
    'kubectl',
    shared: [
      _Opt.value('-n', CommandDescription.namespace),
      _Opt.value('--namespace', CommandDescription.namespace),
      _Opt.value('--context'),
    ],
    subs: [
      _Cmd(
        'get',
        args: _kinds,
        options: [
          _Opt.value('-o', CommandDescription.outputFormat, ['wide', 'yaml', 'json', 'name']),
          _Opt('-A', CommandDescription.allNamespaces),
          _Opt('--all-namespaces', CommandDescription.allNamespaces),
          _Opt('-w'),
          _Opt.value('-l', CommandDescription.selector),
          _Opt('--show-labels'),
        ],
      ),
      _Cmd('describe', args: _kinds, options: [_Opt.value('-l', CommandDescription.selector)]),
      _Cmd(
        'logs',
        options: [
          _follow,
          _tail,
          _Opt.value('-c'),
          _Opt('--previous'),
          _Opt.value('--since', CommandDescription.since, ['5m', '1h', '24h']),
          _Opt.value('-l', CommandDescription.selector),
        ],
      ),
      _Cmd(
        'exec',
        desc: CommandDescription.runInside,
        options: [_interactiveTty, _Opt('-i'), _Opt('-t'), _Opt.value('-c')],
      ),
      _Cmd('apply', options: [_fileValue, _Opt.value('-k')]),
      _Cmd(
        'delete',
        args: _kinds,
        options: [_fileValue, _Opt('--all', CommandDescription.all), _Opt.value('-l', CommandDescription.selector)],
      ),
      _Cmd('rollout', subs: [_Cmd('status'), _Cmd('restart'), _Cmd('history'), _Cmd('undo')]),
      _Cmd('port-forward'),
      _Cmd('scale', options: [_Opt.value('--replicas')]),
      _Cmd('top', subs: [_Cmd('pods'), _Cmd('nodes')]),
      _Cmd(
        'config',
        subs: [_Cmd('current-context'), _Cmd('get-contexts'), _Cmd('use-context'), _Cmd('view'), _Cmd('set-context')],
      ),
      _Cmd('edit', args: _kinds),
      _Cmd('cp'),
      _Cmd('create', options: [_fileValue]),
      _Cmd('label'),
      _Cmd('annotate'),
      _Cmd('api-resources'),
      _Cmd('explain'),
      _Cmd('cluster-info'),
      _Cmd('version'),
    ],
  ),
  _Cmd(
    'helm',
    desc: CommandDescription.toolHelm,
    shared: [_Opt.value('-n', CommandDescription.namespace)],
    subs: [
      _Cmd('list', aliases: ['ls'], options: [_Opt('-A', CommandDescription.allNamespaces)]),
      _Cmd('install', options: [_fileValue, _dryRun]),
      _Cmd('upgrade', desc: CommandDescription.upgrade, options: [_fileValue, _Opt('-i'), _dryRun]),
      _Cmd('uninstall'),
      _Cmd('status'),
      _Cmd('repo', subs: [_Cmd('add'), _Cmd('update'), _Cmd('list')]),
      _Cmd('search'),
      _Cmd('rollback'),
    ],
  ),
  _Cmd(
    'tmux',
    desc: CommandDescription.toolTmux,
    options: [_Opt('-V'), _Opt.value('-L')],
    subs: [
      _Cmd(
        'attach',
        desc: CommandDescription.tmuxAttach,
        aliases: ['a', 'at', 'attach-session'],
        options: [_Opt.value('-t', CommandDescription.target), _Opt('-d'), _Opt('-r')],
      ),
      _Cmd(
        'new',
        desc: CommandDescription.tmuxNew,
        aliases: ['new-session'],
        options: [
          _Opt.value('-s', CommandDescription.label),
          _Opt('-d', CommandDescription.background),
          _Opt.value('-As', CommandDescription.label),
          _Opt.value('-n', CommandDescription.label),
          _Opt.value('-c', CommandDescription.directory),
        ],
      ),
      _Cmd('ls', desc: CommandDescription.tmuxList, aliases: ['list-sessions']),
      _Cmd(
        'kill-session',
        desc: CommandDescription.tmuxKillSession,
        options: [_Opt.value('-t', CommandDescription.target), _Opt('-a')],
      ),
      _Cmd('kill-server', desc: CommandDescription.tmuxKillServer),
      _Cmd('detach', desc: CommandDescription.tmuxDetach, aliases: ['detach-client']),
      _Cmd(
        'list-windows',
        desc: CommandDescription.tmuxWindows,
        aliases: ['lsw'],
        options: [_Opt.value('-t', CommandDescription.target)],
      ),
      _Cmd(
        'new-window',
        desc: CommandDescription.tmuxNewWindow,
        aliases: ['neww'],
        options: [
          _Opt.value('-n', CommandDescription.label),
          _Opt.value('-c', CommandDescription.directory),
          _Opt.value('-t', CommandDescription.target),
        ],
      ),
      _Cmd(
        'split-window',
        desc: CommandDescription.tmuxSplit,
        aliases: ['splitw'],
        options: [_Opt('-h'), _Opt('-v'), _Opt.value('-c', CommandDescription.directory)],
      ),
      _Cmd(
        'rename-session',
        desc: CommandDescription.tmuxRename,
        aliases: ['rename'],
        options: [_Opt.value('-t', CommandDescription.target)],
      ),
      _Cmd(
        'has-session',
        desc: CommandDescription.tmuxHas,
        aliases: ['has'],
        options: [_Opt.value('-t', CommandDescription.target)],
      ),
      _Cmd(
        'bind-key',
        desc: CommandDescription.tmuxBind,
        aliases: ['bind'],
        options: [_Opt('-n'), _Opt('-r'), _Opt.value('-T')],
      ),
      _Cmd(
        'break-pane',
        desc: CommandDescription.tmuxBreak,
        aliases: ['breakp'],
        options: [_Opt('-d'), _Opt.value('-s'), _Opt.value('-t')],
      ),
      _Cmd('source-file', desc: CommandDescription.tmuxSource, aliases: ['source']),
    ],
  ),
  _Cmd(
    'screen',
    desc: CommandDescription.toolScreen,
    options: [_Opt.value('-S', CommandDescription.label), _Opt('-r'), _Opt('-ls'), _Opt('-d')],
  ),
  _Cmd(
    'apt',
    shared: [_yes],
    subs: [
      _Cmd('update', desc: CommandDescription.refreshIndex),
      _Cmd('upgrade', desc: CommandDescription.upgrade),
      _Cmd('install', options: [_Opt('--no-install-recommends')]),
      _Cmd('remove'),
      _Cmd('autoremove'),
      _Cmd('search'),
      _Cmd('show'),
      _Cmd('list', options: [_Opt('--installed'), _Opt('--upgradable')]),
      _Cmd('full-upgrade'),
    ],
  ),
  _Cmd(
    'apt-get',
    shared: [_yes],
    subs: [
      _Cmd('update', desc: CommandDescription.refreshIndex),
      _Cmd('upgrade', desc: CommandDescription.upgrade),
      _Cmd('dist-upgrade'),
      ..._packageSubs,
    ],
  ),
  _Cmd('dnf', shared: [_yes], subs: _dnfSubs),
  _Cmd('yum', shared: [_yes], subs: _dnfSubs),
  _Cmd('rpm', options: [_Opt('-qa'), _Opt('-qi'), _Opt('-ql')]),
  _Cmd('dpkg', options: [_Opt('-l'), _Opt('-s'), _Opt('-L'), _Opt('-S'), _Opt('-i')]),
  _Cmd('pip', subs: _pipSubs),
  _Cmd('pip3', subs: _pipSubs),
  _Cmd(
    'python3',
    options: [
      _Opt.value('-m', null, ['venv', 'pip', 'http.server', 'json.tool']),
      _Opt('-V'),
    ],
  ),
  _Cmd(
    'npm',
    subs: [
      _Cmd('install', aliases: ['i', 'add'], options: [_Opt('-g'), _Opt('-D'), _Opt('--save-dev')]),
      _Cmd('run', args: [_Arg('build'), _Arg('dev'), _Arg('start'), _Arg('test'), _Arg('lint')]),
      _Cmd('start'),
      _Cmd('test'),
      _Cmd('ci'),
      _Cmd('update', desc: CommandDescription.upgrade),
      _Cmd('uninstall', aliases: ['remove', 'rm'], options: [_Opt('-g')]),
      _Cmd('ls', aliases: ['list'], options: [_Opt('-g')]),
      _Cmd('outdated'),
      _Cmd('init'),
    ],
  ),
  _Cmd(
    'make',
    args: [_Arg('all'), _Arg('clean'), _Arg('install'), _Arg('test'), _Arg('build')],
    options: [_Opt.value('-j'), _directoryValue, _Opt('-n', CommandDescription.dryRun), _fileValue],
  ),
  _Cmd(
    'ufw',
    subs: [
      _Cmd('status', args: [_Arg('verbose'), _Arg('numbered')]),
      _Cmd('enable'),
      _Cmd('disable'),
      _Cmd('allow', args: [_Arg('ssh'), _Arg('http'), _Arg('https')]),
      _Cmd('deny'),
      _Cmd('delete'),
      _Cmd('reload'),
    ],
  ),
  _Cmd(
    'firewall-cmd',
    options: [
      _Opt('--list-all'),
      _Opt('--reload'),
      _Opt('--permanent'),
      _Opt('--state'),
      _Opt.value('--add-service', null, ['ssh', 'http', 'https']),
      _Opt.value('--add-port'),
    ],
  ),
  _Cmd(
    'nginx',
    options: [
      _Opt('-t'),
      _Opt.value('-s', null, ['reload', 'stop', 'quit', 'reopen']),
    ],
  ),
  _Cmd('vim'),
  _Cmd('vi'),
  _Cmd('nano'),
  _Cmd('man'),
  _Cmd('clear'),
  _Cmd('echo'),
  _Cmd('history'),
];

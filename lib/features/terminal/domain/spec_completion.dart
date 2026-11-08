/// Completes the last word of a command line from a static [CompletionSpec] (docs/COMPLETION_ENGINE.md). No IO, no
/// shell, no clock: spec and draft in, typed suggestions and an optional path request out. Directories are listed by
/// the caller, who hands the entries to [PathCompletionRequest.resolve].
library;

import 'completion_context.dart';
import 'completion_spec.dart';

export 'completion_context.dart';
export 'completion_spec.dart';

/// Not tied to the catalog's kinds: the caller maps these.
enum SpecSuggestionKind { command, subcommand, option, argument, file, folder }

/// One way to finish the last word. The range [replaceStart]..[replaceEnd] is always the whole last word of the
/// draft, so [replacement] is exactly what that range holds afterwards.
class SpecSuggestion {
  const SpecSuggestion({
    required this.value,
    required this.display,
    required this.kind,
    required this.replaceStart,
    required this.replaceEnd,
    required this.replacement,
    this.suffix,
    this.description,
    this.appendSpace = true,
    this.canBrowse = false,
  });

  /// The whole logical word after insertion (unquoted, unescaped), e.g. `--file=a b`.
  final String value;

  /// A short label: the completed name, not the whole word.
  final String display;
  final String? description;
  final SpecSuggestionKind kind;
  final int replaceStart, replaceEnd;

  /// The raw text of the word after insertion, quoted and escaped for the shell.
  final String replacement;

  /// Set when [replacement] is the typed raw word plus this text, so typing it extends the draft and nothing has to be
  /// deleted. Null when the typed text is not a prefix of [value] (a spec's `insertValue`): applying it replaces typed
  /// characters, which the caller must confirm or skip.
  final String? suffix;

  /// False where the word goes on: after a folder (`/`) and after `--name=`.
  final bool appendSpace;

  /// Whether the candidate has a directory or command branch to browse without changing the draft.
  final bool canBrowse;

  bool get isAppendOnly => suffix != null;

  /// [draft] with the last word replaced; [draft] must be the one this suggestion was made for.
  String applyTo(String draft) => draft.replaceRange(replaceStart, replaceEnd, replacement);
}

class CompletionPathEntry {
  const CompletionPathEntry(this.name, {this.isDirectory = false});

  /// The raw name; a folder here is a directory or a link to one.
  final String name;
  final bool isDirectory;
}

/// A path word whose candidates only the caller can list. All offsets are indices of the draft it was made for.
class PathCompletionRequest {
  const PathCompletionRequest({
    required this.typedPrefix,
    required this.foldersOnly,
    required this.tokenStart,
    required this.tokenEnd,
    required this.valueStart,
    required this.quote,
    required this.tokenValue,
    required this.tokenRaw,
  });

  /// The path text typed so far, unquoted and unescaped: `~/pro`, `src/ma`, `My Do`.
  final String typedPrefix;
  final bool foldersOnly;

  /// The whole last word, raw.
  final int tokenStart, tokenEnd;

  /// Where the path text starts in the draft: [tokenStart], or after the `=` of `--file=x` or the `-I` of `-Ipath`.
  /// An opening quote right after that point is part of the path text.
  final int valueStart;

  /// The quote the word ends inside of, if any.
  final CompletionQuote quote;

  /// The logical value and raw text of the whole last word, `--file=` and all.
  final String tokenValue, tokenRaw;

  /// What comes before [typedPrefix] in the word (`--file=`).
  String get tokenPrefix => tokenValue.substring(0, tokenValue.length - typedPrefix.length);

  /// The directory to list, logical, with a trailing `/`: `~/`, `/etc/`, `src/`, `../`; empty for the working
  /// directory. `~` expands to the login user's home on the caller's side.
  String get directory {
    if (typedPrefix == '~') return '~/';
    final slash = typedPrefix.lastIndexOf('/');
    return slash < 0 ? '' : typedPrefix.substring(0, slash + 1);
  }

  /// The part after the last `/`: what the listed names must start with.
  String get namePrefix => typedPrefix == '~' ? '' : typedPrefix.substring(directory.length);

  /// Suggestions for [entries] of [directory], in the order given (the lister sorts) and at most [limit]. Names that
  /// cannot be a word (control characters, `/`), dotfiles unless [namePrefix] starts with `.`, and files for
  /// [foldersOnly] are dropped. A folder ends in `/` and does not append a space, so the next request goes one
  /// level deeper.
  List<SpecSuggestion> resolve(Iterable<CompletionPathEntry> entries, {int limit = 200}) {
    final dir = directory, prefix = namePrefix, head = tokenPrefix;
    final hideDots = !prefix.startsWith('.');
    final named = <CompletionPathEntry>[
      if (prefix.isNotEmpty && '..'.startsWith(prefix)) const CompletionPathEntry('..', isDirectory: true),
    ];
    final seen = <String>{if (named.isNotEmpty) '..'};
    for (final e in entries) {
      final name = e.name;
      if (name == '.' || name == '..' || name.contains('/') || !completionValueValid(name)) continue;
      if (hideDots && name.startsWith('.')) continue;
      if (!name.startsWith(prefix) || (foldersOnly && !e.isDirectory) || !seen.add(name)) continue;
      named.add(e);
    }
    final out = <SpecSuggestion>[];
    for (final e in named) {
      if (out.length >= limit) break;
      // A name that starts with `-` would be read as an option when nothing precedes it.
      final lead = dir.isEmpty && prefix.isEmpty && e.name.startsWith('-') ? './' : dir;
      final slash = e.isDirectory ? '/' : '';
      final s = _suggestion(
        value: '$head$lead${e.name}$slash',
        display: '${e.name}$slash',
        kind: e.isDirectory ? SpecSuggestionKind.folder : SpecSuggestionKind.file,
        currentValue: tokenValue,
        currentRaw: tokenRaw,
        start: tokenStart,
        end: tokenEnd,
        quote: quote,
        appendSpace: !e.isDirectory,
        canBrowse: e.isDirectory,
      );
      if (s != null) out.add(s);
    }
    return out;
  }
}

typedef SpecLookup = CompletionSpec? Function(String key);

class SpecCompletionConfig {
  const SpecCompletionConfig({
    this.limit = 200,
    this.includeOptionsForEmptyToken = false,
    this.nested,
    this.command,
    this.commandCanBrowse,
    this.commands = const [],
  });

  /// At most this many suggestions are returned; [SpecCompletionResult.truncated] says there were more.
  final int limit;

  /// Also offer the options (canonical names) where the word is still empty.
  final bool includeOptionsForEmptyToken;

  /// Resolves a [CompletionSpec.loadSpec] key; null when it is not loaded (yet).
  final SpecLookup? nested;

  /// Resolves the spec of the command that follows an `isCommand` argument (`sudo git`); null when unknown.
  final SpecLookup? command;

  /// Reads already known command metadata without requesting or loading another spec.
  final bool Function(String name)? commandCanBrowse;

  /// The command names offered where an `isCommand` argument is typed.
  final List<CompletionChoice> commands;
}

class SpecCompletionResult {
  const SpecCompletionResult(
    this.context, {
    this.suggestions = const [],
    this.path,
    this.truncated = false,
    this.missingNested,
    this.missingCommand,
  });

  final CompletionContext context;

  /// Ordered, without repeated values, at most [SpecCompletionConfig.limit].
  final List<SpecSuggestion> suggestions;

  /// Set when the word is a path the caller can list.
  final PathCompletionRequest? path;
  final bool truncated;

  /// A [CompletionSpec.loadSpec] key or a command name whose spec was needed and not supplied. Load it and ask again.
  final String? missingNested, missingCommand;

  bool get isEmpty => suggestions.isEmpty && path == null;
}

/// Suggestions for the last word of [draft]. [spec] is the spec of the command the draft starts with; null (or a spec
/// of another command) means an unknown command, for which only explicit paths and plain arguments get a path request.
SpecCompletionResult completeSpec(
  CompletionSpec? spec,
  String draft, {
  SpecCompletionConfig config = const SpecCompletionConfig(),
}) => completeSpecInContext(spec, CompletionContext.parse(draft), config: config);

/// Like [completeSpec] for a draft that is already parsed.
SpecCompletionResult completeSpecInContext(
  CompletionSpec? spec,
  CompletionContext context, {
  SpecCompletionConfig config = const SpecCompletionConfig(),
}) {
  if (!context.supported) return SpecCompletionResult(context);
  final words = context.words;
  final needs = _Needs();
  if (spec == null || words.isEmpty || !spec.names.contains(words.first.value)) {
    return _fallback(
      context,
      needs,
      atArgument: words.isNotEmpty,
      sawOption: words.skip(1).any((w) => _dashed(w.value)),
    );
  }
  final root = _loaded(spec, config, needs);
  if (root == null) return SpecCompletionResult(context, missingNested: needs.nested);
  final walk = _Walk(config, needs, root);
  for (final word in words.skip(1)) {
    walk.consume(word);
  }
  final leaf = walk.leaf;
  if (leaf.unknown) return _fallback(context, needs, atArgument: true, sawOption: leaf.sawOption);
  return _Collect(context, leaf, config).run(needs);
}

bool _dashed(String text) => text.length > 1 && text.startsWith('-');

final _digits = RegExp(r'^-\d+$');

bool _explicitPath(String text) =>
    text.startsWith('/') ||
    text.startsWith('./') ||
    text.startsWith('../') ||
    text.startsWith('~/') ||
    text == '.' ||
    text == '..' ||
    text == '~';

/// Specs that were asked for and not there; the first of each kind is reported.
class _Needs {
  String? nested, command;
}

/// [node] with the target of its `loadSpec` merged in. A node that has nothing of its own and whose target is not
/// loaded is unusable (null); with content it stays usable but the missing key is still reported.
CompletionSpec? _loaded(CompletionSpec node, SpecCompletionConfig config, _Needs needs) {
  final key = node.loadSpec;
  if (key == null) return node;
  final target = config.nested?.call(key);
  if (target != null) return node.withLoaded(target);
  needs.nested ??= key;
  return node.hasContent ? node : null;
}

PathCompletionRequest? _pathRequest(CompletionContext ctx, int prefixLen, {required bool foldersOnly}) {
  final cur = ctx.current;
  final typed = cur.value.substring(prefixLen);
  // `~name` is another user's home, which cannot be listed.
  if (typed.startsWith('~') && typed != '~' && !typed.contains('/')) return null;
  return PathCompletionRequest(
    typedPrefix: typed,
    foldersOnly: foldersOnly,
    tokenStart: cur.start,
    tokenEnd: ctx.draft.length,
    valueStart: cur.start + cur.rawOffsetAfter(prefixLen),
    quote: ctx.quote,
    tokenValue: cur.value,
    tokenRaw: cur.raw,
  );
}

SpecCompletionResult _fallback(
  CompletionContext ctx,
  _Needs needs, {
  required bool atArgument,
  required bool sawOption,
}) {
  final text = ctx.current.value;
  final generic = atArgument && !sawOption && text.isNotEmpty && !text.startsWith('-');
  return SpecCompletionResult(
    ctx,
    path: _explicitPath(text) || generic ? _pathRequest(ctx, 0, foldersOnly: false) : null,
    missingNested: needs.nested,
    missingCommand: needs.command,
  );
}

/// The suggestion that turns the last word, [currentValue] (raw [currentRaw]), into [value]. Null for the word as it
/// is and for values that cannot be one word.
SpecSuggestion? _suggestion({
  required String value,
  required String display,
  required SpecSuggestionKind kind,
  required String currentValue,
  required String currentRaw,
  required int start,
  required int end,
  required CompletionQuote quote,
  required bool appendSpace,
  bool canBrowse = false,
  String? description,
}) {
  if (value == currentValue || !completionValueValid(value)) return null;
  final String replacement;
  final String? suffix;
  if (value.startsWith(currentValue)) {
    suffix = encodeShellSuffix(
      value.substring(currentValue.length),
      quote,
      atWordStart: currentValue.isEmpty,
      close: appendSpace,
    );
    replacement = currentRaw + suffix;
  } else {
    suffix = null;
    replacement = encodeShellWord(value, quote, close: appendSpace);
  }
  return SpecSuggestion(
    value: value,
    display: display,
    description: description,
    kind: kind,
    replaceStart: start,
    replaceEnd: end,
    replacement: replacement,
    suffix: suffix,
    appendSpace: appendSpace,
    canBrowse: canBrowse,
  );
}

(int, int)? _separatorAt(String text, List<String> separators) {
  int? at;
  var length = 0;
  for (final sep in separators) {
    final i = text.indexOf(sep, 1);
    if (i > 0 && (at == null || i < at)) {
      at = i;
      length = sep.length;
    }
  }
  return at == null ? null : (at, length);
}

/// The index of the argument that the word at [position] belongs to, or -1 when all arguments are used up.
int _argIndex(List<CompletionArg> args, int position) {
  for (var k = 0; k < args.length; k++) {
    if (k == position || (args[k].isVariadic && position >= k)) return k;
  }
  return -1;
}

class _Pending {
  const _Pending(this.option, this.index);

  final CompletionOption option;
  final int index;

  CompletionArg get arg => option.args[index];
}

class _ShortOptions {
  const _ShortOptions(this.hits, this.subcommand, this.valueStart);

  final List<(CompletionOption, String?)> hits;
  final CompletionSpec? subcommand;
  final int? valueStart;
}

/// Reads the words before the last one: which command node they lead to and what is still owed.
class _Walk {
  _Walk(this.config, this.needs, CompletionSpec root) : chain = [root];

  final SpecCompletionConfig config;
  final _Needs needs;

  /// The root and every subcommand entered, innermost last.
  final List<CompletionSpec> chain;
  final used = <CompletionOption, int>{};

  /// Positional words at the innermost node.
  var positionals = 0;

  /// The option whose next word is its value.
  _Pending? pending;

  /// After `--`.
  var delimiter = false;

  /// An option the spec does not know was seen: whether the next word was its value is unknown.
  var tainted = false;

  /// The words cannot be classified (unknown subcommand, spec not loaded).
  var dead = false;

  /// The command after an `isCommand` argument has no spec; [sawOption] tells whether an option followed.
  var unknown = false, sawOption = false;

  /// The walk of the command that an `isCommand` argument started.
  _Walk? inner;

  CompletionSpec get node => chain.last;

  _Walk get leaf => inner?.leaf ?? this;

  void consume(CommandToken word) {
    final next = inner;
    if (next != null) {
      next.consume(word);
      return;
    }
    final text = word.value;
    if (dead) {
      if (unknown && _dashed(text)) sawOption = true;
      return;
    }
    var wait = pending;
    if (wait != null && wait.arg.isVariadic && _dashed(text)) {
      pending = wait = null;
    }
    if (wait != null) {
      _advance(wait);
      return;
    }
    if (delimiter) {
      _positional(word);
    } else if (text == '--') {
      delimiter = true;
    } else if (_dashed(text) && _subcommand(text) != null) {
      _positional(word);
    } else if (_dashed(text) && !(node.directives.optionsMustPrecedeArguments && positionals > 0)) {
      _option(text);
    } else {
      _positional(word);
    }
  }

  /// Options that apply here: the innermost node's, then the persistent ones of the nodes above. A name that a
  /// nearer node declares hides the same name further out.
  List<CompletionOption> available([CompletionSpec? subcommand]) {
    final layers = subcommand == null ? chain : [...chain, subcommand];
    final seen = <String>{};
    final out = <CompletionOption>[];
    for (var i = layers.length - 1; i >= 0; i--) {
      final layer = <String>[];
      for (final o in layers[i].options) {
        if (i != layers.length - 1 && !o.isPersistent) continue;
        if (o.names.any(seen.contains)) continue;
        out.add(o);
        layer.addAll(o.names);
      }
      seen.addAll(layer);
    }
    return out;
  }

  CompletionOption? lookup(String name, [CompletionSpec? subcommand]) {
    for (final o in available(subcommand)) {
      if (o.names.contains(name)) return o;
    }
    return null;
  }

  CompletionSpec? _subcommand(String name) {
    if (delimiter || positionals != 0 || lookup(name) != null) return null;
    for (final subcommand in node.subcommands) {
      if (subcommand.names.contains(name)) return subcommand;
    }
    return null;
  }

  /// Whether [o] may still be offered: not used up, not excluded by or requiring another option. [extra] are options
  /// of the word being typed.
  bool eligible(CompletionOption o, [List<CompletionOption> extra = const []]) {
    var count = used[o] ?? 0;
    for (final e in extra) {
      if (identical(e, o)) count++;
    }
    final most = o.maxUses;
    if (most != null && count >= most) return false;
    final taken = [...used.keys, ...extra];
    for (final t in taken) {
      if (o.exclusiveOn.any(t.names.contains) || t.exclusiveOn.any(o.names.contains)) return false;
    }
    for (final need in o.dependsOn) {
      if (!taken.any((t) => t.names.contains(need))) return false;
    }
    return true;
  }

  void _advance(_Pending p) {
    if (p.arg.isVariadic) {
      pending = p;
      return;
    }
    final next = p.index + 1;
    pending = next < p.option.args.length && !p.option.args[next].isOptional ? _Pending(p.option, next) : null;
  }

  void _hit(CompletionOption o, String? attached) {
    used[o] = (used[o] ?? 0) + 1;
    if (o.args.isEmpty) return;
    if (attached != null) {
      pending = o.args.length > 1 && !o.args.first.isVariadic && !o.args[1].isOptional ? _Pending(o, 1) : null;
    } else if (o.separator == null && !o.args.first.isOptional) {
      pending = _Pending(o, 0);
    }
  }

  void _option(String text) {
    if (_digits.hasMatch(text)) return;
    final exact = lookup(text);
    if (exact != null) {
      _hit(exact, null);
      return;
    }
    final cut = _separatorAt(text, node.directives.optionArgSeparators);
    if (cut != null) {
      final named = lookup(text.substring(0, cut.$1));
      if (named != null) {
        _hit(named, text.substring(cut.$1 + cut.$2));
        return;
      }
    }
    final bundled = !text.startsWith('--') && !node.directives.flagsArePosixNoncompliant && _bundle(text);
    if (!bundled && cut == null) tainted = true;
  }

  /// Reads a short bundle without changing state; a dashed subcommand may select the options for the rest.
  _ShortOptions? shortOptions(String text) {
    final hits = <(CompletionOption, String?)>[];
    CompletionSpec? subcommand;
    int? valueStart;
    for (var i = 1; i < text.length; i++) {
      final name = '-${text[i]}';
      final o = lookup(name, subcommand);
      if (o == null) {
        final sub = subcommand == null ? _subcommand(name) : null;
        if (sub == null) return null;
        subcommand = _loaded(sub, config, needs);
        if (subcommand == null) return null;
        continue;
      }
      if (o.args.isEmpty) {
        hits.add((o, null));
        continue;
      }
      final sep = o.separator;
      var start = i + 1;
      if (sep != null && text.startsWith(sep, start)) start += sep.length;
      valueStart = start;
      hits.add((o, start < text.length ? text.substring(start) : null));
      break;
    }
    return _ShortOptions(hits, subcommand, valueStart);
  }

  /// `-xzf`, `-I/path`: no state changes when any letter is unknown.
  bool _bundle(String text) {
    final bundle = shortOptions(text);
    if (bundle == null) return false;
    final subcommand = bundle.subcommand;
    if (subcommand != null) {
      chain.add(subcommand);
      positionals = 0;
    }
    for (final (o, attached) in bundle.hits) {
      _hit(o, attached);
    }
    return true;
  }

  void _positional(CommandToken word) {
    final here = node;
    if (!delimiter && positionals == 0 && here.subcommands.isNotEmpty) {
      CompletionSpec? sub;
      for (final s in here.subcommands) {
        if (s.names.contains(word.value)) {
          sub = s;
          break;
        }
      }
      if (sub != null) {
        final resolved = _loaded(sub, config, needs);
        if (resolved == null) {
          dead = true;
        } else {
          chain.add(resolved);
          positionals = 0;
        }
        return;
      }
      if (here.args.isEmpty) {
        dead = true;
        return;
      }
    }
    final k = _argIndex(here.args, positionals);
    positionals++;
    if (k >= 0 && here.args[k].isCommand) _reroot(word);
  }

  void _reroot(CommandToken word) {
    final spec = config.command?.call(word.value);
    if (spec == null) {
      needs.command ??= word.value;
      dead = true;
      unknown = true;
      return;
    }
    final root = _loaded(spec, config, needs);
    if (root == null) {
      dead = true;
    } else {
      inner = _Walk(config, needs, root);
    }
  }
}

/// A suggestion before it is turned into text. [match] is what the typed text must prefix; [value] what is inserted.
class _Candidate {
  const _Candidate(
    this.value,
    this.display,
    this.description,
    this.kind,
    this.rank, {
    this.match,
    this.appendSpace = true,
    this.canBrowse = false,
  });

  final String value, display;
  final String? description, match;
  final SpecSuggestionKind kind;
  final int rank;
  final bool appendSpace, canBrowse;
}

/// Turns the state of a [_Walk] into suggestions for the last word.
class _Collect {
  _Collect(this.ctx, this.walk, this.config);

  final CompletionContext ctx;
  final _Walk walk;
  final SpecCompletionConfig config;
  final _out = <SpecSuggestion>[];
  final _seen = <String>{};
  bool? _foldersOnly;
  var _pathPrefix = 0;

  SpecCompletionResult run(_Needs needs) {
    if (!walk.dead) _collect();
    final folders = _foldersOnly;
    final more = _out.length > config.limit;
    return SpecCompletionResult(
      ctx,
      suggestions: List.unmodifiable(_out.take(config.limit)),
      path: folders == null ? null : _pathRequest(ctx, _pathPrefix, foldersOnly: folders),
      truncated: more,
      missingNested: needs.nested,
      missingCommand: needs.command,
    );
  }

  void _collect() {
    final text = ctx.current.value;
    final wait = walk.pending;
    if (wait != null) {
      _values(wait.arg, 0);
    } else if (!walk.delimiter &&
        text.startsWith('-') &&
        !(walk.node.directives.optionsMustPrecedeArguments && walk.positionals > 0)) {
      _options(text);
    } else {
      _positional(text);
    }
  }

  /// [value] is the whole word for a flag that joins the bundle being typed (`-la` + `-h`).
  _Candidate _option(CompletionOption o, String name, {String? value}) {
    final sep = o.separator;
    final match = value ?? (sep == null ? name : '$name$sep');
    final canonical = name == o.names.first;
    return _Candidate(
      value ?? (canonical ? (o.insertValue ?? match) : match),
      (canonical ? o.displayName : null) ?? match,
      o.description,
      SpecSuggestionKind.option,
      (o.isRequired ? 1000 : 0) + o.priority,
      match: match,
      appendSpace: sep == null,
    );
  }

  void _options(String text) {
    final node = walk.node;
    final directives = node.directives;
    final plainBundle = !directives.flagsArePosixNoncompliant && !text.startsWith('--');

    // The value of an option that is already named in this word: `--file=x`, `-Ipath`.
    final cut = _separatorAt(text, directives.optionArgSeparators);
    if (cut != null) {
      final named = walk.lookup(text.substring(0, cut.$1));
      if (named != null) {
        if (named.args.isNotEmpty) _values(named.args.first, cut.$1 + cut.$2);
        return;
      }
    }
    final bundle = plainBundle && text.length >= 2 && walk.lookup(text) == null ? walk.shortOptions(text) : null;
    final valueStart = bundle?.valueStart;
    if (valueStart != null && valueStart < text.length) {
      _values(bundle!.hits.last.$1.args.first, valueStart);
      return;
    }

    final available = walk.available(bundle?.subcommand);
    final candidates = <_Candidate>[];
    if (walk.positionals == 0 && !walk.delimiter) {
      for (final sub in node.subcommands) {
        if (sub.hidden) continue;
        for (final name in sub.names.where((name) => name.startsWith('-'))) {
          candidates.add(
            _Candidate(
              name,
              name,
              sub.description,
              SpecSuggestionKind.subcommand,
              sub.priority,
              canBrowse: sub.canBrowse,
            ),
          );
        }
      }
    }
    for (final o in available) {
      if (o.hidden || !walk.eligible(o)) continue;
      for (final name in o.names) {
        if (name != '--') candidates.add(_option(o, name));
      }
    }

    // `-la` is made of known flags: offer the flags that can join it.
    if (plainBundle && text.length >= 2) {
      final flags = bundle ?? walk.shortOptions(text);
      final inside = flags?.hits.map((hit) => hit.$1).toList() ?? const <CompletionOption>[];
      if (flags != null && flags.valueStart == null) {
        for (final o in available) {
          if (o.hidden || !walk.eligible(o, inside)) continue;
          for (final name in o.names) {
            if (name.length == 2 && !name.startsWith('--')) candidates.add(_option(o, name, value: '$text${name[1]}'));
          }
        }
      }
    }
    _emit(candidates);
  }

  void _positional(String text) {
    if (walk.tainted) return;
    final node = walk.node;
    if (!walk.delimiter && walk.positionals == 0) {
      final candidates = <_Candidate>[];
      for (final sub in node.subcommands) {
        if (sub.hidden) continue;
        for (final name in sub.names) {
          final canonical = name == sub.names.first;
          if (text.isEmpty && !canonical) continue;
          candidates.add(
            _Candidate(
              canonical ? (sub.insertValue ?? name) : name,
              (canonical ? sub.displayName : null) ?? name,
              sub.description,
              SpecSuggestionKind.subcommand,
              sub.priority,
              match: name,
              canBrowse: sub.canBrowse,
            ),
          );
        }
      }
      for (final c in node.additionalSuggestions) {
        candidates.add(_choice(c, '', SpecSuggestionKind.argument));
      }
      _emit(candidates);
    }
    final k = _argIndex(node.args, walk.positionals);
    if (k >= 0) {
      // An optional argument may be skipped, so the one after it is a candidate too.
      for (var j = k; j < node.args.length; j++) {
        _values(node.args[j], 0);
        if (!node.args[j].isOptional || node.args[j].isVariadic) break;
      }
    }
    if (config.includeOptionsForEmptyToken && text.isEmpty && !walk.delimiter) {
      _emit([
        for (final o in walk.available())
          if (!o.hidden && walk.eligible(o)) _option(o, o.names.first),
      ]);
    }
  }

  _Candidate _choice(CompletionChoice c, String head, SpecSuggestionKind kind) => _Candidate(
    '$head${c.inserted}',
    c.displayName ?? c.value,
    c.description,
    kind,
    c.priority,
    match: '$head${c.value}',
    canBrowse: kind == SpecSuggestionKind.command && (config.commandCanBrowse?.call(c.inserted) ?? false),
  );

  /// The value of [arg], whose typed part starts after the first [prefixLen] characters of the word.
  void _values(CompletionArg arg, int prefixLen) {
    if (arg.isScript) return;
    final head = ctx.current.value.substring(0, prefixLen);
    final candidates = <_Candidate>[];
    if (arg.isCommand) {
      for (final c in config.commands) {
        candidates.add(_choice(c, head, SpecSuggestionKind.command));
      }
      _path(prefixLen, foldersOnly: false, explicitOnly: true);
    }
    for (final c in arg.choices) {
      candidates.add(_choice(c, head, SpecSuggestionKind.argument));
    }
    _emit(candidates);
    final files = arg.templates.contains(CompletionTemplate.filepaths);
    if (files || arg.templates.contains(CompletionTemplate.folders)) {
      _path(prefixLen, foldersOnly: !files);
    } else if (!arg.isCommand && arg.choices.isEmpty) {
      _path(prefixLen, foldersOnly: false, explicitOnly: true);
    }
  }

  void _path(int prefixLen, {required bool foldersOnly, bool explicitOnly = false}) {
    if (explicitOnly && !_explicitPath(ctx.current.value.substring(prefixLen))) return;
    _foldersOnly = (_foldersOnly ?? true) && foldersOnly;
    _pathPrefix = prefixLen;
  }

  /// Adds what matches the typed word, best rank first and otherwise in spec order, until one more than the limit.
  void _emit(List<_Candidate> candidates) {
    final cur = ctx.current;
    final matched = [
      for (final c in candidates)
        if ((c.match ?? c.value).startsWith(cur.value)) c,
    ];
    final order = [for (var i = 0; i < matched.length; i++) i]
      ..sort((a, b) {
        final byRank = matched[b].rank - matched[a].rank;
        return byRank != 0 ? byRank : a - b;
      });
    for (final i in order) {
      if (_out.length > config.limit) return;
      final c = matched[i];
      if (_seen.contains(c.value)) continue;
      final s = _suggestion(
        value: c.value,
        display: c.display,
        description: c.description,
        kind: c.kind,
        currentValue: cur.value,
        currentRaw: cur.raw,
        start: cur.start,
        end: ctx.draft.length,
        quote: ctx.quote,
        appendSpace: c.appendSpace,
        canBrowse: c.canBrowse,
      );
      if (s == null) continue;
      _seen.add(c.value);
      _out.add(s);
    }
  }
}

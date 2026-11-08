/// Static command specs as pure data, in the shape of the Fig-style JSON of docs/COMPLETION_SPECS.md. Only what the
/// engine can use is kept (docs/COMPLETION_ENGINE.md). Unknown keys are ignored; a known key of the wrong type is a
/// [FormatException], so a damaged file never becomes a half-read spec. What the engine cannot use is dropped instead:
/// an option without a `-` name, a `loadSpec` that is neither text nor an object, and an argument's `loadSpec`.
library;

/// Where an argument's values come from besides [CompletionArg.choices]. [history] is the caller's business.
enum CompletionTemplate { filepaths, folders, history }

/// The sort hint of a spec that gives none (0-100, higher first).
const completionDefaultPriority = 50;

const _maxDepth = 24;

/// Fig's `parserDirectives`: how the words of one command are read.
class ParserDirectives {
  const ParserDirectives({
    this.flagsArePosixNoncompliant = false,
    this.optionsMustPrecedeArguments = false,
    this.optionArgSeparators = const ['='],
  });

  static const standard = ParserDirectives();

  factory ParserDirectives.fromJson(Object? json) => _directives(json, 'parserDirectives');

  /// `-name` is one option, never the bundle `-n -a -m -e`.
  final bool flagsArePosixNoncompliant;

  /// A word after the first argument is an argument even if it starts with `-`.
  final bool optionsMustPrecedeArguments;

  /// What may join an option and its value in one word (`--file=x`).
  final List<String> optionArgSeparators;
}

/// One static suggestion of an argument.
class CompletionChoice {
  const CompletionChoice(
    this.value, {
    this.description,
    this.displayName,
    this.insertValue,
    this.priority = completionDefaultPriority,
  });

  /// What is matched against the typed text.
  final String value;
  final String? description, displayName;

  /// The whole logical word that is inserted instead of [value] (Fig's `{cursor}` marker already removed).
  final String? insertValue;
  final int priority;

  String get inserted => insertValue ?? value;
}

class CompletionArg {
  const CompletionArg({
    this.name,
    this.description,
    this.isOptional = false,
    this.isVariadic = false,
    this.isCommand = false,
    this.isScript = false,
    this.choices = const [],
    this.templates = const <CompletionTemplate>{},
  });

  factory CompletionArg.fromJson(Object? json) => _arg(json, 'arg');

  final String? name, description;
  final bool isOptional, isVariadic;

  /// The word is a command of its own (`sudo`, `xargs`); the rest of the line belongs to that command.
  final bool isCommand;

  /// The word is shell text (`sh -c`); nothing is suggested for it.
  final bool isScript;
  final List<CompletionChoice> choices;
  final Set<CompletionTemplate> templates;
}

class CompletionOption {
  const CompletionOption(
    this.names, {
    this.description,
    this.displayName,
    this.insertValue,
    this.priority = completionDefaultPriority,
    this.args = const [],
    this.isPersistent = false,
    this.maxUses = 1,
    this.isRequired = false,
    this.separator,
    this.exclusiveOn = const [],
    this.dependsOn = const [],
    this.hidden = false,
  });

  factory CompletionOption.fromJson(Object? json) => _option(json, 'option');

  /// Aliases, each with its dashes; the first is the canonical one.
  final List<String> names;
  final String? description, displayName, insertValue;
  final int priority;
  final List<CompletionArg> args;

  /// Also valid in every subcommand below the one that declares it.
  final bool isPersistent;

  /// How often the option may appear; null is unlimited (Fig's `isRepeatable: true`).
  final int? maxUses;
  final bool isRequired;

  /// The value must be attached with this text (`--file=x`); the next word is never its value.
  final String? separator;
  final List<String> exclusiveOn, dependsOn;
  final bool hidden;
}

/// A command or subcommand node; the root of a spec file is one too.
class CompletionSpec {
  const CompletionSpec(
    this.names, {
    this.description,
    this.displayName,
    this.insertValue,
    this.priority = completionDefaultPriority,
    this.subcommands = const [],
    this.options = const [],
    this.args = const [],
    this.additionalSuggestions = const [],
    this.loadSpec,
    this.directives = ParserDirectives.standard,
    this.hidden = false,
  });

  factory CompletionSpec.fromJson(Object? json) => _spec(json, 'spec', 0);

  /// Null instead of a [FormatException] for data that is not a spec.
  static CompletionSpec? tryParse(Object? json) {
    try {
      return CompletionSpec.fromJson(json);
    } on FormatException {
      return null;
    }
  }

  /// Aliases; the first is the canonical name.
  final List<String> names;
  final String? description, displayName, insertValue;
  final int priority;
  final List<CompletionSpec> subcommands;
  final List<CompletionOption> options;
  final List<CompletionArg> args;

  /// Extra words offered where a subcommand is expected.
  final List<CompletionChoice> additionalSuggestions;

  /// The key of another spec that holds more of this node; unresolved until a loader supplies it.
  final String? loadSpec;
  final ParserDirectives directives;
  final bool hidden;

  String get name => names.first;

  bool get hasContent => subcommands.isNotEmpty || options.isNotEmpty || args.isNotEmpty;

  /// This node with what [loaded] (the target of [loadSpec]) adds after it.
  CompletionSpec withLoaded(CompletionSpec loaded) => CompletionSpec(
    names,
    description: description ?? loaded.description,
    displayName: displayName,
    insertValue: insertValue,
    priority: priority,
    subcommands: [...subcommands, ...loaded.subcommands],
    options: [...options, ...loaded.options],
    args: args.isNotEmpty ? args : loaded.args,
    additionalSuggestions: [...additionalSuggestions, ...loaded.additionalSuggestions],
    directives: identical(directives, ParserDirectives.standard) ? loaded.directives : directives,
    hidden: hidden,
  );
}

Never _bad(String at, String what) => throw FormatException('$at: $what');

Map<String, Object?> _map(Object? v, String at) {
  if (v is! Map) _bad(at, 'expected an object');
  return {for (final e in v.entries) '${e.key}': e.value};
}

List<String> _names(Object? v, String at) {
  final names = switch (v) {
    String s => [s],
    List l => [for (final x in l) x is String ? x : _bad(at, 'a name must be text')],
    _ => _bad(at, 'name must be text or a list of text'),
  };
  if (names.isEmpty || names.any((n) => n.isEmpty)) _bad(at, 'empty name');
  return names.toSet().toList(growable: false);
}

List<String> _strings(Object? v, String at) => switch (v) {
  null => const [],
  String s => [s],
  List l => [for (final x in l) x is String ? x : _bad(at, 'expected text')],
  _ => _bad(at, 'expected text or a list of text'),
};

/// Text, with the empty string as no text.
String? _text(Object? v, String at) => switch (v) {
  null => null,
  String s => s.isEmpty ? null : s,
  _ => _bad(at, 'expected text'),
};

bool _flag(Object? v, String at) => switch (v) {
  null => false,
  bool b => b,
  _ => _bad(at, 'expected true or false'),
};

List<Object?> _items(Object? v, String at) => switch (v) {
  null => const [],
  List l => l,
  _ => _bad(at, 'expected a list'),
};

int _priority(Object? v, String at) => switch (v) {
  null => completionDefaultPriority,
  num n => n < 0 ? 0 : (n > 100 ? 100 : n.round()),
  _ => _bad(at, 'expected a number'),
};

/// Fig's `{cursor}` marks where the caret lands after insertion; a terminal cannot place it, so it is dropped.
String? _insert(Object? v, String at) => _text(v, at)?.replaceAll('{cursor}', '');

int? _maxUses(Object? v, String at) => switch (v) {
  null || false => 1,
  true => null,
  num n => n < 1 ? 1 : n.toInt(),
  _ => _bad(at, 'expected true or a number'),
};

String? _separator(Map<String, Object?> m, String at) => switch (m['requiresSeparator']) {
  String s when s.isNotEmpty => s,
  true => '=',
  null || false => _flag(m['requiresEquals'], '$at.requiresEquals') ? '=' : null,
  _ => _bad('$at.requiresSeparator', 'expected true or text'),
};

ParserDirectives _directives(Object? json, String at) {
  final map = _map(json, at);
  final separators = switch (map['optionArgSeparators']) {
    null => const ['='],
    String s when s.isNotEmpty => [s],
    List l when l.isNotEmpty && l.every((e) => e is String && e.isNotEmpty) => [for (final e in l) e as String],
    _ => _bad('$at.optionArgSeparators', 'expected text or a list of text'),
  };
  return ParserDirectives(
    flagsArePosixNoncompliant: _flag(map['flagsArePosixNoncompliant'], '$at.flagsArePosixNoncompliant'),
    optionsMustPrecedeArguments: _flag(map['optionsMustPrecedeArguments'], '$at.optionsMustPrecedeArguments'),
    optionArgSeparators: separators,
  );
}

List<CompletionChoice> _choices(Object? json, String at) {
  if (json is String) return json.isEmpty ? const [] : [CompletionChoice(json)];
  final map = _map(json, at);
  if (_flag(map['hidden'], '$at.hidden')) return const [];
  final names = _names(map['name'], '$at.name');
  final insert = _insert(map['insertValue'], '$at.insertValue');
  return [
    for (final name in names)
      CompletionChoice(
        name,
        description: _text(map['description'], '$at.description'),
        displayName: _text(map['displayName'], '$at.displayName'),
        insertValue: names.length == 1 ? insert : null,
        priority: _priority(map['priority'], '$at.priority'),
      ),
  ];
}

Set<CompletionTemplate> _templates(Object? v, String at) {
  final names = switch (v) {
    null => const <String>[],
    String s => [s],
    List l => [
      for (final e in l)
        if (e is String) e,
    ],
    _ => _bad(at, 'expected text or a list of text'),
  };
  return {
    for (final n in names)
      for (final t in CompletionTemplate.values)
        if (t.name == n) t,
  };
}

CompletionArg _arg(Object? json, String at) {
  final map = _map(json, at);
  final name = switch (map['name']) {
    List l when l.isNotEmpty && l.first is String => l.first as String,
    final other => _text(other, '$at.name'),
  };
  return CompletionArg(
    name: name,
    description: _text(map['description'], '$at.description'),
    isOptional: _flag(map['isOptional'], '$at.isOptional'),
    isVariadic: _flag(map['isVariadic'], '$at.isVariadic'),
    isCommand: _flag(map['isCommand'], '$at.isCommand'),
    isScript: _flag(map['isScript'], '$at.isScript'),
    choices: [
      for (final (i, item) in _items(map['suggestions'], '$at.suggestions').indexed)
        ..._choices(item, '$at.suggestions[$i]'),
    ],
    templates: _templates(map['template'], '$at.template'),
  );
}

List<CompletionArg> _args(Object? v, String at) => switch (v) {
  null => const [],
  Map m => [_arg(m, at)],
  List l => [for (final (i, item) in l.indexed) _arg(item, '$at[$i]')],
  _ => _bad(at, 'expected an object or a list'),
};

CompletionOption _option(Object? json, String at) =>
    _optionOrNull(json, at) ?? _bad('$at.name', 'an option name starts with "-"');

/// The options of a spec; one that has no name the engine can match is dropped, not an error: the data holds a few
/// hundred (`name`, `+x`, an en dash for `--`) and one of them must not cost the whole spec.
List<CompletionOption> _options(List<Object?> items, String at) {
  final out = <CompletionOption>[];
  for (final (i, item) in items.indexed) {
    final option = _optionOrNull(item, '$at[$i]');
    if (option != null) out.add(option);
  }
  return out;
}

CompletionOption? _optionOrNull(Object? json, String at) {
  final map = _map(json, at);
  // Only a word that starts with `-` is read as an option.
  final names = [
    for (final n in _names(map['name'], '$at.name'))
      if (n.length >= 2 && n.startsWith('-')) n,
  ];
  if (names.isEmpty) return null;
  return CompletionOption(
    names,
    description: _text(map['description'], '$at.description'),
    displayName: _text(map['displayName'], '$at.displayName'),
    insertValue: _insert(map['insertValue'], '$at.insertValue'),
    priority: _priority(map['priority'], '$at.priority'),
    args: _args(map['args'], '$at.args'),
    isPersistent: _flag(map['isPersistent'], '$at.isPersistent'),
    maxUses: _maxUses(map['isRepeatable'], '$at.isRepeatable'),
    isRequired: _flag(map['isRequired'], '$at.isRequired'),
    separator: _separator(map, at),
    exclusiveOn: _strings(map['exclusiveOn'], '$at.exclusiveOn'),
    dependsOn: _strings(map['dependsOn'], '$at.dependsOn'),
    hidden: _flag(map['hidden'], '$at.hidden'),
  );
}

CompletionSpec _spec(Object? json, String at, int depth) {
  if (depth > _maxDepth) _bad(at, 'nested too deeply');
  final map = _map(json, at);
  final subs = _items(map['subcommands'], '$at.subcommands');
  // A key is resolved by the caller; an inline spec is merged right away; anything else is not a reference.
  final load = map['loadSpec'];
  final inline = load is Map ? _spec(load, '$at.loadSpec', depth + 1) : null;
  final spec = CompletionSpec(
    _names(map['name'], '$at.name'),
    description: _text(map['description'], '$at.description'),
    displayName: _text(map['displayName'], '$at.displayName'),
    insertValue: _insert(map['insertValue'], '$at.insertValue'),
    priority: _priority(map['priority'], '$at.priority'),
    subcommands: [for (final (i, s) in subs.indexed) _spec(s, '$at.subcommands[$i]', depth + 1)],
    options: _options(_items(map['options'], '$at.options'), '$at.options'),
    args: _args(map['args'], '$at.args'),
    additionalSuggestions: [
      for (final (i, item) in _items(map['additionalSuggestions'], '$at.additionalSuggestions').indexed)
        ..._choices(item, '$at.additionalSuggestions[$i]'),
    ],
    loadSpec: load is String && load.isNotEmpty ? load : null,
    directives: map['parserDirectives'] == null
        ? ParserDirectives.standard
        : _directives(map['parserDirectives'], '$at.parserDirectives'),
    hidden: _flag(map['hidden'], '$at.hidden'),
  );
  return inline == null ? spec : spec.withLoaded(inline);
}

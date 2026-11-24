/// Reads the draft of one shell line the way a POSIX shell would split it, as far as that is certain
/// (docs/COMPLETION_ENGINE.md). The cursor is at the end of the draft. Quoting and backslash escapes are understood;
/// anything whose meaning depends on the shell at run time (operators, substitutions, globs, history expansion,
/// comments) makes the whole draft unsupported instead of being guessed.
library;

enum CompletionQuote { none, single, double }

/// Shell quoting and escape rules for splitting and encoding completion words.
enum CompletionSyntax {
  posix,
  powershell,
  cmd;

  bool get isWindows => this != posix;
}

enum CompletionIssue {
  /// A line break or another control character; completion is for one line.
  control,

  /// `| & ; < > ( )`: another command starts or the streams change.
  operator,

  /// `$` or a backtick: the words depend on what the shell expands.
  substitution,

  /// `* ? [ ] { } !` and a word-initial `#`: globs, braces, history expansion and comments.
  expansion,

  /// A backslash at the very end: the next character is not typed yet.
  danglingEscape,
  tooLong,
}

/// One word of the line. [raw] is exactly what was typed (quotes and escapes included), [value] what the shell
/// would pass on.
class CommandToken {
  const CommandToken._(this.raw, this.value, this.start, this._bounds);

  final String raw, value;

  /// Index of [raw] in the draft.
  final int start;
  final List<int> _bounds;

  int get end => start + raw.length;

  /// Offset in [raw], from [start], just after the raw text of the first [valueLength] characters of [value].
  /// A quote that opens right after those characters is not counted, so it belongs to what follows.
  int rawOffsetAfter(int valueLength) {
    final i = valueLength < 0 ? 0 : (valueLength > value.length ? value.length : valueLength);
    return _bounds[i];
  }
}

class CompletionContext {
  const CompletionContext._(this.draft, this.words, this.current, this.quote, this.issue, this.syntax);

  /// Longer drafts are not read.
  static const maxLength = 4096;

  /// Splits [draft]; never throws. A draft that cannot be read has [issue] set and no words.
  factory CompletionContext.parse(String draft, {CompletionSyntax syntax = CompletionSyntax.posix}) {
    CompletionContext fail(CompletionIssue issue) => CompletionContext._(
      draft,
      const [],
      CommandToken._('', '', draft.length, const [0]),
      CompletionQuote.none,
      issue,
      syntax,
    );
    if (draft.length > maxLength) return fail(CompletionIssue.tooLong);

    final words = <CommandToken>[];
    var value = StringBuffer();
    var bounds = <int>[0];
    var start = -1;
    var quote = CompletionQuote.none;

    void put(int unit, int rawEnd) {
      value.writeCharCode(unit);
      bounds.add(rawEnd - start);
    }

    void finish(int end) {
      words.add(CommandToken._(draft.substring(start, end), value.toString(), start, bounds));
      start = -1;
    }

    final n = draft.length;
    var i = 0;
    while (i < n) {
      final c = draft.codeUnitAt(i);
      if (_control(c) && c != 0x09) return fail(CompletionIssue.control);

      if (quote == CompletionQuote.single) {
        if (c == 0x27) {
          if (syntax == CompletionSyntax.powershell && i + 1 < n && draft.codeUnitAt(i + 1) == 0x27) {
            put(0x27, i + 2);
            i += 2;
            continue;
          }
          quote = CompletionQuote.none;
        } else {
          put(c, i + 1);
        }
        i++;
        continue;
      }

      if (quote == CompletionQuote.double) {
        if (c == 0x22) {
          quote = CompletionQuote.none;
          i++;
        } else if (syntax == CompletionSyntax.posix && (c == 0x24 || c == 0x60)) {
          return fail(CompletionIssue.substitution);
        } else if (syntax == CompletionSyntax.powershell && c == 0x24) {
          return fail(CompletionIssue.substitution);
        } else if (syntax == CompletionSyntax.cmd && c == 0x25) {
          return fail(CompletionIssue.substitution);
        } else if (syntax == CompletionSyntax.posix && c == 0x21) {
          return fail(CompletionIssue.expansion);
        } else if (syntax == CompletionSyntax.posix && c == 0x5c) {
          if (i + 1 >= n) return fail(CompletionIssue.danglingEscape);
          final d = draft.codeUnitAt(i + 1);
          if (_control(d)) return fail(CompletionIssue.control);
          if (d == 0x24 || d == 0x60 || d == 0x22 || d == 0x5c) {
            put(d, i + 2);
            i += 2;
          } else {
            put(c, i + 1); // the backslash stays; the next character is read on its own
            i++;
          }
        } else if (syntax == CompletionSyntax.powershell && c == 0x60) {
          if (i + 1 >= n) return fail(CompletionIssue.danglingEscape);
          final d = draft.codeUnitAt(i + 1);
          if (_control(d)) return fail(CompletionIssue.control);
          put(d, i + 2);
          i += 2;
        } else {
          put(c, i + 1);
          i++;
        }
        continue;
      }

      if (c == 0x20 || c == 0x09) {
        if (start >= 0) finish(i);
        i++;
        continue;
      }
      if (start < 0) {
        start = i;
        value = StringBuffer();
        bounds = <int>[0];
      }
      switch (c) {
        case 0x27 when syntax != CompletionSyntax.cmd:
          quote = CompletionQuote.single;
          i++;
        case 0x22:
          quote = CompletionQuote.double;
          i++;
        case 0x5c when syntax == CompletionSyntax.posix:
          {
            if (i + 1 >= n) return fail(CompletionIssue.danglingEscape);
            final d = draft.codeUnitAt(i + 1);
            if (_control(d)) return fail(CompletionIssue.control);
            put(d, i + 2);
            i += 2;
          }
        case 0x60 when syntax == CompletionSyntax.powershell:
          {
            if (i + 1 >= n) return fail(CompletionIssue.danglingEscape);
            final d = draft.codeUnitAt(i + 1);
            if (_control(d)) return fail(CompletionIssue.control);
            put(d, i + 2);
            i += 2;
          }
        case 0x7c || 0x26 || 0x3b || 0x3c || 0x3e || 0x28 || 0x29:
          return fail(CompletionIssue.operator);
        case 0x24 || 0x60 when syntax == CompletionSyntax.posix:
          return fail(CompletionIssue.substitution);
        case 0x24 when syntax == CompletionSyntax.powershell:
          return fail(CompletionIssue.substitution);
        case 0x25 when syntax == CompletionSyntax.cmd:
          return fail(CompletionIssue.substitution);
        case 0x2a || 0x3f || 0x5b || 0x5d || 0x7b || 0x7d || 0x21 when syntax == CompletionSyntax.posix:
          return fail(CompletionIssue.expansion);
        case 0x2a || 0x3f || 0x5b || 0x5d || 0x7b || 0x7d when syntax == CompletionSyntax.powershell:
          return fail(CompletionIssue.expansion);
        case 0x2a || 0x3f when syntax == CompletionSyntax.cmd:
          return fail(CompletionIssue.expansion);
        case 0x23 when i == start && syntax != CompletionSyntax.cmd:
          return fail(CompletionIssue.expansion);
        default:
          put(c, i + 1);
          i++;
      }
    }

    final frozen = List<CommandToken>.unmodifiable(words);
    if (start >= 0) {
      final token = CommandToken._(draft.substring(start), value.toString(), start, bounds);
      return CompletionContext._(draft, frozen, token, quote, null, syntax);
    }
    return CompletionContext._(draft, frozen, CommandToken._('', '', n, const [0]), CompletionQuote.none, null, syntax);
  }

  final String draft;

  /// The words before the one being typed, the command first.
  final List<CommandToken> words;

  /// The word being typed: the last one, or an empty word at the end when the draft ends with a space.
  final CommandToken current;

  /// The quote [current] ends inside of, if it is still open.
  final CompletionQuote quote;

  /// Why nothing can be suggested; null when the draft was read.
  final CompletionIssue? issue;

  final CompletionSyntax syntax;

  bool get supported => issue == null;

  /// The range an insertion replaces: the whole last word.
  int get replaceStart => current.start;
  int get replaceEnd => draft.length;
}

/// Control characters (C0, DEL, C1), tab included.
bool _control(int c) => c < 0x20 || (c >= 0x7f && c <= 0x9f);

bool _plain(int c) => switch (c) {
  >= 0x30 && <= 0x39 || >= 0x41 && <= 0x5a || >= 0x61 && <= 0x7a || >= 0x80 => true,
  0x5f || 0x2d || 0x2e || 0x2c || 0x2f || 0x3a || 0x40 || 0x25 || 0x2b || 0x3d || 0x7e => true,
  _ => false,
};

bool _windowsPlain(int c, {required bool cmd}) => switch (c) {
  0x5c => true, // `\` is the Windows path separator, not an escape.
  0x25 when cmd => false, // `%VAR%` expands in CMD.
  0x40 when !cmd => false, // `@` splats/arrays in PowerShell.
  _ => _plain(c),
};

/// Whether [text] may become part of a word: one line, no control characters.
bool completionValueValid(String text) {
  if (text.isEmpty || text.length > 1024) return false;
  for (var i = 0; i < text.length; i++) {
    if (_control(text.codeUnitAt(i))) return false;
  }
  return true;
}

/// Whether [added] can be safely appended to a word ending in [state] under [syntax].
bool canEncodeShellSuffix(
  String added,
  CompletionQuote state, {
  bool atWordStart = false,
  CompletionSyntax syntax = CompletionSyntax.posix,
}) {
  if (syntax != CompletionSyntax.cmd) return true;
  if (added.contains('"') || added.contains('%')) return false;
  if (state == CompletionQuote.double) return true;
  if (state == CompletionQuote.single) return !added.contains("'");
  if (atWordStart) return true;
  for (var i = 0; i < added.length; i++) {
    if (!_windowsPlain(added.codeUnitAt(i), cmd: true)) return false;
  }
  return true;
}

/// The raw text that appends [added] to a word that ends in [state]. Characters the shell would read as syntax are
/// escaped for that state; with [close] an open quote is closed. [atWordStart] also escapes a leading `~` or `#`.
/// [added] must satisfy [completionValueValid].
String encodeShellSuffix(
  String added,
  CompletionQuote state, {
  bool atWordStart = false,
  bool close = false,
  CompletionSyntax syntax = CompletionSyntax.posix,
}) {
  if (syntax.isWindows) {
    return _encodeWindowsSuffix(
      added,
      state,
      atWordStart: atWordStart,
      close: close,
      cmd: syntax == CompletionSyntax.cmd,
    );
  }
  final out = StringBuffer();
  for (var i = 0; i < added.length; i++) {
    final ch = added[i];
    switch (state) {
      case CompletionQuote.none:
        final special = !_plain(added.codeUnitAt(i)) || (i == 0 && atWordStart && (ch == '~' || ch == '#'));
        if (special) out.write(r'\');
        out.write(ch);
      case CompletionQuote.single:
        out.write(ch == "'" ? r"'\''" : ch);
      case CompletionQuote.double:
        if (ch == '"' || ch == r'\' || ch == r'$' || ch == '`') {
          out
            ..write(r'\')
            ..write(ch);
        } else if (ch == '!') {
          out.write(r'"\!"');
        } else {
          out.write(ch);
        }
    }
  }
  if (close) {
    out.write(switch (state) {
      CompletionQuote.none => '',
      CompletionQuote.single => "'",
      CompletionQuote.double => '"',
    });
  }
  return out.toString();
}

String _encodeWindowsSuffix(
  String added,
  CompletionQuote state, {
  required bool atWordStart,
  required bool close,
  required bool cmd,
}) {
  final out = StringBuffer();
  switch (state) {
    case CompletionQuote.none:
      var needsQuote = false;
      for (var i = 0; i < added.length; i++) {
        final c = added.codeUnitAt(i);
        if (!_windowsPlain(c, cmd: cmd) || (i == 0 && atWordStart && !cmd && c == 0x23)) {
          needsQuote = true;
          break;
        }
      }
      if (!needsQuote) {
        out.write(added);
      } else if (atWordStart &&
          !added.contains('"') &&
          (cmd ? !added.contains('%') : !added.contains(r'$') && !added.contains('`'))) {
        out
          ..write('"')
          ..write(added);
        if (close) out.write('"');
      } else if (!cmd) {
        for (var i = 0; i < added.length; i++) {
          final c = added.codeUnitAt(i);
          if (!_windowsPlain(c, cmd: false) || (i == 0 && atWordStart && c == 0x23)) out.write('`');
          out.write(added[i]);
        }
      } else {
        out.write(added);
      }
    case CompletionQuote.single:
      for (var i = 0; i < added.length; i++) {
        final ch = added[i];
        out.write(!cmd && ch == "'" ? "''" : ch);
      }
      if (close) out.write("'");
    case CompletionQuote.double:
      for (var i = 0; i < added.length; i++) {
        final ch = added[i];
        if (!cmd && (ch == '"' || ch == r'$' || ch == '`')) out.write('`');
        out.write(ch);
      }
      if (close) out.write('"');
  }
  return out.toString();
}

/// A whole word for [value], opened with the quote of [quote] if there is one. For replacing a word that [value]
/// does not extend.
String encodeShellWord(
  String value,
  CompletionQuote quote, {
  bool close = true,
  CompletionSyntax syntax = CompletionSyntax.posix,
}) {
  final opener = switch (quote) {
    CompletionQuote.none => '',
    CompletionQuote.single => "'",
    CompletionQuote.double => '"',
  };
  return '$opener${encodeShellSuffix(value, quote, atWordStart: true, close: close, syntax: syntax)}';
}

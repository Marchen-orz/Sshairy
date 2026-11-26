/// What a highlighted word means; the view picks the color (docs/MODULES.md §3).
enum KeywordKind { error, warning, success, custom }

typedef KeywordMatch = ({int start, int end, KeywordKind kind});

/// Finds keywords in one line of terminal text. Latin words match whole and case-insensitively; words without
/// letters on an edge (CJK, symbols) match anywhere. Results are cached by line text, since the same rows are
/// painted again and again.
class KeywordHighlighter {
  factory KeywordHighlighter({String custom = ''}) {
    final words = parseKeywords(custom);
    final kinds = [if (words.isNotEmpty) KeywordKind.custom, ..._builtIn.keys];
    return KeywordHighlighter._(_compile(words), kinds);
  }
  KeywordHighlighter._(this._pattern, this._kinds);

  final RegExp _pattern;

  /// The named groups [_pattern] has, in order.
  final List<KeywordKind> _kinds;
  final _cache = <String, List<KeywordMatch>>{};
  static const _cacheLimit = 1024;

  static const _builtIn = {
    KeywordKind.error: [
      'error', 'errors', 'fail', 'failed', 'failure', 'fatal', 'denied', 'refused', 'exception', 'panic', //
      'critical', 'abort', 'aborted', 'killed', '错误', '失败', '拒绝', '异常',
    ],
    KeywordKind.warning: ['warn', 'warning', 'warnings', 'deprecated', 'timeout', 'timed out', '警告', '超时'],
    KeywordKind.success: [
      'ok', 'success', 'successful', 'successfully', 'succeeded', 'done', 'passed', 'active', 'enabled', //
      'running', '成功', '完成',
    ],
  };

  static final _groups = {
    KeywordKind.custom: 'c',
    KeywordKind.error: 'e',
    KeywordKind.warning: 'w',
    KeywordKind.success: 's',
  };

  static RegExp _compile(List<String> custom) {
    String alternatives(Iterable<String> words) {
      // Longest first, so `failed` is not cut short by `fail`.
      final sorted = words.toSet().toList()..sort((a, b) => b.length.compareTo(a.length));
      return sorted.map(_word).join('|');
    }

    final parts = [
      // Custom words come first and win where they overlap the built-in ones.
      if (custom.isNotEmpty) '(?<c>${alternatives(custom)})',
      for (final MapEntry(:key, :value) in _builtIn.entries) '(?<${_groups[key]}>${alternatives(value)})',
    ];
    return RegExp(parts.join('|'), caseSensitive: false, unicode: true);
  }

  static final _wordChar = RegExp(r'[A-Za-z0-9_]');

  static String _word(String word) {
    final escaped = RegExp.escape(word);
    final head = _wordChar.hasMatch(word[0]) ? r'(?<![A-Za-z0-9_])' : '';
    final tail = _wordChar.hasMatch(word[word.length - 1]) ? r'(?![A-Za-z0-9_])' : '';
    return '$head$escaped$tail';
  }

  List<KeywordMatch> match(String text) {
    if (text.trim().isEmpty) return const [];
    final cached = _cache.remove(text);
    if (cached != null) return _cache[text] = cached;
    final found = <KeywordMatch>[
      for (final m in _pattern.allMatches(text))
        if (m.end > m.start)
          (start: m.start, end: m.end, kind: _kinds.firstWhere((k) => m.namedGroup(_groups[k]!) != null)),
    ];
    if (_cache.length >= _cacheLimit) _cache.remove(_cache.keys.first);
    return _cache[text] = found;
  }
}

/// Comma, semicolon or whitespace separated, without duplicates; one keyword is at most 64 characters.
List<String> parseKeywords(String text) => {
  for (final word in text.split(RegExp(r'[,;，；\s]+')))
    if (word.isNotEmpty && word.length <= 64) word,
}.toList();

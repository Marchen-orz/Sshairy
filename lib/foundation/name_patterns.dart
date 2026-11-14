/// Name patterns with `*` and `?`, matched case-insensitively against one path segment.
bool nameMatchesAny(String name, Iterable<String> patterns) {
  final lower = name.toLowerCase();
  for (final pattern in patterns) {
    final expression = RegExp(
      '^${RegExp.escape(pattern.toLowerCase()).replaceAll(r'\*', '.*').replaceAll(r'\?', '.')}\$',
    );
    if (expression.hasMatch(lower)) return true;
  }
  return false;
}

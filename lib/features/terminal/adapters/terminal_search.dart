part of 'terminal_session.dart';

/// Ctrl+Shift+F: finds text in the scrollback. Enter goes to the next match up, Shift+Enter down, Esc closes.
class _SearchBar extends StatefulWidget {
  const _SearchBar({required this.terminal, required this.controller, required this.reveal, required this.onClose});

  final Terminal terminal;
  final TerminalController controller;
  final void Function(int row) reveal;
  final VoidCallback onClose;

  @override
  State<_SearchBar> createState() => _SearchBarState();
}

class _SearchBarState extends State<_SearchBar> {
  final _query = TextEditingController();
  var _matches = const <TerminalSearchMatch>[];
  var _current = -1;
  var _caseSensitive = false, _regex = false;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  void _search() {
    try {
      _matches = widget.terminal.search(_query.text, caseSensitive: _caseSensitive, useRegex: _regex);
    } on FormatException {
      _matches = const [];
    }
    // Start from the newest output, where the user most likely looks.
    _current = _matches.isEmpty ? -1 : _matches.length - 1;
    widget.controller.setSearchHighlights(
      widget.terminal.buffer,
      [for (final m in _matches) m.range],
      currentIndex: _current < 0 ? 0 : _current,
    );
    if (_matches.isEmpty) widget.controller.clearSearchHighlights();
    _show();
  }

  void _step(int delta) {
    if (_matches.isEmpty) return;
    _current = (_current + delta) % _matches.length;
    widget.controller.setCurrentSearchHighlight(_current);
    _show();
  }

  void _show() {
    setState(() {});
    if (_current >= 0) widget.reveal(_matches[_current].range.begin.y);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    Widget toggle(String glyph, String tooltip, bool on, VoidCallback onTap) => Tooltip(
          message: tooltip,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(Radii.control),
            child: Container(
              width: 28,
              height: 28,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: on ? scheme.primary.withValues(alpha: 0.16) : null,
                borderRadius: BorderRadius.circular(Radii.control),
              ),
              child: Text(glyph, style: theme.textTheme.labelMedium?.copyWith(color: on ? scheme.primary : null)),
            ),
          ),
        );
    Widget icon(IconData icon, String tooltip, VoidCallback? onTap) => IconButton(
          tooltip: tooltip,
          onPressed: onTap,
          constraints: const BoxConstraints.tightFor(width: 28, height: 28),
          style: IconButton.styleFrom(minimumSize: const Size(28, 28), padding: EdgeInsets.zero),
          icon: Icon(icon, size: 16),
        );
    final count = _query.text.isEmpty
        ? ''
        : _matches.isEmpty
            ? l.noResults
            : l.matchCount(_current + 1, _matches.length);
    return Material(
      color: scheme.surfaceContainerHigh,
      elevation: 2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.card),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Space.sm, vertical: Space.xs),
        child: CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.escape): widget.onClose,
            const SingleActivator(LogicalKeyboardKey.enter, shift: true): () => _step(1),
          },
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            SizedBox(
              width: 200,
              child: TextField(
                controller: _query,
                autofocus: true,
                style: theme.textTheme.bodyMedium,
                decoration: InputDecoration(
                  isDense: true,
                  hintText: l.find,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  filled: false,
                ),
                onChanged: (_) => _search(),
                // Keeps focus in the field so Enter can be pressed again.
                onEditingComplete: () {},
                onSubmitted: (_) => _step(-1),
              ),
            ),
            SizedBox(
              width: 64,
              child: Text(count, textAlign: TextAlign.end, style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
            ),
            const SizedBox(width: Space.xs),
            toggle('Aa', l.caseSensitive, _caseSensitive, () {
              _caseSensitive = !_caseSensitive;
              _search();
            }),
            toggle('.*', l.regex, _regex, () {
              _regex = !_regex;
              _search();
            }),
            icon(Icons.keyboard_arrow_up, l.previous, _matches.isEmpty ? null : () => _step(-1)),
            icon(Icons.keyboard_arrow_down, l.next, _matches.isEmpty ? null : () => _step(1)),
            icon(Icons.close, l.close, widget.onClose),
          ]),
        ),
      ),
    );
  }
}

part of 'terminal_session.dart';

extension _AssistancePane on _TerminalPaneState {
  Future<void> _showHistory() async {
    final request = _session.commandAssistance.value.request;
    final selected = await showAppDialog<String>(
      context: context,
      builder: (_) => _CommandHistoryDialog(session: _session, request: request),
    );
    if (!mounted) return;
    if (selected != null && request != null) await _session.acceptCommand(request, selected);
    _focus.requestFocus();
  }

  KeyEventResult? _assistanceKey(KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return null;
    final keys = HardwareKeyboard.instance;
    final modifier = defaultTargetPlatform == TargetPlatform.macOS ? keys.isMetaPressed : keys.isControlPressed;
    if (modifier && keys.isShiftPressed && event.logicalKey == LogicalKeyboardKey.keyH) {
      _showHistory();
      return KeyEventResult.handled;
    }
    final state = _session.commandAssistance.value;
    final enter = event.logicalKey == LogicalKeyboardKey.enter || event.logicalKey == LogicalKeyboardKey.numpadEnter;
    if (_candidateMode && !identical(_candidateRequest, state.request)) _candidateMode = false;
    if (modifier &&
        !keys.isShiftPressed &&
        event.logicalKey == LogicalKeyboardKey.space &&
        state.candidates.isNotEmpty) {
      _update(() {
        _candidateMode = true;
        _candidateRequest = state.request;
        _candidateIndex = 0;
      });
      return KeyEventResult.handled;
    }
    if (_candidateMode && state.candidates.isNotEmpty && state.request != null) {
      if (event.logicalKey == LogicalKeyboardKey.escape) {
        _update(() => _candidateMode = false);
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.arrowDown || event.logicalKey == LogicalKeyboardKey.arrowUp) {
        _update(
          () => _candidateIndex =
              (_candidateIndex + (event.logicalKey == LogicalKeyboardKey.arrowDown ? 1 : -1)) % state.candidates.length,
        );
        return KeyEventResult.handled;
      }
      if (enter || event.logicalKey == LogicalKeyboardKey.tab) {
        _session.acceptCommand(
          state.request!,
          state.candidates[_candidateIndex.clamp(0, state.candidates.length - 1)].text,
        );
        _update(() => _candidateMode = false);
        return KeyEventResult.handled;
      }
      _update(() => _candidateMode = false);
    }
    if (enter && !modifier && !keys.isAltPressed) {
      _session.commandSubmitted();
    }
    return null;
  }

  Widget _completionOverlay() => ValueListenableBuilder<CommandAssistanceState>(
    valueListenable: _session.commandAssistance,
    builder: (context, state, _) {
      if (!identical(_candidateRequest, state.request)) _candidateMode = false;
      if (!widget.active || _searching || !_focus.hasFocus || state.candidates.isEmpty || state.request == null) {
        return const SizedBox.shrink();
      }
      final scheme = Theme.of(context).colorScheme;
      return Align(
        alignment: Alignment.bottomLeft,
        child: Padding(
          padding: EdgeInsets.fromLTRB(Space.sm, Space.sm, Space.sm, _completionBottomInset()),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420, maxHeight: 220),
            child: PopupSurface(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: state.candidates.length,
                itemBuilder: (context, index) {
                  final candidate = state.candidates[index];
                  return Material(
                    color: _candidateMode && index == _candidateIndex ? scheme.primaryContainer : Colors.transparent,
                    child: InkWell(
                      canRequestFocus: false,
                      onTap: () {
                        _session.acceptCommand(state.request!, candidate.text);
                        _update(() => _candidateMode = false);
                        _focus.requestFocus();
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: Space.sm, vertical: Space.xs),
                        child: Row(
                          children: [
                            Icon(
                              candidate.source == CommandCandidateSource.history ? Icons.history : Icons.terminal,
                              size: 14,
                            ),
                            const SizedBox(width: Space.sm),
                            Expanded(child: Text(candidate.text, maxLines: 1, overflow: TextOverflow.ellipsis)),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      );
    },
  );
}

class _CommandHistoryDialog extends StatefulWidget {
  const _CommandHistoryDialog({required this.session, required this.request});
  final TerminalSession session;
  final CommandCompletionRequest? request;

  @override
  State<_CommandHistoryDialog> createState() => _CommandHistoryDialogState();
}

class _CommandHistoryDialogState extends State<_CommandHistoryDialog> {
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return AppDialog(
      title: Text(l.commandHistory),
      width: 580,
      content: SizedBox(
        width: 520,
        height: 340,
        child: Column(
          children: [
            TextField(
              autofocus: true,
              controller: _search,
              decoration: InputDecoration(hintText: l.find, prefixIcon: const Icon(Icons.search, size: 16)),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: Space.sm),
            Expanded(
              child: ValueListenableBuilder<List<String>>(
                valueListenable: widget.session.commandHistory,
                builder: (context, commands, _) {
                  final query = _search.text.toLowerCase();
                  final rows = commands.where((text) => text.toLowerCase().contains(query)).toList();
                  if (rows.isEmpty) return Center(child: Text(l.commandHistoryEmpty));
                  return ListView.builder(
                    itemCount: rows.length,
                    itemBuilder: (context, index) {
                      final text = rows[index];
                      final canInsert = widget.request != null && text.startsWith(widget.request!.text);
                      return Row(
                        children: [
                          Expanded(child: Text(text, maxLines: 2, overflow: TextOverflow.ellipsis)),
                          IconButton(
                            tooltip: l.copy,
                            icon: const Icon(Icons.copy_outlined, size: 16),
                            onPressed: () => Clipboard.setData(ClipboardData(text: text)),
                          ),
                          IconButton(
                            tooltip: l.commandHistoryInsert,
                            icon: const Icon(Icons.keyboard_return, size: 16),
                            onPressed: canInsert ? () => Navigator.pop(context, text) : null,
                          ),
                        ],
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: widget.session.clearCommandHistory, child: Text(l.commandHistoryClear)),
        TextButton(onPressed: () => Navigator.pop(context), child: Text(l.close)),
      ],
    );
  }
}

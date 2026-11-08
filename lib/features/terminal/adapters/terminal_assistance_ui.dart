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
    _syncCandidateSelection(state);
    if (modifier &&
        !keys.isShiftPressed &&
        event.logicalKey == LogicalKeyboardKey.space &&
        state.candidates.isNotEmpty) {
      _update(() {
        _candidateMode = true;
        _candidateRequest = state.request;
        _candidateIndex = 0;
        _candidateText = state.candidates.first.text;
      });
      _scrollCandidateIntoView();
      return KeyEventResult.handled;
    }
    if (_candidateMode && state.candidates.isNotEmpty && state.request != null) {
      if (event.logicalKey == LogicalKeyboardKey.escape) {
        _update(() => _candidateMode = false);
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.arrowDown || event.logicalKey == LogicalKeyboardKey.arrowUp) {
        _update(() {
          _candidateIndex =
              (_candidateIndex + (event.logicalKey == LogicalKeyboardKey.arrowDown ? 1 : -1)) % state.candidates.length;
          _candidateText = state.candidates[_candidateIndex].text;
        });
        _scrollCandidateIntoView();
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

  void _syncCandidateSelection(CommandAssistanceState state) {
    if (!identical(_candidateRequest, state.request)) {
      _candidateMode = false;
      _candidateText = null;
    } else if (_candidateMode && _candidateText != null) {
      final selected = state.candidates.indexWhere((candidate) => candidate.text == _candidateText);
      if (selected < 0) {
        _candidateMode = false;
        _candidateText = null;
      } else if (selected != _candidateIndex) {
        _candidateIndex = selected;
        _scrollCandidateIntoView();
      }
    }
  }

  void _scrollCandidateIntoView() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_candidateMode || !_candidateScroll.hasClients) return;
      final row = max(CompletionSize.row, MediaQuery.textScalerOf(context).scale(13) + Space.lg);
      final position = _candidateScroll.position;
      final top = _candidateIndex * row;
      final bottom = top + row;
      if (top < position.pixels) {
        _candidateScroll.jumpTo(top.clamp(0, position.maxScrollExtent));
      } else if (bottom > position.pixels + position.viewportDimension) {
        _candidateScroll.jumpTo((bottom - position.viewportDimension).clamp(0, position.maxScrollExtent));
      }
    });
  }

  Widget _completionOverlay() => ListenableBuilder(
    listenable: Listenable.merge([_session.commandAssistance, _completionCursor]),
    builder: (context, _) {
      final state = _session.commandAssistance.value;
      final cursor = _completionCursor.value;
      _syncCandidateSelection(state);
      if (!widget.active ||
          _searching ||
          !_focus.hasFocus ||
          cursor == null ||
          state.candidates.isEmpty ||
          state.request == null) {
        return const SizedBox.shrink();
      }
      final scheme = Theme.of(context).colorScheme;
      final l = AppLocalizations.of(context);
      final rowHeight = max(CompletionSize.row, MediaQuery.textScalerOf(context).scale(13) + Space.lg);
      return Positioned.fill(
        child: CustomSingleChildLayout(
          delegate: CursorPopupLayout(
            cursor: cursor,
            preferredSize: Size(
              CompletionSize.width,
              min(CompletionSize.maxHeight, rowHeight * state.candidates.length + Space.sm),
            ),
          ),
          child: PopupSurface(
            key: const ValueKey('command-completion-popup'),
            padding: const EdgeInsets.symmetric(vertical: Space.xs),
            child: SizedBox(
              width: CompletionSize.width,
              child: ListView.builder(
                controller: _candidateScroll,
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                itemCount: state.candidates.length,
                itemExtent: rowHeight,
                itemBuilder: (context, index) {
                  final candidate = state.candidates[index];
                  final title = candidate.displayText ?? candidate.text;
                  final description = candidate.description?.text(l);
                  final selected = _candidateMode && index == _candidateIndex;
                  return Semantics(
                    selected: selected,
                    button: true,
                    label: description == null ? title : '$title, $description',
                    child: Material(
                      color: selected ? scheme.primaryContainer : Colors.transparent,
                      child: InkWell(
                        canRequestFocus: false,
                        onTap: () {
                          _session.acceptCommand(state.request!, candidate.text);
                          _update(() => _candidateMode = false);
                          _focus.requestFocus();
                        },
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: Space.sm),
                          child: Row(
                            children: [
                              Icon(
                                switch (candidate.source) {
                                  CommandCandidateSource.ai => Icons.auto_awesome_outlined,
                                  CommandCandidateSource.history => Icons.history,
                                  _ => switch (candidate.kind) {
                                    CommandKind.option => Icons.tune,
                                    CommandKind.subcommand => Icons.subdirectory_arrow_right,
                                    _ => Icons.terminal,
                                  },
                                },
                                size: 14,
                                color: scheme.onSurfaceVariant,
                              ),
                              const SizedBox(width: Space.sm),
                              Expanded(child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis)),
                              if (description != null) ...[
                                const SizedBox(width: Space.md),
                                Expanded(
                                  child: Text(
                                    description,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    textAlign: TextAlign.end,
                                    style: Theme.of(context).textTheme.bodySmall
                                        ?.copyWith(color: scheme.onSurfaceVariant),
                                  ),
                                ),
                              ],
                            ],
                          ),
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

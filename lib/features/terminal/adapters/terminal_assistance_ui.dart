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

  bool _popupAvailable(CommandAssistanceState state) =>
      widget.active &&
      !_searching &&
      _focus.hasFocus &&
      _completionCursor.value != null &&
      state.request != null &&
      !identical(_dismissedCandidateRequest, state.request) &&
      (state.candidates.isNotEmpty || state.browse != null);

  KeyEventResult? _assistanceKey(KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return null;
    final keys = HardwareKeyboard.instance;
    final modifier = defaultTargetPlatform == TargetPlatform.macOS ? keys.isMetaPressed : keys.isControlPressed;
    if (modifier && keys.isShiftPressed && event.logicalKey == LogicalKeyboardKey.keyH) {
      _showHistory();
      return KeyEventResult.handled;
    }
    final state = _session.commandAssistance.value;
    if (modifier &&
        !keys.isShiftPressed &&
        !keys.isAltPressed &&
        event.logicalKey == LogicalKeyboardKey.space &&
        state.request != null) {
      _update(() {
        _dismissedCandidateRequest = null;
        _candidateRequest = null;
        _syncCandidateSelection(state);
      });
      _scrollCandidateIntoView();
      return KeyEventResult.handled;
    }
    // xterm's text input owns composing events; modified arrows keep shell/application shortcuts.
    if (keys.isControlPressed || keys.isMetaPressed || keys.isAltPressed || keys.isShiftPressed) return null;
    _syncCandidateSelection(state);
    final enter = event.logicalKey == LogicalKeyboardKey.enter || event.logicalKey == LogicalKeyboardKey.numpadEnter;
    if (enter) {
      _update(() {
        _dismissedCandidateRequest = state.request;
        _candidateMode = false;
      });
      _session.commandSubmitted();
      return null;
    }
    if (!_popupAvailable(state)) return null;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      _update(() {
        _dismissedCandidateRequest = state.request;
        _candidateMode = false;
      });
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown || key == LogicalKeyboardKey.arrowUp) {
      if (state.candidates.isNotEmpty) {
        _update(() {
          _candidateIndex =
              (_candidateIndex + (key == LogicalKeyboardKey.arrowDown ? 1 : -1)) % state.candidates.length;
          _candidateText = state.candidates[_candidateIndex].identity;
          _candidateMode = true;
        });
        _scrollCandidateIntoView();
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      _session.returnCommandBrowse();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight || key == LogicalKeyboardKey.tab) {
      if (_candidateMode && state.request != null && state.candidates.isNotEmpty) {
        final candidate = state.candidates[_candidateIndex.clamp(0, state.candidates.length - 1)];
        if (key == LogicalKeyboardKey.arrowRight) {
          _session.browseCommand(state.request!, candidate);
        } else {
          _session.acceptCommand(state.request!, candidate.text);
        }
      }
      return KeyEventResult.handled;
    }
    return null;
  }

  void _syncCandidateSelection(CommandAssistanceState state) {
    final depth = state.browse?.depth ?? 0;
    if (!identical(_candidateRequest, state.request) || depth != _candidateBrowseDepth) {
      _candidateRequest = state.request;
      _candidateBrowseDepth = depth;
      _candidateText = null;
      _candidateIndex = 0;
      _candidateMode = false;
    }
    if (state.candidates.isEmpty) return;
    if (_candidateText == null) {
      _candidateIndex = 0;
      _candidateText = state.candidates.first.identity;
      _candidateMode = true;
      _scrollCandidateIntoView();
    } else {
      final index = state.candidates.indexWhere((candidate) => candidate.identity == _candidateText);
      if (index < 0) {
        // A vanished async result must not silently retarget Tab to a different item.
        _candidateMode = false;
      } else {
        _candidateMode = true;
        if (_candidateIndex != index) {
          _candidateIndex = index;
          _scrollCandidateIntoView();
        }
      }
    }
  }

  void _scrollCandidateIntoView() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_candidateMode || !_candidateScroll.hasClients) return;
      final row = max(CompletionSize.row, MediaQuery.textScalerOf(context).scale(13) + Space.lg);
      final position = _candidateScroll.position;
      final top = _candidateIndex * row, bottom = top + row;
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
      _syncCandidateSelection(state);
      if (!_popupAvailable(state)) return const SizedBox.shrink();
      final scheme = Theme.of(context).colorScheme;
      final l = AppLocalizations.of(context);
      final rowHeight = max(CompletionSize.row, MediaQuery.textScalerOf(context).scale(13) + Space.lg);
      final browse = state.browse;
      final headerHeight = browse == null ? 0.0 : rowHeight;
      final status = browse == null
          ? null
          : switch (browse.load) {
              CompletionLoad.loading => l.completionLoading,
              CompletionLoad.failed => l.completionFailed,
              CompletionLoad.unavailable => l.completionUnavailable,
              CompletionLoad.ready => state.candidates.isEmpty ? l.completionEmpty : null,
            };
      return Positioned.fill(
        child: CustomSingleChildLayout(
          delegate: CursorPopupLayout(
            cursor: _completionCursor.value!,
            preferredSize: Size(
              CompletionSize.width,
              min(CompletionSize.maxHeight, headerHeight + rowHeight * max(1, state.candidates.length) + Space.sm),
            ),
          ),
          child: PopupSurface(
            key: const ValueKey('command-completion-popup'),
            padding: const EdgeInsets.symmetric(vertical: Space.xs),
            child: SizedBox(
              width: CompletionSize.width,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (browse != null)
                    SizedBox(
                      height: rowHeight,
                      child: Row(
                        children: [
                          if (browse.depth > 0)
                            IconButton(
                              tooltip: l.back,
                              icon: const Icon(Icons.arrow_back, size: 14),
                              onPressed: _session.returnCommandBrowse,
                              visualDensity: VisualDensity.compact,
                            )
                          else
                            const Padding(
                              padding: EdgeInsets.symmetric(horizontal: Space.sm),
                              child: Icon(Icons.folder_outlined, size: 14),
                            ),
                          Expanded(
                            child: Text(
                              browse.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ),
                          if (browse.load == CompletionLoad.loading)
                            const Padding(
                              padding: EdgeInsets.all(Space.sm),
                              child: SizedBox.square(dimension: 12, child: CircularProgressIndicator(strokeWidth: 1.5)),
                            ),
                        ],
                      ),
                    ),
                  if (state.candidates.isEmpty && status != null)
                    Padding(
                      padding: const EdgeInsets.all(Space.sm),
                      child: Text(status, style: Theme.of(context).textTheme.bodySmall),
                    )
                  else
                    Flexible(
                      child: ListView.builder(
                        controller: _candidateScroll,
                        shrinkWrap: true,
                        padding: EdgeInsets.zero,
                        itemCount: state.candidates.length,
                        itemExtent: rowHeight,
                        itemBuilder: (context, index) {
                          final candidate = state.candidates[index];
                          final title = candidate.displayText ?? candidate.text;
                          final description = candidate.description?.text(l) ?? candidate.detail;
                          final selected = _candidateMode && index == _candidateIndex;
                          return MouseRegion(
                            onHover: (event) {
                              if (event.delta == Offset.zero || event.position == _candidatePointer) return;
                              _candidatePointer = event.position;
                              _update(() {
                                _candidateIndex = index;
                                _candidateText = candidate.identity;
                                _candidateMode = true;
                              });
                            },
                            child: Semantics(
                              selected: selected,
                              button: true,
                              label: description == null ? title : '$title, $description',
                              child: Material(
                                color: selected ? scheme.primaryContainer : Colors.transparent,
                                child: InkWell(
                                  canRequestFocus: false,
                                  onTap: () {
                                    if (candidate.directory != null) {
                                      _session.browseCommand(state.request!, candidate);
                                    } else {
                                      _session.acceptCommand(state.request!, candidate.text);
                                    }
                                    _focus.requestFocus();
                                  },
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(horizontal: Space.sm),
                                    child: Row(
                                      children: [
                                        Icon(
                                          switch (candidate.source) {
                                            CommandCandidateSource.history => Icons.history,
                                            CommandCandidateSource.ai => Icons.auto_awesome_outlined,
                                            CommandCandidateSource.path =>
                                              candidate.directory != null
                                                  ? Icons.folder_outlined
                                                  : Icons.insert_drive_file_outlined,
                                            CommandCandidateSource.snippet => Icons.code,
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
                                        if (candidate.preview != null)
                                          const Padding(
                                            padding: EdgeInsets.only(left: Space.xs),
                                            child: Icon(Icons.chevron_right, size: 14),
                                          ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  if (browse?.truncated ?? false)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: Space.sm),
                      child: Text(l.completionTruncated, maxLines: 1, style: Theme.of(context).textTheme.bodySmall),
                    ),
                ],
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

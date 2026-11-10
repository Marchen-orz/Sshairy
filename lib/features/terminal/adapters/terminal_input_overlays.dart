part of 'terminal_session.dart';

extension _InputOverlays on _TerminalPaneState {
  void _showHistory([Offset? globalPosition]) {
    if (!mounted || !widget.visible) return;
    final box = context.findRenderObject();
    _update(() {
      _composerOpen = false;
      _historyOpen = true;
      if (globalPosition != null && box is RenderBox) {
        _historyOffset = box.globalToLocal(globalPosition);
      } else if (!_historyPinned) {
        _historyOffset = _completionCursor.value?.bottomRight;
      }
    });
  }

  void _closeHistory({bool restoreFocus = true}) {
    if (!mounted) return;
    _update(() => _historyOpen = false);
    if (restoreFocus && widget.active) _focus.requestFocus();
  }

  void _showComposer() {
    if (!mounted || !_session.canInsert || !widget.visible) return;
    _update(() {
      _historyOpen = false;
      _composerGeneration = _session.shellGeneration;
      _composerOpen = true;
    });
  }

  void _closeComposer({bool restoreFocus = true}) {
    if (!mounted) return;
    _update(() => _composerOpen = false);
    if (restoreFocus && widget.active) _focus.requestFocus();
  }

  Widget _historyOverlay() => Positioned.fill(
    child: LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = min(HistoryPopupSize.maxWidth, max(0.0, constraints.maxWidth - Space.sm * 2));
        final maxHeight = min(HistoryPopupSize.maxHeight, max(0.0, constraints.maxHeight - Space.sm * 2));
        final minWidth = min(HistoryPopupSize.minWidth, maxWidth);
        final minHeight = min(HistoryPopupSize.minHeight, maxHeight);
        final preferred = _historySize ?? const Size(HistoryPopupSize.width, HistoryPopupSize.height);
        final width = preferred.width.clamp(minWidth, maxWidth);
        final height = preferred.height.clamp(minHeight, maxHeight);
        Offset constrain(Offset offset) => Offset(
          offset.dx.clamp(Space.sm, max(Space.sm, constraints.maxWidth - width - Space.sm)),
          offset.dy.clamp(Space.sm, max(Space.sm, constraints.maxHeight - height - Space.sm)),
        );
        final offset = constrain(_historyOffset ?? const Offset(Space.sm, Space.sm));
        return Stack(
          children: [
            Positioned(
              left: offset.dx,
              top: offset.dy,
              width: width,
              height: height,
              child: _CommandHistoryPopup(
                session: _session,
                active: widget.active,
                pinned: _historyPinned,
                onClose: _closeHistory,
                onOutside: () {
                  if (!_historyPinned) _closeHistory(restoreFocus: false);
                },
                onPin: () => _update(() => _historyPinned = !_historyPinned),
                onDragStart: () => _update(() => _historyOffset = offset),
                onDrag: (delta) => _update(() => _historyOffset = constrain((_historyOffset ?? offset) + delta)),
                onResizeStart: () => _update(() {
                  _historyOffset = offset;
                  _historySize = Size(width, height);
                }),
                onResize: (delta) => _update(() {
                  final size = _historySize ?? Size(width, height);
                  _historySize = Size(
                    (size.width + delta.dx).clamp(minWidth, min(maxWidth, constraints.maxWidth - offset.dx - Space.sm)),
                    (size.height + delta.dy).clamp(
                      minHeight,
                      min(maxHeight, constraints.maxHeight - offset.dy - Space.sm),
                    ),
                  );
                }),
                onInserted: () {
                  if (!_historyPinned) _closeHistory();
                  _focus.requestFocus();
                },
              ),
            ),
          ],
        );
      },
    ),
  );

  Widget _composerOverlay() => Positioned.fill(
    child: Padding(
      padding: const EdgeInsets.all(Space.sm),
      child: Align(
        alignment: Alignment.bottomCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: WorkspaceSize.settingsDialog, maxHeight: WorkspaceSize.toolPanel),
          child: _MultilineComposer(
            session: _session,
            generation: _composerGeneration!,
            confirmMultiline: ref.read(settingsProvider).get(SettingKeys.confirmPaste),
            onClose: _closeComposer,
            onOutside: () => _closeComposer(restoreFocus: false),
          ),
        ),
      ),
    ),
  );
}

class _CommandHistoryPopup extends StatefulWidget {
  const _CommandHistoryPopup({
    required this.session,
    required this.active,
    required this.pinned,
    required this.onClose,
    required this.onOutside,
    required this.onPin,
    required this.onDragStart,
    required this.onDrag,
    required this.onResizeStart,
    required this.onResize,
    required this.onInserted,
  });

  final TerminalSession session;
  final bool active, pinned;
  final VoidCallback onClose, onOutside, onPin, onDragStart, onResizeStart, onInserted;
  final ValueChanged<Offset> onDrag, onResize;

  @override
  State<_CommandHistoryPopup> createState() => _CommandHistoryPopupState();
}

class _CommandHistoryPopupState extends State<_CommandHistoryPopup> {
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  final _resizeFocus = FocusNode();
  final _scroll = ScrollController();
  var _index = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.active) _searchFocus.requestFocus();
    });
  }

  List<String> get _rows {
    final query = _search.text.toLowerCase();
    return widget.session.commandHistory.value.where((text) => text.toLowerCase().contains(query)).toList();
  }

  bool _canInsert(String text) {
    final request = widget.session.commandAssistance.value.request;
    return widget.session.canInsert && request != null && text.startsWith(request.text);
  }

  Future<void> _insert(String text) async {
    final request = widget.session.commandAssistance.value.request;
    if (request == null) return;
    final result = await widget.session.acceptCommand(request, text);
    if (mounted && result == InsertResult.sent) widget.onInserted();
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    if (!_search.value.composing.isCollapsed) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      widget.onClose();
      return KeyEventResult.handled;
    }
    final keys = HardwareKeyboard.instance;
    if (keys.isControlPressed || keys.isMetaPressed || keys.isAltPressed || keys.isShiftPressed) {
      return KeyEventResult.ignored;
    }
    final rows = _rows;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowUp || key == LogicalKeyboardKey.arrowDown) {
      if (rows.isNotEmpty) {
        setState(() => _index = (_index + (key == LogicalKeyboardKey.arrowDown ? 1 : -1)) % rows.length);
        if (_scroll.hasClients) {
          final position = _scroll.position;
          final row = max(WorkspaceSize.listRow, MediaQuery.textScalerOf(context).scale(13) + Space.lg);
          final top = _index * row, bottom = top + row;
          if (top < position.pixels) {
            _scroll.jumpTo(top.clamp(0, position.maxScrollExtent));
          } else if (bottom > position.pixels + position.viewportDimension) {
            _scroll.jumpTo((bottom - position.viewportDimension).clamp(0, position.maxScrollExtent));
          }
        }
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter) {
      if (rows.isNotEmpty) {
        final text = rows[_index.clamp(0, rows.length - 1)];
        if (_canInsert(text)) unawaited(_insert(text));
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _resizeBy(Offset delta) {
    widget.onResizeStart();
    widget.onResize(delta);
  }

  @override
  void dispose() {
    _search.dispose();
    _searchFocus.dispose();
    _resizeFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return TapRegion(
      onTapOutside: (_) => widget.onOutside(),
      child: Focus(
        onKeyEvent: _onKey,
        child: PopupSurface(
          key: const ValueKey('command-history-popup'),
          radius: Radii.panel,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Column(
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: MouseRegion(
                          cursor: SystemMouseCursors.move,
                          child: GestureDetector(
                            key: const ValueKey('command-history-drag'),
                            behavior: HitTestBehavior.opaque,
                            onPanStart: (_) => widget.onDragStart(),
                            onPanUpdate: (details) => widget.onDrag(details.delta),
                            child: Padding(
                              padding: const EdgeInsets.all(Space.sm),
                              child: Text(l.commandHistory, maxLines: 1, overflow: TextOverflow.ellipsis),
                            ),
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: l.commandHistoryClear,
                        icon: const Icon(Icons.delete_sweep_outlined, size: 16),
                        constraints: const BoxConstraints.tightFor(
                          width: WorkspaceSize.control,
                          height: WorkspaceSize.control,
                        ),
                        visualDensity: VisualDensity.compact,
                        onPressed: widget.session.clearCommandHistory,
                      ),
                      IconButton(
                        tooltip: widget.pinned ? l.unpin : l.pin,
                        isSelected: widget.pinned,
                        icon: const Icon(Icons.push_pin_outlined, size: 16),
                        selectedIcon: const Icon(Icons.push_pin, size: 16),
                        constraints: const BoxConstraints.tightFor(
                          width: WorkspaceSize.control,
                          height: WorkspaceSize.control,
                        ),
                        visualDensity: VisualDensity.compact,
                        onPressed: widget.onPin,
                      ),
                      IconButton(
                        tooltip: l.close,
                        icon: const Icon(Icons.close, size: 16),
                        constraints: const BoxConstraints.tightFor(
                          width: WorkspaceSize.control,
                          height: WorkspaceSize.control,
                        ),
                        visualDensity: VisualDensity.compact,
                        onPressed: widget.onClose,
                      ),
                    ],
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(Space.sm, 0, Space.sm, Space.sm),
                    child: TextField(
                      key: const ValueKey('command-history-search'),
                      autofocus: widget.active,
                      focusNode: _searchFocus,
                      controller: _search,
                      decoration: InputDecoration(hintText: l.find, prefixIcon: const Icon(Icons.search, size: 16)),
                      onChanged: (_) {
                        setState(() => _index = 0);
                        if (_scroll.hasClients) _scroll.jumpTo(0);
                      },
                    ),
                  ),
                  Expanded(
                    child: ListenableBuilder(
                      listenable: Listenable.merge([widget.session.commandHistory, widget.session.commandAssistance]),
                      builder: (context, _) {
                        final rows = _rows;
                        if (rows.isEmpty) return Center(child: Text(l.commandHistoryEmpty));
                        final row = max(WorkspaceSize.listRow, MediaQuery.textScalerOf(context).scale(13) + Space.lg);
                        return ListView.builder(
                          controller: _scroll,
                          itemExtent: row,
                          itemCount: rows.length,
                          padding: const EdgeInsets.only(bottom: HistoryPopupSize.resizeGrip),
                          itemBuilder: (context, index) {
                            final text = rows[index];
                            final canInsert = _canInsert(text);
                            final selected = index == _index.clamp(0, rows.length - 1);
                            return PopupRow(
                              selected: selected,
                              height: row,
                              onTap: canInsert ? () => _insert(text) : null,
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Tooltip(
                                      message: text,
                                      child: Text(
                                        text,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: mono(context),
                                      ),
                                    ),
                                  ),
                                  IconButton(
                                    tooltip: l.copy,
                                    icon: const Icon(Icons.copy_outlined, size: 14),
                                    visualDensity: VisualDensity.compact,
                                    onPressed: () => Clipboard.setData(ClipboardData(text: text)),
                                  ),
                                  IconButton(
                                    tooltip: l.commandHistoryInsert,
                                    icon: const Icon(Icons.keyboard_return, size: 14),
                                    visualDensity: VisualDensity.compact,
                                    onPressed: canInsert ? () => _insert(text) : null,
                                  ),
                                ],
                              ),
                            );
                          },
                        );
                      },
                    ),
                  ),
                ],
              ),
              Positioned(
                right: 0,
                bottom: 0,
                child: Semantics(
                  label: l.resizeToolPanel,
                  onIncrease: () => _resizeBy(const Offset(Space.lg, Space.lg)),
                  onDecrease: () => _resizeBy(const Offset(-Space.lg, -Space.lg)),
                  child: Tooltip(
                    message: l.resizeToolPanel,
                    child: MouseRegion(
                      cursor: SystemMouseCursors.resizeDownRight,
                      child: Focus(
                        focusNode: _resizeFocus,
                        onFocusChange: (_) => setState(() {}),
                        onKeyEvent: (_, event) {
                          if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
                          final delta = switch (event.logicalKey) {
                            LogicalKeyboardKey.arrowLeft => const Offset(-Space.lg, 0),
                            LogicalKeyboardKey.arrowRight => const Offset(Space.lg, 0),
                            LogicalKeyboardKey.arrowUp => const Offset(0, -Space.lg),
                            LogicalKeyboardKey.arrowDown => const Offset(0, Space.lg),
                            _ => null,
                          };
                          if (delta == null) return KeyEventResult.ignored;
                          _resizeBy(delta);
                          return KeyEventResult.handled;
                        },
                        child: GestureDetector(
                          key: const ValueKey('command-history-resize'),
                          behavior: HitTestBehavior.opaque,
                          onPanStart: (_) => widget.onResizeStart(),
                          onPanUpdate: (details) => widget.onResize(details.delta),
                          child: SizedBox.square(
                            dimension: HistoryPopupSize.resizeGrip,
                            child: Icon(
                              Icons.south_east,
                              size: Space.md,
                              color: _resizeFocus.hasFocus
                                  ? Theme.of(context).colorScheme.primary
                                  : Theme.of(context).colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MultilineComposer extends StatefulWidget {
  const _MultilineComposer({
    required this.session,
    required this.generation,
    required this.confirmMultiline,
    required this.onClose,
    required this.onOutside,
  });

  final TerminalSession session;
  final int generation;
  final bool confirmMultiline;
  final VoidCallback onClose, onOutside;

  @override
  State<_MultilineComposer> createState() => _MultilineComposerState();
}

class _MultilineComposerState extends State<_MultilineComposer> {
  late final _text = TextEditingController(text: widget.session.multilineDraft);
  final _focus = FocusNode();
  CancellationToken? _sending;

  @override
  void initState() {
    super.initState();
    _text.addListener(_saveDraft);
    widget.session.addListener(_sessionChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  void _sessionChanged() {
    if (mounted) setState(() {});
  }

  void _saveDraft() {
    widget.session.multilineDraft = _text.text;
    setState(() {});
  }

  bool get _canSend =>
      _sending == null &&
      _text.text.isNotEmpty &&
      widget.session.canInsert &&
      widget.generation == widget.session.shellGeneration;

  Future<void> _send() async {
    if (!_canSend || !_text.value.composing.isCollapsed) return;
    final cancel = CancellationToken();
    final text = _text.text;
    setState(() => _sending = cancel);
    try {
      final result = await widget.session.insert(
        text,
        confirmMultiline: widget.confirmMultiline,
        cancel: cancel,
        confirm: (preview) => confirmTerminalInsert(context, preview),
      );
      if (!mounted || cancel.isCancelled) return;
      if (result == InsertResult.sent) {
        _text.clear();
        widget.onClose();
      } else if (result != InsertResult.rejected && result != InsertResult.cancelled) {
        ScaffoldMessenger.maybeOf(context)
            ?.showSnackBar(SnackBar(content: Text(AppLocalizations.of(context).snippetUnavailable)));
      }
    } finally {
      if (mounted) setState(() => _sending = null);
    }
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent || !_text.value.composing.isCollapsed) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      widget.onClose();
      return KeyEventResult.handled;
    }
    final keys = HardwareKeyboard.instance;
    final modifier = defaultTargetPlatform == TargetPlatform.macOS ? keys.isMetaPressed : keys.isControlPressed;
    if (modifier &&
        !keys.isAltPressed &&
        !keys.isShiftPressed &&
        (event.logicalKey == LogicalKeyboardKey.enter || event.logicalKey == LogicalKeyboardKey.numpadEnter)) {
      unawaited(_send());
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  void dispose() {
    _sending?.cancel();
    widget.session.removeListener(_sessionChanged);
    _text.removeListener(_saveDraft);
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final key = defaultTargetPlatform == TargetPlatform.macOS ? '⌘↵' : 'Ctrl+Enter';
    return TapRegion(
      onTapOutside: (_) {
        if (_sending == null) widget.onOutside();
      },
      child: Focus(
        onKeyEvent: _onKey,
        child: PopupSurface(
          key: const ValueKey('terminal-multiline-composer'),
          radius: Radii.panel,
          padding: const EdgeInsets.all(Space.sm),
          child: Column(
            children: [
              Expanded(
                child: TextField(
                  key: const ValueKey('terminal-multiline-editor'),
                  autofocus: true,
                  focusNode: _focus,
                  controller: _text,
                  readOnly: _sending != null,
                  expands: true,
                  minLines: null,
                  maxLines: null,
                  maxLength: 64 * 1024,
                  maxLengthEnforcement: MaxLengthEnforcement.truncateAfterCompositionEnds,
                  textAlignVertical: TextAlignVertical.top,
                  keyboardType: TextInputType.multiline,
                  textInputAction: TextInputAction.newline,
                  style: mono(context),
                  decoration: InputDecoration(hintText: l.terminalMultilinePlaceholder, counterText: ''),
                ),
              ),
              const SizedBox(height: Space.sm),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  IconButton(tooltip: l.close, icon: const Icon(Icons.close, size: 16), onPressed: widget.onClose),
                  const SizedBox(width: Space.sm),
                  Flexible(
                    child: Tooltip(
                      message: '${l.terminalMultilineSend} ($key)',
                      child: FilledButton.icon(
                        key: const ValueKey('terminal-multiline-send'),
                        onPressed: _canSend ? _send : null,
                        icon: const Icon(Icons.send_outlined, size: 16),
                        label: Text(l.terminalMultilineSend, maxLines: 1, overflow: TextOverflow.ellipsis),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

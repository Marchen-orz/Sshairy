part of 'terminal_session.dart';

/// Observe only frames Flutter already draws; no background polling or extra frames for AI.
class _AiFrames {
  static final listeners = <VoidCallback>{};
  static bool _installed = false;
  static void add(VoidCallback listener) {
    if (!_installed) {
      _installed = true;
      WidgetsBinding.instance.addPersistentFrameCallback((_) {
        for (final callback in listeners.toList()) {
          callback();
        }
      });
    }
    listeners.add(listener);
  }
}

extension _TerminalAiPane on _TerminalPaneState {
  bool get _terminalCompositionReady {
    final root = _view.currentContext;
    if (root == null) return false;
    bool? composing;
    void visit(Element element) {
      if (composing != null) return;
      if (element is StatefulElement && element.state is TextInputClient) {
        final value = (element.state as TextInputClient).currentTextEditingValue;
        composing = value == null || !value.composing.isCollapsed;
      } else {
        element.visitChildren(visit);
      }
    }

    visit(root as Element);
    return composing == false;
  }

  void _bindAiService(TerminalAiService service) {
    if (identical(_aiService, service)) return;
    _aiChanges?.cancel();
    _cancelAiCompletion();
    _aiService = service;
    _session._inlineAi.bind(service);
    _aiChanges = service.changes.listen((_) {
      _cancelAiCompletion();
      if (mounted) _update(() => _inlineAiOpen = false);
      _scheduleAi();
    });
    _scheduleAi();
  }

  void _stopAiFrames() {
    _AiFrames.listeners.remove(_aiFrameCallback);
    _aiFrameListening = false;
  }

  void _aiFrame() {
    if (!mounted) return;
    final ready = _terminalCompositionReady;
    if (_aiLastCompositionReady != ready) {
      _aiLastCompositionReady = ready;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _update(() {});
        _scheduleAi();
      });
    }
    final expected = _aiCompletionContext;
    if (expected != null && (!ready || !sameTerminalAiContext(expected, _session.readAiContext()))) {
      _cancelAiCompletion();
      _scheduleAi();
    }
  }

  void _scheduleAi() {
    if (!mounted || _aiScheduled) return;
    _aiScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _aiScheduled = false;
      if (!mounted) return;
      _syncAi();
    });
  }

  void _cancelAiCompletion() {
    _aiTimer?.cancel();
    _aiTimer = null;
    _aiCompletionCancel?.cancel();
    _aiCompletionCancel = null;
    _aiCompletionContext = null;
    _aiCandidate = null;
  }

  bool _completionEligible(TerminalAiContext context) =>
      widget.active &&
      widget.visible &&
      _applicationActive &&
      _focus.hasFocus &&
      !_inlineAiOpen &&
      !_searching &&
      !_composerOpen &&
      !_historyOpen &&
      !_session._historyBrowsing &&
      context.ready &&
      _terminalCompositionReady &&
      !identical(_dismissedCandidateRequest, _session.commandAssistance.value.request) &&
      (_aiService?.canComplete(context) ?? false);

  void _syncAi() {
    final context = _session.readAiContext();
    final inline = _canOpenInlineAi;
    final presentation = (
      inline,
      inline && terminalInputIntent(context.draft ?? '') == TerminalInputIntent.naturalLanguage,
    );
    if (_aiPresentation != presentation) _update(() => _aiPresentation = presentation);
    final eligible = _completionEligible(context);
    final observes =
        widget.active &&
        widget.visible &&
        _applicationActive &&
        ((_aiService?.canGenerate(context) ?? false) || (_aiService?.canComplete(context) ?? false));
    if (observes && !_aiFrameListening) {
      _AiFrames.add(_aiFrameCallback);
      _aiFrameListening = true;
    } else if (!observes) {
      _stopAiFrames();
    }
    if (!eligible) {
      final had = _aiCandidate != null;
      _cancelAiCompletion();
      if (had && mounted) _update(() {});
      return;
    }
    if (_aiCompletionContext != null && sameTerminalAiContext(_aiCompletionContext!, context)) return;
    _cancelAiCompletion();
    _aiCompletionContext = context;
    final cancel = _aiCompletionCancel = CancellationToken();
    _aiTimer = Timer(const Duration(milliseconds: 800), () => _requestAiCompletion(context, cancel));
  }

  Future<void> _requestAiCompletion(TerminalAiContext expected, CancellationToken cancel) async {
    bool current() =>
        mounted &&
        !cancel.isCancelled &&
        identical(_aiCompletionCancel, cancel) &&
        _completionEligible(expected) &&
        sameTerminalAiContext(expected, _session.readAiContext());
    if (!current()) return;
    try {
      final result = await _aiService!.complete(expected, _session.readAiHistory(expected), cancel);
      if (!current() || result == null || !validTerminalAiCommand(result) || !result.startsWith(expected.draft!)) {
        return;
      }
      final suffix = result.substring(expected.draft!.length);
      if (suffix.isEmpty || utf8.encode(suffix).length > 2048) return;
      _update(() => _aiCandidate = CommandCandidate(result, source: CommandCandidateSource.ai));
    } on Object {
      // Optional AI completion quietly leaves the local candidates available.
    }
  }

  CommandAssistanceState get _candidateState {
    final state = _session.commandAssistance.value;
    final candidate = _aiCandidate, expected = _aiCompletionContext;
    if (state.request == null ||
        state.browse != null ||
        candidate == null ||
        expected == null ||
        !_completionEligible(expected) ||
        !sameTerminalAiContext(expected, _session.readAiContext())) {
      return state;
    }
    return CommandAssistanceState(
      request: state.request,
      candidates: mergeCommandCandidates(state.request!.text, state.candidates, [candidate]),
      browse: state.browse,
      loading: state.loading,
    );
  }

  Future<void> _acceptCandidate(CommandCompletionRequest request, CommandCandidate candidate) async {
    if (candidate.source != CommandCandidateSource.ai) {
      await _session.acceptCommand(request, candidate.text);
      return;
    }
    final expected = _aiCompletionContext;
    if (!_terminalCompositionReady || !identical(request, _session.commandAssistance.value.request)) return;
    if (expected != null &&
        identical(candidate, _aiCandidate) &&
        _completionEligible(expected) &&
        sameTerminalAiContext(expected, _session.readAiContext())) {
      await _session.acceptAiDraft(expected, candidate.text.substring(expected.draft!.length), suffix: true);
    }
    _cancelAiCompletion();
  }

  bool get _canOpenInlineAi {
    final context = _session.readAiContext();
    return widget.active &&
        widget.visible &&
        _applicationActive &&
        context.ready &&
        _terminalCompositionReady &&
        (_aiService?.canGenerate(context) ?? false);
  }

  /// A small AI badge rides above the cursor so it belongs to the line being typed, not the pane corner.
  Widget _inlineAiBadge(BoxConstraints box) => ValueListenableBuilder<Rect?>(
    valueListenable: _completionCursor,
    builder: (context, cursor, _) {
      if (cursor == null || !_canOpenInlineAi) return const SizedBox.shrink();
      final scheme = Theme.of(context).colorScheme;
      final natural = terminalInputIntent(_session.readAiContext().draft ?? '') == TerminalInputIntent.naturalLanguage;
      const size = 20.0, gap = 2.0;
      final left = min(max(cursor.right + gap, gap), max(gap, box.maxWidth - size - gap));
      final above = cursor.top - size - gap;
      final top = min(above >= gap ? above : cursor.bottom + gap, max(gap, box.maxHeight - size - gap));
      return Positioned(
        left: left,
        top: top,
        width: size,
        height: size,
        child: Tooltip(
          message: AppLocalizations.of(context).terminalAiGenerate,
          child: IconButton(
            key: const ValueKey('terminal-ai-toggle'),
            onPressed: _showInlineAi,
            padding: EdgeInsets.zero,
            style: IconButton.styleFrom(
              minimumSize: const Size.square(size),
              fixedSize: const Size.square(size),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
              backgroundColor: scheme.surfaceContainerHigh.withValues(alpha: .92),
              foregroundColor: natural ? scheme.primary : scheme.onSurfaceVariant,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.control)),
            ),
            icon: const Icon(Icons.auto_awesome_outlined, size: 12),
          ),
        ),
      );
    },
  );

  void _showInlineAi() {
    if (!_canOpenInlineAi) return;
    _cancelAiCompletion();
    final inline = _session._inlineAi;
    inline.open();
    if (!inline.busy && inline.result == null && inline.instruction.trim().isNotEmpty) unawaited(inline.generate());
    _update(() {
      _historyOpen = _composerOpen = false;
      _inlineAiOpen = true;
    });
  }

  void _closeInlineAi() {
    if (!mounted) return;
    _update(() => _inlineAiOpen = false);
    if (widget.active && widget.visible) _focus.requestFocus();
    _scheduleAi();
  }

  Widget _inlineAiOverlay() => Positioned.fill(
    child: LayoutBuilder(
      builder: (context, box) {
        final width = min(InlineAiPopupSize.width, max(0.0, box.maxWidth - Space.sm * 2));
        final height = min(InlineAiPopupSize.maxHeight, max(0.0, box.maxHeight - Space.sm * 2));
        Offset constrain(Offset offset) => Offset(
          offset.dx.clamp(Space.sm, max(Space.sm, box.maxWidth - width - Space.sm)),
          offset.dy.clamp(Space.sm, max(Space.sm, box.maxHeight - height - Space.sm)),
        );
        final offset = constrain(
          _inlineAiOffset ?? _completionCursor.value?.bottomLeft ?? const Offset(Space.sm, Space.sm),
        );
        return Stack(
          children: [
            Positioned(
              left: offset.dx,
              top: offset.dy,
              width: width,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: height),
                child: _InlineAiComposer(
                  key: ObjectKey(_session._inlineAi.context),
                  session: _session,
                  service: _aiService!,
                  isActive: () => mounted && widget.active && widget.visible && _applicationActive && _inlineAiOpen,
                  onClose: _closeInlineAi,
                  onDrag: (delta) => _update(() => _inlineAiOffset = constrain((_inlineAiOffset ?? offset) + delta)),
                  onAskAgent: widget.onAskAgent,
                ),
              ),
            ),
          ],
        );
      },
    ),
  );
}

class _InlineAiComposer extends StatefulWidget {
  const _InlineAiComposer({
    super.key,
    required this.session,
    required this.service,
    required this.isActive,
    required this.onClose,
    required this.onDrag,
    this.onAskAgent,
  });
  final TerminalSession session;
  final TerminalAiService service;
  final bool Function() isActive;
  final VoidCallback onClose;
  final ValueChanged<Offset> onDrag;
  final ValueChanged<String>? onAskAgent;
  @override
  State<_InlineAiComposer> createState() => _InlineAiComposerState();
}

String _failureText(AppLocalizations l, TerminalAiFailure failure) => switch (failure.reason) {
  TerminalAiFailureReason.timeout => l.terminalAiFailedTimeout,
  TerminalAiFailureReason.network => l.terminalAiFailedNetwork,
  TerminalAiFailureReason.http => l.terminalAiFailedHttp(failure.statusCode ?? 0),
  TerminalAiFailureReason.invalid => l.terminalAiFailedInvalid,
  _ => l.terminalAiFailed,
};

class _InlineAiComposerState extends State<_InlineAiComposer> {
  late final _inline = widget.session._inlineAi;
  late final _captured = _inline.context!;
  late final _instruction = TextEditingController(text: _inline.instruction);
  late final _command = TextEditingController(text: _inline.command);
  final _editorFocus = FocusNode();
  final _focus = FocusNode();
  CancellationToken? _acceptCancel;
  bool _insertFailed = false;
  TerminalAiGeneration? _acceptedPreview;
  TerminalAiGeneration? get _result => _acceptedPreview ?? _inline.result;
  TerminalAiFailure? get _failure => _inline.failure;
  bool get _stale => _inline.stale;

  @override
  void initState() {
    super.initState();
    _inline.addListener(_changed);
    widget.session.commandAssistance.addListener(_changed);
    widget.session._directory.changes.addListener(_changed);
    widget.session.addListener(_changed);
    _instruction.addListener(_edited);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  void _edited() {
    _acceptCancel?.cancel();
    _insertFailed = false;
    _acceptedPreview = null;
    _inline.editInstruction(_instruction.text);
    if (!_instruction.value.composing.isCollapsed) _inline.stop();
    if (mounted) setState(() {});
  }

  void _changed() {
    if (_acceptedPreview == null && _command.text != _inline.command) _command.text = _inline.command;
    if (mounted) setState(() {});
  }

  Future<void> _generate() async {
    if (_stale || !_editorFocus.hasFocus || !_instruction.value.composing.isCollapsed) return;
    await _inline.generate();
  }

  bool get _canAccept {
    final current = widget.session.readAiContext();
    return !_stale &&
        widget.isActive() &&
        _editorFocus.hasFocus &&
        _result?.kind == TerminalAiGenerationKind.command &&
        !_inline.busy &&
        _acceptCancel == null &&
        _command.value.composing.isCollapsed &&
        current.ready &&
        (sameTerminalAiContext(_captured, current) ||
            current.draft!.isEmpty && sameTerminalAiContext(_captured, current, draft: false)) &&
        validTerminalAiCommand(_command.text) &&
        widget.service.canGenerate(current);
  }

  Future<void> _accept() async {
    if (!_canAccept) return;
    final current = widget.session.readAiContext();
    _acceptedPreview = _result;
    final cancel = _acceptCancel = CancellationToken();
    setState(() => _insertFailed = false);
    try {
      final sent = await widget.session.acceptAiDraft(
        current,
        _command.text,
        cancel: cancel,
        isCurrent: () =>
            mounted &&
            widget.isActive() &&
            _editorFocus.hasFocus &&
            _instruction.value.composing.isCollapsed &&
            _command.value.composing.isCollapsed &&
            widget.service.canGenerate(_captured),
      );
      if (!mounted) return;
      if (sent == InsertResult.sent) {
        _inline.clear();
        widget.onClose();
      } else if (sent != InsertResult.cancelled) {
        setState(() => _insertFailed = true);
      }
    } finally {
      cancel.cancel();
      _acceptCancel = null;
      if (mounted) setState(() {});
    }
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent || !_instruction.value.composing.isCollapsed || !_command.value.composing.isCollapsed) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      widget.onClose();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter || event.logicalKey == LogicalKeyboardKey.numpadEnter) {
      if (HardwareKeyboard.instance.isShiftPressed) return KeyEventResult.ignored;
      unawaited(_result?.kind == TerminalAiGenerationKind.command ? _accept() : _generate());
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.tab && _canAccept) {
      unawaited(_accept());
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  void dispose() {
    _acceptCancel?.cancel();
    _inline.removeListener(_changed);
    widget.session.commandAssistance.removeListener(_changed);
    widget.session._directory.changes.removeListener(_changed);
    widget.session.removeListener(_changed);
    _instruction.removeListener(_edited);
    _instruction.dispose();
    _command.dispose();
    _focus.dispose();
    _editorFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context), theme = Theme.of(context);
    return TapRegion(
      onTapOutside: (_) => widget.onClose(),
      child: Focus(
        focusNode: _editorFocus,
        onFocusChange: (focused) {
          if (!focused) _acceptCancel?.cancel();
          if (mounted) setState(() {});
        },
        onKeyEvent: _onKey,
        child: PopupSurface(
          key: const ValueKey('terminal-ai-composer'),
          radius: Radii.panel,
          padding: const EdgeInsets.all(Space.sm),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: MouseRegion(
                        cursor: SystemMouseCursors.move,
                        child: GestureDetector(
                          key: const ValueKey('terminal-ai-drag'),
                          behavior: HitTestBehavior.opaque,
                          onPanUpdate: (details) => widget.onDrag(details.delta),
                          child: SizedBox(
                            height: WorkspaceSize.control,
                            child: Row(
                              children: [
                                const Icon(Icons.auto_awesome_outlined, size: 14),
                                const SizedBox(width: Space.sm),
                                Flexible(child: Text(l.terminalAiGenerate, style: theme.textTheme.labelLarge)),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                    IconButton(onPressed: widget.onClose, tooltip: l.close, icon: const Icon(Icons.close, size: 16)),
                  ],
                ),
                const SizedBox(height: Space.sm),
                TextField(
                  key: const ValueKey('terminal-ai-instruction'),
                  controller: _instruction,
                  focusNode: _focus,
                  minLines: 1,
                  maxLines: 3,
                  maxLength: 2048,
                  decoration: InputDecoration(isDense: true, hintText: l.terminalAiInstruction, counterText: ''),
                ),
                if (_inline.busy || _acceptCancel != null)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: Space.sm),
                    child: LinearProgressIndicator(minHeight: 2),
                  ),
                if (_failure case final failure?)
                  Padding(
                    padding: const EdgeInsets.only(top: Space.sm),
                    child: Text(_failureText(l, failure), style: TextStyle(color: theme.colorScheme.error)),
                  ),
                if (_insertFailed)
                  Padding(
                    padding: const EdgeInsets.only(top: Space.sm),
                    child: Text(l.terminalAiInsertFailed, style: TextStyle(color: theme.colorScheme.error)),
                  )
                else if (_stale && _acceptCancel == null)
                  Padding(
                    padding: const EdgeInsets.only(top: Space.sm),
                    child: Text(l.terminalAiChanged, style: theme.textTheme.bodySmall),
                  ),
                if (_result case final result?) ...[
                  const SizedBox(height: Space.sm),
                  if (result.kind == TerminalAiGenerationKind.command)
                    TextField(
                      key: const ValueKey('terminal-ai-command'),
                      controller: _command,
                      minLines: 1,
                      maxLines: 3,
                      style: mono(context),
                      onChanged: (value) {
                        _acceptCancel?.cancel();
                        _inline.command = value;
                        setState(() {});
                      },
                      decoration: const InputDecoration(isDense: true),
                    )
                  else
                    Text(result.message ?? l.terminalAiClarify, style: theme.textTheme.bodySmall),
                  if (result.kind == TerminalAiGenerationKind.command && result.message?.trim().isNotEmpty == true)
                    Padding(
                      padding: const EdgeInsets.only(top: Space.sm),
                      child: Text(result.message!, style: theme.textTheme.bodySmall),
                    ),
                ],
                const SizedBox(height: Space.sm),
                Wrap(
                  alignment: WrapAlignment.end,
                  spacing: Space.sm,
                  runSpacing: Space.sm,
                  children: [
                    if (_result?.kind == TerminalAiGenerationKind.command)
                      TextButton.icon(
                        onPressed: () => Clipboard.setData(ClipboardData(text: _command.text)),
                        icon: const Icon(Icons.copy_outlined, size: 16),
                        label: Text(l.copy),
                      ),
                    if (_result?.kind == TerminalAiGenerationKind.useAgent && widget.onAskAgent != null)
                      TextButton.icon(
                        key: const ValueKey('terminal-ai-agent'),
                        onPressed: () {
                          final instruction = _instruction.text;
                          widget.onClose();
                          widget.onAskAgent!(instruction);
                        },
                        icon: const Icon(Icons.auto_awesome_outlined, size: 16),
                        label: Text(l.terminalAiOpenAgent),
                      ),
                    if (_inline.busy)
                      TextButton(key: const ValueKey('terminal-ai-stop'), onPressed: _inline.stop, child: Text(l.stop))
                    else if (_result?.kind == TerminalAiGenerationKind.command)
                      FilledButton.icon(
                        key: const ValueKey('terminal-ai-accept'),
                        onPressed: _canAccept ? _accept : null,
                        icon: const Icon(Icons.subdirectory_arrow_left, size: 16),
                        label: Text(l.terminalAiInsert),
                      )
                    else
                      FilledButton.icon(
                        key: const ValueKey('terminal-ai-generate'),
                        onPressed: _stale || _instruction.text.trim().isEmpty ? null : _generate,
                        icon: const Icon(Icons.auto_awesome, size: 16),
                        label: Text(l.terminalAiGenerate),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

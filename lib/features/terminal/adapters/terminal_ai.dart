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
    child: Padding(
      padding: const EdgeInsets.all(Space.sm),
      child: Align(
        alignment: Alignment.bottomCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: WorkspaceSize.flyoutWide, maxHeight: WorkspaceSize.toolPanel),
          child: _InlineAiComposer(
            session: _session,
            service: _aiService!,
            onClose: _closeInlineAi,
            onAskAgent: widget.onAskAgent,
          ),
        ),
      ),
    ),
  );
}

class _InlineAiComposer extends StatefulWidget {
  const _InlineAiComposer({required this.session, required this.service, required this.onClose, this.onAskAgent});
  final TerminalSession session;
  final TerminalAiService service;
  final VoidCallback onClose;
  final ValueChanged<String>? onAskAgent;
  @override
  State<_InlineAiComposer> createState() => _InlineAiComposerState();
}

class _InlineAiComposerState extends State<_InlineAiComposer> {
  late final _captured = widget.session.readAiContext();
  late final _instruction = TextEditingController(
    text: _captured.draft!.isEmpty ? widget.session.inlineAiDraft : _captured.draft,
  );
  late final _command = TextEditingController(text: widget.session.inlineAiCommand);
  final _editorFocus = FocusNode();
  final _focus = FocusNode();
  CancellationToken? _cancel;
  TerminalAiGeneration? _result;
  bool _failed = false, _stale = false;

  @override
  void initState() {
    super.initState();
    final saved = widget.session.inlineAiContext;
    if (saved != null && sameTerminalAiContext(saved, _captured, draft: false)) {
      _result = widget.session.inlineAiResult;
    } else {
      _command.clear();
    }
    widget.session.commandAssistance.addListener(_changed);
    widget.session._directory.changes.addListener(_changed);
    widget.session.addListener(_changed);
    _instruction.addListener(_edited);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _focus.requestFocus();
      // Opening from an existing prompt asks the model straight away; the result stays editable.
      if (_result == null && _captured.draft!.trim().isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _editorFocus.hasFocus) unawaited(_generate());
        });
      }
    });
  }

  void _edited() {
    widget.session.inlineAiDraft = _instruction.text;
    if (!_instruction.value.composing.isCollapsed) _cancel?.cancel();
    if (mounted) setState(() {});
  }

  void _changed() {
    final current = widget.session.readAiContext();
    if (!sameTerminalAiContext(_captured, current)) {
      _cancel?.cancel();
      _stale = true;
    }
    if (mounted) setState(() {});
  }

  Future<void> _generate() async {
    if (_cancel != null ||
        _stale ||
        !_editorFocus.hasFocus ||
        !_instruction.value.composing.isCollapsed ||
        _instruction.text.trim().isEmpty) {
      return;
    }
    final current = widget.session.readAiContext();
    if (!sameTerminalAiContext(_captured, current) || !widget.service.canGenerate(current)) return;
    final token = CancellationToken();
    setState(() {
      _cancel = token;
      _result = null;
      _failed = false;
    });
    try {
      final result = await widget.service.generate(
        _captured,
        _instruction.text.trim(),
        token,
        history: widget.session.readAiHistory(_captured),
      );
      if (!mounted || token.isCancelled || !sameTerminalAiContext(_captured, widget.session.readAiContext())) return;
      if (result.kind == TerminalAiGenerationKind.command && !validTerminalAiCommand(result.command ?? '')) {
        throw const FormatException('command');
      }
      setState(() {
        _result = result;
        _command.text = result.command ?? '';
      });
    } on Object {
      if (mounted && !token.isCancelled) setState(() => _failed = true);
    } finally {
      if (mounted && identical(_cancel, token)) setState(() => _cancel = null);
    }
  }

  /// Stops the visible wait at once; the cancelled token makes any late model result a no-op.
  void _stop() {
    _cancel?.cancel();
    if (mounted) setState(() => _cancel = null);
  }

  bool get _canAccept {
    final current = widget.session.readAiContext();
    return !_stale &&
        _editorFocus.hasFocus &&
        _result?.kind == TerminalAiGenerationKind.command &&
        _cancel == null &&
        _command.value.composing.isCollapsed &&
        current.ready &&
        current.draft!.isEmpty &&
        sameTerminalAiContext(_captured, current, draft: false) &&
        validTerminalAiCommand(_command.text) &&
        widget.service.canGenerate(current);
  }

  Future<void> _accept() async {
    if (!_canAccept) return;
    final current = widget.session.readAiContext();
    final sent = await widget.session.acceptAiDraft(current, _command.text);
    if (mounted && sent == InsertResult.sent) {
      _result = null;
      _command.clear();
      widget.onClose();
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
    _cancel?.cancel();
    widget.session.commandAssistance.removeListener(_changed);
    widget.session._directory.changes.removeListener(_changed);
    widget.session.removeListener(_changed);
    if (widget.session.canInsert) {
      widget.session.inlineAiContext = _captured;
      widget.session.inlineAiResult = _result;
      widget.session.inlineAiCommand = _command.text;
    }
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
          if (!focused) _cancel?.cancel();
          if (mounted) setState(() {});
        },
        onKeyEvent: _onKey,
        child: PopupSurface(
          key: const ValueKey('terminal-ai-composer'),
          radius: Radii.panel,
          padding: const EdgeInsets.all(Space.md),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const Icon(Icons.auto_awesome_outlined, size: 16),
                    const SizedBox(width: Space.sm),
                    Expanded(child: Text(l.terminalAiGenerate, style: theme.textTheme.labelLarge)),
                    IconButton(onPressed: widget.onClose, tooltip: l.close, icon: const Icon(Icons.close, size: 16)),
                  ],
                ),
                const SizedBox(height: Space.sm),
                TextField(
                  key: const ValueKey('terminal-ai-instruction'),
                  controller: _instruction,
                  focusNode: _focus,
                  readOnly: _cancel != null,
                  minLines: 2,
                  maxLines: 4,
                  maxLength: 2048,
                  decoration: InputDecoration(hintText: l.terminalAiInstruction, counterText: ''),
                ),
                if (_cancel != null)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: Space.md),
                    child: LinearProgressIndicator(minHeight: 2),
                  ),
                if (_failed)
                  Padding(
                    padding: const EdgeInsets.only(top: Space.sm),
                    child: Text(l.terminalAiFailed, style: TextStyle(color: theme.colorScheme.error)),
                  ),
                if (_stale)
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
                      maxLines: 5,
                      style: mono(context),
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(isDense: true),
                    )
                  else
                    Text(result.message ?? l.terminalAiClarify, style: theme.textTheme.bodySmall),
                  if (result.kind == TerminalAiGenerationKind.command && result.message?.trim().isNotEmpty == true)
                    Padding(
                      padding: const EdgeInsets.only(top: Space.sm),
                      child: Text(result.message!, style: theme.textTheme.bodySmall),
                    ),
                  if (!_canAccept && result.kind == TerminalAiGenerationKind.command)
                    Padding(
                      padding: const EdgeInsets.only(top: Space.sm),
                      child: Text(l.terminalAiClearPrompt, style: theme.textTheme.bodySmall),
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
                    if (_cancel != null)
                      TextButton(key: const ValueKey('terminal-ai-stop'), onPressed: _stop, child: Text(l.stop))
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

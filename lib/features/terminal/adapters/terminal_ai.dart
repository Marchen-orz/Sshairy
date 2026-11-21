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
        if (value == null) {
          composing = true;
        } else if (value.composing.isCollapsed) {
          composing = false;
        } else if (widget.compact) {
          // Mobile soft keyboards underline the active ASCII word as composing even after characters reach the shell;
          // only treat non-ASCII IME pre-edit (e.g. CJK pinyin) as active composition.
          final slice = value.composing.textInside(value.text);
          composing = slice.codeUnits.any((c) => c > 0x7F);
        } else {
          composing = true;
        }
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
      _session._aiTask == null &&
      !_searching &&
      !_composerOpen &&
      !_historyOpen &&
      !_session._historyBrowsing &&
      context.ready &&
      _terminalCompositionReady &&
      (context.draft!.isEmpty || !identical(_dismissedCandidateRequest, _session.commandAssistance.value.request)) &&
      (_aiService?.canComplete(context) ?? false);

  void _syncAi() {
    final context = _session.readAiContext();
    final inline = _canOpenInlineAi;
    final task = _session._aiTask;
    final presentation = (
      inline,
      inline && terminalInputIntent(context.draft ?? '') == TerminalInputIntent.naturalLanguage,
      task == null ? null : (task.auto, task.thinking),
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
    final had = _aiCandidate != null;
    _cancelAiCompletion();
    if (had) _update(() {});
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
    var started = false;
    Duration? deferred;
    try {
      final result = await _aiService!.complete(
        expected,
        _session.readAiHistory(expected),
        cancel,
        onStarted: () => started = true,
        onDeferred: (delay) => deferred = delay,
      );
      if (current() && result == null && !started && deferred != null && deferred! > Duration.zero) {
        _aiTimer?.cancel();
        _aiTimer = Timer(deferred!, () => _requestAiCompletion(expected, cancel));
        return;
      }
      if (!current() || result == null || !validTerminalAiCommand(result) || !result.startsWith(expected.draft!)) {
        return;
      }
      final suffix = result.substring(expected.draft!.length);
      if (suffix.isEmpty || utf8.encode(suffix).length > 2048) return;
      _update(() => _aiCandidate = result);
    } on Object {
      // Optional AI completion quietly leaves the local candidates available.
    }
  }

  /// The validated AI suffix, or a whole next command on an empty prompt, drawn after the cursor as ghost text.
  String? get _ghost {
    final candidate = _aiCandidate, expected = _aiCompletionContext;
    if (candidate == null ||
        expected == null ||
        !_completionEligible(expected) ||
        !sameTerminalAiContext(expected, _session.readAiContext())) {
      return null;
    }
    return candidate.substring(expected.draft!.length);
  }

  Future<void> _acceptGhost(String suffix) async {
    final expected = _aiCompletionContext!;
    _update(_cancelAiCompletion);
    await _session.acceptAiDraft(expected, suffix, suffix: true);
  }

  Widget _ghostText() => ValueListenableBuilder<Rect?>(
    valueListenable: _completionCursor,
    builder: (context, cursor, _) {
      final suffix = _ghost;
      if (cursor == null || suffix == null) return const SizedBox.shrink();
      final settings = ref.read(settingsProvider);
      final ghost = Text(
        suffix,
        key: const ValueKey('terminal-ai-ghost'),
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.clip,
        style: TextStyle(
          fontFamily: settings.terminalFontFamily ?? AppFonts.mono,
          fontFamilyFallback: AppFonts.monoFallback,
          fontSize: _liveFontSize ?? settings.fontSize,
          height: 1.2,
          color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: .6),
        ),
      );
      return Positioned(
        left: cursor.left,
        top: cursor.top,
        right: 0,
        height: cursor.height,
        child: widget.compact
            ? GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => unawaited(_acceptGhost(suffix)),
                child: ghost,
              )
            : IgnorePointer(child: ghost),
      );
    },
  );

  /// The last command in this shell generation exited nonzero by a reliable OSC 133 D and can be sent.
  bool get _fixAvailable {
    final context = _session.readAiContext(), last = _session._aiHistory.lastOrNull;
    return context.prompt == TerminalAiPrompt.semantic &&
        context.draft?.isEmpty == true &&
        last != null &&
        last.generation == context.generation &&
        (last.exitCode ?? 0) != 0 &&
        boundedTerminalAiHistory([last]).isNotEmpty;
  }

  bool get _canOpenInlineAi {
    final context = _session.readAiContext();
    return _session._aiTask == null &&
        widget.active &&
        widget.visible &&
        _applicationActive &&
        (_focus.hasFocus || _inlineAiOpen) &&
        !_searching &&
        !_composerOpen &&
        !_historyOpen &&
        !_session._historyBrowsing &&
        context.ready &&
        _terminalCompositionReady &&
        (_aiService?.canGenerate(context) ?? false);
  }

  /// A small AI badge rides above the cursor so it belongs to the line being typed, not the pane corner.
  /// While a task runs it becomes the task's auto toggle and stop button.
  Widget _inlineAiBadge(BoxConstraints box) => ValueListenableBuilder<Rect?>(
    valueListenable: _completionCursor,
    builder: (context, cursor, _) {
      final task = _session._aiTask;
      if (cursor == null || task == null && (!_canOpenInlineAi || _inlineAiOpen)) return const SizedBox.shrink();
      final l = AppLocalizations.of(context), scheme = Theme.of(context).colorScheme;
      const size = 20.0, gap = 2.0;
      final width = task == null ? size : size * 2;
      final left = min(max(cursor.right + gap, gap), max(gap, box.maxWidth - width - gap));
      final above = cursor.top - size - gap;
      final top = min(above >= gap ? above : cursor.bottom + gap, max(gap, box.maxHeight - size - gap));
      Widget button(Key key, String tooltip, Color color, VoidCallback onPressed, Widget icon) => Tooltip(
        message: tooltip,
        child: IconButton(
          key: key,
          onPressed: onPressed,
          padding: EdgeInsets.zero,
          style: IconButton.styleFrom(
            minimumSize: const Size.square(size),
            fixedSize: const Size.square(size),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            visualDensity: VisualDensity.compact,
            backgroundColor: scheme.surfaceContainerHigh.withValues(alpha: .92),
            foregroundColor: color,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.control)),
          ),
          icon: icon,
        ),
      );
      final Widget child;
      if (task == null) {
        final fix = _fixAvailable;
        final highlighted =
            terminalInputIntent(_session.readAiContext().draft ?? '') == TerminalInputIntent.naturalLanguage;
        child = button(
          const ValueKey('terminal-ai-toggle'),
          fix ? l.terminalAiFix : l.terminalAiGenerate,
          fix
              ? scheme.error
              : highlighted
              ? scheme.primary
              : scheme.onSurfaceVariant,
          _showInlineAi,
          Icon(fix ? Icons.build_outlined : Icons.auto_awesome_outlined, size: 12),
        );
      } else {
        child = Row(
          children: [
            button(
              const ValueKey('terminal-ai-auto'),
              l.terminalAiAuto,
              task.auto ? scheme.primary : scheme.onSurfaceVariant,
              () => _session._setAiTaskAuto(!task.auto),
              Icon(task.auto ? Icons.fast_forward : Icons.fast_forward_outlined, size: 12),
            ),
            button(
              const ValueKey('terminal-ai-stop'),
              l.stop,
              scheme.primary,
              () => _session._stopAiTask(restore: true),
              Stack(
                alignment: Alignment.center,
                children: [
                  if (task.thinking)
                    const SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 1.5)),
                  const Icon(Icons.stop, size: 10),
                ],
              ),
            ),
          ],
        );
      }
      return Positioned(left: left, top: top, width: width, height: size, child: child);
    },
  );

  /// A failed command gets fixed and a typed draft becomes the request; an empty prompt asks for one.
  void _showInlineAi() {
    if (!_canOpenInlineAi) return;
    _cancelAiCompletion();
    final draft = _session.readAiContext().draft!;
    if (_fixAvailable) return _startInlineAi(AppLocalizations.of(context).terminalAiFix);
    if (draft.trim().isNotEmpty) return _startInlineAi(draft);
    _update(() {
      _historyOpen = _composerOpen = false;
      _inlineAiOpen = true;
    });
  }

  void _startInlineAi(String instruction) {
    final l = AppLocalizations.of(context);
    unawaited(_session._startAiTask(_aiService!, instruction, (failure) => _failureText(l, failure)));
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
        final cursor = _completionCursor.value;
        final below = cursor == null || cursor.bottom < box.maxHeight / 2;
        return Stack(
          children: [
            Positioned(
              left: (cursor?.left ?? Space.sm).clamp(Space.sm, max(Space.sm, box.maxWidth - width - Space.sm)),
              top: below ? cursor?.bottom ?? Space.sm : null,
              bottom: below ? null : box.maxHeight - cursor.top,
              width: width,
              child: Entrance(
                offset: Offset.zero,
                child: _InlineAiComposer(
                  onSubmit: (instruction) {
                    if (_canOpenInlineAi) _startInlineAi(instruction);
                    _closeInlineAi();
                  },
                  onClose: _closeInlineAi,
                ),
              ),
            ),
          ],
        );
      },
    ),
  );
}

String _failureText(AppLocalizations l, TerminalAiFailure failure) => switch (failure.reason) {
  TerminalAiFailureReason.timeout => l.terminalAiFailedTimeout,
  TerminalAiFailureReason.network => l.terminalAiFailedNetwork,
  TerminalAiFailureReason.http => l.terminalAiFailedHttp(failure.statusCode ?? 0),
  TerminalAiFailureReason.invalid => l.terminalAiFailedInvalid,
  _ => l.terminalAiFailed,
};

class _InlineAiComposer extends StatefulWidget {
  const _InlineAiComposer({required this.onSubmit, required this.onClose});
  final ValueChanged<String> onSubmit;
  final VoidCallback onClose;
  @override
  State<_InlineAiComposer> createState() => _InlineAiComposerState();
}

class _InlineAiComposerState extends State<_InlineAiComposer> {
  final _instruction = TextEditingController();
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent || !_instruction.value.composing.isCollapsed) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      widget.onClose();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter || event.logicalKey == LogicalKeyboardKey.numpadEnter) {
      if (HardwareKeyboard.instance.isShiftPressed) return KeyEventResult.ignored;
      if (_instruction.text.trim().isNotEmpty) widget.onSubmit(_instruction.text);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  void dispose() {
    _instruction.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TapRegion(
    onTapOutside: (_) => widget.onClose(),
    child: Focus(
      onKeyEvent: _onKey,
      child: PopupSurface(
        key: const ValueKey('terminal-ai-composer'),
        radius: Radii.panel,
        padding: const EdgeInsets.all(Space.sm),
        child: TextField(
          key: const ValueKey('terminal-ai-instruction'),
          controller: _instruction,
          focusNode: _focus,
          minLines: 1,
          maxLines: 3,
          maxLength: 2048,
          decoration: InputDecoration(
            isDense: true,
            hintText: AppLocalizations.of(context).terminalAiInstruction,
            counterText: '',
          ),
        ),
      ),
    ),
  );
}

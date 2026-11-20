part of 'terminal_session.dart';

/// An entry the owner adds to the pane's context menu, such as splitting.
class PaneAction {
  const PaneAction(this.label, this.icon, this.run);

  final String label;
  final IconData icon;
  final VoidCallback run;
}

class TerminalPane extends ConsumerStatefulWidget {
  const TerminalPane(
    this.session, {
    super.key,
    required this.active,
    this.visible = true,
    this.compact = false,
    this.onKeyEvent,
    this.onAskAgent,
    this.onOpenSnippets,
    this.focusNode,
    this.actions = const [],
  });

  final TerminalSession session;
  final bool active;
  final bool visible;

  /// True in mobile / compact workspace mode: shows the touch key bar and enables pinch-to-zoom.
  final bool compact;

  /// Sees keys before the terminal does, so application shortcuts are not sent to the shell.
  final FocusOnKeyEventCallback? onKeyEvent;
  final ValueChanged<String>? onAskAgent;
  final VoidCallback? onOpenSnippets;

  /// Lets the owner move focus between panes; the pane makes its own when none is given.
  final FocusNode? focusNode;
  final List<PaneAction> actions;

  @override
  ConsumerState<TerminalPane> createState() => _TerminalPaneState();
}

class _TerminalPaneState extends ConsumerState<TerminalPane> with WidgetsBindingObserver {
  late final FocusNode _focus = widget.focusNode ?? FocusNode();
  final _controller = TerminalController();
  final _view = GlobalKey<TerminalViewState>();
  final _scroll = ScrollController();
  final _terminalOwnsBackground = ValueNotifier<bool>(false);
  final _completionCursor = ValueNotifier<Rect?>(null);
  Rect? _imeRect;
  var _imeRectScheduled = false;
  var _searching = false;
  var _candidateMode = false;
  CommandCompletionRequest? _candidateRequest;
  var _candidateIndex = 0;
  String? _candidateText;
  final _candidateScroll = ScrollController();
  CommandCompletionRequest? _dismissedCandidateRequest;
  int _candidateBrowseDepth = 0;
  Offset? _candidatePointer;
  var _candidateTranslationsScheduled = false;
  CompletionTranslations? _candidateTranslations;
  CancellationToken? _candidateTranslationCancel;
  Set<String> _candidateTranslationOriginals = const {};
  String? _candidateTranslationLocale;
  var _historyOpen = false, _historyPinned = false, _composerOpen = false;
  Offset? _historyOffset;
  Offset? _inlineAiOffset;
  Size? _historySize;
  int? _composerGeneration;
  TerminalAiService? _aiService;
  StreamSubscription<void>? _aiChanges;
  Timer? _aiTimer;
  CancellationToken? _aiCompletionCancel;
  TerminalAiContext? _aiCompletionContext;
  (bool, bool)? _aiPresentation;
  CommandCandidate? _aiCandidate;
  bool? _aiLastCompositionReady;
  bool _inlineAiOpen = false,
      _aiScheduled = false,
      _aiFrameListening = false,
      _aiCompletionLoading = false,
      _applicationActive = true;
  late final VoidCallback _aiFrameCallback = _aiFrame;
  var _touchCtrl = TouchModifierState.off;
  var _touchAlt = TouchModifierState.off;
  double? _pinchBaseFontSize;
  double? _liveFontSize;

  TerminalSession get _session => widget.session;
  Terminal get _terminal => _session._terminal;

  // The assistance extension lives outside the State subclass and may not call the protected setState.
  void _update(VoidCallback change) => setState(change);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _session.commandAssistance.addListener(_scheduleAi);
    _session._directory.changes.addListener(_scheduleAi);
    _focus.addListener(_scheduleAi);
    _session.addListener(_scheduleAi);
    _session.addListener(_focusWhenConnected);
    _terminal.addListener(_scheduleImeRect);
    _terminal.addListener(_backgroundChanged);
    _scroll.addListener(_scheduleImeRect);
    _candidateScroll.addListener(_scheduleCandidateTranslations);
    _focus.addListener(_scheduleImeRect);
    _focus.addListener(_assistanceFocusChanged);
    _markViewed();
    // A pane can be rebuilt (moved into a split, a tab restored): only a session that never ran dials by itself.
    if (_session.status == SessionStatus.idle && _session.autoConnect) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _connect();
      });
    }
  }

  @override
  void didUpdateWidget(TerminalPane old) {
    super.didUpdateWidget(old);
    _scheduleImeRect();
    _scheduleCandidateTranslations();
    if (!widget.active || !widget.visible) {
      if (!_historyPinned) _historyOpen = false;
      _composerOpen = false;
      _inlineAiOpen = false;
      _cancelAiCompletion();
    }
    _scheduleAi();
    if (widget.active != old.active) _markViewed();
    if (widget.active && !old.active) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.active && !_searching && !_composerOpen && !_inlineAiOpen) _focus.requestFocus();
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _applicationActive = state == AppLifecycleState.resumed;
    if (!_applicationActive) {
      _cancelAiCompletion();
      if (mounted) setState(() => _inlineAiOpen = false);
    }
    _scheduleAi();
  }

  /// Clearing the unread mark rebuilds the tab bar, so it waits until this build is over.
  void _markViewed() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (mounted) _session.viewed = widget.active;
  });

  Future<void> _connect() => _session.connect(DialogPrompts(context));

  void _focusWhenConnected() {
    if (widget.active &&
        !_searching &&
        !_historyOpen &&
        !_composerOpen &&
        !_inlineAiOpen &&
        _session.status == SessionStatus.connected) {
      _focus.requestFocus();
    }
  }

  void _backgroundChanged() {
    _terminalOwnsBackground.value = _terminal.backgroundColorOverride != null || _terminal.reverseDisplayMode;
  }

  void _assistanceFocusChanged() {
    _scheduleCandidateTranslations();
    if (mounted) {
      setState(() {
        _candidateMode = false;
        _candidateRequest = null;
      });
    }
  }

  /// xterm2 never sends the composing rect, so Windows puts the IME candidate window at the window corner.
  /// Its editable transform is the identity, so the cursor's global rect is what the engine expects.
  void _scheduleImeRect() {
    if (_imeRectScheduled) return;
    _imeRectScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _imeRectScheduled = false;
      final view = _view.currentState;
      if (!mounted || view == null) return;
      final box = context.findRenderObject();
      final render = view.renderTerminal;
      final rect = MatrixUtils.transformRect(render.getTransformTo(null), view.cursorRect);
      if (box is RenderBox && box.hasSize) {
        final local = Rect.fromPoints(box.globalToLocal(rect.topLeft), box.globalToLocal(rect.bottomRight));
        _completionCursor.value = (Offset.zero & box.size).overlaps(local) ? local : null;
      }
      if (!_focus.hasFocus) return;
      if (rect == _imeRect) return;
      _imeRect = rect;
      SystemChannels.textInput.invokeMethod<void>('TextInput.setMarkedTextRect', {
        'x': rect.left,
        'y': rect.top,
        'width': rect.width,
        'height': rect.height,
      });
      final scale = View.of(context).devicePixelRatio;
      ImeCaret.moveTo(Rect.fromLTRB(rect.left * scale, rect.top * scale, rect.right * scale, rect.bottom * scale));
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _session.commandAssistance.removeListener(_scheduleAi);
    _session._directory.changes.removeListener(_scheduleAi);
    _focus.removeListener(_scheduleAi);
    _session.removeListener(_scheduleAi);
    _aiChanges?.cancel();
    _cancelAiCompletion();
    _stopAiFrames();
    _terminal.removeListener(_scheduleImeRect);
    _terminal.removeListener(_backgroundChanged);
    _terminalOwnsBackground.dispose();
    _completionCursor.dispose();
    _scroll.removeListener(_scheduleImeRect);
    _focus.removeListener(_scheduleImeRect);
    _focus.removeListener(_assistanceFocusChanged);
    _session.removeListener(_focusWhenConnected);
    _session.viewed = false;
    _cancelCandidateTranslations();
    _candidateScroll.removeListener(_scheduleCandidateTranslations);
    _candidateScroll.dispose();
    _controller.dispose();
    _scroll.dispose();
    if (widget.focusNode == null) _focus.dispose();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final keys = HardwareKeyboard.instance;
    final shortcuts = ref.read(settingsProvider).shortcuts;
    if (event is KeyDownEvent &&
        _canOpenInlineAi &&
        AppShortcuts.matches(shortcuts, AppShortcutAction.inlineGenerate, event)) {
      _showInlineAi();
      return KeyEventResult.handled;
    }
    if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.escape && _historyOpen) {
      _closeHistory();
      return KeyEventResult.handled;
    }
    final assistance = _assistanceKey(event);
    if (assistance != null) return assistance;
    if (event is KeyDownEvent) {
      if (AppShortcuts.matches(shortcuts, AppShortcutAction.terminalSearch, event)) {
        setState(() => _searching = true);
        return KeyEventResult.handled;
      }
      if (AppShortcuts.matches(shortcuts, AppShortcutAction.terminalCopy, event)) {
        _copy();
        return KeyEventResult.handled;
      }
      if (AppShortcuts.matches(shortcuts, AppShortcutAction.terminalPaste, event)) {
        unawaited(_paste());
        return KeyEventResult.handled;
      }
    }
    // xterm2 copies on Ctrl+C while text is selected; docs/UI.md §6 always passes it to the shell.
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.keyC &&
        keys.isControlPressed &&
        !keys.isShiftPressed &&
        !keys.isAltPressed) {
      _controller.clearSelection();
    }
    if (widget.compact &&
        event is KeyDownEvent &&
        (_touchCtrl != TouchModifierState.off || _touchAlt != TouchModifierState.off) &&
        event.character != null &&
        event.character!.isNotEmpty) {
      _sendTouchSequence(event.character!);
      return KeyEventResult.handled;
    }
    return widget.onKeyEvent?.call(node, event) ?? KeyEventResult.ignored;
  }

  void _toggleTouchCtrl() => setState(() {
    _touchCtrl = _touchCtrl == TouchModifierState.off ? TouchModifierState.oneshot : TouchModifierState.off;
  });

  void _lockTouchCtrl() => setState(() {
    _touchCtrl = _touchCtrl == TouchModifierState.locked ? TouchModifierState.off : TouchModifierState.locked;
  });

  void _toggleTouchAlt() => setState(() {
    _touchAlt = _touchAlt == TouchModifierState.off ? TouchModifierState.oneshot : TouchModifierState.off;
  });

  void _lockTouchAlt() => setState(() {
    _touchAlt = _touchAlt == TouchModifierState.locked ? TouchModifierState.off : TouchModifierState.locked;
  });

  void _sendTouchSequence(String raw) {
    final ctrl = _touchCtrl != TouchModifierState.off;
    final alt = _touchAlt != TouchModifierState.off;
    final text = applyTouchModifiers(raw, ctrl: ctrl, alt: alt);
    _terminal.textInput(text);
    if (_touchCtrl == TouchModifierState.oneshot || _touchAlt == TouchModifierState.oneshot) {
      setState(() {
        if (_touchCtrl == TouchModifierState.oneshot) _touchCtrl = TouchModifierState.off;
        if (_touchAlt == TouchModifierState.oneshot) _touchAlt = TouchModifierState.off;
      });
    }
  }

  String? get _selectedText {
    final range = _controller.selection;
    return range == null ? null : _terminal.buffer.getText(range);
  }

  Future<void> _copy() async {
    final text = _selectedText;
    if (text != null && text.isNotEmpty) {
      await Clipboard.setData(ClipboardData(text: text));
    }
  }

  Future<void> _paste() async {
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    if (text == null || text.isEmpty || !mounted) return;
    await _session.insert(
      text,
      confirmMultiline: ref.read(settingsProvider).get(SettingKeys.confirmPaste),
      confirm: (preview) => confirmTerminalInsert(context, preview),
    );
  }

  void _selectAll() {
    final buffer = _terminal.buffer;
    _controller.setSelection(
      buffer.createAnchorFromOffset(const CellOffset(0, 0)),
      buffer.createAnchorFromOffset(CellOffset(_terminal.viewWidth, buffer.height - 1)),
    );
  }

  /// The http(s) link under [cell], joining soft-wrapped rows so a long link is found whole.
  String? _linkAt(CellOffset cell) {
    final lines = _terminal.buffer.lines;
    if (cell.y < 0 || cell.y >= lines.length) return null;
    var first = cell.y, last = cell.y;
    while (first > 0 && lines[first].isWrapped) {
      first--;
    }
    while (last + 1 < lines.length && lines[last + 1].isWrapped) {
      last++;
    }
    final text = StringBuffer();
    int? index;
    for (var y = first; y <= last; y++) {
      final line = lines[y];
      for (var x = 0; x < line.length; x++) {
        if (y == cell.y && x == cell.x) index = text.length;
        if (line.getWidth(x) == 0) continue;
        final cp = line.getCodePoint(x);
        text.write(String.fromCharCode(cp == 0 ? 0x20 : cp));
      }
    }
    return index == null ? null : linkAt(text.toString(), index);
  }

  void _onTapUp(TapUpDetails _, CellOffset cell) {
    if (!HardwareKeyboard.instance.isControlPressed && !HardwareKeyboard.instance.isMetaPressed) {
      return;
    }
    final link = _linkAt(cell);
    if (link != null) openExternal(link);
  }

  Future<void> _onSecondaryTapUp(TapUpDetails details, CellOffset cell) async {
    if (ref.read(settingsProvider).get(SettingKeys.rightClick) == RightClick.paste &&
        !HardwareKeyboard.instance.isShiftPressed) {
      return _paste();
    }
    final l = AppLocalizations.of(context);
    final link = _linkAt(cell);
    final hasSelection = _selectedText?.isNotEmpty ?? false;
    AppMenuItem<VoidCallback> item(String label, IconData icon, VoidCallback run, {bool enabled = true}) =>
        AppMenuItem(value: run, label: label, icon: icon, enabled: enabled);
    final run = await showAppMenu<VoidCallback>(
      context: context,
      anchor: anchorAt(details.globalPosition),
      items: [
        if (link != null) ...[
          item(l.openLink, Icons.open_in_new, () => openExternal(link)),
          item(l.copyLink, Icons.link, () => Clipboard.setData(ClipboardData(text: link))),
          const AppMenuDivider(),
        ],
        item(l.copy, Icons.copy_outlined, _copy, enabled: hasSelection),
        item(l.paste, Icons.content_paste_outlined, _paste),
        item(l.selectAll, Icons.select_all, _selectAll),
        item(l.find, Icons.search, () => setState(() => _searching = true)),
        item(l.commandHistory, Icons.history, () => _showHistory(details.globalPosition)),
        item(l.terminalMultilineInput, Icons.edit_note_outlined, _showComposer, enabled: _session.canInsert),
        item(l.clearScreen, Icons.clear_all, _terminal.clear),
        if (_session.sshHost != null)
          item(
            _session.shellIntegrated ? l.shellIntegrationRemove : l.shellIntegrationInstall,
            Icons.integration_instructions_outlined,
            () => _setShellIntegration(!_session.shellIntegrated),
          ),
        if (widget.actions.isNotEmpty) const AppMenuDivider(),
        for (final a in widget.actions) item(a.label, a.icon, a.run),
      ],
    );
    run?.call();
  }

  Future<void> _setShellIntegration(bool install) async {
    final messenger = ScaffoldMessenger.maybeOf(context), l = AppLocalizations.of(context);
    final ok = await _session.setShellIntegration(install);
    messenger?.showSnackBar(
      SnackBar(
        content: Text(
          !ok
              ? l.shellIntegrationFailed
              : install
              ? l.shellIntegrationInstalled
              : l.shellIntegrationRemoved,
        ),
      ),
    );
  }

  void _closeSearch() {
    setState(() => _searching = false);
    _controller.clearSearchHighlights();
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    _scheduleImeRect();
    _bindAiService(ref.watch(terminalAiServiceProvider));
    final l = AppLocalizations.of(context);
    final settings = ref.watch(settingsProvider);
    final copyOnSelect = settings.get(SettingKeys.copyOnSelect);
    final palette = TerminalPalette.of(Theme.of(context));
    final imageOpacity =
        ref.watch(backgroundImagesProvider)[BackgroundSlot.terminal] ??
        settings.get<double>(SettingKeys.terminalBackgroundOpacity);
    final imageAvailable =
        widget.visible &&
        imageOpacity > 0 &&
        ref.watch(backgroundImageStoreProvider).file(settings.get(SettingKeys.terminalBackgroundImage)) != null;
    return ListenableBuilder(
      listenable: Listenable.merge([_session, _terminalOwnsBackground]),
      builder: (context, _) {
        final hasImage = imageAvailable && _terminal.backgroundColorOverride == null && !_terminal.reverseDisplayMode;
        final stack = Stack(
          fit: StackFit.expand,
          children: [
            // The image is composed at the chosen opacity here, rather than drawn opaque under a terminal surface
            // that carries the remaining 1 - opacity: while a dock resizes the pane the frozen grid no longer
            // covers all of it, and a strip showing the raw image would flash brighter for a moment. It stays
            // outside the snapshot so the picture keeps covering the viewport instead of sliding with the grid.
            Positioned.fill(
              child: hasImage
                  ? BackgroundImageView(
                      slot: BackgroundSlot.terminal,
                      baseColor: palette.background,
                      opacity: imageOpacity,
                    )
                  : ColoredBox(color: palette.background),
            ),
            Positioned.fill(
              // xterm2 draws every cell on its own; on Impeller a full screen costs tens of milliseconds a frame, so
              // transitions elsewhere see it as a still image.
              child: MotionSnapshot(
                freezeLayout: true,
                child: Listener(
                  onPointerUp: copyOnSelect ? (_) => _copy() : null,
                  child: ScrollConfiguration(
                    behavior: const AppScrollBehavior(gutter: 0),
                    child: TerminalView(
                      _terminal,
                      key: _view,
                      focusNode: _focus,
                      controller: _controller,
                      scrollController: _scroll,
                      onKeyEvent: _onKey,
                      padding: const EdgeInsets.all(Space.sm),
                      theme: _terminalTheme(palette),
                      // The backdrop already carries the image's transparency; a second veil would tint it twice.
                      backgroundOpacity: hasImage ? 0 : 1,
                      cursorType: switch (settings.get(SettingKeys.cursorShape)) {
                        CursorShape.block => TerminalCursorType.block,
                        CursorShape.underline => TerminalCursorType.underline,
                        CursorShape.bar => TerminalCursorType.verticalBar,
                      },
                      onPaste: _paste,
                      onTapUp: _onTapUp,
                      onSecondaryTapUp: _onSecondaryTapUp,
                      textStyle: TerminalStyle(
                        fontSize: _liveFontSize ?? settings.fontSize,
                        fontFamily: settings.terminalFontFamily ?? AppFonts.mono,
                        fontFamilyFallback: AppFonts.monoFallback,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            _completionOverlay(),
            if (widget.visible)
              Positioned.fill(
                child: LayoutBuilder(builder: (context, box) => Stack(children: [_inlineAiBadge(box)])),
              ),
            if (_searching)
              Positioned(
                top: Space.sm,
                right: Space.lg,
                child: Entrance(
                  offset: const Offset(0, -6),
                  child: _SearchBar(
                    terminal: _terminal,
                    controller: _controller,
                    reveal: _reveal,
                    onClose: _closeSearch,
                  ),
                ),
              ),
            if (_session.status != SessionStatus.connected)
              Center(
                child: Entrance(
                  offset: const Offset(0, 6),
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.all(Space.lg),
                      child: switch (_session) {
                        TerminalSession(status: SessionStatus.connecting) => Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                            const SizedBox(width: Space.md),
                            Text(l.connecting),
                          ],
                        ),
                        TerminalSession(reconnectIn: final n?) => Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(_message(l, _session)),
                            const SizedBox(height: Space.sm),
                            Text(l.reconnectingIn(n)),
                            const SizedBox(height: Space.md),
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                TextButton(onPressed: _session.stopReconnect, child: Text(l.stop)),
                                const SizedBox(width: Space.sm),
                                FilledButton(autofocus: true, onPressed: _connect, child: Text(l.retry)),
                              ],
                            ),
                          ],
                        ),
                        _ => Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(_session.status == SessionStatus.idle ? _session.targetLabel : _message(l, _session)),
                            const SizedBox(height: Space.md),
                            FilledButton(
                              autofocus: true,
                              onPressed: _connect,
                              child: Text(_session.status == SessionStatus.idle ? l.connect : l.retry),
                            ),
                          ],
                        ),
                      },
                    ),
                  ),
                ),
              ),
            if (widget.visible) ...[
              if (!_searching &&
                  !_composerOpen &&
                  !_historyOpen &&
                  !_inlineAiOpen &&
                  _session.status == SessionStatus.connected)
                Positioned(
                  top: Space.xs,
                  right: Space.sm,
                  child: IconButton(
                    key: const ValueKey('terminal-multiline-toggle'),
                    tooltip: l.terminalMultilineInput,
                    icon: const Icon(Icons.edit_note_outlined, size: 18),
                    visualDensity: VisualDensity.compact,
                    onPressed: _showComposer,
                  ),
                ),
              if ((widget.active || _historyPinned) && _historyOpen) _historyOverlay(),
              if (widget.active && _composerOpen) _composerOverlay(),
              if (widget.active && _inlineAiOpen) _inlineAiOverlay(),
            ],
          ],
        );
        if (!widget.compact) return stack;
        final zoomed = GestureDetector(
          behavior: HitTestBehavior.translucent,
          onScaleStart: (details) {
            if (details.pointerCount >= 2) {
              _pinchBaseFontSize = _liveFontSize ?? settings.fontSize;
            }
          },
          onScaleUpdate: (details) {
            if (details.pointerCount < 2 || _pinchBaseFontSize == null) return;
            final next = (_pinchBaseFontSize! * details.scale).clamp(8.0, 32.0);
            if ((_liveFontSize ?? settings.fontSize) != next) {
              setState(() => _liveFontSize = next);
            }
          },
          onScaleEnd: (_) {
            final finalSize = _liveFontSize;
            _pinchBaseFontSize = null;
            if (finalSize != null) {
              final rounded = finalSize.roundToDouble().clamp(8.0, 32.0);
              setState(() => _liveFontSize = null);
              ref.read(settingsProvider.notifier).set(SettingKeys.fontSize, rounded);
            }
          },
          child: stack,
        );
        return Column(
          children: [
            Expanded(child: zoomed),
            if (_session.status == SessionStatus.connected)
              MobileTerminalKeyBar(
                ctrl: _touchCtrl,
                alt: _touchAlt,
                hapticsEnabled: ref.watch(settingsProvider).get(SettingKeys.mobileHaptics),
                onToggleCtrl: _toggleTouchCtrl,
                onLockCtrl: _lockTouchCtrl,
                onToggleAlt: _toggleTouchAlt,
                onLockAlt: _lockTouchAlt,
                onSendSequence: _sendTouchSequence,
                onPaste: () => unawaited(_paste()),
                onOpenComposer: _showComposer,
                onOpenSearch: () => setState(() => _searching = !_searching),
                onOpenSnippets: widget.onOpenSnippets,
                onOpenAiry: widget.onAskAgent == null ? null : () => widget.onAskAgent!(_recentVisibleExcerpt()),
                onGenerateDraft: _canGenerateMobileDraft() ? _generateMobileDraft : null,
                keyboardFocused: _focus.hasFocus,
                onToggleKeyboard: () {
                  if (_focus.hasFocus) {
                    _focus.unfocus();
                  } else {
                    _focus.requestFocus();
                  }
                  setState(() {});
                },
              ),
          ],
        );
      },
    );
  }

  String _recentVisibleExcerpt() {
    final buf = _session._terminal.buffer;
    final total = buf.lines.length;
    final start = max(0, total - 35);
    final lines = <String>[];
    for (var i = start; i < total; i++) {
      final text = buf.lines[i].getText().trimRight();
      if (text.isNotEmpty) lines.add(text);
    }
    return lines.join('\n');
  }

  bool _canGenerateMobileDraft() {
    final service = _aiService;
    if (service == null) return false;
    return service.canGenerate(_session.readAiContext());
  }

  Future<String?> _generateMobileDraft(String instruction) async {
    final service = _aiService;
    if (service == null) return null;
    final context = _session.readAiContext();
    if (!service.canGenerate(context)) return null;
    final cancel = CancellationToken();
    try {
      final result = await service.generate(context, instruction, cancel, history: _session.readAiHistory(context));
      if (result.kind == TerminalAiGenerationKind.command && result.command != null) {
        return result.command;
      }
      return null;
    } on Object {
      return null;
    }
  }

  /// Scrolls so buffer row [y] sits in the middle of the view.
  void _reveal(int y) {
    final view = _view.currentState;
    if (view == null || !_scroll.hasClients) return;
    final line = view.renderTerminal.lineHeight;
    final position = _scroll.position;
    final target = y * line - position.viewportDimension / 2 + line / 2;
    _scroll.jumpTo(target.clamp(position.minScrollExtent, position.maxScrollExtent));
  }

  String _message(AppLocalizations l, TerminalSession s) =>
      s.error == null ? l.disconnected : connectErrorText(l, s.error);
}

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
      widget.visible &&
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
      _session.reopenCommandCompletion();
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
    final key = event.logicalKey;
    if (!_popupAvailable(state)) {
      if (key == LogicalKeyboardKey.arrowUp || key == LogicalKeyboardKey.arrowDown) {
        _session.browseShellHistory();
      }
      return null;
    }
    if (key == LogicalKeyboardKey.escape) {
      _update(() {
        _dismissedCandidateRequest = state.request;
        _candidateMode = false;
      });
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown || key == LogicalKeyboardKey.arrowUp) {
      if (state.candidates.isEmpty) {
        _session.browseShellHistory();
        return null;
      }
      _update(() {
        _candidateIndex = (_candidateIndex + (key == LogicalKeyboardKey.arrowDown ? 1 : -1)) % state.candidates.length;
        _candidateText = state.candidates[_candidateIndex].identity;
        _candidateMode = true;
      });
      _scrollCandidateIntoView();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      if (_session.returnCommandBrowse()) return KeyEventResult.handled;
      _update(() => _dismissedCandidateRequest = state.request);
      return null;
    }
    if (key == LogicalKeyboardKey.arrowRight || key == LogicalKeyboardKey.tab) {
      if (_candidateMode && state.request != null && state.candidates.isNotEmpty) {
        final candidate = state.candidates[_candidateIndex.clamp(0, state.candidates.length - 1)];
        if (key == LogicalKeyboardKey.tab) {
          _session.acceptCommand(state.request!, candidate.text);
          return KeyEventResult.handled;
        }
        if (_session.browseCommand(state.request!, candidate)) return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowRight) {
        _update(() => _dismissedCandidateRequest = state.request);
        return null;
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

  void _cancelCandidateTranslations() {
    _candidateTranslationCancel?.cancel();
    _candidateTranslationCancel = null;
    _candidateTranslationOriginals = const {};
    _candidateTranslationLocale = null;
    _candidateTranslations = null;
  }

  void _scheduleCandidateTranslations() {
    if (_candidateTranslationsScheduled) return;
    _candidateTranslationsScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _candidateTranslationsScheduled = false;
      if (!mounted) return;
      final state = _session.commandAssistance.value;
      final locale = AppLocalizations.of(context).localeName.toLowerCase().replaceAll('_', '-').split('-').first;
      if (!_popupAvailable(state) ||
          locale != 'zh' ||
          !ref.read(settingsProvider).get(SettingKeys.completionTranslation) ||
          !_candidateScroll.hasClients) {
        _cancelCandidateTranslations();
        return;
      }
      final translations = _session._translations ?? ref.read<CompletionTranslations>(completionTranslationsProvider);
      final position = _candidateScroll.position;
      if (!position.hasContentDimensions || position.viewportDimension <= 0) {
        _cancelCandidateTranslations();
        return;
      }
      final rowHeight = max(CompletionSize.row, MediaQuery.textScalerOf(context).scale(13) + Space.lg);
      final first = (max(0, position.pixels) / rowHeight).floor().clamp(0, state.candidates.length);
      final end = ((position.pixels + position.viewportDimension) / rowHeight).ceil().clamp(
        first,
        state.candidates.length,
      );
      final originals = <String>{};
      for (var i = first; i < end; i++) {
        final candidate = state.candidates[i];
        final original = _session._translationSources[candidate];
        if (original != null) originals.add(original);
      }
      // Retain fulfilled rows in demand so cache notifications do not cancel their neighbors.
      if (identical(translations, _candidateTranslations) &&
          locale == _candidateTranslationLocale &&
          originals.length == _candidateTranslationOriginals.length &&
          originals.containsAll(_candidateTranslationOriginals)) {
        return;
      }
      _cancelCandidateTranslations();
      if (originals.isEmpty) return;
      _candidateTranslations = translations;
      _candidateTranslationOriginals = originals;
      _candidateTranslationLocale = locale;
      final cancel = _candidateTranslationCancel = CancellationToken();
      for (final original in originals) {
        if (translations.lookup(original, locale) == null) {
          unawaited(translations.translate(original, locale, cancel: cancel));
        }
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  Widget _completionOverlay() {
    final enabled = ref.watch(settingsProvider.select((settings) => settings.get(SettingKeys.completionTranslation)));
    final translations = _session._translations ?? ref.watch<CompletionTranslations>(completionTranslationsProvider);
    return ScrollGutterScope(child: _completionList(translations, enabled));
  }

  Widget _completionList(CompletionTranslations translations, bool enabled) => ListenableBuilder(
    listenable: Listenable.merge([_session.commandAssistance, _completionCursor, translations]),
    builder: (context, _) {
      final state = _session.commandAssistance.value;
      _syncCandidateSelection(state);
      _scheduleCandidateTranslations();
      if (!_popupAvailable(state)) return const SizedBox.shrink();
      final scheme = Theme.of(context).colorScheme;
      final l = AppLocalizations.of(context);
      final rowHeight = max(CompletionSize.row, MediaQuery.textScalerOf(context).scale(13) + Space.lg);
      final browse = state.browse;
      final locale = l.localeName.toLowerCase().replaceAll('_', '-').split('-').first;
      final gutter = ScrollGutterScope.gapOf(context);
      final rowEndPadding = gutter == 0 ? Space.sm : 0.0;
      String? originalDescription(CommandCandidate candidate) {
        final original = _session._translationSources[candidate] ?? candidate.detail;
        return original == null || original.trim().isEmpty ? null : original;
      }

      String? description(CommandCandidate candidate) {
        final original = originalDescription(candidate);
        if (original != null) {
          final trusted = _session._translationSources[candidate];
          return (trusted == null ? null : translations.lookup(trusted, locale)) ?? original;
        }
        final own = candidate.description?.text(l);
        if (own != null) return own;
        if (locale != 'zh' || candidate.source != CommandCandidateSource.builtin) return null;
        return switch (candidate.kind) {
          CommandKind.command => l.completionCommand,
          CommandKind.subcommand => l.completionSubcommand,
          CommandKind.option => l.completionOption,
          _ => l.completionArgument,
        };
      }

      bool pending(CommandCandidate candidate) {
        final original = _session._translationSources[candidate];
        return enabled &&
            locale == 'zh' &&
            original != null &&
            identical(translations, _candidateTranslations) &&
            locale == _candidateTranslationLocale &&
            _candidateTranslationOriginals.contains(original) &&
            translations.lookup(original, locale) == null &&
            translations.isPending(original, locale);
      }

      double textWidth(String text, TextStyle? style) {
        final painter = TextPainter(
          text: TextSpan(text: text, style: style),
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
          maxLines: 1,
        )..layout();
        final width = painter.width;
        painter.dispose();
        return width;
      }

      double widest(Iterable<String> texts, TextStyle? style) =>
          texts.fold(0.0, (width, text) => max(width, textWidth(text, style)));
      final titleWidth = min(
        CompletionSize.labelWidth,
        widest(state.candidates.map((c) => c.displayText ?? c.text), Theme.of(context).textTheme.bodyMedium),
      );
      final details = state.candidates.map(description).whereType<String>().toList();
      final detailWidth = min(
        CompletionSize.detailWidth,
        state.candidates.fold(0.0, (width, candidate) {
          final detail = description(candidate);
          return detail == null
              ? width
              : max(
                  width,
                  textWidth(detail, Theme.of(context).textTheme.bodySmall) + (pending(candidate) ? Space.xs + 12 : 0),
                );
        }),
      );
      final hasBranch = state.candidates.any((candidate) => candidate.preview != null);
      final width =
          (Space.sm +
                  rowEndPadding +
                  gutter +
                  14 +
                  Space.sm +
                  titleWidth +
                  (details.isEmpty ? 0 : Space.sm + detailWidth) +
                  (hasBranch ? Space.xs + 14 : 0))
              .clamp(CompletionSize.minWidth, CompletionSize.width)
              .toDouble();
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
              width,
              min(CompletionSize.maxHeight, headerHeight + rowHeight * max(1, state.candidates.length) + Space.sm),
            ),
          ),
          child: PopupSurface(
            key: const ValueKey('command-completion-popup'),
            padding: const EdgeInsets.symmetric(vertical: Space.xs),
            child: SizedBox(
              width: width,
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
                          final detail = description(candidate);
                          final loading = pending(candidate);
                          final original = originalDescription(candidate);
                          final explanation = detail != null && original != null && detail != original
                              ? '$detail\n$original'
                              : detail;
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
                              label: detail == null ? title : '$title, $detail',
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
                                    padding: EdgeInsetsDirectional.only(start: Space.sm, end: rowEndPadding),
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
                                        Expanded(
                                          child: LayoutBuilder(
                                            builder: (context, constraints) => Row(
                                              children: [
                                                ConstrainedBox(
                                                  constraints: BoxConstraints(
                                                    maxWidth: min(
                                                      titleWidth,
                                                      constraints.maxWidth * (detail == null ? 1 : .5),
                                                    ),
                                                  ),
                                                  child: Tooltip(
                                                    message: title,
                                                    child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
                                                  ),
                                                ),
                                                if (detail != null) ...[
                                                  const SizedBox(width: Space.sm),
                                                  Expanded(
                                                    child: Tooltip(
                                                      message: explanation!,
                                                      child: LayoutBuilder(
                                                        builder: (context, constraints) => Row(
                                                          children: [
                                                            Flexible(
                                                              child: Text(
                                                                detail,
                                                                maxLines: 1,
                                                                overflow: TextOverflow.ellipsis,
                                                                style: Theme.of(context).textTheme.bodySmall
                                                                    ?.copyWith(color: scheme.onSurfaceVariant),
                                                              ),
                                                            ),
                                                            if (loading && constraints.maxWidth >= Space.xs + 12) ...[
                                                              const SizedBox(width: Space.xs),
                                                              const SizedBox.square(
                                                                dimension: 12,
                                                                child: CircularProgressIndicator(strokeWidth: 1.5),
                                                              ),
                                                            ],
                                                          ],
                                                        ),
                                                      ),
                                                    ),
                                                  ),
                                                ],
                                              ],
                                            ),
                                          ),
                                        ),
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

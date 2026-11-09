part of 'terminal_session.dart';

class _BrowseFrame {
  const _BrowseFrame(this.draft);
  final String draft;
}

extension _CommandAssistance on TerminalSession {
  void _semanticPrompt(TerminalSemanticPromptState state) {
    _semanticSeen = true;
    _semanticInput = state.content == TerminalSemanticPromptContent.input;
    if (_semanticInput) {
      _promptRow = _terminal.buffer.absoluteCursorY;
      _promptColumn = _terminal.buffer.cursorX;
      _submittedLine = null;
      _submittedText = null;
    } else {
      _promptRow = _promptColumn = null;
    }
  }

  String _rowText(int row, int start, int end) {
    final line = _terminal.buffer.lines[row];
    final text = StringBuffer();
    for (var x = start; x < end; x++) {
      if (line.getWidth(x) == 0) continue;
      final code = line.getCodePoint(x);
      text.writeCharCode(code == 0 ? 32 : code);
      final combining = line.getCombiningCharacters(x);
      if (combining != null) text.write(combining);
    }
    return text.toString();
  }

  String? _echoedCommand() {
    if (!canInsert || _inputPending || _terminal.isUsingAltBuffer) return null;
    final buffer = _terminal.buffer;
    final row = buffer.absoluteCursorY, column = buffer.cursorX;
    if (row < 0 || row >= buffer.lines.length) return null;
    final line = buffer.lines[row];
    if (identical(line, _submittedLine)) return null;
    if (line.isWrapped || (row + 1 < buffer.lines.length && buffer.lines[row + 1].isWrapped)) return null;
    final tail = _rowText(row, column, line.length);
    if (tail.trim().isNotEmpty) return null;
    if (_semanticSeen) {
      if (!_semanticInput || row != _promptRow || column < (_promptColumn ?? 0)) return null;
      final text = _rowText(row, _promptColumn!, column);
      return commandIsSingleLine(text) ? text : null;
    }
    return visibleShellCommand(_rowText(row, 0, column), tail);
  }

  bool _requestCurrent(CommandCompletionRequest request) =>
      !_closed &&
      canInsert &&
      request.generation == _shellGeneration &&
      request.revision == _draftRevision &&
      identical(_assistance.value.request, request);

  void _cancelCompletion() {
    _completionTimer?.cancel();
    _completionCancel?.cancel();
    _completionCancel = null;
    _browseStack.clear();
  }

  void _syncCommandDraft() {
    if (_closed) return;
    final text = _echoedCommand();
    final previous = _assistance.value.request;
    if (previous?.text == text && previous?.generation == _shellGeneration) return;
    _cancelCompletion();
    final revision = ++_draftRevision;
    if (text == null) {
      _assistance.value = const CommandAssistanceState();
      return;
    }
    final request = CommandCompletionRequest(
      text: text,
      generation: _shellGeneration,
      revision: revision,
      directory: _directory.value,
    );
    _assistance.value = CommandAssistanceState(request: request);
    if (text.trim().isEmpty || _historyBrowsing) return;
    _completionTimer = Timer(const Duration(milliseconds: 180), () => _complete(request));
  }

  Future<void> _complete(CommandCompletionRequest request) async {
    _completionCancel?.cancel();
    final cancel = CancellationToken();
    _completionCancel = cancel;
    final draft = _browseStack.isEmpty ? request.text : _browseStack.last.draft;
    final depth = _browseStack.length;
    bool current() => !cancel.isCancelled && _requestCurrent(request);
    final local = <CommandCandidate>[
      if (depth == 0) ...localCommandCandidates(request.text, _commands, catalog: false),
    ];
    var supplied = <CommandCandidate>[];
    CommandBrowseState? browse = depth == 0 ? null : CommandBrowseState(label: draft, depth: depth);
    var loading = true;
    void publish() {
      if (!current()) return;
      _assistance.value = CommandAssistanceState(
        request: request,
        candidates: mergeCommandCandidates(request.text, local, supplied),
        browse: browse,
        loading: loading,
      );
    }

    publish();
    Future<void> optionalProvider() async {
      final provider = completionProvider;
      if (provider == null || depth != 0) return;
      final providerCancel = CancellationToken();
      unawaited(cancel.whenCancelled.then((_) => providerCancel.cancel()));
      try {
        supplied = await provider.complete(request, providerCancel).timeout(const Duration(seconds: 5));
        publish();
      } on Object {
        // Optional sources cannot change shell input or remove built-in results.
      } finally {
        providerCancel.cancel();
      }
    }

    final extra = optionalProvider();
    try {
      final context = CompletionContext.parse(draft);
      if (!context.supported) return;
      if (context.words.isEmpty && context.current.start == 0) {
        final names = await _completionSpecs.commandNames();
        if (!current()) return;
        final prefix = context.current.value;
        for (final name in names) {
          if (!name.startsWith(prefix) || name == prefix) continue;
          final text =
              '$draft${encodeShellSuffix(name.substring(prefix.length), context.quote, atWordStart: prefix.isEmpty, close: true)} ';
          final metadata = completionCommandMetadata(name);
          final candidate = CommandCandidate(
            text,
            source: CommandCandidateSource.builtin,
            kind: CommandKind.command,
            displayText: name,
            detail: metadata?.description,
            preview: metadata?.canBrowse == true ? text : null,
          );
          if (metadata?.description case final original?) _translationSources[candidate] = original;
          local.add(candidate);
        }
        if (names.isEmpty) {
          local.addAll(localCommandCandidates(draft, CommandHistory()));
        }
      } else {
        final completed = await _completionSpecs.complete(draft);
        if (!current()) return;
        final result = completed.result;
        for (final item in result.suggestions) {
          if (item.isAppendOnly) local.add(_specCandidate(draft, item));
        }
        if (!completed.available && result.suggestions.isEmpty) {
          local.addAll(localCommandCandidates(draft, CommandHistory()));
        }
        final path = result.path;
        if (path != null) {
          browse = CommandBrowseState(
            label: path.directory.isEmpty ? '.' : path.directory,
            depth: depth,
            load: CompletionLoad.loading,
          );
          publish();
          final source = remotePaths ?? _ownedPaths;
          var typedDirectory = path.directory;
          final rawPath = draft.substring(path.valueStart);
          // Quoted/escaped tildes, and option values after '=', name a literal directory.
          if (typedDirectory.startsWith('~') && (path.tokenPrefix.isNotEmpty || !rawPath.startsWith('~'))) {
            typedDirectory = './$typedDirectory';
          }
          String? cwd = request.directory ?? _directory.value;
          if (RemotePaths.absolute(typedDirectory, cwd: cwd) == null) {
            cwd = await _look(force: true);
          }
          if (!current()) return;
          final directory = RemotePaths.absolute(typedDirectory, cwd: cwd);
          if (source == null || directory == null) {
            browse = CommandBrowseState(
              label: path.directory.isEmpty ? '.' : path.directory,
              depth: depth,
              load: CompletionLoad.unavailable,
            );
          } else {
            try {
              final listing = await source.browse(
                RemotePathQuery(directory: directory, prefix: path.namePrefix, foldersOnly: path.foldersOnly),
                cancel: cancel,
              );
              if (!current()) return;
              final suggestions = path.resolve([
                for (final entry in listing.entries) CompletionPathEntry(entry.name, isDirectory: entry.enterable),
              ]);
              for (final item in suggestions) {
                if (item.isAppendOnly) local.add(_specCandidate(draft, item, path: true));
              }
              browse = CommandBrowseState(
                label: path.directory.isEmpty ? (cwd ?? '.') : path.directory,
                depth: depth,
                truncated: listing.truncated || result.truncated,
              );
            } on RemotePathException catch (e) {
              if (!current()) return;
              browse = CommandBrowseState(
                label: path.directory.isEmpty ? '.' : path.directory,
                depth: depth,
                load: e.kind == RemotePathFailure.unavailable ? CompletionLoad.unavailable : CompletionLoad.failed,
              );
            }
          }
        }
      }
      if (depth == 0) {
        for (final snippet in _snippets()) {
          if (snippet.text.startsWith(request.text) && commandIsSingleLine(snippet.text)) {
            local.add(CommandCandidate(snippet.text, source: CommandCandidateSource.snippet, detail: snippet.label));
          }
        }
      }
    } on Object {
      if (current()) local.addAll(localCommandCandidates(draft, CommandHistory()));
    } finally {
      loading = false;
      publish();
      await extra;
      if (identical(_completionCancel, cancel)) _completionCancel = null;
    }
  }

  CommandCandidate _specCandidate(String draft, SpecSuggestion item, {bool path = false}) {
    final replacement = item.applyTo(draft);
    final text = item.appendSpace ? '$replacement ' : replacement;
    final directory = item.kind == SpecSuggestionKind.folder;
    final branch = !directory && item.canBrowse;
    final candidate = CommandCandidate(
      text,
      source: path ? CommandCandidateSource.path : CommandCandidateSource.builtin,
      kind: switch (item.kind) {
        SpecSuggestionKind.command => CommandKind.command,
        SpecSuggestionKind.subcommand => CommandKind.subcommand,
        SpecSuggestionKind.option => CommandKind.option,
        _ => CommandKind.argument,
      },
      displayText: item.display,
      detail: item.description,
      directory: directory ? item.value : null,
      preview: directory || branch ? (branch && !text.endsWith(' ') ? '$text ' : text) : null,
    );
    if (!path && item.description != null) _translationSources[candidate] = item.description!;
    return candidate;
  }

  bool _browseCommand(CommandCompletionRequest request, CommandCandidate candidate) {
    final draft = candidate.preview;
    if (!_requestCurrent(request) ||
        draft == null ||
        !draft.startsWith(request.text) ||
        !commandIsSingleLine(draft) ||
        _browseStack.length >= 32 ||
        (_browseStack.isNotEmpty && draft == _browseStack.last.draft)) {
      return false;
    }
    _browseStack.add(_BrowseFrame(draft));
    unawaited(_complete(request));
    return true;
  }

  bool _returnCommandBrowse() {
    final request = _assistance.value.request;
    if (request == null || !_requestCurrent(request) || _browseStack.isEmpty) return false;
    _browseStack.removeLast();
    unawaited(_complete(request));
    return true;
  }

  void _rememberCommand(String text) {
    _commands.remember(text);
    _history.value = _commands.commands;
  }

  void _invalidateCommandDraft() {
    _cancelCompletion();
    _draftRevision++;
    _assistance.value = const CommandAssistanceState();
  }

  void _markCommandSubmitted() {
    final buffer = _terminal.buffer;
    final row = buffer.absoluteCursorY;
    _submittedLine = row >= 0 && row < buffer.lines.length ? buffer.lines[row] : null;
    _submittedText = _submittedLine == null ? null : _rowText(row, 0, buffer.cursorX);
  }

  void _submitCommand() {
    _historyBrowsing = false;
    final text = _echoedCommand();
    if (text != null) _rememberCommand(text);
    _markCommandSubmitted();
    _semanticInput = false;
    _invalidateCommandDraft();
  }

  void _resetCommandDraft() {
    _shellGeneration++;
    _semanticSeen = _semanticInput = false;
    _promptRow = _promptColumn = null;
    _submittedLine = null;
    _submittedText = null;
    _inputPending = _historyBrowsing = false;
    _ownedPaths?.dispose();
    _ownedPaths = null;
    _reported = null;
    _directoryRevision++;
    _directoryLookup = null;
    _directory.value = null;
    _invalidateCommandDraft();
  }

  Future<InsertResult> _acceptCommand(CommandCompletionRequest request, String text) async {
    if (!canInsert) return InsertResult.unavailable;
    if (!commandIsSingleLine(text) || !text.startsWith(request.text)) return InsertResult.rejected;
    if (request.generation != _shellGeneration ||
        request.revision != _draftRevision ||
        _echoedCommand() != request.text) {
      return InsertResult.stale;
    }
    final suffix = text.substring(request.text.length);
    if (suffix.isEmpty) return InsertResult.sent;
    _terminal.paste(suffix);
    _invalidateCommandDraft();
    return InsertResult.sent;
  }
}

part of 'terminal_session.dart';

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

  void _syncCommandDraft() {
    if (_closed) return;
    final text = _echoedCommand();
    final previous = _assistance.value.request;
    if (previous?.text == text && previous?.generation == _shellGeneration) return;
    _completionTimer?.cancel();
    _completionCancel?.cancel();
    _completionCancel = null;
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
    if (text.trim().isEmpty) return;
    _completionTimer = Timer(const Duration(milliseconds: 180), () => _complete(request));
  }

  Future<void> _complete(CommandCompletionRequest request) async {
    final cancel = CancellationToken();
    _completionCancel = cancel;
    final local = localCommandCandidates(request.text, _commands);
    bool current() => !_closed && !cancel.isCancelled && identical(_assistance.value.request, request) && canInsert;
    if (!current()) return;
    _assistance.value = CommandAssistanceState(request: request, candidates: local);
    final provider = _completionProvider;
    if (provider == null) return;
    try {
      final supplied = await provider.complete(request, cancel).timeout(const Duration(seconds: 5));
      if (!current()) return;
      final candidates = mergeCommandCandidates(request.text, local, supplied);
      _assistance.value = CommandAssistanceState(request: request, candidates: List.unmodifiable(candidates));
    } on Object {
      // A failed optional provider never changes normal terminal input.
    } finally {
      if (identical(_completionCancel, cancel)) _completionCancel = null;
    }
  }

  void _rememberCommand(String text) {
    _commands.remember(text);
    _history.value = _commands.commands;
  }

  void _invalidateCommandDraft() {
    _completionTimer?.cancel();
    _completionCancel?.cancel();
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
    final text = _echoedCommand();
    if (text != null) _rememberCommand(text);
    _markCommandSubmitted();
    _semanticInput = false;
    _completionTimer?.cancel();
    _completionCancel?.cancel();
    _draftRevision++;
    _assistance.value = const CommandAssistanceState();
  }

  void _resetCommandDraft() {
    _shellGeneration++;
    _draftRevision++;
    _semanticSeen = _semanticInput = false;
    _promptRow = _promptColumn = null;
    _submittedLine = null;
    _submittedText = null;
    _inputPending = false;
    _completionTimer?.cancel();
    _completionCancel?.cancel();
    _assistance.value = const CommandAssistanceState();
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
    // No erase-line control sequence or newline: only append to a verified echoed prefix.
    _terminal.paste(suffix);
    _completionTimer?.cancel();
    _completionCancel?.cancel();
    _draftRevision++;
    _assistance.value = const CommandAssistanceState();
    return InsertResult.sent;
  }
}

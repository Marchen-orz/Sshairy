part of 'terminal_session.dart';

/// Track destructive screen changes even when a TUI enters and leaves within one output chunk.
class _HistoryTerminal extends Terminal {
  _HistoryTerminal({required super.maxLines});
  var resultMutation = 0;

  @override
  void useAltBuffer() {
    resultMutation++;
    super.useAltBuffer();
  }

  @override
  void reset() {
    resultMutation++;
    super.reset();
  }

  @override
  void softReset() {
    resultMutation++;
    super.softReset();
  }

  @override
  void resize(int width, int height, [int? pixelWidth, int? pixelHeight]) {
    if (width != viewWidth || height != viewHeight) resultMutation++;
    super.resize(width, height, pixelWidth, pixelHeight);
  }

  @override
  void setCursor(int x, int y) {
    resultMutation++;
    super.setCursor(x, y);
  }

  @override
  void setCursorY(int y) {
    resultMutation++;
    super.setCursorY(y);
  }

  @override
  void moveCursorY(int amount) {
    resultMutation++;
    super.moveCursorY(amount);
  }

  @override
  void cursorNextLine(int amount) {
    resultMutation++;
    super.cursorNextLine(amount);
  }

  @override
  void cursorPrecedingLine(int amount) {
    resultMutation++;
    super.cursorPrecedingLine(amount);
  }

  @override
  void scrollUp(int amount) {
    resultMutation++;
    super.scrollUp(amount);
  }

  @override
  void scrollDown(int amount) {
    resultMutation++;
    super.scrollDown(amount);
  }

  @override
  void setMargins(int top, [int? bottom]) {
    resultMutation++;
    super.setMargins(top, bottom);
  }

  @override
  void setLeftRightMargins(int left, [int? right]) {
    resultMutation++;
    super.setLeftRightMargins(left, right);
  }

  @override
  void eraseScrollbackOnly() {
    resultMutation++;
    super.eraseScrollbackOnly();
  }

  @override
  void restoreCursor() {
    resultMutation++;
    super.restoreCursor();
  }

  @override
  void reverseIndex() {
    resultMutation++;
    super.reverseIndex();
  }

  @override
  void eraseDisplayBelow() {
    resultMutation++;
    super.eraseDisplayBelow();
  }

  @override
  void eraseDisplayAbove() {
    resultMutation++;
    super.eraseDisplayAbove();
  }

  @override
  void eraseDisplay() {
    resultMutation++;
    super.eraseDisplay();
  }

  @override
  void insertLines(int amount) {
    resultMutation++;
    super.insertLines(amount);
  }

  @override
  void deleteLines(int amount) {
    resultMutation++;
    super.deleteLines(amount);
  }
}

class _PendingCommandResult {
  _PendingCommandResult(this.entry, this.submitted, this.prefix, this.mutation, this.screenGeneration);
  final TerminalAiHistoryEntry entry;
  final CellAnchor submitted;
  final String prefix;
  final int mutation, screenGeneration;
  CellAnchor? start;
  TerminalAiHistoryBoundary? boundary;
  bool sensitive = false;
  String secretTail = '';

  /// Completes with the finished record, or null when the boundary was lost or the record was dropped.
  final done = Completer<TerminalAiHistoryEntry?>();

  void dispose([TerminalAiHistoryEntry? result]) {
    submitted.dispose();
    start?.dispose();
    if (!done.isCompleted) done.complete(result);
  }
}

extension _TerminalHistoryResults on TerminalSession {
  void _discardPendingCommandResult() {
    final pending = _pendingCommandResult;
    if (pending == null) return;
    if (pending.sensitive) {
      final count = _aiHistory.length;
      _aiHistory.removeWhere((entry) => identical(entry, pending.entry));
      if (_aiHistory.length != count) _historyRevision++;
    }
    pending.dispose();
    _pendingCommandResult = null;
  }

  void _clearAiHistory() {
    _discardPendingCommandResult();
    _aiHistory.clear();
    _historyRevision++;
  }

  void _beginCommandResult(TerminalAiHistoryEntry entry) {
    _discardPendingCommandResult();
    if (pendingOutputBytes != 0 || _echoedCommand() != entry.text || _terminal.isUsingAltBuffer) return;
    final buffer = _terminal.mainBuffer;
    _pendingCommandResult = _PendingCommandResult(
      entry,
      buffer.createAnchorFromCursor(),
      _logicalLinePrefix(buffer.absoluteCursorY, buffer.cursorX),
      _terminal.resultMutation,
      buffer.screenClearGeneration,
    );
  }

  void _scanCommandResult(String data) {
    final pending = _pendingCommandResult;
    if (pending == null) return;
    final text = '${pending.secretTail}$data';
    pending.sensitive |= terminalAiSensitiveText(text);
    pending.secretTail = text.substring(max(0, text.length - 128));
  }

  bool _resultBoundaryCurrent(_PendingCommandResult pending) {
    final buffer = _terminal.mainBuffer;
    return pending.entry.generation == _shellGeneration &&
        !_terminal.isUsingAltBuffer &&
        pending.mutation == _terminal.resultMutation &&
        pending.screenGeneration == buffer.screenClearGeneration &&
        buffer.ownsAnchor(pending.submitted) &&
        _logicalLinePrefix(pending.submitted.y, pending.submitted.x) == pending.prefix;
  }

  void _historyOsc(String code, List<String> arguments) {
    if (code != '133' && code != '633' || arguments.isEmpty) return;
    final pending = _pendingCommandResult;
    if (pending == null) return;
    if (!_resultBoundaryCurrent(pending)) {
      _discardPendingCommandResult();
      return;
    }
    final boundary = code == '133' ? TerminalAiHistoryBoundary.osc133 : TerminalAiHistoryBoundary.osc633;
    switch (arguments.first) {
      case 'C':
        if (pending.start != null) {
          _discardPendingCommandResult();
          return;
        }
        pending.start = _terminal.mainBuffer.createAnchorFromCursor();
        pending.boundary = boundary;
        break;
      case 'D':
        if (pending.start == null || pending.boundary != boundary) {
          _discardPendingCommandResult();
          return;
        }
        final exitCode = arguments.length > 1 && RegExp(r'^-?\d{1,10}$').hasMatch(arguments[1])
            ? int.tryParse(arguments[1])
            : null;
        _finishCommandResult(_terminal.mainBuffer.absoluteCursorY, _terminal.mainBuffer.cursorX, exitCode: exitCode);
        break;
      case 'A' || 'B' || 'N':
        // A new semantic prompt without a matched execution end cannot prove an output range.
        _discardPendingCommandResult();
    }
  }

  void _finishRecognizedCommandResult() {
    final pending = _pendingCommandResult;
    if (pending == null || pending.start != null) return;
    if (!_resultBoundaryCurrent(pending)) {
      _discardPendingCommandResult();
      return;
    }
    if (_semanticSeen || _echoedCommand() != '') return;
    final buffer = _terminal.mainBuffer;
    if (buffer.absoluteCursorY <= pending.submitted.y) return;
    if (pending.prefix.length < pending.entry.text.length ||
        _rowText(buffer.absoluteCursorY, 0, buffer.cursorX) !=
            pending.prefix.substring(0, pending.prefix.length - pending.entry.text.length)) {
      _discardPendingCommandResult();
      return;
    }
    pending.start = buffer.createAnchor(pending.submitted.x, pending.submitted.y);
    pending.boundary = TerminalAiHistoryBoundary.prompt;
    _finishCommandResult(buffer.absoluteCursorY, 0);
  }

  void _finishCommandResult(int endRow, int endColumn, {int? exitCode}) {
    final pending = _pendingCommandResult;
    if (pending == null) return;
    final start = pending.start, buffer = _terminal.mainBuffer;
    if (!_resultBoundaryCurrent(pending) ||
        start == null ||
        !buffer.ownsAnchor(start) ||
        endRow < start.y ||
        endRow == start.y && endColumn < start.x) {
      _discardPendingCommandResult();
      return;
    }
    final index = _aiHistory.indexWhere((entry) => identical(entry, pending.entry));
    if (index < 0) {
      _discardPendingCommandResult();
      return;
    }
    if (pending.sensitive) {
      _aiHistory.removeAt(index);
      _historyRevision++;
      _discardPendingCommandResult();
      return;
    }
    final text = StringBuffer();
    var bytes = 0, truncated = false;
    final firstRow = start.y + (pending.boundary == TerminalAiHistoryBoundary.prompt ? 1 : 0);
    rows:
    for (var row = firstRow; row <= endRow; row++) {
      if (row - firstRow == 200) {
        truncated = true;
        break;
      }
      final line = buffer.lines[row];
      final from = row == start.y ? start.x : 0;
      var to = row == endRow ? endColumn : line.length;
      while (to > from && (line.getCodePoint(to - 1) == 0 || line.getCodePoint(to - 1) == 32)) {
        to--;
      }
      if (row > firstRow) {
        if (bytes == 4096) {
          truncated = true;
          break;
        }
        text.write('\n');
        bytes++;
      }
      for (var column = from; column < to; column++) {
        if (line.getWidth(column) == 0) continue;
        final code = line.getCodePoint(column);
        final value = '${String.fromCharCode(code == 0 ? 32 : code)}${line.getCombiningCharacters(column) ?? ''}';
        final size = utf8.encode(value).length;
        if (bytes + size > 4096) {
          truncated = true;
          break rows;
        }
        text.write(value);
        bytes += size;
      }
    }
    final result = _aiHistory[index] = pending.entry.withResult(
      status: truncated ? TerminalAiHistoryResultStatus.truncated : TerminalAiHistoryResultStatus.available,
      output: text.toString(),
      exitCode: exitCode,
      boundary: pending.boundary,
    );
    pending.done.complete(result);
    final bounded = boundedTerminalAiHistory(_aiHistory);
    _aiHistory
      ..clear()
      ..addAll(bounded);
    _historyRevision++;
    _discardPendingCommandResult();
  }
}

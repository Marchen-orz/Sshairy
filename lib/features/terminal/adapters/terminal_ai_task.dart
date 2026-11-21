part of 'terminal_session.dart';

/// One inline AI task in this terminal. Its only action is a command line at this terminal's prompt.
class _AiTask {
  _AiTask(this.instruction, this.maxSteps, AiTextStyle style)
    : sgr = switch (style) {
        AiTextStyle.italicFaint => '\x1b[2;3m',
        AiTextStyle.italic => '\x1b[3m',
        AiTextStyle.faint => '\x1b[2m',
        AiTextStyle.plain => '',
      };
  final String instruction;
  final int maxSteps;

  /// Set before our text so it reads apart from shell output; SGR survives the line breaks until the reset.
  final String sgr;
  final cancel = CancellationToken();
  final executed = <String>[];
  StreamSubscription<void>? changes;
  Completer<void>? _wake;
  _PendingCommandResult? pending;
  var auto = false, thinking = false, awaiting = false, submitted = false;

  /// Our ✦ text holds the cursor on a line the shell does not know about, since input sequence [printedAt].
  var lineOpen = false, printedAt = 0;

  Future<void> sleep() => (_wake = Completer<void>()).future;

  void wake() {
    final wake = _wake;
    _wake = null;
    if (wake != null && !wake.isCompleted) wake.complete();
  }

  /// Called for every submitted line; only the one after this task filled its command counts.
  void submit(_PendingCommandResult? result) {
    if (!awaiting) return;
    awaiting = false;
    submitted = true;
    pending = result;
    wake();
  }
}

final _aiTaskUnsafe = RegExp(r'[\x00-\x09\x0b-\x1f\x7f-\x9f\u061c\u200e\u200f\u2028-\u202e\u2066-\u2069]');

extension _TerminalAiTask on TerminalSession {
  /// [restore] gives the shell back a fresh prompt when our ✦ text still holds its line.
  void _stopAiTask({bool restore = false}) {
    final task = _aiTask;
    if (task == null) return;
    _aiTask = null;
    task.cancel.cancel();
    unawaited(task.changes?.cancel());
    task.wake();
    if (_closed) return;
    if (restore) _aiReturnLine(task);
    _aiTaskChanged();
  }

  void _setAiTaskAuto(bool value) {
    final task = _aiTask;
    if (task == null || task.auto == value) return;
    task.auto = value;
    task.wake();
    _aiTaskChanged();
  }

  void _setAiTaskThinking(_AiTask task, bool value) {
    task.thinking = value;
    if (identical(_aiTask, task) && !_closed) _aiTaskChanged();
  }

  /// Local-only text between commands: never sent to the shell and outside every command's result interval.
  void _aiPrint(_AiTask task, String text) {
    final clean = text.replaceAll(_aiTaskUnsafe, '').trim();
    if (clean.isEmpty) return;
    final bounded = String.fromCharCodes(clean.runes.take(1024)).replaceAll('\n', '\r\n  ');
    final data = '${task.lineOpen ? '\r\n' : '\r\x1b[K'}\x1b[35m✦\x1b[0m ${task.sgr}$bounded\x1b[0m';
    if (!task.lineOpen) task.printedAt = _inputSequence;
    task.lineOpen = true;
    _terminal.write(data);
    if (_mirrorOut.hasListener) _mirrorOut.add(Uint8List.fromList(utf8.encode(data)));
  }

  Future<bool> _aiUntil(_AiTask task, bool Function() done, Duration timeout) async {
    final end = DateTime.now().add(timeout);
    while (!done()) {
      if (!identical(_aiTask, task) || DateTime.now().isAfter(end)) return false;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    return identical(_aiTask, task);
  }

  /// Hands the line back to the shell with an empty Enter; never when the user has typed since, as it would submit that.
  bool _aiReturnLine(_AiTask task) {
    if (!task.lineOpen) return true;
    if (_inputSequence != task.printedAt || _terminal.onOutput == null) return false;
    task.lineOpen = false;
    _semanticInput = false;
    _markCommandSubmitted();
    _terminal.onOutput!('\r');
    return true;
  }

  /// Waits for the shell's fresh empty prompt.
  Future<TerminalAiContext?> _aiPrompt(_AiTask task) async {
    if (!_aiReturnLine(task)) return null;
    TerminalAiContext? prompt;
    await _aiUntil(task, () {
      final current = readAiContext();
      if (current.ready && current.draft!.isEmpty) prompt = current;
      return prompt != null;
    }, const Duration(seconds: 5));
    return identical(_aiTask, task) ? prompt : null;
  }

  /// Fills [command] and returns its finished record once the user, or auto mode on an exact echo, submits it.
  Future<TerminalAiHistoryEntry?> _aiRun(_AiTask task, TerminalAiContext prompt, String command) async {
    final filled = await acceptAiDraft(prompt, command, cancel: task.cancel, isCurrent: () => identical(_aiTask, task));
    if (filled != InsertResult.sent || !identical(_aiTask, task)) return null;
    task
      ..pending = null
      ..submitted = false
      ..awaiting = true;
    while (identical(_aiTask, task) && !task.submitted) {
      final echoed =
          task.auto &&
          await _aiUntil(
            task,
            () => task.submitted || pendingOutputBytes == 0 && _echoedCommand() == command,
            const Duration(seconds: 2),
          );
      if (echoed && !task.submitted && task.auto) {
        _submitCommand();
        _terminal.onOutput?.call('\r');
      } else if (!task.submitted && identical(_aiTask, task)) {
        await task.sleep();
      }
    }
    task.awaiting = false;
    final pending = task.pending;
    if (!identical(_aiTask, task) || pending == null) return null;
    return Future.any([pending.done.future, task.cancel.whenCancelled.then<TerminalAiHistoryEntry?>((_) => null)]);
  }

  Future<void> _startAiTask(
    TerminalAiService service,
    String instruction,
    String Function(TerminalAiFailure) describe, {
    int maxSteps = 12,
    AiTextStyle style = AiTextStyle.italicFaint,
  }) async {
    var context = readAiContext();
    if (_aiTask != null || instruction.trim().isEmpty || !service.canGenerate(context)) return;
    final task = _aiTask = _AiTask(instruction.trim(), maxSteps, style);
    task.changes = service.changes.listen((_) {
      if (identical(_aiTask, task)) _stopAiTask();
    });
    _aiTaskChanged();
    try {
      if (context.draft!.isNotEmpty) {
        final erased = await _eraseAiDraft(context, task.cancel, () => identical(_aiTask, task));
        if (erased != InsertResult.sent || !identical(_aiTask, task)) return;
        context = readAiContext();
      }
      var heading = task.instruction;
      while (identical(_aiTask, task) && context.ready && context.draft!.isEmpty) {
        final sequence = _inputSequence, history = readAiHistory(context);
        _aiPrint(task, heading);
        _setAiTaskThinking(task, true);
        TerminalAiGeneration step;
        try {
          step = await service.generate(
            context,
            task.instruction,
            task.cancel,
            history: history,
            steps: List.unmodifiable(task.executed),
            stepsLeft: task.maxSteps - task.executed.length,
          );
        } on TerminalAiFailure catch (failure) {
          if (failure.reason == TerminalAiFailureReason.cancelled) return;
          step = TerminalAiGeneration(TerminalAiGenerationKind.done, message: describe(failure));
        } finally {
          _setAiTaskThinking(task, false);
        }
        // A `cd` result may still be resolving the directory; reconnects stop the task in _resetCommandDraft.
        if (!identical(_aiTask, task) || _inputSequence != sequence) return;
        _aiPrint(task, step.message ?? '');
        final command = step.kind == TerminalAiGenerationKind.command && task.executed.length < task.maxSteps
            ? step.command
            : null;
        final prompt = await _aiPrompt(task);
        if (command == null || prompt == null || !validTerminalAiCommand(command)) return;
        final entry = await _aiRun(task, prompt, command);
        if (entry == null) return;
        task.executed.add(entry.text);
        final next = await _aiPrompt(task);
        if (next == null) return;
        context = next;
        heading = '';
      }
    } finally {
      if (identical(_aiTask, task)) _stopAiTask();
    }
  }
}

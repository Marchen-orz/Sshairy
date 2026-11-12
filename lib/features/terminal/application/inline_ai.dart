import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../foundation/cancellation.dart';
import '../domain/ai_terminal.dart';

/// A session owns one inline request; showing or hiding its editor does not own the request.
class InlineAiController extends ChangeNotifier {
  InlineAiController({required this.readContext, required this.readHistory});

  final TerminalAiContext Function() readContext;
  final List<TerminalAiHistoryEntry> Function(TerminalAiContext) readHistory;
  TerminalAiService? _service;
  StreamSubscription<void>? _changes;
  CancellationToken? _cancel;
  bool _closed = false, _invalidated = false;
  TerminalAiContext? context;
  String instruction = '', command = '';
  TerminalAiGeneration? result;
  TerminalAiFailure? failure;

  bool get busy => _cancel != null;
  bool get stale => _invalidated;

  void bind(TerminalAiService service) {
    if (identical(service, _service)) return;
    _changes?.cancel();
    clear();
    _service = service;
    _changes = service.changes.listen((_) => clear());
  }

  void open() {
    synchronize();
    final current = readContext(), previous = context;
    if (previous != null && !_invalidated && sameTerminalAiContext(previous, current)) return;
    final keepPreview =
        previous != null &&
        result?.kind == TerminalAiGenerationKind.command &&
        current.ready &&
        current.draft!.isEmpty &&
        sameTerminalAiContext(previous, current, draft: false);
    if (!keepPreview) {
      stop();
      instruction = current.draft ?? '';
    }
    context = current;
    _invalidated = false;
    notifyListeners();
  }

  /// Called by the session on input and environment changes, including while no pane is mounted.
  void synchronize() {
    if (_closed || context == null) return;
    final current = readContext();
    if (!_invalidated && sameTerminalAiContext(context!, current)) return;
    final changed = !_invalidated;
    _cancel?.cancel();
    _cancel = null;
    _invalidated = true;
    failure = null;
    // Keep a completed preview only so the user can clear the original line before accepting it.
    final discard =
        result != null &&
        (!sameTerminalAiEnvironment(context!, current) ||
            context!.historyRevision != current.historyRevision ||
            current.draft != null && current.draft!.isNotEmpty && current.draft != context!.draft);
    if (discard) {
      result = null;
      command = '';
    }
    if (changed || discard) notifyListeners();
  }

  void editInstruction(String value) {
    if (value == instruction) return;
    stop();
    instruction = value;
    notifyListeners();
  }

  Future<void> generate() async {
    synchronize();
    final captured = context, service = _service;
    if (_closed || busy || _invalidated || captured == null || service == null || instruction.trim().isEmpty) return;
    if (!service.canGenerate(captured)) return;
    final token = _cancel = CancellationToken();
    result = null;
    command = '';
    failure = null;
    notifyListeners();
    try {
      final generated = await service.generate(captured, instruction.trim(), token, history: readHistory(captured));
      synchronize();
      if (_closed || token.isCancelled || !identical(_cancel, token)) return;
      if (generated.kind == TerminalAiGenerationKind.command && !validTerminalAiCommand(generated.command ?? '')) {
        throw const TerminalAiFailure(TerminalAiFailureReason.invalid);
      }
      result = generated;
      command = generated.command ?? '';
    } on Object catch (error) {
      if (!_closed && !token.isCancelled && identical(_cancel, token)) {
        failure = error is TerminalAiFailure ? error : const TerminalAiFailure(TerminalAiFailureReason.invalid);
      }
    } finally {
      if (!_closed && identical(_cancel, token)) {
        _cancel = null;
        notifyListeners();
      }
    }
  }

  void stop() {
    _cancel?.cancel();
    _cancel = null;
    result = null;
    command = '';
    failure = null;
    if (!_closed) notifyListeners();
  }

  void clear() {
    context = null;
    instruction = '';
    _invalidated = true;
    stop();
  }

  @override
  void dispose() {
    _closed = true;
    clear();
    _changes?.cancel();
    _service = null;
    super.dispose();
  }
}

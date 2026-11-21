import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../foundation/cancellation.dart';
import '../domain/ai_terminal.dart';

final terminalAiServiceProvider = Provider<TerminalAiService>((_) => const _DisabledTerminalAi());

class _DisabledTerminalAi implements TerminalAiService {
  const _DisabledTerminalAi();
  @override
  bool canGenerate(TerminalAiContext context) => false;
  @override
  bool canComplete(TerminalAiContext context) => false;
  @override
  Stream<void> get changes => const Stream.empty();
  @override
  Future<TerminalAiGeneration> generate(
    TerminalAiContext context,
    String instruction,
    CancellationToken cancel, {
    List<TerminalAiHistoryEntry> history = const [],
    List<String> steps = const [],
    int stepsLeft = 12,
  }) async => const TerminalAiGeneration(TerminalAiGenerationKind.done);
  @override
  Future<String?> complete(
    TerminalAiContext context,
    List<TerminalAiHistoryEntry> history,
    CancellationToken cancel, {
    void Function()? onStarted,
    void Function(Duration)? onDeferred,
  }) async => null;
}

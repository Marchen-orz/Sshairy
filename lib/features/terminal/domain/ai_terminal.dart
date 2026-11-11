import 'dart:convert';

import '../../../foundation/cancellation.dart';
import '../../../foundation/ids.dart';
import 'insertion.dart';
import 'terminal_target.dart';

/// A logical session target, without authentication details or a local executable path.
sealed class TerminalAiTarget {
  const TerminalAiTarget();
}

final class SshTerminalAiTarget extends TerminalAiTarget {
  const SshTerminalAiTarget(this.hostId);
  final HostId hostId;
}

final class LocalTerminalAiTarget extends TerminalAiTarget {
  const LocalTerminalAiTarget(this.kind);
  final LocalShellKind kind;
}

enum TerminalAiPrompt { unavailable, unknown, recognized, semantic }

/// Only currently echoed input and already known directory metadata. No output or history is read implicitly.
/// A recognized prompt is a compatibility heuristic, not proof of the remote account or nested shell identity.
class TerminalAiContext {
  const TerminalAiContext({
    required this.sessionId,
    required this.target,
    required this.generation,
    required this.revision,
    required this.prompt,
    this.draft,
    this.directory,
  });

  final SessionId sessionId;
  final TerminalAiTarget target;
  final int generation, revision;
  final TerminalAiPrompt prompt;
  final String? draft, directory;
  bool get ready => draft != null && (prompt == TerminalAiPrompt.recognized || prompt == TerminalAiPrompt.semantic);
}

class TerminalAiSnapshot {
  const TerminalAiSnapshot({
    required this.context,
    required this.text,
    required this.firstLine,
    required this.lastLine,
    required this.truncated,
  });

  final TerminalAiContext context;
  final String text;
  final int firstLine, lastLine;
  final bool truncated;
}

abstract interface class TerminalContextReader {
  TerminalAiContext readAiContext();

  /// Explicit local access only. Callers still need a separate grant before sending terminal content to a model.
  TerminalAiSnapshot? readAiSnapshot(TerminalAiContext expected, {int maxLines = 200, int maxBytes = 32768});
}

enum TerminalAiGenerationKind { command, clarify, useAgent }

class TerminalAiGeneration {
  const TerminalAiGeneration(this.kind, {this.command, this.message});
  final TerminalAiGenerationKind kind;
  final String? command, message;
}

class TerminalAiHistoryEntry {
  const TerminalAiHistoryEntry({required this.text, required this.at, required this.generation});
  final String text;
  final DateTime at;
  final int generation;
}

abstract interface class TerminalAiService {
  bool canGenerate(TerminalAiContext context);
  bool canComplete(TerminalAiContext context);
  Stream<void> get changes;
  Future<TerminalAiGeneration> generate(
    TerminalAiContext context,
    String instruction,
    CancellationToken cancel, {
    List<TerminalAiHistoryEntry> history = const [],
  });
  Future<String?> complete(TerminalAiContext context, List<TerminalAiHistoryEntry> history, CancellationToken cancel);
}

bool sameTerminalAiContext(TerminalAiContext a, TerminalAiContext b, {bool draft = true}) =>
    a.sessionId == b.sessionId &&
    a.generation == b.generation &&
    (!draft || (a.revision == b.revision && a.draft == b.draft)) &&
    a.prompt == b.prompt &&
    a.directory == b.directory &&
    switch ((a.target, b.target)) {
      (SshTerminalAiTarget(hostId: final x), SshTerminalAiTarget(hostId: final y)) => x == y,
      (LocalTerminalAiTarget(kind: final x), LocalTerminalAiTarget(kind: final y)) => x == y,
      _ => false,
    };

abstract interface class TerminalDraftAcceptor {
  /// Full commands require an empty prompt. A suffix is appended to the exact captured echoed draft.
  /// Neither path deletes input, sends Enter, executes a command, or claims focus/IME authorization.
  Future<InsertResult> acceptAiDraft(TerminalAiContext expected, String text, {bool suffix = false});
}

bool validTerminalAiCommand(String text) =>
    text.trim().isNotEmpty &&
    text.length <= 2048 &&
    utf8.encode(text).length <= 4096 &&
    !text.runes.any(
      (r) =>
          r < 32 ||
          (r >= 127 && r <= 159) ||
          (r >= 0xd800 && r <= 0xdfff) ||
          r == 0x2028 ||
          r == 0x2029 ||
          r == 0x061c ||
          r == 0x200e ||
          r == 0x200f ||
          (r >= 0x202a && r <= 0x202e) ||
          (r >= 0x2066 && r <= 0x2069),
    );

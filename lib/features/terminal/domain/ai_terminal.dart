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

class TerminalHistorySession {
  const TerminalHistorySession({
    required this.sessionId,
    required this.target,
    required this.label,
    required this.generation,
    required this.historyRevision,
    required this.binding,
    this.tabId,
    this.paneId,
  });

  final SessionId sessionId;
  final TerminalAiTarget target;
  final String label;
  final int generation, historyRevision;

  /// Local workspace IDs for layout actions; never credentials or transport identity.
  final String? tabId, paneId;

  /// Local identity only; never serialize or send it to a model.
  final Object binding;
}

class TerminalHistorySnapshot {
  const TerminalHistorySnapshot({required this.session, required this.prompt, required this.history, this.directory});

  final TerminalHistorySession session;
  final String? directory;
  final TerminalAiPrompt prompt;
  final List<TerminalAiHistoryEntry> history;
}

/// The visible screen only, never scrollback; text is already bounded by the caller's limits.
class TerminalScreenSnapshot {
  const TerminalScreenSnapshot({
    required this.session,
    required this.text,
    required this.firstLine,
    required this.lastLine,
    required this.truncated,
  });

  final TerminalHistorySession session;
  final String text;
  final int firstLine, lastLine;
  final bool truncated;
}

abstract interface class TerminalHistoryReader {
  List<TerminalHistorySession> get sessions;
  SessionId? get focusedSession;
  bool isCurrent(TerminalHistorySession expected);
  TerminalHistorySnapshot? read(TerminalHistorySession expected);
  TerminalScreenSnapshot? readScreen(TerminalHistorySession expected, {int maxLines = 200, int maxBytes = 32768});
}

/// Only currently echoed input and already known directory metadata. No output or history is read implicitly.
/// A recognized prompt is a compatibility heuristic, not proof of the remote account or nested shell identity.
class TerminalAiContext {
  const TerminalAiContext({
    required this.sessionId,
    required this.target,
    required this.generation,
    required this.revision,
    required this.prompt,
    this.historyRevision = 0,
    this.draft,
    this.directory,
  });

  final SessionId sessionId;
  final TerminalAiTarget target;
  final int generation, revision, historyRevision;
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

enum TerminalAiHistoryResultStatus { available, truncated, unavailable }

enum TerminalAiHistoryBoundary { prompt, osc133, osc633 }

class TerminalAiHistoryEntry {
  const TerminalAiHistoryEntry({
    required this.text,
    required this.at,
    required this.generation,
    this.output = '',
    this.resultStatus = TerminalAiHistoryResultStatus.unavailable,
    this.exitCode,
    this.boundary,
  });
  final String text, output;
  final DateTime at;
  final int generation;
  final TerminalAiHistoryResultStatus resultStatus;
  final int? exitCode;
  final TerminalAiHistoryBoundary? boundary;

  TerminalAiHistoryEntry withResult({
    required TerminalAiHistoryResultStatus status,
    required String output,
    int? exitCode,
    TerminalAiHistoryBoundary? boundary,
  }) => TerminalAiHistoryEntry(
    text: text,
    at: at,
    generation: generation,
    output: output,
    resultStatus: status,
    exitCode: exitCode,
    boundary: boundary,
  );
}

final _terminalAiSensitive = RegExp(
  r'(?:password|passwd|passphrase|secret|token|api[-_]?key|authorization|private[-_]?key|BEGIN [A-Z ]*PRIVATE KEY|\bBearer[ \t]+[A-Za-z0-9._~+/=\-]+)',
  caseSensitive: false,
);

/// Auxiliary filtering only; it cannot identify every unknown secret.
bool terminalAiSensitiveText(String text) => _terminalAiSensitive.hasMatch(text);

Map<String, Object?> terminalAiHistoryData(TerminalAiHistoryEntry entry) => {
  'text': entry.text,
  'at': entry.at.toUtc().toIso8601String(),
  'result': {
    'status': entry.resultStatus.name,
    if (entry.resultStatus != TerminalAiHistoryResultStatus.unavailable) 'text': entry.output,
    if (entry.exitCode != null) 'exitCode': entry.exitCode,
    if (entry.boundary != null) 'boundary': entry.boundary!.name,
  },
};

/// Keeps complete command records and shares the remaining encoded budget between their results.
List<TerminalAiHistoryEntry> boundedTerminalAiHistory(Iterable<TerminalAiHistoryEntry> history) {
  final selected = <TerminalAiHistoryEntry>[], originals = <TerminalAiHistoryEntry>[];
  var bytes = 2;
  for (final entry in history.toList().reversed) {
    if (selected.length == 8) break;
    if (!validTerminalAiCommand(entry.text) ||
        entry.text.startsWith(' ') ||
        terminalAiSensitiveText(entry.text) ||
        terminalAiSensitiveText(entry.output) ||
        !_terminalAiHistoryOutputValid(entry.output)) {
      continue;
    }
    final empty = entry.resultStatus == TerminalAiHistoryResultStatus.unavailable
        ? entry.output.isEmpty && entry.exitCode == null && entry.boundary == null
              ? entry
              : entry.withResult(status: TerminalAiHistoryResultStatus.unavailable, output: '')
        : entry.output.isEmpty
        ? entry
        : entry.withResult(
            status: TerminalAiHistoryResultStatus.truncated,
            output: '',
            exitCode: entry.exitCode,
            boundary: entry.boundary,
          );
    final size = utf8.encode(jsonEncode(terminalAiHistoryData(empty))).length + (selected.isEmpty ? 0 : 1);
    if (bytes + size > 4096) continue;
    originals.add(entry);
    selected.add(empty);
    bytes += size;
  }
  var remaining = originals
      .where((entry) => entry.output.isNotEmpty && entry.resultStatus != TerminalAiHistoryResultStatus.unavailable)
      .length;
  for (var i = 0; i < selected.length; i++) {
    final entry = originals[i];
    if (entry.output.isEmpty || entry.resultStatus == TerminalAiHistoryResultStatus.unavailable) continue;
    final allowance = (4096 - bytes) ~/ remaining--;
    final text = StringBuffer();
    var added = 0;
    for (final rune in entry.output.runes) {
      final char = String.fromCharCode(rune);
      final size = utf8.encode(jsonEncode(char)).length - 2;
      if (added + size > allowance) break;
      text.write(char);
      added += size;
    }
    final output = text.toString();
    selected[i] = output == entry.output
        ? entry
        : entry.withResult(
            status: TerminalAiHistoryResultStatus.truncated,
            output: output,
            exitCode: entry.exitCode,
            boundary: entry.boundary,
          );
    bytes += added;
  }
  return List.unmodifiable(selected.reversed);
}

bool _terminalAiHistoryOutputValid(String text) => !text.runes.any(
  (r) =>
      r < 32 && r != 9 && r != 10 ||
      r >= 127 && r <= 159 ||
      r >= 0xd800 && r <= 0xdfff ||
      r == 0x2028 ||
      r == 0x2029 ||
      r == 0x061c ||
      r == 0x200e ||
      r == 0x200f ||
      r >= 0x202a && r <= 0x202e ||
      r >= 0x2066 && r <= 0x2069,
);

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
  Future<String?> complete(
    TerminalAiContext context,
    List<TerminalAiHistoryEntry> history,
    CancellationToken cancel, {
    void Function()? onStarted,
    void Function(Duration)? onDeferred,
  });
}

/// Why an inline request produced no usable command; carries no user text or credential.
enum TerminalAiFailureReason { unavailable, cancelled, timeout, network, http, invalid }

class TerminalAiFailure implements Exception {
  const TerminalAiFailure(this.reason, {this.statusCode});
  final TerminalAiFailureReason reason;
  final int? statusCode;
}

bool sameTerminalAiContext(TerminalAiContext a, TerminalAiContext b, {bool draft = true}) =>
    sameTerminalAiEnvironment(a, b) &&
    (!draft || (a.revision == b.revision && a.draft == b.draft)) &&
    a.historyRevision == b.historyRevision &&
    a.prompt == b.prompt;

bool sameTerminalAiEnvironment(TerminalAiContext a, TerminalAiContext b) =>
    a.sessionId == b.sessionId &&
    a.generation == b.generation &&
    a.directory == b.directory &&
    switch ((a.target, b.target)) {
      (SshTerminalAiTarget(hostId: final x), SshTerminalAiTarget(hostId: final y)) => x == y,
      (LocalTerminalAiTarget(kind: final x), LocalTerminalAiTarget(kind: final y)) => x == y,
      _ => false,
    };

abstract interface class TerminalDraftAcceptor {
  /// Full commands replace the exact echoed draft, verifying an empty echo before paste; suffixes only append.
  /// Never sends Enter or executes. The caller owns focus/IME authorization and cancels if it changes.
  Future<InsertResult> acceptAiDraft(
    TerminalAiContext expected,
    String text, {
    bool suffix = false,
    CancellationToken? cancel,
    bool Function()? isCurrent,
  });
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

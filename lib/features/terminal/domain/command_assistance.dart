import '../../../foundation/cancellation.dart';
import 'command_catalog.dart';

export 'command_catalog.dart' show CommandDescription, CommandKind;

enum CommandCandidateSource { history, ai, builtin, path, snippet, provider }

class CommandCandidate {
  const CommandCandidate(
    this.text, {
    this.source = CommandCandidateSource.provider,
    this.kind = CommandKind.line,
    this.displayText,
    this.description,
    this.detail,
    this.directory,
    this.preview,
  });

  /// Whole line to append to a verified echoed draft; never a shell command to run.
  final String text;
  final CommandCandidateSource source;
  final CommandKind kind;
  final String? displayText;
  final CommandDescription? description;

  /// Third-party static specification text, or a user-owned snippet label.
  final String? detail;

  /// A raw logical path ending in '/', for a directory that can be browsed without writing to the shell.
  final String? directory;

  /// A longer virtual draft for drilling into the next command level without writing to the shell.
  final String? preview;
  String get identity => '${source.name}:$text:${directory ?? ''}';
}

class CommandSnippet {
  const CommandSnippet(this.text, this.label);
  final String text, label;
}

class CommandCompletionRequest {
  const CommandCompletionRequest({
    required this.text,
    required this.generation,
    required this.revision,
    this.directory,
  });
  final String text;
  final int generation, revision;
  final String? directory;
  int get cursor => text.length;
}

abstract interface class CommandCompletionProvider {
  Future<List<CommandCandidate>> complete(CommandCompletionRequest request, CancellationToken cancel);
}

enum CompletionLoad { ready, loading, failed, unavailable }

class CommandBrowseState {
  const CommandBrowseState({
    required this.label,
    required this.depth,
    this.load = CompletionLoad.ready,
    this.truncated = false,
  });
  final String label;
  final int depth;
  final CompletionLoad load;
  final bool truncated;
}

class CommandAssistanceState {
  const CommandAssistanceState({this.request, this.candidates = const [], this.browse, this.loading = false});
  final CommandCompletionRequest? request;
  final List<CommandCandidate> candidates;
  final CommandBrowseState? browse;
  final bool loading;
}

bool commandIsSingleLine(String text) =>
    text.length <= CommandHistory.maxLength && !text.runes.any((r) => r < 32 || (r >= 127 && r <= 159));

class CommandHistory {
  static const limit = 100, maxLength = 2048;
  final _commands = <String>[];
  List<String> get commands => List.unmodifiable(_commands);
  void remember(String command) {
    if (!commandIsSingleLine(command) || command.trim().isEmpty || command.startsWith(' ')) return;
    _commands.remove(command);
    _commands.insert(0, command);
    if (_commands.length > limit) _commands.removeLast();
  }

  void clear() => _commands.clear();
}

String? visibleShellCommand(String beforeCursor, String afterCursor) {
  if (afterCursor.trim().isNotEmpty) return null;
  final prompt = RegExp(r'^(?:\[[^\]\r\n]*@[^\]\r\n]+\]|[\w.-]+@[\w.-]+:[^\r\n]*?)[#$] ').firstMatch(beforeCursor);
  if (prompt == null) return null;
  final command = beforeCursor.substring(prompt.end);
  return commandIsSingleLine(command) ? command : null;
}

/// Conservative defaults for local shells. Custom prompts still require semantic OSC boundaries.
String? visibleLocalShellCommand(
  String beforeCursor,
  String afterCursor, {
  required bool powershell,
  required bool bash,
}) {
  if (afterCursor.trim().isNotEmpty) return null;
  final prompt =
      (bash
              ? RegExp(r'^[#$] ')
              : powershell
              ? RegExp(r'^PS (?:[A-Za-z]:\\|\\\\)[^\r\n>]*> ')
              : RegExp(r'^(?:[A-Za-z]:\\|\\\\)[^\r\n>]*>'))
          .firstMatch(beforeCursor);
  if (prompt == null) return null;
  final command = beforeCursor.substring(prompt.end);
  return commandIsSingleLine(command) ? command : null;
}

const commandCandidateLimit = 200, commandHistoryCandidateLimit = 50;

bool commandCandidateValid(CommandCandidate candidate, String draft) {
  if (!commandIsSingleLine(candidate.text) || !candidate.text.startsWith(draft)) return false;
  final shown = candidate.displayText;
  if (shown == null) return true;
  if (shown.isEmpty || !commandIsSingleLine(shown)) return false;
  if (candidate.source == CommandCandidateSource.ai || candidate.source == CommandCandidateSource.provider) {
    return shown.length >= candidate.text.length - draft.length && candidate.text.endsWith(shown);
  }
  return true;
}

/// The small built-in catalog is a fallback if packaged specifications are unavailable.
List<CommandCandidate> localCommandCandidates(String prefix, CommandHistory history, {bool catalog = true}) {
  if (prefix.trim().isEmpty || !commandIsSingleLine(prefix)) return const [];
  return mergeCommandCandidates(prefix, [
    for (final command in history.commands)
      if (command.startsWith(prefix) && command != prefix)
        CommandCandidate(command, source: CommandCandidateSource.history),
    if (catalog)
      for (final s in catalogSuggestions(prefix))
        CommandCandidate(
          s.text,
          source: CommandCandidateSource.builtin,
          kind: s.kind,
          displayText: s.display,
          description: s.description,
        ),
  ], const []);
}

/// A validated AI line is first; asynchronous selection remains owned by candidate identity.
List<CommandCandidate> mergeCommandCandidates(
  String draft,
  List<CommandCandidate> local,
  Iterable<CommandCandidate> supplied,
) {
  final provided = supplied.take(commandCandidateLimit * 2).toList();
  final all = [...local, ...provided];
  final seen = <String>{draft};
  final merged = <CommandCandidate>[];
  var history = 0;
  for (final source in [
    CommandCandidateSource.ai,
    ...CommandCandidateSource.values.where((s) => s != CommandCandidateSource.ai),
  ]) {
    for (final candidate in all.where((c) => c.source == source)) {
      if (source == CommandCandidateSource.history && history >= commandHistoryCandidateLimit) break;
      if (commandCandidateValid(candidate, draft) && seen.add(candidate.text)) {
        merged.add(candidate);
        if (source == CommandCandidateSource.history) history++;
        if (merged.length == commandCandidateLimit) return List.unmodifiable(merged);
        if (source == CommandCandidateSource.ai) break;
      }
    }
  }
  return List.unmodifiable(merged);
}

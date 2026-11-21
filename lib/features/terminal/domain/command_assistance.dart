import '../../../foundation/cancellation.dart';

enum CommandKind { line, command, subcommand, option, argument }

enum CommandCandidateSource { history, builtin, path, snippet, provider }

class CommandCandidate {
  const CommandCandidate(
    this.text, {
    this.source = CommandCandidateSource.provider,
    this.kind = CommandKind.line,
    this.displayText,
    this.detail,
    this.directory,
    this.preview,
  });

  /// Whole line to append to a verified echoed draft; never a shell command to run.
  final String text;
  final CommandCandidateSource source;
  final CommandKind kind;
  final String? displayText;

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
  // Conda and virtualenv put `(env) ` in front of the usual user@host prompt.
  final prompt = RegExp(r'^(?:\([^)\r\n]+\) )*(?:\[[^\]\r\n]*@[^\]\r\n]+\]|[\w.-]+@[\w.-]+:[^\r\n]*?)[#$] ')
      .firstMatch(beforeCursor);
  if (prompt == null) return null;
  final command = beforeCursor.substring(prompt.end);
  return commandIsSingleLine(command) ? command : null;
}

/// Default Unix prompts for local shells and SSH; custom prompts still require semantic OSC boundaries.
String? visibleUnixShellCommand(String beforeCursor, String afterCursor, {bool percent = false, bool fish = false}) {
  if (afterCursor.trim().isNotEmpty) return null;
  if (!fish) {
    final known =
        visibleShellCommand(beforeCursor, afterCursor) ??
        visibleLocalShellCommand(beforeCursor, afterCursor, powershell: false, bash: true);
    if (known != null) return known;
  }
  const envPrefix = r'(?:\([^)\r\n]+\) )*';
  final prompt =
      (fish
              ? RegExp(
                  '^$envPrefix'
                  r'[\w.-]+@[\w.-]+ [^\r\n>]*> ',
                )
              : percent
              ? RegExp(
                  '^$envPrefix'
                  r'(?:[\w.-]+@[\w.-]+ [^\r\n]*?|[\w.-]+)[%#] ',
                )
              : null)
          ?.firstMatch(beforeCursor);
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
  const envPrefix = r'(?:\([^)\r\n]+\) )*';
  final prompt =
      (bash
              ? RegExp(
                  '^$envPrefix'
                  r'[#$] ',
                )
              : powershell
              ? RegExp(
                  '^$envPrefix'
                  r'PS (?:[A-Za-z]:\\|\\\\)[^\r\n>]*> ',
                )
              : RegExp(
                  '^$envPrefix'
                  r'(?:[A-Za-z]:\\|\\\\)[^\r\n>]*>',
                ))
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
  if (candidate.source == CommandCandidateSource.provider) {
    return shown.length >= candidate.text.length - draft.length && candidate.text.endsWith(shown);
  }
  return true;
}

List<CommandCandidate> localCommandCandidates(String prefix, CommandHistory history) {
  if (prefix.trim().isEmpty || !commandIsSingleLine(prefix)) return const [];
  return mergeCommandCandidates(prefix, [
    for (final command in history.commands)
      if (command.startsWith(prefix) && command != prefix)
        CommandCandidate(command, source: CommandCandidateSource.history),
  ], const []);
}

/// Asynchronous selection remains owned by candidate identity.
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
  for (final source in CommandCandidateSource.values) {
    for (final candidate in all.where((c) => c.source == source)) {
      if (source == CommandCandidateSource.history && history >= commandHistoryCandidateLimit) break;
      if (commandCandidateValid(candidate, draft) && seen.add(candidate.text)) {
        merged.add(candidate);
        if (source == CommandCandidateSource.history) history++;
        if (merged.length == commandCandidateLimit) return List.unmodifiable(merged);
      }
    }
  }
  return List.unmodifiable(merged);
}

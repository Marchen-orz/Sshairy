import '../../../foundation/cancellation.dart';
import 'command_catalog.dart';

export 'command_catalog.dart' show CommandDescription, CommandKind;

/// [ai] is reserved for a future, separately authorized provider; it sorts before everything else.
enum CommandCandidateSource { ai, history, builtin, provider }

class CommandCandidate {
  const CommandCandidate(
    this.text, {
    this.source = CommandCandidateSource.provider,
    this.kind = CommandKind.line,
    this.displayText,
    this.description,
  });

  /// The whole command line after insertion; it always starts with the draft it was offered for.
  final String text;
  final CommandCandidateSource source;
  final CommandKind kind;

  /// Only the completed word, shown instead of [text]; null for whole-line candidates.
  final String? displayText;
  final CommandDescription? description;
}

/// A provider has no terminal handle. An AI implementation must be injected only after its own authorization.
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

class CommandAssistanceState {
  const CommandAssistanceState({this.request, this.candidates = const []});

  final CommandCompletionRequest? request;
  final List<CommandCandidate> candidates;
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

/// Deliberately narrow: the normal SSH shell prompts we can identify without installing integration scripts.
String? visibleShellCommand(String beforeCursor, String afterCursor) {
  if (afterCursor.trim().isNotEmpty) return null;
  final prompt = RegExp(r'^(?:\[[^\]\r\n]*@[^\]\r\n]+\]|[\w.-]+@[\w.-]+:[^\r\n]*?)[#$] ').firstMatch(beforeCursor);
  if (prompt == null) return null;
  final command = beforeCursor.substring(prompt.end);
  return commandIsSingleLine(command) ? command : null;
}

const commandCandidateLimit = 8, _historySlots = 5;

/// What may be offered for [draft]: one line that only extends it, and a label that is the text actually inserted.
bool commandCandidateValid(CommandCandidate candidate, String draft) {
  final text = candidate.text, shown = candidate.displayText;
  if (!commandIsSingleLine(text) || !text.startsWith(draft)) return false;
  return shown == null ||
      (commandIsSingleLine(shown) && shown.length >= text.length - draft.length && text.endsWith(shown));
}

/// History first (keeping slots for the catalog), then contextual catalog words; never more than the visible limit.
List<CommandCandidate> localCommandCandidates(String prefix, CommandHistory history) {
  if (prefix.trim().isEmpty || !commandIsSingleLine(prefix)) return const [];
  final seen = <String>{prefix};
  final past = [
    for (final command in history.commands)
      if (command.startsWith(prefix) && seen.add(command))
        CommandCandidate(command, source: CommandCandidateSource.history),
  ];
  final known = [
    for (final s in catalogSuggestions(prefix))
      if (commandIsSingleLine(s.text) && seen.add(s.text))
        CommandCandidate(
          s.text,
          source: CommandCandidateSource.builtin,
          kind: s.kind,
          displayText: s.display,
          description: s.description,
        ),
  ];
  return [
    ...past.take(_historySlots),
    ...known,
    ...past.skip(_historySlots),
  ].take(commandCandidateLimit).toList(growable: false);
}

/// Order: [CommandCandidateSource.ai], then local, then other provider results. Duplicates and invalid items are dropped.
List<CommandCandidate> mergeCommandCandidates(
  String draft,
  List<CommandCandidate> local,
  Iterable<CommandCandidate> supplied,
) {
  final provided = supplied.take(32).toList();
  final seen = <String>{draft};
  final merged = <CommandCandidate>[];
  for (final candidate in [
    ...provided.where((c) => c.source == CommandCandidateSource.ai),
    ...local,
    ...provided.where((c) => c.source != CommandCandidateSource.ai),
  ]) {
    if (commandCandidateValid(candidate, draft) && seen.add(candidate.text)) {
      merged.add(candidate);
      if (merged.length == commandCandidateLimit) break;
    }
  }
  return merged;
}

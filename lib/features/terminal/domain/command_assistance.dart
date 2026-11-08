import '../../../foundation/cancellation.dart';

enum CommandCandidateSource { history, builtin, provider }

class CommandCandidate {
  const CommandCandidate(this.text, {this.source = CommandCandidateSource.provider});

  final String text;
  final CommandCandidateSource source;
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

const _builtinCommands = [
  'ls',
  'ls -la',
  'pwd',
  'cd ',
  'cat ',
  'tail -f ',
  'grep ',
  'find ',
  'git status',
  'git diff',
  'git log --oneline',
  'docker ps',
  'docker logs ',
  'systemctl status ',
  'journalctl -f',
  'ps aux',
  'df -h',
  'du -sh ',
  'free -h',
  'top',
  'htop',
];

List<CommandCandidate> localCommandCandidates(String prefix, CommandHistory history) {
  if (prefix.trim().isEmpty || !commandIsSingleLine(prefix)) return const [];
  final seen = <String>{prefix};
  return [
    for (final command in history.commands)
      if (command.startsWith(prefix) && seen.add(command))
        CommandCandidate(command, source: CommandCandidateSource.history),
    for (final command in _builtinCommands)
      if (command.startsWith(prefix) && seen.add(command))
        CommandCandidate(command, source: CommandCandidateSource.builtin),
  ].take(8).toList(growable: false);
}

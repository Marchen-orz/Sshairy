import 'command_catalog.dart';
import 'completion_context.dart';

enum TerminalInputIntent { command, naturalLanguage, uncertain }

TerminalInputIntent terminalInputIntent(String text) {
  final line = text.trim();
  if (line.isEmpty || line.length > 2048) return TerminalInputIntent.uncertain;
  final first = line.split(RegExp(r'\s+')).first;
  if (catalogCommandNames().contains(first) ||
      first.contains('/') ||
      first.contains('\\') ||
      RegExp(r'^(?:\./|\.\./|~|[A-Za-z]:)').hasMatch(first)) {
    return TerminalInputIntent.command;
  }
  if (RegExp(r'^(?:请(?:帮我)?|帮我|如何|怎么|怎样|为什么|查看|显示|查找|列出|检查|生成|删除|创建|统计|找出|解释|帮忙)').hasMatch(line) &&
      RegExp(r'[㐀-鿿]').hasMatch(line) &&
      line.length >= 4) {
    return TerminalInputIntent.naturalLanguage;
  }
  if (RegExp(
    r'^(?:please\s+|how\s+(?:do|can|to)\b|why\s+|show\s+me\s+|find\s+the\s+|help\s+me\s+)',
    caseSensitive: false,
  ).hasMatch(line)) {
    return TerminalInputIntent.naturalLanguage;
  }
  final parsed = CompletionContext.parse(line);
  if (parsed.supported &&
      (parsed.words.any((word) => word.value.startsWith('-')) || line.contains('=') || line.contains('|'))) {
    return TerminalInputIntent.command;
  }
  return TerminalInputIntent.uncertain;
}

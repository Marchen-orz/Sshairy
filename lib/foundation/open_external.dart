import 'dart:io';

/// http(s) links found in terminal output, and folders, opened in the system's default program.
/// Arguments go to the program directly, never through a shell, so a link cannot smuggle a command.
Future<bool> openExternal(String target) async {
  final isDir = _isDir(target);
  final uri = Uri.tryParse(target);
  if (!isDir && (uri == null || !const ['http', 'https'].contains(uri.scheme) || uri.host.isEmpty)) return false;
  final (exe, args) = switch (Platform.operatingSystem) {
    'windows' => isDir ? ('explorer', [target]) : ('rundll32', ['url.dll,FileProtocolHandler', uri.toString()]),
    'macos' => ('open', [isDir ? target : uri.toString()]),
    _ => ('xdg-open', [isDir ? target : uri.toString()]),
  };
  try {
    await Process.start(exe, args, mode: ProcessStartMode.detached);
    return true;
  } on ProcessException {
    return false;
  }
}

/// Opens a local file in the program the system associates with its type, without a shell.
Future<bool> openFile(String path) async {
  if (!File(path).existsSync()) return false;
  final (exe, args) = switch (Platform.operatingSystem) {
    'windows' => ('rundll32', ['shell32.dll,ShellExec_RunDLL', path]),
    'macos' => ('open', [path]),
    _ => ('xdg-open', [path]),
  };
  try {
    await Process.start(exe, args, mode: ProcessStartMode.detached);
    return true;
  } on ProcessException {
    return false;
  }
}

/// Windows throws rather than answering false for names it cannot parse, such as URLs.
bool _isDir(String path) {
  try {
    return Directory(path).existsSync();
  } on FileSystemException {
    return false;
  }
}

final _url = RegExp(r'''https?://[^\s<>"'`]+''');

/// The http(s) link in [line] that covers column [x], without trailing punctuation that usually ends a sentence.
String? linkAt(String line, int x) {
  for (final m in _url.allMatches(line)) {
    var text = m[0]!;
    while (text.isNotEmpty && '.,;:!?)]}'.contains(text[text.length - 1])) {
      final last = text[text.length - 1];
      // Keep a closing bracket that has its opening one inside the link, as in wiki URLs.
      if (')]}'.contains(last) && text.contains(const {')': '(', ']': '[', '}': '{'}[last]!)) break;
      text = text.substring(0, text.length - 1);
    }
    if (x >= m.start && x < m.start + text.length) return text;
  }
  return null;
}

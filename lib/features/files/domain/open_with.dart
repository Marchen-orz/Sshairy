/// A program a file can open in, and which one each file type opens with (docs/EXTERNAL_EDITS.md). The
/// operating system's own association is [OpenWithApp.system]. Nothing here touches the disk or starts a process;
/// discovery and launching are in adapters/open_with.dart.
class OpenWithApp {
  const OpenWithApp(this.id, this.name, this.executable);

  const OpenWithApp.system() : this('system', '', null);

  /// A program at [executable]. The id follows the path, so the same program found twice is one entry.
  factory OpenWithApp.program(String executable, {String? name}) =>
      OpenWithApp(executable.toLowerCase(), name ?? programName(executable), executable);

  final String id, name;

  /// Null for the system association.
  final String? executable;

  bool get isSystem => executable == null;

  @override
  bool operator ==(Object other) => other is OpenWithApp && other.id == id;

  @override
  int get hashCode => id.hashCode;

  /// Only what is needed to find the program again: how it is started is worked out at launch, because it can
  /// change with the program's own updates.
  Map<String, Object?> toJson() => {'name': name, 'executable': executable};

  static OpenWithApp? tryFromJson(Object? json) {
    if (json is! Map) return null;
    final executable = json['executable'];
    if (executable is! String || !isAbsoluteProgramPath(executable)) return null;
    final name = json['name'];
    return OpenWithApp.program(
      executable,
      name: name is String && name.trim().isNotEmpty && name.length <= 128 ? name : null,
    );
  }
}

/// How a launched program's end is read. Only [closed] may end an edit.
enum EditorExit {
  /// A document-aware wait command confirms the file closed.
  closed,

  /// It cannot confirm that the document closed, for example after a handoff or failed wait command. The
  /// file may well still be open there.
  handedOff,
}

/// What a launch gave: whether it started, and when the program's exit can say the file was closed. [exited] is
/// null when there is nothing to watch (the system opened it, or the platform has no verified launcher).
class EditorLaunch {
  const EditorLaunch.started({this.exited}) : started = true;

  const EditorLaunch.failed() : started = false, exited = null;

  final bool started;
  final Future<EditorExit>? exited;
}

/// The local side of opening a file: which programs exist and how to start one.
abstract interface class EditorLauncher {
  /// Whether programs can be listed and picked on this platform; elsewhere only the system association opens files.
  bool get canChoose;

  /// Programs offered for [fileName], most fitting first. Never includes [OpenWithApp.system].
  Future<List<OpenWithApp>> apps(String fileName);

  /// The program at [executable], or null when it is not one that can open files.
  Future<OpenWithApp?> program(String executable);

  /// Opens [path]; the file is never executed, even when its type is one the system would run.
  Future<EditorLaunch> launch(OpenWithApp app, String path);
}

/// What a default program applies to: the extension, or the whole name for files without one (`Dockerfile`, `.bashrc`).
String fileTypeKey(String name) {
  final lower = name.toLowerCase();
  final dot = lower.lastIndexOf('.');
  return dot > 0 && dot < lower.length - 1 ? 'ext:${lower.substring(dot + 1)}' : 'name:$lower';
}

/// [key] as the user knows it: `.txt`, or the file name.
String fileTypeLabel(String key) => key.startsWith('ext:') ? '.${key.substring(4)}' : key.substring(5);

const _runnable = {
  'exe', 'com', 'bat', 'cmd', 'ps1', 'psm1', 'vbs', 'vbe', 'js', 'jse', 'wsf', 'wsh', 'msi', 'msp', 'msc', 'scr', //
  'lnk', 'reg', 'hta', 'cpl', 'jar', 'pif', 'url', 'inf', 'scf', 'gadget', 'application', 'appref-ms', //
  'sh', 'command', 'tool', 'app', 'pkg', 'dmg', 'run', 'desktop', 'appimage',
};

/// Whether the system would run a file of this type when told to open it. Such a file is opened for editing or not at all.
bool opensByRunning(String fileName) {
  final key = fileTypeKey(fileName);
  return key.startsWith('ext:') && _runnable.contains(key.substring(4));
}

/// The default program for each file type, kept as the user chose.
class EditorApps {
  const EditorApps([this._byType = const {}]);

  static const maxTypes = 256;

  final Map<String, OpenWithApp> _byType;

  bool get isEmpty => _byType.isEmpty;

  /// The program chosen for this file's type; null follows the system.
  OpenWithApp? forFile(String fileName) => _byType[fileTypeKey(fileName)];

  /// Null or the system association clears the choice.
  EditorApps withDefault(String fileName, OpenWithApp? app) {
    final key = fileTypeKey(fileName);
    // A type that the stored form could not hold (control characters in a remote name) is not kept.
    if (!_typeKey.hasMatch(key)) return this;
    final next = {..._byType};
    if (app == null || app.isSystem) {
      next.remove(key);
    } else {
      next.remove(key);
      next[key] = app;
      while (next.length > maxTypes) {
        next.remove(next.keys.first);
      }
    }
    return EditorApps(Map.unmodifiable(next));
  }

  Map<String, Object?> toJson() => {
    'schemaVersion': 1,
    'types': {for (final MapEntry(:key, :value) in _byType.entries) key: value.toJson()},
  };

  /// Throws [FormatException] when the document is not one this app wrote.
  static void validate(Map<String, dynamic> json) {
    final types = json['types'];
    if (types is! Map) throw const FormatException('invalid editor apps');
    for (final key in types.keys) {
      if (key is! String || !_typeKey.hasMatch(key)) throw const FormatException('invalid file type');
    }
  }

  /// Entries that no longer read as a program are left out rather than failing the start.
  factory EditorApps.fromJson(Map<String, dynamic> json) {
    final types = json['types'];
    if (types is! Map) return const EditorApps();
    final out = <String, OpenWithApp>{};
    for (final MapEntry(:key, :value) in types.entries) {
      if (key is! String || !_typeKey.hasMatch(key) || out.length >= maxTypes) continue;
      final app = OpenWithApp.tryFromJson(value);
      if (app != null) out[key] = app;
    }
    return EditorApps(Map.unmodifiable(out));
  }

  static final _typeKey = RegExp(r'^(ext|name):[^\u0000-\u001f]{1,255}$');
}

/// An absolute path in Windows or POSIX form, without control characters.
bool isAbsoluteProgramPath(String path) =>
    path.length <= 1024 &&
    !RegExp(r'[\u0000-\u001f]').hasMatch(path) &&
    (RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path) || path.startsWith(r'\\') || path.startsWith('/'));

/// The file name of [path] in either syntax.
String baseName(String path) {
  final i = [path.lastIndexOf('/'), path.lastIndexOf(r'\')].reduce((a, b) => a > b ? a : b);
  return i < 0 ? path : path.substring(i + 1);
}

const _knownNames = {
  'code.exe': 'Visual Studio Code',
  'code - insiders.exe': 'Visual Studio Code Insiders',
  'codium.exe': 'VSCodium',
  'vscodium.exe': 'VSCodium',
  'cursor.exe': 'Cursor',
  'windsurf.exe': 'Windsurf',
  'antigravity.exe': 'Antigravity',
  'sublime_text.exe': 'Sublime Text',
};

/// A readable name for the program at [executable].
String programName(String executable) {
  final file = baseName(executable);
  final known = _knownNames[file.toLowerCase()];
  if (known != null) return known;
  final base = file.toLowerCase().endsWith('.exe') ? file.substring(0, file.length - 4) : file;
  // `NOTEPAD` and `notepad` read as `Notepad`; a mixed-case name was written that way on purpose.
  final plain = base == base.toLowerCase() || base == base.toUpperCase();
  return plain && base.isNotEmpty ? '${base[0].toUpperCase()}${base.substring(1).toLowerCase()}' : base;
}

/// Programs that start a command or script host rather than show a file; never offered, and never taken from a
/// registry command as the program for a file.
const _scriptHosts = {
  'cmd.exe', 'powershell.exe', 'pwsh.exe', 'wscript.exe', 'cscript.exe', 'mshta.exe', 'rundll32.exe', //
  'regsvr32.exe', 'msiexec.exe', 'explorer.exe', 'wsl.exe', 'bash.exe', 'conhost.exe', 'forfiles.exe', //
  'schtasks.exe', 'reg.exe', 'regedit.exe', 'certutil.exe', 'bitsadmin.exe', 'wmic.exe', 'sc.exe', 'dllhost.exe',
};

bool isScriptHost(String executable) => _scriptHosts.contains(baseName(executable).toLowerCase());

/// The program of a registry `shell\open\command` value such as `"C:\App\a.exe" "%1"` or
/// `%SystemRoot%\system32\NOTEPAD.EXE %1`; the arguments are not used. Null when the command is not a plain
/// program: it starts with the file itself (`"%1" %*`), is a script host, or has no `.exe` in it.
String? commandProgram(String command, {Map<String, String> environment = const {}}) {
  final env = {for (final e in environment.entries) e.key.toUpperCase(): e.value};
  final expanded = command.trim().replaceAllMapped(
    RegExp(r'%([A-Za-z_][A-Za-z0-9_()]*)%'),
    (m) => env[m[1]!.toUpperCase()] ?? m[0]!,
  );
  String? program;
  if (expanded.startsWith('"')) {
    final end = expanded.indexOf('"', 1);
    if (end > 1) program = expanded.substring(1, end);
  } else {
    // An unquoted path may hold spaces; the program ends at the first piece that ends in .exe.
    var piece = '';
    for (final word in expanded.split(RegExp(r'\s+'))) {
      piece = piece.isEmpty ? word : '$piece $word';
      if (piece.toLowerCase().endsWith('.exe')) {
        program = piece;
        break;
      }
    }
  }
  if (program == null || !program.toLowerCase().endsWith('.exe') || !isAbsoluteProgramPath(program)) return null;
  return isScriptHost(program) ? null : program;
}

/// A key as `reg query` prints it: its values (name to type and data) and the names of its subkeys.
class RegistryKey {
  const RegistryKey(this.values, this.subkeys);

  final Map<String, ({String type, String data})> values;
  final List<String> subkeys;
}

final _registryValue = RegExp(r'^ {4}(.+?) {4}(REG_[A-Z_]+)(?: {4}(.*))?$');

/// Parses the output of `reg query`. The first `HKEY_` line names the key itself; later ones are its subkeys.
/// The name of the unnamed value is localised by Windows, so callers that need it ask for it with `/ve` and
/// take the only value.
RegistryKey parseRegistryQuery(String output) {
  final values = <String, ({String type, String data})>{};
  final subkeys = <String>[];
  var header = false;
  for (final raw in output.split('\n')) {
    final line = raw.endsWith('\r') ? raw.substring(0, raw.length - 1) : raw;
    if (line.startsWith('HKEY_')) {
      if (header) subkeys.add(baseName(line));
      header = true;
      continue;
    }
    final m = _registryValue.firstMatch(line);
    if (m != null) values[m[1]!] = (type: m[2]!, data: (m[3] ?? '').trim());
  }
  return RegistryKey(values, subkeys);
}

/// Programs known to wait for a document, for which the app can tell a closed file from a handed-over one.
enum EditorFamily {
  /// Visual Studio Code and its forks: their bundled `cli.js` run by their own executable in Node mode takes `--wait`.
  electron,

  /// Sublime Text: `subl.exe` beside the program takes `--wait`.
  sublime,
}

const _electronExecutables = {
  'code.exe', 'code - insiders.exe', 'codium.exe', 'vscodium.exe', 'cursor.exe', 'windsurf.exe', 'antigravity.exe', //
};

EditorFamily? editorFamily(String executable) {
  final file = baseName(executable).toLowerCase();
  if (_electronExecutables.contains(file)) return EditorFamily.electron;
  if (file == 'sublime_text.exe') return EditorFamily.sublime;
  return null;
}

import 'dart:async';
import 'dart:io';

import '../../../foundation/open_external.dart';
import '../domain/open_with.dart';

part 'unix_editor_apps.dart';

/// Reads the Windows registry through `reg.exe`: started without a shell, with arguments that are never joined into
/// a command line.
abstract interface class Registry {
  /// The values and subkeys of [path]; null when the key does not exist.
  Future<RegistryKey?> key(String path);

  /// The data of the value [name], or of the unnamed one when null; null when there is none.
  Future<String?> value(String path, [String? name]);
}

class RegExe implements Registry {
  RegExe({String? executable})
    : _executable = executable ?? '${Platform.environment['SystemRoot'] ?? r'C:\Windows'}\\System32\\reg.exe';

  final String _executable;

  Future<String?> _query(List<String> arguments) async {
    try {
      // The output is in the system's code page, which is what Process.run decodes with.
      final result = await Process.run(_executable, ['query', ...arguments]);
      return result.exitCode == 0 ? result.stdout as String : null;
    } on ProcessException {
      return null;
    }
  }

  @override
  Future<RegistryKey?> key(String path) async {
    final output = await _query([path]);
    return output == null ? null : parseRegistryQuery(output);
  }

  @override
  Future<String?> value(String path, [String? name]) async {
    final output = await _query([
      path,
      if (name == null) '/ve' else ...['/v', name],
    ]);
    if (output == null) return null;
    final data = parseRegistryQuery(output).values.values.firstOrNull?.data;
    return data == null || data.isEmpty ? null : data;
  }
}

/// How one program is started for one file.
class LaunchRecipe {
  const LaunchRecipe(this.executable, this.arguments, [this.environment = const {}, this.waitsForDocument = false]);

  final bool waitsForDocument;
  final String executable;
  final List<String> arguments;
  final Map<String, String> environment;
}

const _fileExts = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts';
const _appPaths = r'Software\Microsoft\Windows\CurrentVersion\App Paths';
final _executableName = RegExp(r'^[^\\/:*?"<>|!{}]+\.exe$', caseSensitive: false);

/// Finds the programs Explorer's "Open with" offers for a file type: the recorded choices and associations of the
/// current user and of the machine, resolved to programs that exist.
class WindowsApps {
  WindowsApps(
    this._registry, {
    Map<String, String>? environment,
    bool Function(String path)? fileExists,
    List<String> Function(String directory)? subdirectories,
  }) : _environment = environment ?? Platform.environment,
       _exists = fileExists ?? ((path) => File(path).existsSync()),
       _directories = subdirectories ?? _listDirectories;

  final Registry _registry;
  final Map<String, String> _environment;
  final bool Function(String path) _exists;
  final List<String> Function(String directory) _directories;

  String? _extension(String fileName) {
    final key = fileTypeKey(fileName);
    return key.startsWith('ext:') ? '.${key.substring(4)}' : null;
  }

  /// Programs for [fileName], the system's choice for its type first. Editors are mostly opened for text, so the
  /// programs of `.txt` follow for files whose own type has few.
  Future<List<OpenWithApp>> find(String fileName) async {
    final extension = _extension(fileName);
    final lists = await Future.wait([
      for (final e in [?extension, if (extension != '.txt') '.txt']) _forExtension(e),
    ]);
    final seen = <String>{};
    return [
      for (final list in lists)
        for (final app in list)
          if (seen.add(app.id)) app,
    ];
  }

  Future<List<OpenWithApp>> _forExtension(String extension) async {
    final base = '$_fileExts\\$extension';
    final (userList, userProgIds, classList, classProgIds, choice, classDefault) = await (
      _registry.key('$base\\OpenWithList'),
      _registry.key('$base\\OpenWithProgids'),
      _registry.key('HKCR\\$extension\\OpenWithList'),
      _registry.key('HKCR\\$extension\\OpenWithProgids'),
      _registry.value('$base\\UserChoice', 'ProgId'),
      _registry.value('HKCR\\$extension'),
    ).wait;
    final mru = userList?.values['MRUList']?.data ?? '';
    final recent = <(String, String)>[
      if (userList != null)
        for (final MapEntry(:key, :value) in userList.values.entries)
          if (key != 'MRUList') (key, value.data),
    ]..sort((a, b) => _rank(mru, a.$1).compareTo(_rank(mru, b.$1)));
    final progIds = <String>{?choice, ?classDefault, ...?userProgIds?.values.keys, ...?classProgIds?.values.keys};
    final names = [for (final (_, name) in recent) name, ...?classList?.subkeys];
    final apps = await Future.wait([
      for (final progId in progIds) _byProgId(progId),
      for (final name in names) _byName(name),
    ]);
    return [for (final app in apps) ?app];
  }

  /// Position in Explorer's most-recently-used order, which names the values by letter.
  static int _rank(String mru, String name) {
    final i = mru.indexOf(name);
    return i < 0 ? mru.length : i;
  }

  Future<OpenWithApp?> _byProgId(String progId) async {
    final command = await _registry.value('HKCR\\$progId\\shell\\open\\command');
    return _app(command == null ? null : commandProgram(command, environment: _environment), null);
  }

  Future<OpenWithApp?> _byName(String name) async {
    if (!_executableName.hasMatch(name)) return null;
    final (command, friendly) = await (
      _registry.value('HKCR\\Applications\\$name\\shell\\open\\command'),
      _registry.value('HKCR\\Applications\\$name', 'FriendlyAppName'),
    ).wait;
    var program = command == null ? null : commandProgram(command, environment: _environment);
    program ??= await _registered(name);
    return _app(program, friendly);
  }

  /// Where the program registered itself as [name] under App Paths.
  Future<String?> _registered(String name) async {
    for (final root in const ['HKCU', 'HKLM']) {
      final path = await _registry.value('$root\\$_appPaths\\$name');
      if (path == null) continue;
      final program = commandProgram(path.startsWith('"') ? path : '"$path"', environment: _environment);
      if (program != null) return program;
    }
    return null;
  }

  OpenWithApp? _app(String? program, String? friendly) {
    if (program == null || !_exists(program)) return null;
    // A friendly name can be a resource reference (`@file.dll,-100`) that only Windows can resolve.
    final name = friendly != null && friendly.trim().isNotEmpty && !friendly.startsWith('@') ? friendly.trim() : null;
    return OpenWithApp.program(program, name: name);
  }

  /// The program the system opens [fileName] with, when that is a plain program. Types the system would run get
  /// their editing command, or Notepad; null when the association is not a plain program (a store app, a COM
  /// handler), which only the system itself can start.
  Future<String?> associated(String fileName) async {
    final extension = _extension(fileName);
    final runs = opensByRunning(fileName);
    String? progId;
    if (extension != null) {
      progId =
          await _registry.value('$_fileExts\\$extension\\UserChoice', 'ProgId') ??
          await _registry.value('HKCR\\$extension');
    }
    if (progId != null) {
      final command = await _registry.value('HKCR\\$progId\\shell\\${runs ? 'edit' : 'open'}\\command');
      final program = command == null ? null : commandProgram(command, environment: _environment);
      if (program != null && _exists(program)) return program;
    }
    if (!runs) return null;
    final system = _environment['SystemRoot'] ?? _environment['SYSTEMROOT'] ?? r'C:\Windows';
    final notepad = '$system\\System32\\notepad.exe';
    return _exists(notepad) ? notepad : null;
  }

  /// How to start [executable] for [path]. Editors that can wait for the document are started through the command
  /// that does so, so the end of the process is the end of the editing; any other program just gets the file.
  LaunchRecipe recipe(String executable, String path) {
    final root = executable.substring(0, executable.length - baseName(executable).length);
    switch (editorFamily(executable)) {
      case EditorFamily.electron:
        final cli = _electronCli(root);
        if (cli != null) {
          return LaunchRecipe(
            executable,
            [cli, '--wait', '--', path],
            const {'ELECTRON_RUN_AS_NODE': '1', 'VSCODE_DEV': ''},
            true,
          );
        }
      case EditorFamily.sublime:
        final command = '${root}subl.exe';
        if (_exists(command)) return LaunchRecipe(command, ['--wait', '--', path], const {}, true);
      case null:
        break;
    }
    return LaunchRecipe(executable, [path]);
  }

  /// The `cli.js` of an Electron editor: beside the program, or in the folder named for the build that newer
  /// installs put it in. The most recently changed folder wins, so one left behind by an update is not used.
  String? _electronCli(String root) {
    const tail = r'resources\app\out\cli.js';
    if (_exists('$root$tail')) return '$root$tail';
    for (final directory in _directories(root)) {
      final candidate = '$root$directory\\$tail';
      if (_exists(candidate)) return candidate;
    }
    return null;
  }

  static List<String> _listDirectories(String root) {
    try {
      final found = [
        for (final entry in Directory(root).listSync(followLinks: false).take(256))
          if (entry is Directory) (baseName(entry.path), entry.statSync().modified),
      ]..sort((a, b) => b.$2.compareTo(a.$2));
      return [for (final (name, _) in found) name];
    } on FileSystemException {
      return const [];
    }
  }
}

/// Lists installed applications and uses a document-aware wait command only when the editor supports it.
class PlatformEditorLauncher implements EditorLauncher {
  PlatformEditorLauncher({WindowsApps? windows, UnixApps? unix})
    : _windows = windows ?? (unix == null && Platform.isWindows ? WindowsApps(RegExe()) : null),
      _unix = unix ?? (windows == null && (Platform.isMacOS || Platform.isLinux) ? UnixApps() : null);

  final WindowsApps? _windows;
  final UnixApps? _unix;

  @override
  bool get canChoose => _windows != null || (_unix?.supported ?? false);

  @override
  Future<List<OpenWithApp>> apps(String fileName) async =>
      await _windows?.find(fileName) ?? await _unix?.find(fileName) ?? const [];

  @override
  Future<OpenWithApp?> program(String executable) async {
    if (_unix case final unix?) return unix.program(executable);
    if (_windows == null || !_launchable(executable)) return null;
    return OpenWithApp.program(executable);
  }

  /// A program that can be started for a file: absolute, an `.exe`, not a script host, and present.
  bool _launchable(String executable) =>
      isAbsoluteProgramPath(executable) &&
      executable.toLowerCase().endsWith('.exe') &&
      !isScriptHost(executable) &&
      File(executable).existsSync();

  @override
  Future<EditorLaunch> launch(OpenWithApp app, String path) async {
    if (!File(path).existsSync()) return const EditorLaunch.failed();
    final windows = _windows;
    if (windows == null) {
      final unix = _unix;
      if (unix == null) return _system(path);
      if (!app.isSystem) {
        final recipe = await unix.recipe(app.executable!, path);
        return recipe == null ? const EditorLaunch.failed() : _spawn(recipe);
      }
      // An executable remote file is edited by a text app, never passed to a system handler that may run it.
      if (opensByRunning(baseName(path)) || UnixApps._canExecute(path)) {
        if (unix.mac) return _spawn(LaunchRecipe('/usr/bin/open', ['-t', path]));
        for (final editor in await unix.find('document.txt')) {
          final recipe = await unix.recipe(editor.executable!, path);
          if (recipe == null) continue;
          final result = await _spawn(recipe);
          if (result.started) return result;
        }
        return const EditorLaunch.failed();
      }
      return _system(path);
    }
    final name = baseName(path);
    final executable = app.isSystem ? await windows.associated(name) : app.executable;
    if (executable == null) {
      // A type that would be run is never handed to the system's "open".
      return opensByRunning(name) ? const EditorLaunch.failed() : _system(path);
    }
    if (!_launchable(executable)) return const EditorLaunch.failed();
    return _spawn(windows.recipe(executable, path));
  }

  Future<EditorLaunch> _spawn(LaunchRecipe recipe) async {
    try {
      final process = await Process.start(
        recipe.executable,
        recipe.arguments,
        environment: recipe.environment.isEmpty ? null : recipe.environment,
      );
      // Nobody reads the program's output; an unread pipe would stall one that writes.
      unawaited(process.stdout.drain<void>().then((_) {}, onError: (Object _) {}));
      unawaited(process.stderr.drain<void>().then((_) {}, onError: (Object _) {}));
      unawaited(process.stdin.close().then((_) {}, onError: (Object _) {}));
      return EditorLaunch.started(
        exited: recipe.waitsForDocument
            ? process.exitCode.then((code) => code == 0 ? EditorExit.closed : EditorExit.handedOff)
            : null,
      );
    } on ProcessException {
      return const EditorLaunch.failed();
    }
  }

  Future<EditorLaunch> _system(String path) async {
    final bool started;
    if (Platform.isMacOS && opensByRunning(baseName(path))) {
      try {
        await Process.start('open', ['-t', path], mode: ProcessStartMode.detached);
        started = true;
      } on ProcessException {
        return const EditorLaunch.failed();
      }
    } else {
      started = await openFile(path);
    }
    return started ? const EditorLaunch.started() : const EditorLaunch.failed();
  }
}

part of 'open_with.dart';

/// Unix application discovery reads bounded desktop metadata, never executes a discovered program.
class UnixApps {
  UnixApps({
    String? operatingSystem,
    Map<String, String>? environment,
    bool Function(String path)? fileExists,
    bool Function(String path)? directoryExists,
    bool Function(String path)? canExecute,
    String? Function(String path)? readText,
    List<String> Function(String path)? entries,
    Future<String?> Function(String executable, List<String> arguments)? query,
  }) : operatingSystem = operatingSystem ?? Platform.operatingSystem,
       _environment = environment ?? Platform.environment,
       _file = fileExists ?? ((path) => File(path).existsSync()),
       _directory = directoryExists ?? ((path) => Directory(path).existsSync()),
       _executable = canExecute ?? _canExecute,
       _text = readText ?? _readText,
       _entries = entries ?? _listEntries,
       _query = query ?? _runQuery;

  final String operatingSystem;
  final Map<String, String> _environment;
  final bool Function(String) _file, _directory, _executable;
  final String? Function(String) _text;
  final List<String> Function(String) _entries;
  final Future<String?> Function(String, List<String>) _query;
  bool get mac => operatingSystem == 'macos';
  bool get supported => mac || operatingSystem == 'linux';
  String get _home => _environment['HOME'] ?? '';

  static bool _absolute(String path) => path.startsWith('/') && isAbsoluteProgramPath(path);
  static bool _safeProgram(String path) {
    final name = baseName(path).toLowerCase();
    return !isScriptHost(path) &&
        !const {
          'sh',
          'bash',
          'dash',
          'zsh',
          'fish',
          'ksh',
          'csh',
          'tcsh',
          'pwsh',
          'python',
          'python2',
          'python3',
          'perl',
          'ruby',
          'node',
          'nodejs',
          'env',
          'xargs',
          'exec',
          'sudo',
          'doas',
          'pkexec',
          'gio',
          'xdg-open',
          'open',
          'osascript',
          'terminal.app',
          'iterm.app',
          'iterm2.app',
          'automator.app',
          'script editor.app',
          'gnome-terminal',
          'konsole',
          'xterm',
          'alacritty',
          'kitty',
          'wezterm',
        }.contains(name) &&
        !RegExp(r'^(python|perl|ruby|node|bash|zsh|fish|sh)(?:[0-9.]+)?$').hasMatch(name);
  }

  static bool _canExecute(String path) {
    try {
      final stat = File(path).statSync();
      return stat.type == FileSystemEntityType.file && stat.mode & 0x49 != 0;
    } on FileSystemException {
      return false;
    }
  }

  static String? _readText(String path) {
    try {
      final file = File(path);
      return file.lengthSync() <= 256 * 1024 ? file.readAsStringSync() : null;
    } on Object {
      return null;
    }
  }

  static List<String> _listEntries(String path) {
    try {
      final entries = Directory(path).listSync(followLinks: false).take(2048).map((entry) => entry.path).toList();
      return entries..sort();
    } on FileSystemException {
      return const [];
    }
  }

  static Future<String?> _runQuery(String executable, List<String> arguments) async {
    try {
      final process = await Process.start(executable, arguments);
      final output = process.stdout.fold<List<int>>(<int>[], (bytes, chunk) {
        if (bytes.length + chunk.length > 256 * 1024) {
          process.kill();
          throw const FormatException('Application metadata too large');
        }
        return bytes..addAll(chunk);
      });
      final errors = process.stderr.drain<void>();
      await process.stdin.close();
      try {
        final result = await Future.wait<Object?>([process.exitCode, output, errors])
            .timeout(const Duration(seconds: 3));
        return result[0] == 0 ? systemEncoding.decode(result[1] as List<int>) : null;
      } on Object {
        process.kill();
        return null;
      }
    } on Object {
      return null;
    }
  }

  String? _resolve(String command) {
    if (!_safeProgram(command)) return null;
    if (_absolute(command)) return _executable(command) ? command : null;
    if (command.contains('/') || command.isEmpty) return null;
    for (final root in (_environment['PATH'] ?? '/usr/local/bin:/usr/bin:/bin').split(':').take(256)) {
      if (!_absolute(root)) continue;
      final path = '$root/$command';
      if (_executable(path)) return path;
    }
    return null;
  }

  List<String> get _dataRoots => {
    if (_absolute(_environment['XDG_DATA_HOME'] ?? ''))
      _environment['XDG_DATA_HOME']!
    else if (_home.isNotEmpty)
      '$_home/.local/share',
    for (final root in (_environment['XDG_DATA_DIRS'] ?? '/usr/local/share:/usr/share').split(':').take(32))
      if (_absolute(root)) root,
  }.toList();

  List<String> get _mimeFiles {
    final config = _environment['XDG_CONFIG_HOME'] ?? '$_home/.config';
    final desktops = (_environment['XDG_CURRENT_DESKTOP'] ?? '')
        .split(':')
        .map((value) => value.toLowerCase())
        .where((value) => RegExp(r'^[a-z0-9_-]+$').hasMatch(value));
    final configRoots = [config, ...(_environment['XDG_CONFIG_DIRS'] ?? '/etc/xdg').split(':').take(32)];
    return [
      for (final root in configRoots.where(_absolute)) ...[
        for (final desktop in desktops) '$root/$desktop-mimeapps.list',
        '$root/mimeapps.list',
      ],
      for (final root in _dataRoots) '$root/applications/mimeapps.list',
    ];
  }

  static Map<String, String> _section(String text, String section) {
    final values = <String, String>{};
    var inside = false;
    for (final raw in text.split('\n')) {
      final line = raw.trim();
      if (line.startsWith('[')) {
        inside = line == '[$section]';
        continue;
      }
      if (!inside || line.startsWith('#')) continue;
      final equal = line.indexOf('=');
      if (equal > 0) values.putIfAbsent(line.substring(0, equal).trim(), () => line.substring(equal + 1));
    }
    return values;
  }

  static String _mime(String name) => switch (fileTypeKey(name)) {
    'ext:json' => 'application/json',
    'ext:yaml' || 'ext:yml' => 'application/yaml',
    'ext:html' || 'ext:htm' => 'text/html',
    'ext:xml' => 'application/xml',
    'ext:md' => 'text/markdown',
    _ => 'text/plain',
  };

  String? _desktopPath(String id) {
    if (!RegExp(r'^[A-Za-z0-9_.-]+\.desktop$').hasMatch(id)) return null;
    for (final root in _dataRoots) {
      final path = '$root/applications/$id';
      if (_file(path)) return path;
    }
    return null;
  }

  /// The desktop Exec grammar has quoting, not shell evaluation. Unsupported/malformed field codes are refused.
  static List<String>? _execWords(String raw) {
    final words = <String>[];
    var word = StringBuffer(), quoted = false, escaped = false, started = false;
    for (final rune in raw.runes) {
      final char = String.fromCharCode(rune);
      if (escaped) {
        if (!const ['"', '\\', '`', r'$', ' '].contains(char)) return null;
        word.write(char);
        escaped = false;
        started = true;
      } else if (char == '\\') {
        escaped = true;
      } else if (char == '"') {
        quoted = !quoted;
        started = true;
      } else if (!quoted && (char == ' ' || char == '\t')) {
        if (started) words.add(word.toString());
        word = StringBuffer();
        started = false;
      } else {
        if (rune < 32 || rune == 127 || (!quoted && const [';', '|', '&', '<', '>', '`', r'$', "'"].contains(char))) {
          return null;
        }
        word.write(char);
        started = true;
      }
    }
    if (escaped || quoted) return null;
    if (started) words.add(word.toString());
    return words.isEmpty ? null : words;
  }

  ({String name, String executable, List<String> arguments})? _desktop(String path) {
    final text = _text(path);
    if (text == null) return null;
    final entry = _section(text, 'Desktop Entry');
    if (entry['Type'] != 'Application' || entry['Hidden'] == 'true' || entry['Terminal'] == 'true') return null;
    if (entry['TryExec'] case final command?) {
      if (_resolve(command) == null) return null;
    }
    final words = _execWords(entry['Exec'] ?? '');
    if (words == null) return null;
    final executable = _resolve(words.first);
    if (executable == null) return null;
    final name = _desktopString(entry['Name'] ?? programName(executable));
    if (name.isEmpty || name.length > 128 || RegExp(r'[\x00-\x1f\x7f]').hasMatch(name)) return null;
    return (name: name, executable: executable, arguments: words.skip(1).toList());
  }

  static String _desktopString(String value) => value.replaceAllMapped(
    RegExp(r'\\([sntr\\])'),
    (m) => switch (m[1]) {
      's' => ' ',
      'n' => '\n',
      't' => '\t',
      'r' => '\r',
      _ => '\\',
    },
  );

  static String? _xmlString(String text, String key) {
    final match = RegExp('<key>\\s*$key\\s*</key>\\s*<string>(.*?)</string>', dotAll: true).firstMatch(text);
    return match?[1]
        ?.replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&apos;', "'");
  }

  Future<OpenWithApp?> program(String path) async {
    if (!supported || !_absolute(path) || !_safeProgram(path)) return null;
    if (mac && path.endsWith('.app')) {
      if (!_directory(path)) return null;
      final info = await _plist(path);
      final executable = info == null ? null : _xmlString(info, 'CFBundleExecutable');
      if (executable == null ||
          executable.contains('/') ||
          executable.contains('\\') ||
          !_safeProgram(executable) ||
          !_executable('$path/Contents/MacOS/$executable')) {
        return null;
      }
      return OpenWithApp.program(
        path,
        name: _xmlString(info!, 'CFBundleDisplayName') ?? _xmlString(info, 'CFBundleName'),
      );
    }
    if (!mac && path.endsWith('.desktop')) {
      final desktop = _desktop(path);
      return desktop == null ? null : OpenWithApp.program(path, name: desktop.name);
    }
    return _executable(path) ? OpenWithApp.program(path) : null;
  }

  Future<String?> _plist(String app) async {
    final path = '$app/Contents/Info.plist';
    final text = _text(path);
    if (text != null && text.trimLeft().startsWith('<?xml')) return text;
    return _query('/usr/bin/plutil', ['-convert', 'xml1', '-o', '-', path]);
  }

  Future<List<OpenWithApp>> find(String fileName) async {
    if (!supported) return const [];
    final found = <OpenWithApp>[], seen = <String>{};
    Future<void> add(String path) async {
      if (!seen.add(path)) return;
      final app = await program(path);
      if (app != null) found.add(app);
    }

    if (mac) {
      // App bundles are immediate children only, with one bounded Utilities directory for Apple's text tools.
      for (final root in [
        if (_home.isNotEmpty) '$_home/Applications',
        '/Applications',
        '/System/Applications',
        '/Applications/Utilities',
      ]) {
        for (final path in _entries(root).take(512)) {
          if (!path.endsWith('.app')) continue;
          final plist = await _plist(path);
          if (plist != null && (plist.contains('<key>CFBundleDocumentTypes</key>') || _macCli(path) != null)) {
            await add(path);
          }
        }
      }
    } else {
      final mimes = {_mime(fileName), 'text/plain'};
      for (final path in _mimeFiles) {
        final text = _text(path);
        if (text == null) continue;
        for (final section in ['Default Applications', 'Added Associations']) {
          final associations = _section(text, section);
          for (final mime in mimes) {
            for (final id in (associations[mime] ?? '').split(';')) {
              final desktop = _desktopPath(id);
              if (desktop != null) await add(desktop);
              if (found.length >= 128) return found;
            }
          }
        }
      }
      final ids = <String>{};
      var scanned = 0;
      for (final root in _dataRoots) {
        for (final path in _entries('$root/applications').take(2048)) {
          if (++scanned > 2048) break;
          if (!path.endsWith('.desktop') || !ids.add(baseName(path))) continue;
          // An earlier XDG directory shadows a system entry even when its metadata disables it.
          if (_desktopPath(baseName(path)) != path) continue;
          final text = _text(path);
          if (text == null) continue;
          final types = (_section(text, 'Desktop Entry')['MimeType'] ?? '').split(';');
          if (mimes.any(types.contains)) await add(path);
          if (found.length >= 128) return found;
        }
      }
    }
    return found;
  }

  String? _macCli(String app) {
    final name = baseName(app).toLowerCase();
    final relative = switch (name) {
      'visual studio code.app' => 'Resources/app/bin/code',
      'visual studio code - insiders.app' => 'Resources/app/bin/code-insiders',
      'vscodium.app' => 'Resources/app/bin/codium',
      'cursor.app' => 'Resources/app/bin/cursor',
      'windsurf.app' => 'Resources/app/bin/windsurf',
      'antigravity.app' => 'Resources/app/bin/antigravity',
      'sublime text.app' => 'SharedSupport/bin/subl',
      _ => null,
    };
    final path = relative == null ? null : '$app/Contents/$relative';
    return path != null && _executable(path) ? path : null;
  }

  static bool _waits(String executable) => const {
    'code',
    'code-insiders',
    'codium',
    'vscodium',
    'cursor',
    'windsurf',
    'antigravity',
    'subl',
    'sublime_text',
    'gedit',
    'mate',
  }.contains(baseName(executable).toLowerCase());

  Future<LaunchRecipe?> recipe(String selected, String path) async {
    final app = await program(selected);
    if (app == null || !_absolute(path)) return null;
    if (mac && selected.endsWith('.app')) {
      final cli = _macCli(selected);
      return cli != null
          ? LaunchRecipe(cli, ['--wait', '--', path], const {}, true)
          : LaunchRecipe('/usr/bin/open', ['-a', selected, path]);
    }
    var executable = selected, arguments = <String>[];
    if (selected.endsWith('.desktop')) {
      final desktop = _desktop(selected);
      if (desktop == null) return null;
      executable = desktop.executable;
      var inserted = false;
      for (final token in desktop.arguments) {
        switch (token) {
          case '%f' || '%F':
            arguments.add(path);
            inserted = true;
          case '%u' || '%U':
            arguments.add(Uri.file(path).toString());
            inserted = true;
          case '%c':
            arguments.add(desktop.name);
          case '%k':
            arguments.add(selected);
          case '%i':
            break;
          default:
            final literal = token.replaceAll('%%', '\u0000');
            if (literal.contains('%')) return null;
            arguments.add(literal.replaceAll('\u0000', '%'));
        }
      }
      if (!inserted) arguments.add(path);
    } else {
      arguments = [path];
    }
    if (_waits(executable)) return LaunchRecipe(executable, ['--wait', '--', path], const {}, true);
    if (baseName(executable) == 'kate') return LaunchRecipe(executable, ['--block', '--', path], const {}, true);
    return LaunchRecipe(executable, arguments);
  }
}

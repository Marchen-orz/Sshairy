import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart' as selector;
import 'package:yaml/yaml.dart';

import '../domain/host_import.dart';
import '../domain/ssh_config.dart';
import 'finalshell_locations.dart';
import 'ssh_config_files.dart';

/// Hosts read from one source, not yet planned.
class ImportRead {
  const ImportRead(this.name, this.format, this.config, {this._path});

  final String name;
  final ImportFormat format;
  final SshConfig config;
  final String? _path;
  String get path => _path ?? name;
}

/// Reads other programs' session stores and files (docs/HOST_IMPORT.md): only text and PuTTY's registry key,
/// within the size limits; nothing is executed but `reg.exe query` with fixed arguments.
class HostImportFiles {
  const HostImportFiles({
    this.finalShellLocations = const FinalShellLocations(),
    this.environment,
    this.operatingSystem,
  });

  final FinalShellLocations finalShellLocations;
  final Map<String, String>? environment;
  final String? operatingSystem;

  bool get _windows => (operatingSystem ?? Platform.operatingSystem) == 'windows';
  String get _home => (_windows ? _env('USERPROFILE') : _env('HOME')) ?? _env('HOME') ?? '';
  String get _user => (_windows ? _env('USERNAME') : _env('USER')) ?? '';
  String? _env(String name) => (environment ?? Platform.environment)[name];

  /// Session stores kept in a folder of many files rather than one.
  static const folders = {ImportFormat.securecrt, ImportFormat.xshell, ImportFormat.finalshell};

  /// Where each program keeps its sessions by default, in the order to try.
  List<String> defaults(ImportFormat format) {
    final home = _home, appData = _env('APPDATA');
    String join(String a, String b) => '$a/${b.replaceAll(r'\', '/')}';
    return switch (format) {
      ImportFormat.openssh => [join(join(home, '.ssh'), 'config')],
      ImportFormat.putty => [
        if (!_windows) ...[
          if (_env('PUTTYDIR') case final root?) join(root, 'sessions'),
          join(home, '.putty/sessions'),
          join(_env('XDG_CONFIG_HOME') ?? join(home, '.config'), 'putty/sessions'),
        ],
      ],
      ImportFormat.mobaxterm => [if (appData != null) join(join(appData, 'MobaXterm'), 'MobaXterm.ini')],
      ImportFormat.securecrt => [
        if (_windows && appData != null) join(appData, r'VanDyke\Config\Sessions'),
        if (!_windows) ...[
          join(home, 'Library/Application Support/VanDyke/SecureCRT/Config/Sessions'),
          join(home, '.vandyke/SecureCRT/Config/Sessions'),
        ],
      ],
      ImportFormat.xshell => [
        for (final docs in [join(home, 'Documents'), join(home, r'OneDrive\Documents'), join(home, r'OneDrive\文档')])
          ..._xshell(join(docs, 'NetSarang Computer')),
      ],
      ImportFormat.finalshell => finalShellLocations.defaults,
      ImportFormat.tabby => [
        if (appData != null) join(appData, r'tabby\config.yaml'),
        join(home, 'Library/Application Support/tabby/config.yaml'),
        join(home, '.config/tabby/config.yaml'),
      ],
      ImportFormat.csv => const [],
    };
  }

  /// `NetSarang Computer/<version>/Xshell/Sessions`, newest version first.
  List<String> _xshell(String root) {
    final dir = Directory(root);
    if (!dir.existsSync()) return const [];
    final versions = dir.listSync().whereType<Directory>().map((d) => d.path).toList()..sort();
    return [for (final v in versions.reversed) '$v${Platform.pathSeparator}Xshell${Platform.pathSeparator}Sessions'];
  }

  /// Whether PuTTY's registry key can be read here.
  bool get hasRegistry => _windows;

  String? found(ImportFormat format) {
    for (final path in defaults(format)) {
      if (FileSystemEntity.typeSync(path) != FileSystemEntityType.notFound) return path;
    }
    return null;
  }

  /// Reads [format] from its default place; null when it is not there.
  Future<ImportRead?> readDefault(ImportFormat format) async {
    if (format == ImportFormat.putty && hasRegistry) return _registry();
    final paths = format == ImportFormat.finalshell ? await finalShellLocations.candidates() : defaults(format);
    ImportRead? unreadable;
    for (final path in paths) {
      try {
        if (FileSystemEntity.typeSync(path, followLinks: false) == FileSystemEntityType.notFound) continue;
        final result = await read(format, path);
        if (result.config.hosts.isNotEmpty) return result;
        if (result.config.issues.isNotEmpty) unreadable ??= result;
      } on FileSystemException {
        continue;
      }
    }
    return unreadable;
  }

  /// Asks for a file, or a folder for [folders], and reads it as [format]; null [format] sniffs the file.
  Future<ImportRead?> pick([ImportFormat? format]) async {
    if (format != null && (folders.contains(format) || (format == ImportFormat.putty && !hasRegistry))) {
      final dir = await selector.getDirectoryPath(initialDirectory: _parentOf(defaults(format).firstOrNull));
      return dir == null ? null : read(format, dir);
    }
    final groups = switch (format) {
      ImportFormat.csv => const [
        selector.XTypeGroup(label: 'CSV', extensions: ['csv']),
      ],
      ImportFormat.putty => const [
        selector.XTypeGroup(label: 'REG', extensions: ['reg']),
      ],
      ImportFormat.tabby => const [
        selector.XTypeGroup(label: 'YAML', extensions: ['yaml', 'yml']),
      ],
      _ => const <selector.XTypeGroup>[],
    };
    final initial = format == null ? null : _parentOf(defaults(format).firstOrNull);
    final file = await selector.openFile(acceptedTypeGroups: groups, initialDirectory: initial);
    return file == null ? null : read(format, file.path);
  }

  String? _parentOf(String? path) {
    if (path == null) return null;
    final parent = File(path).parent;
    return parent.existsSync() ? parent.path : null;
  }

  /// [path] is a file, or a folder of session files; a null [format] is sniffed.
  Future<ImportRead> read(ImportFormat? format, String path) async {
    final name = path.split(RegExp(r'[/\\]')).where((p) => p.isNotEmpty).lastOrNull ?? path;
    if (FileSystemEntity.isDirectorySync(path)) {
      final files = await _folder(path, putty: format == ImportFormat.putty);
      final f = format ?? _sniffFolder(files);
      final config = switch (f) {
        ImportFormat.putty => _puttyFiles(files),
        ImportFormat.securecrt => parseSecureCrt(files, defaultUser: _user),
        ImportFormat.xshell => parseXshell(files, defaultUser: _user),
        _ => parseFinalShell([
          for (final file in files)
            if (file.name.toLowerCase().endsWith('_connect_config.json')) file,
        ], defaultUser: _user),
      };
      return ImportRead(name, f, config, path: Directory(path).absolute.path);
    }
    if (format == ImportFormat.openssh) {
      return ImportRead(name, ImportFormat.openssh, await _openssh(path), path: File(path).absolute.path);
    }
    final ImportText file;
    try {
      file = ImportText(name, decodeImportText(await _bytes(File(path))));
    } on FileSystemException {
      return ImportRead(name, format ?? ImportFormat.openssh, _unreadable(name), path: File(path).absolute.path);
    }
    final f = format ?? sniffImport(name, file.text) ?? ImportFormat.openssh;
    final config = switch (f) {
      ImportFormat.openssh => await _openssh(path),
      ImportFormat.putty =>
        file.text.trimLeft().startsWith('Windows Registry Editor') ||
                file.text.contains(r'\SimonTatham\PuTTY\Sessions\')
            ? parsePuttyReg(file, defaultUser: _user)
            : _puttyFiles([file]),
      ImportFormat.mobaxterm => parseMobaXterm(file, defaultUser: _user),
      ImportFormat.securecrt => parseSecureCrt([file], defaultUser: _user),
      ImportFormat.xshell => parseXshell([file], defaultUser: _user),
      ImportFormat.finalshell => parseFinalShell([file], defaultUser: _user),
      ImportFormat.tabby => parseTabby(_yaml(file.text), name, defaultUser: _user),
      ImportFormat.csv => parseCsvHosts(file, defaultUser: _user),
    };
    return ImportRead(name, f, config, path: File(path).absolute.path);
  }

  SshConfig _unreadable(String name) =>
      SshConfig(const [], [SshConfigIssue(SshConfigIssueKind.unreadable, name, 0)], complete: false);

  Future<SshConfig> _openssh(String path) async {
    final file = await readSshConfig(path);
    return parseSshConfig(file.input, defaultUser: file.username, home: file.home);
  }

  Future<ImportRead?> _registry() async {
    final reg = '${_env('SystemRoot') ?? r'C:\Windows'}\\System32\\reg.exe';
    final ProcessResult result;
    try {
      result = await Process.run(reg, [
        'query',
        r'HKCU\Software\SimonTatham\PuTTY\Sessions',
        '/s',
      ], stdoutEncoding: systemEncoding);
    } on ProcessException {
      return null;
    }
    if (result.exitCode != 0) return null;
    final output = result.stdout as String;
    return ImportRead(
      'PuTTY',
      ImportFormat.putty,
      parsePuttyQuery(output, defaultUser: _user),
      path: r'HKCU\Software\SimonTatham\PuTTY\Sessions',
    );
  }

  // Unix PuTTY stores one flat key=value file per percent-encoded session name. Feed only its public connection
  // fields through the same parser as registry exports, so protocol/key validation and host limits remain shared.
  SshConfig _puttyFiles(List<ImportText> files) {
    final text = StringBuffer('Windows Registry Editor Version 5.00\n');
    for (final file in files) {
      final name = file.name.replaceAllMapped(RegExp(r'[\[\]\\\r\n]'), (m) => Uri.encodeComponent(m[0]!));
      text.writeln('[HKEY_CURRENT_USER\\Software\\SimonTatham\\PuTTY\\Sessions\\$name]');
      for (final raw in const LineSplitter().convert(file.text)) {
        final equal = raw.indexOf('=');
        if (equal < 1) continue;
        final key = raw.substring(0, equal);
        if (!const {'HostName', 'UserName', 'PortNumber', 'Protocol', 'PublicKeyFile'}.contains(key)) continue;
        final value = raw.substring(equal + 1).replaceAll('\\', '\\\\').replaceAll('"', '\\"');
        text.writeln('"$key"="$value"');
      }
    }
    return parsePuttyReg(ImportText('PuTTY', text.toString()), defaultUser: _user);
  }

  ImportFormat _sniffFolder(List<ImportText> files) {
    bool any(String suffix) => files.any((f) => f.name.toLowerCase().endsWith(suffix));
    if (any('.xsh')) return ImportFormat.xshell;
    if (any('_connect_config.json')) return ImportFormat.finalshell;
    return ImportFormat.securecrt;
  }

  /// Session files under [root], at most [importMaxDepth] deep, [importMaxFiles] files and [importMaxBytes].
  Future<List<ImportText>> _folder(String root, {bool putty = false}) async {
    final out = <ImportText>[];
    var total = 0;
    final base = Directory(root).absolute.path;
    Future<void> walk(Directory dir, int depth) async {
      if (depth > importMaxDepth) return;
      final List<FileSystemEntity> entries;
      try {
        entries = await dir.list(followLinks: false).toList();
      } on FileSystemException {
        return;
      }
      entries.sort((a, b) => a.path.compareTo(b.path));
      for (final e in entries) {
        if (out.length >= importMaxFiles || total >= importMaxBytes) return;
        if (e is Directory) {
          if (!putty) await walk(e, depth + 1);
          continue;
        }
        final lower = e.path.toLowerCase();
        if (e is! File || (!putty && !(lower.endsWith('.ini') || lower.endsWith('.xsh') || lower.endsWith('.json')))) {
          continue;
        }
        final relative = e.absolute.path.substring(base.length).replaceAll(r'\', '/').replaceFirst(RegExp('^/'), '');
        try {
          final bytes = await _bytes(e);
          total += bytes.length;
          out.add(ImportText(relative, decodeImportText(bytes)));
        } on FileSystemException {
          continue;
        }
      }
    }

    await walk(Directory(root), 0);
    return out;
  }

  Future<Uint8List> _bytes(File file) async {
    if (await file.length() > importMaxFileBytes) throw const FileSystemException('too large');
    return file.readAsBytes();
  }

  Object? _yaml(String text) {
    Object? plain(Object? node) => switch (node) {
      final YamlMap m => {for (final e in m.entries) '${e.key}': plain(e.value)},
      final YamlList l => [for (final v in l) plain(v)],
      final Map<Object?, Object?> m => {for (final e in m.entries) '${e.key}': plain(e.value)},
      final List<Object?> l => [for (final v in l) plain(v)],
      _ => node,
    };
    try {
      return plain(loadYaml(text));
    } on Object {
      return null;
    }
  }
}

/// Byte order marks first; then UTF-8, and the system code page (GBK on Chinese Windows) when that fails.
String decodeImportText(Uint8List bytes) {
  if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) return _utf16(bytes.sublist(2), little: true);
  if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) return _utf16(bytes.sublist(2), little: false);
  final start = bytes.length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF ? 3 : 0;
  try {
    return utf8.decode(bytes.sublist(start));
  } on FormatException {
    return systemEncoding.decode(bytes);
  }
}

String _utf16(Uint8List bytes, {required bool little}) {
  final units = <int>[
    for (var i = 0; i + 1 < bytes.length; i += 2) little ? bytes[i] | bytes[i + 1] << 8 : bytes[i] << 8 | bytes[i + 1],
  ];
  return String.fromCharCodes(units);
}

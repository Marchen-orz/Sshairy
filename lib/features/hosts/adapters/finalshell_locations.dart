import 'dart:convert';
import 'dart:io';

/// Known install locations and Windows install metadata; never scans drives or runs an installed executable.
class FinalShellLocations {
  const FinalShellLocations({this.environment, this.windows, this.registry});

  final Map<String, String>? environment;
  final bool? windows;
  final Future<String?> Function(List<String> arguments)? registry;

  Map<String, String> get _env => environment ?? Platform.environment;
  bool get _windows => windows ?? Platform.isWindows;

  List<String> get defaults {
    final env = _env;
    final home = env['USERPROFILE'] ?? env['HOME'] ?? '';
    return {
      if (home.isNotEmpty) '$home/.finalshell/conn',
      if (_windows) ...[
        for (final base in [env['LOCALAPPDATA'], env['APPDATA'], env['ProgramFiles'], env['ProgramFiles(x86)']])
          if (base != null && base.isNotEmpty) '$base/finalshell/conn',
        if (env['LOCALAPPDATA'] case final local?) '$local/Programs/FinalShell/conn',
        '${env['SystemDrive'] ?? 'C:'}/finalshell/conn',
        if (home.isNotEmpty) '$home/finalshell/conn',
      ] else ...[
        if (home.isNotEmpty) '$home/Library/FinalShell/conn',
        '/Applications/FinalShell.app/Contents/Java/conn',
        '/Applications/FinalShell.app/Contents/Resources/conn',
        '/opt/finalshell/conn',
        '/usr/lib/finalshell/conn',
      ],
    }.toList();
  }

  static const _appPaths = [
    r'HKCU\Software\Microsoft\Windows\CurrentVersion\App Paths\finalshell.exe',
    r'HKLM\Software\Microsoft\Windows\CurrentVersion\App Paths\finalshell.exe',
    r'HKLM\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\finalshell.exe',
  ];
  static const _uninstall = [
    r'HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall',
    r'HKLM\Software\Microsoft\Windows\CurrentVersion\Uninstall',
    r'HKLM\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
  ];

  Future<String?> _query(List<String> arguments) async {
    try {
      if (registry case final query?) return await query(arguments);
      final reg = '${_env['SystemRoot'] ?? r'C:\Windows'}/System32/reg.exe';
      final result = await Process.run(
        reg,
        arguments,
        stdoutEncoding: systemEncoding,
      ).timeout(const Duration(seconds: 3));
      return result.exitCode == 0 ? result.stdout as String : null;
    } on Object {
      return null;
    }
  }

  /// Registry values only add `<installation>/conn`, never arbitrary configuration search roots.
  Future<List<String>> candidates() async {
    final paths = {...defaults};
    if (!_windows) return paths.toList();
    void add(String? directory) {
      if (directory == null) return;
      final expanded = directory
          .replaceAllMapped(RegExp(r'%([^%]+)%'), (m) {
            return _env.entries.where((e) => e.key.toLowerCase() == m[1]!.toLowerCase()).firstOrNull?.value ?? m[0]!;
          })
          .replaceAll('\\', '/')
          .replaceAll(RegExp(r'^"|"$'), '')
          .replaceFirst(RegExp(r'/+$'), '');
      if (expanded.length > 4096 || expanded.contains('\u0000') || expanded.contains('%')) return;
      if (!RegExp(r'^(?:[a-zA-Z]:/|//)').hasMatch(expanded)) return;
      paths.add('$expanded/conn');
    }

    void addExecutable(String value) {
      final match = RegExp(r'^"?(.+[/\\]finalshell\.exe)"?(?:,-?\d+)?$', caseSensitive: false).firstMatch(value);
      if (match != null) add(match[1]!.replaceFirst(RegExp(r'[/\\][^/\\]+$'), ''));
    }

    for (final key in _appPaths) {
      final text = await _query(['query', key, '/ve']);
      for (final value in _values(text).values) {
        addExecutable(value);
      }
    }
    for (final root in _uninstall) {
      final matches = await _query(['query', root, '/s', '/f', 'FinalShell', '/d']);
      final prefix = '${root.replaceFirst('HKCU', 'HKEY_CURRENT_USER').replaceFirst('HKLM', 'HKEY_LOCAL_MACHINE')}\\';
      final keys = {
        for (final line in const LineSplitter().convert(matches ?? ''))
          if (line.trim().toLowerCase().startsWith(prefix.toLowerCase()) &&
              !line.trim().substring(prefix.length).contains('\\'))
            line.trim(),
      };
      for (final key in keys.take(16)) {
        final values = _values(await _query(['query', key]));
        if (!(values['displayname'] ?? '').toLowerCase().contains('finalshell')) continue;
        add(values['installlocation']);
        if (values['displayicon'] case final icon?) addExecutable(icon);
      }
    }
    return paths.toList();
  }
}

Map<String, String> _values(String? text) => {
  for (final line in const LineSplitter().convert(text ?? ''))
    if (RegExp(r'^\s+(.+?)\s+REG_(?:EXPAND_)?SZ\s+(.+?)\s*$').firstMatch(line) case final match?)
      match[1]!.toLowerCase(): match[2]!,
};

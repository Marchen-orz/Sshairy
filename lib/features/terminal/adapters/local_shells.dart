import 'dart:io';

import '../domain/terminal_target.dart';

/// Checks only explicit environment/installation paths; discovering a shell never executes it.
List<LocalShell> discoverLocalShells({
  Map<String, String>? environment,
  String? operatingSystem,
  bool Function(String path)? fileExists,
}) {
  final env = environment ?? Platform.environment;
  final os = operatingSystem ?? Platform.operatingSystem;
  final windows = os == 'windows';
  if (!windows && os != 'linux' && os != 'macos') return const [];
  final exists = fileExists ?? (path) => File(path).existsSync();
  String? variable(String name) {
    for (final e in env.entries) {
      if (windows ? e.key.toLowerCase() == name.toLowerCase() : e.key == name) return e.value;
    }
    return null;
  }

  String? normalize(String? path) {
    if (path == null || path.isEmpty || path.length > 4096) return null;
    var value = path.trim();
    if (value.startsWith('"') && value.endsWith('"')) value = value.substring(1, value.length - 1);
    if (!LocalShell.validExecutable(value)) return null;
    value = windows ? value.replaceAll('/', r'\') : value;
    // Environment paths must already be absolute. Never resolve an empty PATH entry against the app's cwd.
    final prefix = windows && value.startsWith(r'\\') ? r'\\' : '';
    if (prefix.isNotEmpty) value = value.substring(2);
    final parts = <String>[];
    for (final part in value.split(windows ? r'\' : '/')) {
      if (part.isEmpty || part == '.') continue;
      if (part == '..') {
        if (parts.length <= (windows ? 1 : 0)) return null;
        parts.removeLast();
      } else {
        parts.add(part);
      }
    }
    return windows ? '$prefix${parts.join(r'\')}' : '/${parts.join('/')}';
  }

  String join(String root, String relative) => '$root${windows ? r'\' : '/'}$relative';
  final found = <LocalShell>[], seen = <String>{};
  void add(LocalShellKind kind, String? path) {
    final normalized = normalize(path);
    if (normalized == null) return;
    final key = windows ? normalized.toLowerCase() : normalized;
    if (seen.contains(key)) return;
    try {
      if (!exists(normalized)) return;
    } on Object {
      return;
    }
    seen.add(key);
    found.add(LocalShell(kind: kind, executable: normalized));
  }

  final paths = (variable('PATH') ?? '')
      .split(windows ? ';' : ':')
      .take(256)
      .map(normalize)
      .whereType<String>()
      .toList();
  if (windows) {
    final root = normalize(variable('SystemRoot') ?? variable('WINDIR'));
    add(LocalShellKind.cmd, variable('COMSPEC'));
    if (root != null) {
      add(LocalShellKind.cmd, join(root, r'System32\cmd.exe'));
      add(LocalShellKind.powershell, join(root, r'System32\WindowsPowerShell\v1.0\powershell.exe'));
    }
    for (final path in paths) {
      add(LocalShellKind.pwsh, join(path, 'pwsh.exe'));
      add(LocalShellKind.powershell, join(path, 'powershell.exe'));
      add(LocalShellKind.cmd, join(path, 'cmd.exe'));
      // PATH often contains Git/cmd rather than Git/bin. Only accept its real bash executable.
      if (RegExp(r'\\Git\\(?:cmd|bin|usr\\bin)$', caseSensitive: false).hasMatch(path)) {
        final git = path.replaceFirst(RegExp(r'\\(?:cmd|bin|usr\\bin)$', caseSensitive: false), '');
        add(LocalShellKind.gitBash, join(git, r'bin\bash.exe'));
      }
      // A generic bash.exe on PATH can be the WSL launcher; only recognized Git installation paths qualify.
    }
    for (final key in ['ProgramW6432', 'ProgramFiles', 'ProgramFiles(x86)']) {
      final base = normalize(variable(key));
      if (base == null) continue;
      add(LocalShellKind.pwsh, join(base, r'PowerShell\7\pwsh.exe'));
      add(LocalShellKind.gitBash, join(base, r'Git\bin\bash.exe'));
    }
    final appData = normalize(variable('LOCALAPPDATA'));
    if (appData != null) add(LocalShellKind.gitBash, join(appData, r'Programs\Git\bin\bash.exe'));
  } else {
    LocalShellKind? kind(String path) => switch (path.split('/').last) {
      'bash' => LocalShellKind.bash,
      'zsh' => LocalShellKind.zsh,
      'fish' => LocalShellKind.fish,
      'sh' => LocalShellKind.sh,
      'pwsh' => LocalShellKind.pwsh,
      'dash' || 'ksh' || 'mksh' || 'csh' || 'tcsh' => LocalShellKind.unix,
      _ => null,
    };
    final preferred = normalize(variable('SHELL'));
    if (preferred != null) {
      final preferredKind = kind(preferred);
      if (preferredKind != null) add(preferredKind, preferred);
    }
    final roots = [...paths, '/bin', '/usr/bin', '/usr/local/bin', if (os == 'macos') '/opt/homebrew/bin'];
    for (final root in roots) {
      for (final name in ['zsh', 'bash', 'fish', 'sh', 'pwsh', 'ksh', 'dash', 'tcsh']) {
        add(kind(name)!, join(root, name));
      }
    }
  }
  return List.unmodifiable(found);
}

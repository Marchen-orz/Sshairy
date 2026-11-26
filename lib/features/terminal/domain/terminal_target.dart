import '../../../foundation/ids.dart';

/// A shell reference only; the inherited environment belongs to the running adapter, never the layout.
enum LocalShellKind {
  cmd,
  powershell,
  pwsh,
  gitBash,
  bash,
  zsh,
  fish,
  sh,
  unix;

  /// Shells that use `\` as a path separator rather than a POSIX escape character.
  bool get isWindowsShell => this == cmd || this == powershell || this == pwsh;
}

class LocalShell {
  const LocalShell({required this.kind, required this.executable});

  final LocalShellKind kind;
  final String executable;

  String get name => switch (kind) {
    LocalShellKind.cmd => 'CMD',
    LocalShellKind.powershell => 'Windows PowerShell',
    LocalShellKind.pwsh => 'PowerShell',
    LocalShellKind.gitBash => 'Git Bash',
    LocalShellKind.bash => 'Bash',
    LocalShellKind.zsh => 'Zsh',
    LocalShellKind.fish => 'Fish',
    LocalShellKind.sh => 'Shell',
    LocalShellKind.unix => executable.split('/').last,
  };

  List<String> get arguments => switch (kind) {
    LocalShellKind.powershell || LocalShellKind.pwsh => const ['-NoLogo'],
    LocalShellKind.gitBash || LocalShellKind.bash => const ['--login', '-i'],
    LocalShellKind.zsh => const ['-l', '-i'],
    LocalShellKind.fish || LocalShellKind.sh || LocalShellKind.unix => const ['-i'],
    LocalShellKind.cmd => const [],
  };

  bool get usesPosixSyntax => switch (kind) {
    LocalShellKind.gitBash || LocalShellKind.bash || LocalShellKind.zsh || LocalShellKind.sh => true,
    LocalShellKind.unix => const {'dash', 'ksh', 'mksh'}.contains(executable.split('/').last),
    _ => false,
  };

  /// [path] as one word this shell takes literally. CMD has no escape inside quotes, but Windows paths cannot
  /// contain `"`; PowerShell also closes single quotes on typographic ones.
  String quote(String path) => switch (kind) {
    LocalShellKind.cmd => '"$path"',
    LocalShellKind.powershell ||
    LocalShellKind.pwsh => "'${path.replaceAllMapped(RegExp("['‘-‛]"), (m) => '${m[0]}${m[0]}')}'",
    LocalShellKind.fish => "'${path.replaceAll(r'\', r'\\').replaceAll("'", r"\'")}'",
    _ => "'${path.replaceAll("'", r"'\''")}'",
  };

  static bool validExecutable(String value) =>
      value.isNotEmpty &&
      value.length <= 4096 &&
      !value.runes.any((r) => r < 32 || (r >= 127 && r <= 159)) &&
      (value.startsWith('/') || RegExp(r'^[A-Za-z]:[\\/]').hasMatch(value) || value.startsWith(r'\\'));

  Map<String, Object?> toJson() => {'kind': kind.name, 'executable': executable};

  factory LocalShell.fromJson(Map<String, Object?> json) {
    final kind = LocalShellKind.values.byName(json['kind'] as String);
    final executable = json['executable'] as String;
    if (!validExecutable(executable)) throw const FormatException('Invalid shell reference');
    return LocalShell(kind: kind, executable: executable);
  }

  @override
  bool operator ==(Object other) => other is LocalShell && other.kind == kind && other.executable == executable;
  @override
  int get hashCode => Object.hash(kind, executable);
}

sealed class TerminalTarget {
  const TerminalTarget();
}

final class SshTerminalTarget extends TerminalTarget {
  const SshTerminalTarget(this.hostId);
  final HostId hostId;
}

/// [directory] and [label] come from a saved local terminal (docs/MODULES.md §3); without them the shell starts in
/// the home directory under its own name.
final class LocalTerminalTarget extends TerminalTarget {
  const LocalTerminalTarget(this.shell, {this.directory, this.label});
  final LocalShell shell;
  final String? directory, label;

  Map<String, Object?> toJson() => {
    'type': 'local',
    'shell': shell.toJson(),
    if (directory != null) 'directory': directory,
    if (label != null) 'label': label,
  };

  factory LocalTerminalTarget.fromJson(Map<String, Object?> json) => LocalTerminalTarget(
    LocalShell.fromJson((json['shell'] as Map).cast()),
    directory: json['directory'] as String?,
    label: json['label'] as String?,
  );
}

enum LinkTerminalKind { mirror, proxy }

/// A terminal routed through a paired desktop via Sshairy Link: either a live mirror of a desktop session or a
/// desktop-proxied SSH / local shell connection whose private keys stay on the desktop.
final class LinkTerminalTarget extends TerminalTarget {
  const LinkTerminalTarget({
    required this.peerId,
    required this.peerName,
    required this.remoteId,
    required this.title,
    required this.targetLabel,
    required this.kind,
    this.isLocal = false,
    this.localShellKind,
  });

  final String peerId;
  final String peerName;
  final String remoteId;
  final String title;
  final String targetLabel;
  final LinkTerminalKind kind;
  final bool isLocal;
  final LocalShellKind? localShellKind;
}

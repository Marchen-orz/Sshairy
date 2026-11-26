import 'terminal_target.dart';

/// A local shell saved in the host library with the folder it starts in (docs/MODULES.md §3). An empty
/// [directory] starts in the home directory.
class LocalProfile {
  const LocalProfile({required this.id, required this.label, required this.shell, this.directory = ''});

  final String id, label, directory;
  final LocalShell shell;

  static final _control = RegExp(r'[\x00-\x1f\x7f]');

  LocalTerminalTarget get target =>
      LocalTerminalTarget(shell, directory: directory.isEmpty ? null : directory, label: label);

  void validate() {
    if (id.isEmpty ||
        label.trim().isEmpty ||
        label.length > 128 ||
        _control.hasMatch(label) ||
        directory.length > 4096 ||
        _control.hasMatch(directory) ||
        !LocalShell.validExecutable(shell.executable)) {
      throw ArgumentError('invalid local terminal');
    }
  }

  bool matches(String query) {
    final hay = '$label ${shell.name} $directory'.toLowerCase();
    return query.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).every(hay.contains);
  }

  factory LocalProfile.fromJson(Map<String, Object?> json) => LocalProfile(
    id: json['id'] as String,
    label: json['label'] as String,
    shell: LocalShell.fromJson((json['shell'] as Map).cast()),
    directory: json['directory'] as String? ?? '',
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'label': label,
    'shell': shell.toJson(),
    if (directory.isNotEmpty) 'directory': directory,
  };
}

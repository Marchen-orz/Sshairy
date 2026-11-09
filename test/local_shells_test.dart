import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/features/terminal/adapters/local_shells.dart';
import 'package:sshairy/features/terminal/api.dart';

void main() {
  test('Windows discovery uses absolute environment paths and real shell executables without executing', () {
    final checked = <String>[];
    final files = <String>{
      r'C:\Windows\System32\cmd.exe',
      r'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe',
      r'C:\Program Files\PowerShell\7\pwsh.exe',
      r'C:\Program Files\Git\bin\bash.exe',
    };
    final shells = discoverLocalShells(
      operatingSystem: 'windows',
      environment: {
        'ComSpec': r'C:\Windows\System32\cmd.exe',
        'SYSTEMROOT': r'C:\Windows',
        'Path': r';relative;C:\Windows\System32;C:\Program Files\PowerShell\7;C:\Program Files\Git\cmd',
        'ProgramFiles': r'C:\Program Files',
      },
      fileExists: (path) {
        checked.add(path);
        return files.contains(path);
      },
    );
    expect(shells.map((s) => s.kind), containsAll(LocalShellKind.values));
    expect(shells.map((s) => s.executable).toSet(), files);
    expect(shells.where((s) => s.kind == LocalShellKind.cmd), hasLength(1));
    expect(checked.every((p) => LocalShell.validExecutable(p)), isTrue);
    expect(checked.any((p) => p.contains('mintty') || p.contains('git-bash')), isFalse);
    expect(shells.last.name, 'Git Bash');
  });

  test('shell references reject relative paths and persist no environment or arbitrary arguments', () {
    const shell = LocalShell(kind: LocalShellKind.gitBash, executable: r'C:\Program Files\Git\bin\bash.exe');
    expect(LocalShell.fromJson(shell.toJson()), shell);
    expect(shell.toJson().keys, ['kind', 'executable']);
    expect(shell.arguments, ['--login', '-i']);
    expect(() => LocalShell.fromJson({'kind': 'cmd', 'executable': 'cmd.exe'}), throwsFormatException);
    expect(() => LocalShell.fromJson({'kind': 'cmd', 'executable': 'C:\\bad\n.exe'}), throwsFormatException);
  });

  test('unimplemented desktop PTY platforms offer no unusable shell entries', () {
    var checked = false;
    expect(
      discoverLocalShells(
        operatingSystem: 'linux',
        environment: {'SHELL': '/bin/bash'},
        fileExists: (_) {
          checked = true;
          return true;
        },
      ),
      isEmpty,
    );
    expect(checked, isFalse);
  });
}

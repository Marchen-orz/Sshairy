import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/features/hosts/adapters/finalshell_locations.dart';
import 'package:sshairy/features/hosts/adapters/host_import_files.dart';
import 'package:sshairy/features/hosts/domain/host_import.dart';

void main() {
  test('FinalShell known locations cover user, installed and app bundle stores', () {
    const locations = FinalShellLocations(
      windows: true,
      environment: {
        'USERPROFILE': 'C:/Users/test',
        'LOCALAPPDATA': 'C:/Users/test/AppData/Local',
        'APPDATA': 'C:/Users/test/AppData/Roaming',
        'ProgramFiles': 'C:/Program Files',
        'ProgramFiles(x86)': 'C:/Program Files (x86)',
        'SystemDrive': 'C:',
      },
    );
    expect(
      locations.defaults,
      containsAll([
        'C:/Users/test/AppData/Local/finalshell/conn',
        'C:/Users/test/AppData/Local/Programs/FinalShell/conn',
        'C:/Program Files/finalshell/conn',
        'C:/Program Files (x86)/finalshell/conn',
        'C:/finalshell/conn',
      ]),
    );
    const mac = FinalShellLocations(windows: false, environment: {'HOME': '/Users/test'});
    expect(
      mac.defaults,
      containsAll([
        '/Users/test/Library/FinalShell/conn',
        '/Users/test/.finalshell/conn',
        '/Applications/FinalShell.app/Contents/Java/conn',
      ]),
    );
  });

  test('FinalShell uses only App Paths and matched immediate uninstall keys, never commands', () async {
    const root = r'HKLM\Software\Microsoft\Windows\CurrentVersion\Uninstall';
    const install = r'HKEY_LOCAL_MACHINE\Software\Microsoft\Windows\CurrentVersion\Uninstall\{synthetic}';
    const nested = '$install\\child';
    final queries = <List<String>>[];
    final locations = FinalShellLocations(
      windows: true,
      environment: const {'LOCALAPPDATA': 'C:/Local'},
      registry: (args) async {
        queries.add(args);
        if (args.contains('/ve') && args[1].startsWith('HKCU')) {
          return '    (Default)    REG_SZ    "D:\\Portable\\FinalShell\\finalshell.exe"\n';
        }
        if (args[1] == root && args.contains('/f')) return '$install\n$nested\n';
        if (args[1] == install) {
          return '    DisplayName    REG_SZ    FinalShell 4.0\n'
              '    InstallLocation    REG_EXPAND_SZ    %LOCALAPPDATA%\\Programs\\FinalShell\n'
              '    DisplayIcon    REG_SZ    "E:\\FinalShell\\finalshell.exe",0\n'
              '    UninstallString    REG_SZ    ignored.exe --run-this\n';
        }
        return null;
      },
    );
    final paths = await locations.candidates();
    expect(
      paths,
      containsAll(['D:/Portable/FinalShell/conn', 'C:/Local/Programs/FinalShell/conn', 'E:/FinalShell/conn']),
    );
    expect(queries.every((args) => args.first == 'query'), isTrue);
    expect(queries.any((args) => args.contains(nested)), isFalse);
    expect(queries.any((args) => args.any((a) => a.contains('ignored.exe'))), isFalse);
    expect(paths.any((p) => p.contains('ignored.exe')), isFalse);
  });

  test('unrelated install names and executables with arguments do not become sources', () async {
    const key = r'HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Uninstall\other';
    final locations = FinalShellLocations(
      windows: true,
      environment: const {},
      registry: (args) async {
        if (args.contains('/ve')) return '    (Default)    REG_SZ    D:\\FinalShell\\finalshell.exe --command\n';
        if (args.contains('/f') && args[1].startsWith('HKCU')) return key;
        if (args[1] == key) {
          return '    DisplayName    REG_SZ    Another App\n    InstallLocation    REG_SZ    D:\\Other\n';
        }
        return null;
      },
    );
    expect(await locations.candidates(), isNot(contains('D:/Other/conn')));
    expect(await locations.candidates(), isNot(contains('D:/FinalShell/conn')));
  });

  test('a missing registry view does not hide default locations', () async {
    final locations = FinalShellLocations(
      windows: true,
      environment: const {'LOCALAPPDATA': 'C:/Local'},
      registry: (_) async => throw const ProcessException('reg.exe', [], 'missing'),
    );
    expect(await locations.candidates(), contains('C:/Local/finalshell/conn'));
  });

  test('default discovery skips an empty store and preserves the real selected source path', () async {
    final dir = Directory.systemTemp.createTempSync('sshairy-discovery-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final empty = Directory('${dir.path}/user/.finalshell/conn')..createSync(recursive: true);
    final populated = Directory('${dir.path}/local/finalshell/conn')..createSync(recursive: true);
    File('${populated.path}/one_connect_config.json').writeAsStringSync(
      jsonEncode({
        'name': 'synthetic',
        'host': 'example.invalid',
        'user_name': 'test',
        'password': 'unsupported-synthetic-encoding',
      }),
    );
    final files = HostImportFiles(
      finalShellLocations: FinalShellLocations(
        windows: true,
        environment: {'USERPROFILE': empty.parent.parent.path, 'LOCALAPPDATA': '${dir.path}/local'},
        registry: (_) async => null,
      ),
    );
    final read = await files.readDefault(ImportFormat.finalshell);
    expect(read, isNotNull);
    expect(read!.config.hosts.single.address, 'example.invalid');
    expect(read.path.replaceAll('\\', '/'), populated.absolute.path.replaceAll('\\', '/'));
    expect(read.name, 'conn');
  });
}

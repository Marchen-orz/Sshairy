import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/features/files/adapters/open_with.dart';
import 'package:sshairy/features/files/application/open_with.dart';
import 'package:sshairy/features/files/domain/open_with.dart';
import 'package:sshairy/foundation/data_dir.dart';
import 'package:sshairy/foundation/result.dart';

const _ext = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts';
const _appPaths = r'Software\Microsoft\Windows\CurrentVersion\App Paths';
const _environment = {'SystemRoot': r'C:\Windows'};

/// Answers from a table and records what was asked; nothing reads the machine's registry.
class _Registry implements Registry {
  _Registry({this.keys = const {}, this.values = const {}});

  final Map<String, RegistryKey> keys;

  /// `path` for the unnamed value, `path|name` for a named one.
  final Map<String, String> values;
  final queried = <String>[];

  @override
  Future<RegistryKey?> key(String path) async {
    queried.add(path);
    return keys[path];
  }

  @override
  Future<String?> value(String path, [String? name]) async {
    queried.add(path);
    return values[name == null ? path : '$path|$name'];
  }
}

RegistryKey _key({Map<String, String> values = const {}, List<String> subkeys = const []}) =>
    RegistryKey({for (final e in values.entries) e.key: (type: 'REG_SZ', data: e.value)}, subkeys);

WindowsApps _windows(_Registry registry, Set<String> files, {List<String> Function(String)? directories}) =>
    WindowsApps(
      registry,
      environment: _environment,
      fileExists: (path) => files.contains(path.toLowerCase()),
      subdirectories: directories ?? (_) => const [],
    );

/// A machine whose .txt opens in Notepad (by file type) with Visual Studio Code and an unusable entry also offered.
_Registry _machine() => _Registry(
  keys: {
    '$_ext\\.txt\\OpenWithList': _key(values: {'a': 'notepad.exe', 'b': 'Code.exe', 'MRUList': 'ba'}),
    '$_ext\\.txt\\OpenWithProgids': _key(values: {'txtfile': ''}),
    r'HKCR\.txt\OpenWithList': _key(subkeys: ['Obscure.exe']),
  },
  values: {
    '$_ext\\.txt\\UserChoice|ProgId': 'txtfile',
    r'HKCR\.txt': 'txtfile',
    r'HKCR\txtfile\shell\open\command': r'%SystemRoot%\system32\NOTEPAD.EXE %1',
    r'HKCR\Applications\Code.exe\shell\open\command': r'"C:\Code\Code.exe" "%1"',
    r'HKCR\Applications\Code.exe|FriendlyAppName': 'Visual Studio Code',
    'HKLM\\$_appPaths\\notepad.exe': r'C:\Windows\System32\notepad.exe',
  },
);

const _installed = {r'c:\windows\system32\notepad.exe', r'c:\code\code.exe'};

void main() {
  group('file types', () {
    test('a type is the extension, or the whole name when there is none', () {
      expect(fileTypeKey('Notes.TXT'), 'ext:txt');
      expect(fileTypeKey('archive.tar.gz'), 'ext:gz');
      expect(fileTypeKey('Dockerfile'), 'name:dockerfile');
      expect(fileTypeKey('.bashrc'), 'name:.bashrc');
      expect(fileTypeKey('trailing.'), 'name:trailing.');
      expect(fileTypeLabel('ext:txt'), '.txt');
      expect(fileTypeLabel('name:dockerfile'), 'dockerfile');
    });

    test('types the system would run are told from ones it would show', () {
      for (final name in ['run.bat', 'x.PS1', 'a.sh', 'tool.exe', 'link.lnk', 'dev.reg', 'app.jar', 'setup.msi']) {
        expect(opensByRunning(name), isTrue, reason: name);
      }
      for (final name in ['a.txt', 'Dockerfile', 'script', 'notes.md', 'data.json', '.sh']) {
        expect(opensByRunning(name), isFalse, reason: name);
      }
    });
  });

  group('programs', () {
    test('the same program found twice is one entry, however its path is cased', () {
      expect(OpenWithApp.program(r'C:\A\Code.exe'), OpenWithApp.program(r'c:\a\code.exe'));
      expect(OpenWithApp.program(r'C:\A\Code.exe'), isNot(const OpenWithApp.system()));
    });

    test('names are readable without a lookup', () {
      expect(OpenWithApp.program(r'C:\x\Code.exe').name, 'Visual Studio Code');
      expect(OpenWithApp.program(r'C:\x\NOTEPAD.EXE').name, 'Notepad');
      expect(OpenWithApp.program(r'C:\x\notepad++.exe').name, 'Notepad++');
      expect(OpenWithApp.program(r'C:\x\WordPad.exe').name, 'WordPad');
      expect(OpenWithApp.program(r'C:\x\ed.exe', name: 'Mine').name, 'Mine');
    });

    test('only a name and an absolute path are stored, and only such a record is read back', () {
      final app = OpenWithApp.program(r'C:\Apps\ed.exe', name: 'Ed');
      expect(app.toJson(), {'name': 'Ed', 'executable': r'C:\Apps\ed.exe'});
      expect(OpenWithApp.tryFromJson(app.toJson()), app);
      expect(OpenWithApp.tryFromJson({'name': 'x', 'executable': 'ed.exe'}), isNull);
      expect(OpenWithApp.tryFromJson({'name': 'x', 'executable': 'C:\\a\u0001.exe'}), isNull);
      expect(OpenWithApp.tryFromJson({'name': 'x'}), isNull);
      expect(OpenWithApp.tryFromJson('C:\\a.exe'), isNull);
      expect(OpenWithApp.tryFromJson({'name': 'n' * 200, 'executable': r'C:\Apps\ed.exe'})?.name, 'Ed');
    });

    test('programs that start a command or script host are told apart', () {
      for (final name in [r'C:\Windows\System32\cmd.exe', r'C:\x\PowerShell.EXE', r'C:\Windows\explorer.exe']) {
        expect(isScriptHost(name), isTrue, reason: name);
      }
      expect(isScriptHost(r'C:\Code\Code.exe'), isFalse);
    });

    test('editors that can wait for a document are known by name', () {
      expect(editorFamily(r'C:\a\Code.exe'), EditorFamily.electron);
      expect(editorFamily(r'C:\a\Code - Insiders.exe'), EditorFamily.electron);
      expect(editorFamily(r'C:\a\Cursor.exe'), EditorFamily.electron);
      expect(editorFamily(r'C:\a\sublime_text.exe'), EditorFamily.sublime);
      expect(editorFamily(r'C:\a\notepad.exe'), isNull);
    });
  });

  group('commandProgram', () {
    test('takes the program of a quoted command and drops its arguments', () {
      expect(
        commandProgram(r'"C:\Program Files\Notepad++\notepad++.exe" "%1"'),
        r'C:\Program Files\Notepad++\notepad++.exe',
      );
    });

    test('expands variables it is given and leaves unknown ones unresolved', () {
      expect(
        commandProgram(r'%SystemRoot%\system32\NOTEPAD.EXE %1', environment: _environment),
        r'C:\Windows\system32\NOTEPAD.EXE',
      );
      expect(commandProgram(r'%systemroot%\notepad.exe %1', environment: _environment), r'C:\Windows\notepad.exe');
      expect(commandProgram(r'%NOPE%\a.exe %1', environment: _environment), isNull);
    });

    test('finds the end of an unquoted path that has spaces', () {
      expect(commandProgram(r'C:\Program Files\Foo\foo.exe %1'), r'C:\Program Files\Foo\foo.exe');
    });

    test('is null when the command is not a plain program', () {
      expect(commandProgram(r'"%1" %*'), isNull);
      expect(commandProgram(r'"C:\Windows\System32\cmd.exe" /c "%1"'), isNull);
      expect(commandProgram(r'"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" -File "%1"'), isNull);
      expect(commandProgram(r'rundll32.exe shell32.dll,OpenAs_RunDLL %1'), isNull);
      expect(commandProgram(r'notepad.exe "%1"'), isNull);
      expect(commandProgram(r'"C:\a\b.bat" "%1"'), isNull);
      expect(commandProgram(''), isNull);
    });
  });

  group('parseRegistryQuery', () {
    test('reads values with their types and the names of subkeys, in either line ending', () {
      const lines = [
        r'HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\.txt\OpenWithList',
        '    a    REG_SZ    notepad.exe',
        '    b    REG_SZ    Code.exe',
        '    MRUList    REG_SZ    ba',
        '    Count    REG_DWORD    0x2',
        '    Empty    REG_SZ',
        '',
        r'HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\.txt\OpenWithList\Child',
        '',
      ];
      for (final newline in ['\n', '\r\n']) {
        final key = parseRegistryQuery(lines.join(newline));
        expect(key.values['a'], (type: 'REG_SZ', data: 'notepad.exe'));
        expect(key.values['MRUList']?.data, 'ba');
        expect(key.values['Count'], (type: 'REG_DWORD', data: '0x2'));
        expect(key.values['Empty']?.data, '');
        expect(key.subkeys, ['Child']);
      }
    });

    test('keeps spaces inside data and reads the unnamed value whatever its localised name', () {
      final key = parseRegistryQuery(
        'HKEY_CLASSES_ROOT\\txtfile\\shell\\open\\command\r\n'
        '    (Default)    REG_EXPAND_SZ    C:\\Program Files\\A  B\\ed.exe %1\r\n',
      );
      expect(key.values.values.single.data, r'C:\Program Files\A  B\ed.exe %1');
      final localised = parseRegistryQuery('HKEY_CLASSES_ROOT\\.txt\r\n    (默认)    REG_SZ    txtfile\r\n');
      expect(localised.values.values.single.data, 'txtfile');
    });

    test('a key with nothing in it has nothing', () {
      final key = parseRegistryQuery('\r\nHKEY_CLASSES_ROOT\\.none\r\n\r\n');
      expect(key.values, isEmpty);
      expect(key.subkeys, isEmpty);
    });
  });

  group('EditorApps', () {
    final ed = OpenWithApp.program(r'C:\Apps\ed.exe', name: 'Ed');

    test('a choice follows the file type and the system association clears it', () {
      var apps = const EditorApps().withDefault('a.txt', ed);
      expect(apps.forFile('Other.TXT'), ed);
      expect(apps.forFile('a.md'), isNull);
      expect(apps.forFile('Dockerfile'), isNull);
      apps = apps.withDefault('Dockerfile', ed);
      expect(apps.forFile('dockerfile'), ed);
      apps = apps.withDefault('b.txt', const OpenWithApp.system());
      expect(apps.forFile('a.txt'), isNull);
      apps = apps.withDefault('x.txt', ed).withDefault('y.txt', null);
      expect(apps.forFile('a.txt'), isNull);
      expect(apps.forFile('z.dockerfile'), isNull);
    });

    test('survives its stored form', () {
      final apps = const EditorApps().withDefault('a.txt', ed).withDefault('Makefile', ed);
      final back = EditorApps.fromJson(jsonDecode(jsonEncode(apps.toJson())) as Map<String, dynamic>);
      expect(back.forFile('b.txt'), ed);
      expect(back.forFile('makefile')?.name, 'Ed');
      expect(back.forFile('a.md'), isNull);
    });

    test('records that no longer read as a program are left out, not fatal', () {
      final apps = EditorApps.fromJson({
        'types': {
          'ext:txt': {'name': 'x', 'executable': 'relative.exe'},
          'ext:md': {'name': 'Ed', 'executable': r'C:\Apps\ed.exe'},
          'bad key': {'name': 'Ed', 'executable': r'C:\Apps\ed.exe'},
          'ext:log': 5,
        },
      });
      expect(apps.forFile('a.txt'), isNull);
      expect(apps.forFile('a.md'), ed);
      expect(apps.forFile('a.log'), isNull);
      expect(EditorApps.fromJson({'types': 3}).isEmpty, isTrue);
    });

    test('the stored document is checked before it is written or read', () {
      EditorApps.validate({
        'types': {'ext:txt': <String, Object?>{}},
      });
      expect(() => EditorApps.validate({'types': 3}), throwsFormatException);
      expect(
        () => EditorApps.validate({
          'types': {'txt': <String, Object?>{}},
        }),
        throwsFormatException,
      );
      expect(() => EditorApps.validate({'schemaVersion': 1}), throwsFormatException);
    });

    test('keeps the newest 256 types', () {
      var apps = const EditorApps();
      for (var i = 0; i < 300; i++) {
        apps = apps.withDefault('f.t$i', ed);
      }
      expect(apps.forFile('f.t0'), isNull);
      expect(apps.forFile('f.t43'), isNull);
      expect(apps.forFile('f.t44'), ed);
      expect(apps.forFile('f.t299'), ed);
    });

    test('a name the stored form cannot hold is not kept, so later saves still work', () {
      final apps = const EditorApps().withDefault('a.t\u0001x', ed).withDefault('a.txt', ed);
      expect(apps.forFile('a.t\u0001x'), isNull);
      expect(apps.forFile('a.txt'), ed);
      EditorApps.validate(apps.toJson().cast<String, dynamic>());
    });
  });

  group('WindowsApps.find', () {
    test('lists the type\'s own choice first, then the recently used programs that exist', () async {
      final apps = await _windows(_machine(), _installed).find('notes.txt');
      expect([for (final app in apps) app.name], ['Notepad', 'Visual Studio Code']);
      expect(apps.first.executable, r'C:\Windows\system32\NOTEPAD.EXE');
      expect(apps.last.executable, r'C:\Code\Code.exe');
    });

    test('leaves out programs that are gone, and never lists the system or Store apps', () async {
      final apps = await _windows(_machine(), {r'c:\windows\system32\notepad.exe'}).find('notes.txt');
      expect([for (final app in apps) app.name], ['Notepad']);
      expect(apps.any((app) => app.isSystem), isFalse);

      final store = _Registry(
        values: {r'HKCR\.txt': 'AppX1234', r'HKCR\Applications\App!Id.exe\shell\open\command': r'"C:\a\a.exe" "%1"'},
        keys: {
          '$_ext\\.txt\\OpenWithList': _key(values: {'a': r'App!Id.exe', 'MRUList': 'a'}),
        },
      );
      expect(await _windows(store, {r'c:\a\a.exe'}).find('x.txt'), isEmpty);
    });

    test('programs of text files are offered for other types, after the type\'s own', () async {
      final registry = _machine();
      registry.values[r'HKCR\.md'] = 'Typora.md';
      registry.values[r'HKCR\Typora.md\shell\open\command'] = r'"C:\Typora\Typora.exe" "%1"';
      final apps = await _windows(registry, {..._installed, r'c:\typora\typora.exe'}).find('readme.md');
      expect([for (final app in apps) app.name], ['Typora', 'Notepad', 'Visual Studio Code']);
      expect(
        [for (final app in await _windows(_machine(), _installed).find('Dockerfile')) app.name],
        ['Notepad', 'Visual Studio Code'],
      );
    });

    test('script hosts named by an association are not offered', () async {
      final registry = _Registry(
        values: {r'HKCR\.txt': 'weird', r'HKCR\weird\shell\open\command': r'"C:\Windows\System32\cmd.exe" /c "%1"'},
      );
      expect(await _windows(registry, {r'c:\windows\system32\cmd.exe'}).find('a.txt'), isEmpty);
    });
  });

  group('WindowsApps.associated', () {
    test('a text file opens with the program its type opens with', () async {
      final windows = _windows(_machine(), _installed);
      expect(await windows.associated('notes.txt'), r'C:\Windows\system32\NOTEPAD.EXE');
    });

    test('a file the system would run is edited through its edit command and never its open command', () async {
      final registry = _Registry(
        values: {
          r'HKCR\.bat': 'batfile',
          r'HKCR\batfile\shell\open\command': r'"%1" %*',
          r'HKCR\batfile\shell\edit\command': r'%SystemRoot%\System32\NOTEPAD.EXE %1',
        },
      );
      final windows = _windows(registry, {r'c:\windows\system32\notepad.exe'});
      expect(await windows.associated('run.bat'), r'C:\Windows\System32\NOTEPAD.EXE');
      expect(registry.queried.any((path) => path.endsWith(r'\shell\open\command')), isFalse);
    });

    test('a file the system would run falls back to Notepad, or to nothing', () async {
      final bare = _Registry(values: {r'HKCR\.ps1': 'Microsoft.PowerShellScript.1'});
      expect(await _windows(bare, {r'c:\windows\system32\notepad.exe'}).associated('go.ps1'), contains('notepad.exe'));
      expect(await _windows(bare, const {}).associated('go.ps1'), isNull);
    });

    test('an association that is not a plain program is for the system to start', () async {
      final store = _Registry(values: {r'HKCR\.jpg': 'AppX43hnxtbyyps62jhe9sqpdzxn1790zetc'});
      expect(await _windows(store, const {}).associated('a.jpg'), isNull);
      final shell = _Registry(
        values: {
          r'HKCR\.jpg': 'jpgfile',
          r'HKCR\jpgfile\shell\open\command':
              r'"C:\Windows\System32\rundll32.exe" "C:\x\shimgvw.dll",ImageView_Fullscreen %1',
        },
      );
      expect(await _windows(shell, {r'c:\windows\system32\rundll32.exe'}).associated('a.jpg'), isNull);
    });
  });

  group('WindowsApps.recipe', () {
    const code = r'C:\Users\u\AppData\Local\Programs\Microsoft VS Code\Code.exe';
    const root = r'C:\Users\u\AppData\Local\Programs\Microsoft VS Code\';
    const path = r'C:\data\edits\1\a.txt';

    test('Visual Studio Code is started through its own command line so that it waits', () {
      final recipe = _windows(_Registry(), {'${root}resources\\app\\out\\cli.js'.toLowerCase()}).recipe(code, path);
      expect(recipe.executable, code);
      expect(recipe.arguments, ['${root}resources\\app\\out\\cli.js', '--wait', '--', path]);
      expect(recipe.environment, {'ELECTRON_RUN_AS_NODE': '1', 'VSCODE_DEV': ''});
    });

    test('a build folder holds the command line in current installs, the newest one winning', () {
      final windows = _windows(
        _Registry(),
        {
          '${root}old11111\\resources\\app\\out\\cli.js'.toLowerCase(),
          '${root}new22222\\resources\\app\\out\\cli.js'.toLowerCase(),
        },
        directories: (directory) {
          expect(directory, root);
          return ['new22222', 'old11111'];
        },
      );
      expect(windows.recipe(code, path).arguments.first, '${root}new22222\\resources\\app\\out\\cli.js');

      final onlyOld = _windows(_Registry(), {
        '${root}old11111\\resources\\app\\out\\cli.js'.toLowerCase(),
      }, directories: (_) => ['new22222', 'old11111']);
      expect(onlyOld.recipe(code, path).arguments.first, '${root}old11111\\resources\\app\\out\\cli.js');
    });

    test('an editor whose waiting command cannot be found just gets the file', () {
      final recipe = _windows(_Registry(), const {}).recipe(code, path);
      expect(recipe.executable, code);
      expect(recipe.arguments, [path]);
      expect(recipe.environment, isEmpty);
      expect(recipe.waitsForDocument, isFalse);
    });

    test('Sublime Text waits through subl.exe beside it', () {
      const sublime = r'C:\Program Files\Sublime Text\sublime_text.exe';
      final waiting = _windows(_Registry(), {r'c:\program files\sublime text\subl.exe'}).recipe(sublime, path);
      expect(waiting.executable, r'C:\Program Files\Sublime Text\subl.exe');
      expect(waiting.arguments, ['--wait', '--', path]);
      expect(waiting.waitsForDocument, isTrue);
      expect(_windows(_Registry(), const {}).recipe(sublime, path).arguments, [path]);
    });

    test('any other program gets the file and nothing else', () {
      final recipe = _windows(_Registry(), const {}).recipe(r'C:\Windows\System32\notepad.exe', path);
      expect(recipe.arguments, [path]);
      expect(recipe.environment, isEmpty);
      expect(recipe.waitsForDocument, isFalse);
    });
  });

  group('PlatformEditorLauncher', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('sshairy-launch-'));
    tearDown(() => dir.deleteSync(recursive: true));

    String at(String name) => '${dir.path}${Platform.pathSeparator}$name';

    /// Knows no program at all, so any launch that succeeded would have started something unexpected.
    PlatformEditorLauncher launcher() => PlatformEditorLauncher(windows: _windows(_Registry(), const {}));

    test('programs can be chosen where there is a way to list them', () {
      expect(launcher().canChoose, isTrue);
    });

    test('a file that would be run is not opened when no editor is known for it', () async {
      final file = File(at('run.bat'))..writeAsStringSync('@rem nothing to run');
      expect((await launcher().launch(const OpenWithApp.system(), file.path)).started, isFalse);
    });

    test('a file that is gone is not launched', () async {
      expect((await launcher().launch(const OpenWithApp.system(), at('missing.txt'))).started, isFalse);
    });

    test('a program that starts scripts, or is not there, is refused as the editor', () async {
      final file = File(at('note.txt'))..writeAsStringSync('x');
      for (final app in [
        OpenWithApp.program(r'C:\Windows\System32\cmd.exe'),
        OpenWithApp.program(r'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'),
        OpenWithApp.program(at('gone.exe')),
        OpenWithApp.program(at('note.txt')),
      ]) {
        expect((await launcher().launch(app, file.path)).started, isFalse, reason: app.executable);
      }
    });

    test('only a program that exists, is an exe and is not a script host can be picked', () async {
      File(at('ed.exe')).writeAsStringSync('');
      File(at('note.txt')).writeAsStringSync('');
      final picked = await launcher().program(at('ed.exe'));
      expect(picked?.executable, at('ed.exe'));
      expect(picked?.name, 'Ed');
      expect(await launcher().program(at('note.txt')), isNull);
      expect(await launcher().program(at('gone.exe')), isNull);
      expect(await launcher().program('ed.exe'), isNull);
      expect(await launcher().program(r'C:\Windows\System32\cmd.exe'), isNull);
    });
  });

  group('editorAppsProvider', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('sshairy-apps-'));
    tearDown(() => dir.deleteSync(recursive: true));

    ProviderContainer open() {
      final container = ProviderContainer(overrides: [dataDirProvider.overrideWithValue(dir.path)]);
      addTearDown(container.dispose);
      return container;
    }

    File stored() => File('${dir.path}${Platform.pathSeparator}editor_apps.json');

    test('a choice applies at once, is kept for the next start and holds only a name and a path', () async {
      final first = open();
      final result = await first
          .read(editorAppsProvider.notifier)
          .setDefault('a.txt', OpenWithApp.program(r'C:\Apps\ed.exe', name: 'Ed'));
      expect(result, isA<Ok<void>>());
      expect(first.read(editorAppsProvider).forFile('b.TXT')?.executable, r'C:\Apps\ed.exe');

      final json = jsonDecode(stored().readAsStringSync()) as Map<String, dynamic>;
      expect(json['types'], {
        'ext:txt': {'name': 'Ed', 'executable': r'C:\Apps\ed.exe'},
      });

      final second = open();
      expect(second.read(editorAppsProvider).forFile('x.txt')?.name, 'Ed');
      await second.read(editorAppsProvider.notifier).setDefault('x.txt', null);
      expect(second.read(editorAppsProvider).forFile('x.txt'), isNull);
      expect(open().read(editorAppsProvider).forFile('x.txt'), isNull);
    });

    test('a damaged file is neither used nor overwritten, and the choice still applies until the app closes', () async {
      stored().writeAsStringSync('{ not json');
      final container = open();
      expect(container.read(editorAppsProvider).isEmpty, isTrue);

      final result = await container
          .read(editorAppsProvider.notifier)
          .setDefault('a.txt', OpenWithApp.program(r'C:\Apps\ed.exe'));
      expect(result, isA<Err<void>>());
      expect((result as Err<void>).error.code, 'saveFailed');
      expect(container.read(editorAppsProvider).forFile('a.txt')?.name, 'Ed');
      expect(stored().readAsStringSync(), '{ not json');
    });
  });
}

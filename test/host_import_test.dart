import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/features/hosts/adapters/host_import_files.dart';
import 'package:sshairy/features/hosts/domain/host_import.dart';
import 'package:sshairy/features/hosts/domain/import_plan.dart';
import 'package:sshairy/features/hosts/domain/ssh_config.dart';
import 'package:sshairy/foundation/ids.dart';

const _me = 'me';

SshConfigHost _host(SshConfig config, String alias) => config.hosts.singleWhere((h) => h.alias == alias);

List<(SshConfigIssueKind, String)> _issues(SshConfig config) => [for (final i in config.issues) (i.kind, i.option)];

Uint8List _utf16le(String text) {
  final out = <int>[0xFF, 0xFE];
  for (final unit in text.codeUnits) {
    out
      ..add(unit & 0xFF)
      ..add(unit >> 8);
  }
  return Uint8List.fromList(out);
}

void main() {
  group('PuTTY', () {
    test('registry query output: escaped names, user@host, hex ports; .ppk and telnet are reported', () {
      const output = r'''

HKEY_CURRENT_USER\Software\SimonTatham\PuTTY\Sessions\Default%20Settings
    HostName    REG_SZ
    Protocol    REG_SZ    ssh

HKEY_CURRENT_USER\Software\SimonTatham\PuTTY\Sessions\web%20one
    HostName    REG_SZ    root@10.0.0.5
    PortNumber    REG_DWORD    0x8fc
    Protocol    REG_SZ    ssh
    PublicKeyFile    REG_SZ    C:\keys\web.ppk

HKEY_CURRENT_USER\Software\SimonTatham\PuTTY\Sessions\router
    HostName    REG_SZ    192.168.1.1
    Protocol    REG_SZ    telnet
''';
      final config = parsePuttyQuery(output, defaultUser: _me);
      expect(config.hosts, hasLength(1));
      final web = _host(config, 'web one');
      expect((web.address, web.username, web.port, web.keyPath), ('10.0.0.5', 'root', 2300, null));
      expect(_issues(config), [(SshConfigIssueKind.ppk, 'web one'), (SshConfigIssueKind.notSsh, 'router')]);
    });

    test('a regedit export unescapes backslashes and reads dwords', () {
      const reg = r'''Windows Registry Editor Version 5.00

[HKEY_CURRENT_USER\Software\SimonTatham\PuTTY\Sessions\db]
"HostName"="db.example"
"PortNumber"=dword:00000016
"UserName"="pg"
"Protocol"="ssh"
"PublicKeyFile"="C:\\keys\\id_ed25519"

[HKEY_CURRENT_USER\Software\SimonTatham\PuTTY\Jumplist]
"HostName"="ignored.example"
''';
      expect(sniffImport('putty.reg', reg), ImportFormat.putty);
      final config = parsePuttyReg(const ImportText('putty.reg', reg), defaultUser: _me);
      final db = config.hosts.single;
      expect((db.alias, db.address, db.username, db.port), ('db', 'db.example', 'pg', 22));
      expect(db.keyPath, r'C:\keys\id_ed25519');
    });
  });

  test('MobaXterm: SSH bookmarks with their folder; other session types are reported', () {
    const ini = r'''[Misc]
web=ignored
[Bookmarks]
SubRep=
ImgNum=42
web=#109#0%10.0.0.1%2222%admin%%-1%-1%%%%%0%0%0%%%-1%0%0%0%%1080%%0%0%1#MobaFont%10%0%0%-1%15#0# #-1
[Bookmarks_1]
SubRep=prod\db
ImgNum=41
pg=#109#0%db.example%22%%%-1%-1#MobaFont#0# #-1
desk=#91#4%win.example%3389%%%-1#MobaFont#0# #-1
''';
    expect(sniffImport('MobaXterm.ini', ini), ImportFormat.mobaxterm);
    final config = parseMobaXterm(const ImportText('MobaXterm.ini', ini), defaultUser: _me);
    expect(config.hosts.map((h) => h.alias), ['web', 'pg']);
    final web = _host(config, 'web'), pg = _host(config, 'pg');
    expect((web.address, web.port, web.username, web.group), ('10.0.0.1', 2222, 'admin', ''));
    expect((pg.address, pg.port, pg.username, pg.group), ('db.example', 22, _me, 'prod/db'));
    expect(_issues(config), [(SshConfigIssueKind.notSsh, 'desk')]);
  });

  test('SecureCRT: one session per .ini, hex port, folder as group; folder data and telnet skipped', () {
    final files = [
      const ImportText('__FolderData__.ini', 'S:"Folder Description"=x\n'),
      const ImportText('Default.ini', 'S:"Hostname"=default.example\n'),
      const ImportText(
        'prod/web.ini',
        'S:"Protocol Name"=SSH2\nS:"Hostname"=w.example\nS:"Username"=deploy\nD:"[SSH2] Port"=000008ae\n',
      ),
      const ImportText('tel.ini', 'S:"Protocol Name"=Telnet\nS:"Hostname"=t.example\n'),
    ];
    expect(sniffImport('web.ini', files[2].text), ImportFormat.securecrt);
    final config = parseSecureCrt(files, defaultUser: _me);
    final web = config.hosts.single;
    expect((web.alias, web.address, web.username, web.port, web.group), ('web', 'w.example', 'deploy', 2222, 'prod'));
    expect(_issues(config), [(SshConfigIssueKind.notSsh, 'tel')]);
  });

  test('Xshell: UTF-16 session files decode, and the subfolder is the group', () {
    const text =
        '[CONNECTION]\r\nHost=x.example\r\nPort=2200\r\nProtocol=SSH\r\n'
        '[CONNECTION:AUTHENTICATION]\r\nUserName=中文用户\r\nPassword=secret\r\n';
    final decoded = decodeImportText(_utf16le(text));
    expect(decoded, text);
    expect(sniffImport('x.xsh', decoded), ImportFormat.xshell);
    final config = parseXshell([
      ImportText('group/x 服务器.xsh', decoded),
      const ImportText('rdp.xsh', '[CONNECTION]\nHost=r\nProtocol=TELNET\n'),
    ], defaultUser: _me);
    final x = config.hosts.single;
    expect((x.alias, x.address, x.port, x.username, x.group), ('x 服务器', 'x.example', 2200, '中文用户', 'group'));
    expect(_issues(config), [(SshConfigIssueKind.notSsh, 'rdp')]);
  });

  test('text decoding: UTF-8 with and without a BOM, UTF-16 BE', () {
    expect(decodeImportText(Uint8List.fromList([0xEF, 0xBB, 0xBF, ...utf8.encode('名称')])), '名称');
    expect(decodeImportText(Uint8List.fromList(utf8.encode('host'))), 'host');
    expect(decodeImportText(Uint8List.fromList([0xFE, 0xFF, 0x00, 0x41, 0x4E, 0x2D])), 'A中');
  });

  test('FinalShell: connection JSON without its password; broken files are reported', () {
    final good = jsonEncode({'name': 'fs', 'host': 'f.example', 'port': 2022, 'user_name': 'u', 'password': 'secret'});
    expect(sniffImport('a_connect_config.json', good), ImportFormat.finalshell);
    final config = parseFinalShell([
      ImportText('a_connect_config.json', good),
      const ImportText('b_connect_config.json', '{'),
    ], defaultUser: _me);
    final fs = config.hosts.single;
    expect((fs.alias, fs.address, fs.port, fs.username), ('fs', 'f.example', 2022, 'u'));
    expect(config.issues.single.kind, SshConfigIssueKind.unreadable);
    expect(config.issues.single.file, 'b_connect_config.json');
  });

  test('Tabby: SSH profiles with group names and file URI keys; telnet is reported', () {
    final config = parseTabby(
      {
        'groups': [
          {'id': 'g1', 'name': 'Prod'},
        ],
        'profiles': [
          {
            'type': 'ssh',
            'name': 'api',
            'group': 'g1',
            'options': {
              'host': 'api.example',
              'port': 2201,
              'user': 'ops',
              'privateKeys': ['file:///C:/Users/me/.ssh/id_rsa'],
            },
          },
          {
            'type': 'ssh',
            'name': 'local',
            'options': {
              'host': 'l.example',
              'privateKeys': ['file:///home/me/.ssh/id_ed25519'],
            },
          },
          {
            'type': 'telnet',
            'name': 'old',
            'options': {'host': 'o'},
          },
          {'type': 'local', 'name': 'shell'},
        ],
      },
      'config.yaml',
      defaultUser: _me,
    );
    final api = _host(config, 'api'), local = _host(config, 'local');
    expect((api.address, api.port, api.username, api.group), ('api.example', 2201, 'ops', 'Prod'));
    expect(api.keyPath, r'C:\Users\me\.ssh\id_rsa');
    expect((local.port, local.username, local.keyPath), (22, _me, '/home/me/.ssh/id_ed25519'));
    expect(_issues(config), [(SshConfigIssueKind.notSsh, 'old')]);
    expect(parseTabby('nope', 'config.yaml', defaultUser: _me).issues.single.kind, SshConfigIssueKind.unreadable);
  });

  group('CSV', () {
    test('quoted cells, Chinese headers and a BOM; rows without an address are blocked', () {
      const csv =
          '\uFEFF名称,主机,端口,用户名,分组\r\n'
          '"web, one",10.0.0.1,2222,root,prod\r\n'
          '"say ""hi""",h2.example,,,\r\n'
          ',,,,\r\n'
          'bad,,22,,\r\n';
      expect(sniffImport('hosts.csv', csv), ImportFormat.csv);
      final config = parseCsvHosts(const ImportText('hosts.csv', csv), defaultUser: _me);
      expect(config.hosts.map((h) => h.alias), ['web, one', 'say "hi"', 'bad']);
      final web = config.hosts[0], hi = config.hosts[1], bad = config.hosts[2];
      expect((web.address, web.port, web.username, web.group, web.line), ('10.0.0.1', 2222, 'root', 'prod', 2));
      expect((hi.port, hi.username, hi.group), (22, _me, ''));
      expect(bad.issues.single.kind, SshConfigIssueKind.noAddress);
      expect(bad.issues.single.line, 5);
    });

    test('an English header in any order is recognised without the extension', () {
      const csv = 'user,port,host\nadmin,2200,e.example\n';
      expect(sniffImport('export.txt', csv), ImportFormat.csv);
      final h = parseCsvHosts(const ImportText('export.txt', csv), defaultUser: _me).hosts.single;
      expect((h.alias, h.address, h.port, h.username), ('e.example', 'e.example', 2200, 'admin'));
    });

    test('a table without an address column is unreadable', () {
      final config = parseCsvHosts(const ImportText('x.csv', 'a,b\n1,2\n'), defaultUser: _me);
      expect(config.hosts, isEmpty);
      expect(config.issues.single.kind, SshConfigIssueKind.unreadable);
    });

    test('invalid ports and addresses are blocked, not guessed', () {
      final config = parseCsvHosts(
        const ImportText('x.csv', 'host,port\na.example,99999\nb example,22\n[::1],22\n'),
        defaultUser: _me,
      );
      expect(config.hosts[0].issues.single.kind, SshConfigIssueKind.invalid);
      expect(config.hosts[1].issues.single.kind, SshConfigIssueKind.invalid);
      expect(config.hosts[2].address, '::1');
      expect(config.hosts[2].issues, isEmpty);
    });

    test('more than the host limit is cut and reported', () {
      final rows = [for (var i = 0; i <= sshConfigMaxHosts; i++) 'h$i.example'];
      final config = parseCsvHosts(ImportText('many.csv', 'host\n${rows.join('\n')}'), defaultUser: _me);
      expect(config.hosts, hasLength(sshConfigMaxHosts));
      expect(config.complete, isFalse);
      expect(config.issues.last.kind, SshConfigIssueKind.hostLimit);
    });
  });

  test('anything else is left to the SSH config parser', () {
    expect(sniffImport('config', 'Host web\n  HostName w.example\n'), isNull);
  });

  test('same-named sessions in different folders stay apart and go below the chosen group', () {
    final config = parseXshell([
      const ImportText('a/web.xsh', '[CONNECTION]\nHost=a.example\n'),
      const ImportText('b/web.xsh', '[CONNECTION]\nHost=b.example\n'),
    ], defaultUser: _me);
    var n = 0;
    final plan = planSshConfig(config, const [], newId: () => HostId('id${n++}'), group: 'imported');
    expect(plan.drafts.map((d) => d.key).toSet(), hasLength(2));
    final added = plan.additions({for (final d in plan.drafts) d.key});
    expect([for (final h in added) (h.address, h.group)], [('a.example', 'imported/a'), ('b.example', 'imported/b')]);
  });

  group('files', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('sshairy-import-'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('a Tabby YAML file is recognised and read without being told the format', () async {
      final file = File('${dir.path}/config.yaml')
        ..writeAsStringSync('''
version: 3
profiles:
  - type: ssh
    name: yaml host
    options:
      host: y.example
      user: ops
''');
      final read = await const HostImportFiles().read(null, file.path);
      expect(read.format, ImportFormat.tabby);
      expect(read.config.hosts.single.alias, 'yaml host');
    });

    test('a folder of Xshell sessions is read recursively, as relative names', () async {
      Directory('${dir.path}/prod').createSync();
      File('${dir.path}/prod/web.xsh').writeAsBytesSync(_utf16le('[CONNECTION]\r\nHost=w.example\r\n'));
      File('${dir.path}/notes.txt').writeAsStringSync('Host=not.a.session');
      final read = await const HostImportFiles().read(null, dir.path);
      expect(read.format, ImportFormat.xshell);
      final web = read.config.hosts.single;
      expect((web.file, web.group, web.address), ('prod/web.xsh', 'prod', 'w.example'));
    });

    test('a file over the size limit is reported, not read', () async {
      final file = File('${dir.path}/big.csv')..writeAsBytesSync(Uint8List(importMaxFileBytes + 1));
      final read = await const HostImportFiles().read(null, file.path);
      expect(read.config.hosts, isEmpty);
      expect(read.config.issues.single.kind, SshConfigIssueKind.unreadable);
    });
  });
}

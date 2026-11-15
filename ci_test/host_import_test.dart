import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/features/hosts/domain/host_import.dart';
import 'package:sshairy/features/hosts/domain/ssh_config.dart';

const _me = 'default';

void main() {
  test('CSV import maps headers, keeps groups and reports rows without an address', () {
    const csv = '\uFEFFhost,port,user,group\nweb.example,2222,root,prod\n,22,,\n';
    expect(sniffImport('hosts.csv', csv), ImportFormat.csv);
    final config = parseCsvHosts(const ImportText('hosts.csv', csv), defaultUser: _me);
    expect(config.hosts.map((host) => host.alias), ['web.example', '']);
    final web = config.hosts.first;
    expect((web.address, web.port, web.username, web.group), ('web.example', 2222, 'root', 'prod'));
    expect(config.hosts.last.issues.single.kind, SshConfigIssueKind.noAddress);
  });

  test('PuTTY registry sessions keep the login, key path and default port', () {
    const reg = '''
Windows Registry Editor Version 5.00

[HKEY_CURRENT_USER\\Software\\SimonTatham\\PuTTY\\Sessions\\db]
"HostName"="db.example"
"UserName"="pg"
"Protocol"="ssh"
"PublicKeyFile"="C:\\\\keys\\\\id_ed25519"
''';
    expect(sniffImport('putty.reg', reg), ImportFormat.putty);
    final host = parsePuttyReg(const ImportText('putty.reg', reg), defaultUser: _me).hosts.single;
    expect((host.alias, host.address, host.username, host.port), ('db', 'db.example', 'pg', 22));
    expect(host.keyPath, r'C:\keys\id_ed25519');
  });
}

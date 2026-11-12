import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/features/hosts/domain/host.dart';
import 'package:sshairy/features/hosts/domain/host_validation.dart';
import 'package:sshairy/features/hosts/domain/import_plan.dart';
import 'package:sshairy/features/hosts/domain/ssh_config.dart';
import 'package:sshairy/foundation/ids.dart';

SshConfig parse(List<String> lines) => parseSshConfig(
  SshConfigInput([for (var i = 0; i < lines.length; i++) SshConfigLine('config', i + 1, lines[i])]),
  defaultUser: 'me',
  home: '/home/me',
);

Host saved(String label, String address, {int port = 22, String username = 'me'}) =>
    Host(id: HostId(label), label: label, address: address, port: port, username: username, auth: AuthKind.password);

void main() {
  test('directives parse OpenSSH syntax: separators, quotes, comments and escapes', () {
    expect(sshConfigDirective('HostName web.example.com ')!.arguments, ['web.example.com']);
    expect(sshConfigDirective('HostName="quoted host"')!.arguments, ['quoted host']);
    expect(sshConfigDirective('HostName a # trailing')!.arguments, ['a']);
    expect(sshConfigDirective("HostName 'a\\'b'")!.arguments, ["a'b"]);
    expect(sshConfigDirective('# comment'), isNull);
    expect(() => sshConfigDirective('HostName'), throwsFormatException);
  });

  test('a plain host takes hostname, user, port and identity file', () {
    final config = parse([
      'Host web',
      '  HostName web.example.com',
      '  User deploy',
      '  Port 2222',
      '  IdentityFile ~/.ssh/id_ed25519',
    ]);
    final host = config.hosts.single;
    expect((host.alias, host.address, host.username, host.port), ('web', 'web.example.com', 'deploy', 2222));
    expect(host.keyPath, '/home/me/.ssh/id_ed25519');
    expect(host.blocked, isFalse);
  });

  test('defaults come from the * block; first value wins, later identity files are reported', () {
    final config = parse([
      'Host *',
      '  User default',
      '  Port 2022',
      'Host a',
      '  User first',
      '  User second',
      'Host b',
      '  IdentityFile one',
      '  IdentityFile two',
      'Host c',
      '  User later',
    ]);
    final a = config.hosts.firstWhere((h) => h.alias == 'a');
    final b = config.hosts.firstWhere((h) => h.alias == 'b');
    final c = config.hosts.firstWhere((h) => h.alias == 'c');
    // OpenSSH keeps the first obtained value, so a leading * block outranks later blocks.
    expect(a.username, 'default');
    expect(b.username, 'default');
    expect(b.port, 2022);
    expect(b.keyPath, '/home/me/one');
    // Within one block the first directive also wins.
    expect(c.username, 'default');
    expect(config.issues.any((i) => i.kind == SshConfigIssueKind.extraIdentity), isTrue);
  });

  test('unknown options, Match blocks and patterns are reported, not guessed', () {
    final config = parse([
      'Host web',
      '  Compression yes',
      'Match host web',
      '  User other',
      'Host prod-*',
      '  HostName example.com',
    ]);
    expect(config.issues.map((i) => i.kind), containsAll([SshConfigIssueKind.unsupported, SshConfigIssueKind.match]));
    expect(config.hosts.firstWhere((h) => h.alias == 'web').username, 'me');
    final pattern = config.issues.singleWhere((i) => i.kind == SshConfigIssueKind.pattern);
    expect(pattern.line, 5);
    expect(config.hosts.where((h) => h.alias.startsWith('prod')), isEmpty);
  });

  test('ProxyCommand and invalid endpoints block the host', () {
    final config = parse(['Host via', '  ProxyCommand nc -x proxy %h %p', 'Host bad', '  Port notaport']);
    expect(config.hosts.firstWhere((h) => h.alias == 'via').issues.map((i) => i.kind), [
      SshConfigIssueKind.proxyCommand,
    ]);
    expect(config.hosts.firstWhere((h) => h.alias == 'bad').issues.map((i) => i.kind), [SshConfigIssueKind.invalid]);
  });

  test('ProxyJump chains become jump hosts, dependencies included once', () {
    final config = parse([
      'Host bastion',
      '  HostName jump.example.com',
      '  Port 2222',
      'Host web',
      '  HostName web.internal',
      '  ProxyJump deploy@bastion:2222',
    ]);
    final plan = planSshConfig(config, [saved('laptop', 'laptop.internal')], newId: () => HostId(newId()));
    final web = plan.drafts.firstWhere((d) => d.source.alias == 'web');
    final bastion = plan.drafts.firstWhere((d) => d.source.alias == 'bastion');
    expect(web.selectable, isTrue);
    final added = plan.additions({'web'});
    expect(added.map((h) => h.label), containsAll(['web', 'bastion']));
    final jump = added.firstWhere((h) => h.label == 'bastion');
    final target = added.firstWhere((h) => h.label == 'web');
    // The user in the ProxyJump line applies to the jump host it names.
    expect((jump.address, jump.port, jump.username), ('jump.example.com', 2222, 'deploy'));
    expect(target.jumpHostId, jump.id);
    // Bastion itself was not checked, yet its dependency comes along exactly once.
    expect(added.where((h) => h.label == 'bastion'), hasLength(1));
    expect(bastion.existing, isNull);
  });

  test('a saved endpoint is reused instead of duplicated, with a different jump kept separate', () {
    final config = parse([
      'Host db',
      '  HostName db.internal',
      'Host db2',
      '  HostName db.internal',
      '  ProxyJump bastion',
      'Host bastion',
      '  HostName jump.example.com',
    ]);
    final existing = saved('db', 'db.internal');
    final plan = planSshConfig(config, [existing], newId: () => HostId(newId()));
    expect(plan.drafts.firstWhere((d) => d.source.alias == 'db').existing, same(existing));
    final added = plan.additions({'db2'});
    // A different jump keeps the same endpoint as a separate clone, never editing the saved host.
    final db2 = added.firstWhere((h) => h.address == 'db.internal' && h.id != existing.id);
    expect(db2.jumpHostId, isNotNull);
    expect(added.where((h) => h.address == 'db.internal').map((h) => h.id), isNot(contains(existing.id)));
  });

  test('cyclic proxy jumps are refused, not resolved', () {
    final config = parse(['Host a', '  ProxyJump b', 'Host b', '  ProxyJump a']);
    final plan = planSshConfig(config, const [], newId: () => HostId(newId()));
    expect(plan.drafts.map((d) => d.issues.map((i) => i.kind)), everyElement(contains(SshConfigIssueKind.jumpCycle)));
    expect(plan.additions({'a', 'b'}), isEmpty);
  });

  test('every produced host passes the shared validation', () {
    final config = parse([
      'Host ok',
      '  HostName ok.example.com',
      'Host deep',
      '  HostName deep.internal',
      '  ProxyJump j@ok:2200',
    ]);
    final plan = planSshConfig(config, const [], newId: () => HostId(newId()));
    for (final host in plan.additions({'ok', 'deep'})) {
      expect(() => validateHost(host), returnsNormally, reason: host.label);
    }
  });
}

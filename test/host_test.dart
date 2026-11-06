import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/features/hosts/domain/host.dart';
import 'package:sshairy/foundation/ids.dart';

void main() {
  group('parseQuickConnect', () {
    test('accepts the documented forms', () {
      expect(parseQuickConnect('ubuntu@example.com')?.target, 'ubuntu@example.com');
      expect(parseQuickConnect(' root@10.0.0.1:2222 ')?.port, 2222);
      expect(parseQuickConnect('ssh -p 2200 a@b')?.port, 2200);
      expect(parseQuickConnect('ssh a@b')?.address, 'b');
      expect(parseQuickConnect('a@[::1]:2222')?.address, '::1');
    });

    test('rejects anything else', () {
      for (final input in ['', 'example.com', 'a@b:0', 'a@b:70000', 'ssh -p 22 a@b:22', 'ssh -p x a@b', 'a@b c']) {
        expect(parseQuickConnect(input), isNull, reason: input);
      }
    });

    test('quick-connect hosts are transient', () {
      expect(parseQuickConnect('a@b')!.transient, isTrue);
    });
  });

  test('Host survives a JSON round trip', () {
    const host = Host(id: HostId('x'), label: 'web', address: 'h', port: 2222, username: 'u', auth: AuthKind.key, keyPath: '~/k');
    final copy = Host.fromJson(host.toJson());
    expect(copy.toJson(), host.toJson());
    expect(copy.passwordRef, 'host/x/password');
  });
}

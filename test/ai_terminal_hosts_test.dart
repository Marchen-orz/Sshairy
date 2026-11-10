import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/app/ai_terminal_hosts.dart';
import 'package:sshairy/features/hosts/api.dart';
import 'package:sshairy/foundation/ids.dart';

Host host(String id, {String label = '', String address = 'example.test', String? jump}) => Host(
  id: HostId(id),
  label: label,
  address: address,
  username: 'user',
  jumpHostId: jump == null ? null : HostId(jump),
);

void main() {
  test('automatic terminal grants follow the complete route and ignore cosmetic edits', () {
    final first = aiTerminalHosts([host('web', jump: 'jump'), host('jump')]);
    final renamed = aiTerminalHosts([host('web', label: 'New alias', jump: 'jump'), host('jump')]);
    final rerouted = aiTerminalHosts([host('web', jump: 'jump'), host('jump', address: 'other.test')]);
    expect(first.first.signature, renamed.first.signature);
    expect(renamed.first.label, 'New alias');
    expect(first.first.signature, isNot(rerouted.first.signature));
  });

  test('transient, missing, cyclic and too deep routes cannot be selected for automatic sending', () {
    expect(aiTerminalHosts([host('')]), isEmpty);
    expect(aiTerminalHosts([host('web', jump: 'missing')]), isEmpty);
    expect(aiTerminalHosts([host('a', jump: 'b'), host('b', jump: 'a')]), isEmpty);
    final chain = [for (var i = 0; i < 9; i++) host('h$i', jump: i == 8 ? null : 'h${i + 1}')];
    final allowed = aiTerminalHosts(chain);
    expect(allowed.map((entry) => entry.id.value), isNot(contains('h0')));
    expect(allowed.map((entry) => entry.id.value), contains('h1'));
  });
}

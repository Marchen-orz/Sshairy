import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/app/ai_terminal_hosts.dart';
import 'package:sshairy/app/composition.dart';
import 'package:sshairy/features/ai/api.dart';
import 'package:sshairy/features/connections/api.dart';
import 'package:sshairy/features/credentials/api.dart';
import 'package:sshairy/features/hosts/api.dart';
import 'package:sshairy/foundation/ids.dart';

Host _host(String id, {String label = '', String address = 'example.test', String? jump}) => Host(
  id: HostId(id),
  label: label,
  address: address,
  username: 'user',
  jumpHostId: jump == null ? null : HostId(jump),
);

class _Hosts extends HostsNotifier {
  @override
  List<Host> build() => [_host('web', jump: 'jump'), _host('jump')];

  void replace(List<Host> hosts) => state = hosts;
}

class _Trust implements HostTrustService {
  @override
  int revision = 0;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError('Unexpected trust operation');
}

class _Credentials implements ConnectionCredentials {
  @override
  int revision = 0;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError('Unexpected credential operation');
}

void main() {
  test('conversation fingerprint is opaque and binds route, revisions and security session', () {
    String fingerprint(List<Host> hosts, {int trust = 0, int credentials = 0, String session = 'session-a'}) =>
        conversationRouteFingerprint(
          aiTerminalHosts(hosts).first.signature,
          trustRevision: trust,
          credentialRevision: credentials,
          securitySession: session,
        );

    final route = [_host('web', jump: 'jump'), _host('jump')];
    final initial = fingerprint(route);
    expect(initial, matches(RegExp(r'^[a-f0-9]{64}$')));
    expect(initial, fingerprint(route));
    expect(initial, fingerprint([_host('web', label: 'Renamed', jump: 'jump'), _host('jump')]));
    expect(initial, isNot(fingerprint([_host('web', jump: 'jump'), _host('jump', address: 'other.test')])));
    expect(initial, isNot(fingerprint(route, trust: 1)));
    expect(initial, isNot(fingerprint(route, credentials: 1)));
    expect(initial, isNot(fingerprint(route, session: 'session-b')));
    expect(initial, isNot(contains('example.test')));
    expect(initial, isNot(contains('user')));
  });

  test('cached route callback reads current hosts and nonreactive security revisions', () {
    final trust = _Trust();
    final credentials = _Credentials();
    final hosts = _Hosts();
    final container = ProviderContainer(
      overrides: [
        ...appOverrides(),
        hostsProvider.overrideWith(() => hosts),
        hostTrustProvider.overrideWithValue(trust),
        connectionCredentialsProvider.overrideWithValue(credentials),
      ],
    );
    addTearDown(container.dispose);
    final routes = container.read(agentConversationRoutesProvider);
    const web = HostId('web');
    final first = routes()[web];
    expect(first, isNotNull);
    expect(routes()[web], first);

    trust.revision++;
    final changedTrust = routes()[web];
    expect(changedTrust, isNot(first));
    credentials.revision++;
    final changedCredentials = routes()[web];
    expect(changedCredentials, isNot(changedTrust));

    hosts.replace([_host('web', jump: 'jump'), _host('jump', address: 'other.test')]);
    expect(routes()[web], isNot(changedCredentials));
    hosts.replace([_host('web', jump: 'missing')]);
    expect(routes(), isNot(contains(web)));
  });
}

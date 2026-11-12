import '../../../foundation/ids.dart';

extension type const ForwardId(String value) {}

enum ForwardKind { local, remote, dynamic }

enum ForwardPhase { stopped, starting, running, reconnecting, stopping, failed, stopFailed }

class ForwardRule {
  const ForwardRule({
    required this.id,
    required this.hostId,
    this.label = '',
    this.kind = ForwardKind.local,
    this.listenAddress = '127.0.0.1',
    required this.listenPort,
    this.destinationAddress = '127.0.0.1',
    this.destinationPort = 0,
    this.autoStart = false,
    this.autoReconnect = false,
  });

  final ForwardId id;
  final HostId hostId;
  final String label, listenAddress, destinationAddress;
  final ForwardKind kind;
  final int listenPort, destinationPort;
  final bool autoStart, autoReconnect;

  bool get exposed => !isLoopback(listenAddress);
  String get endpoint => addressPort(listenAddress, listenPort);
  String get destination => addressPort(destinationAddress, destinationPort);
  String get title => label.isEmpty ? '${kind.name.toUpperCase()} $endpoint' : label;

  void validate() {
    bool validAddress(String s) => s.isNotEmpty && !RegExp(r'[\s\x00-\x1f\x7f]').hasMatch(s);
    if (id.value.isEmpty || hostId.value.isEmpty) throw ArgumentError('id');
    if (!validAddress(listenAddress) || listenPort < 0 || listenPort > 65535) throw ArgumentError('listen');
    if (kind != ForwardKind.dynamic &&
        (!validAddress(destinationAddress) || destinationPort < 1 || destinationPort > 65535)) {
      throw ArgumentError('destination');
    }
  }

  Map<String, Object?> toJson() => {
    'id': id.value,
    'hostId': hostId.value,
    'label': label,
    'kind': kind.name,
    'listenAddress': listenAddress,
    'listenPort': listenPort,
    if (kind != ForwardKind.dynamic) 'destinationAddress': destinationAddress,
    if (kind != ForwardKind.dynamic) 'destinationPort': destinationPort,
    'autoStart': autoStart,
    'autoReconnect': autoReconnect,
  };

  factory ForwardRule.fromJson(Map<String, dynamic> j) {
    final rule = ForwardRule(
      id: ForwardId(j['id'] as String),
      hostId: HostId(j['hostId'] as String),
      label: j['label'] as String? ?? '',
      kind: ForwardKind.values.byName(j['kind'] as String),
      listenAddress: j['listenAddress'] as String? ?? '127.0.0.1',
      listenPort: j['listenPort'] as int,
      destinationAddress: j['destinationAddress'] as String? ?? '127.0.0.1',
      destinationPort: j['destinationPort'] as int? ?? 0,
      autoStart: j['autoStart'] as bool? ?? false,
      autoReconnect: j['autoReconnect'] as bool? ?? false,
    );
    rule.validate();
    return rule;
  }
}

bool isLoopback(String address) {
  if (address == '::1' || address.toLowerCase() == 'localhost') return true;
  final parts = address.split('.');
  return parts.length == 4 &&
      parts.first == '127' &&
      parts.every((p) {
        final n = int.tryParse(p);
        return n != null && n >= 0 && n <= 255;
      });
}

String addressPort(String address, int port) => address.contains(':') ? '[$address]:$port' : '$address:$port';

/// Per rule: forwarded connections open at once, handshaking and dialling ones included.
const forwardMaxConnections = 128;

/// How long the SOCKS5 handshake and the local TCP dial may each take.
const forwardDialTimeout = Duration(seconds: 15);

/// Waits before each automatic reconnect after the connection is lost; the list length is the attempt limit.
const forwardRetryDelays = [
  Duration(seconds: 1),
  Duration(seconds: 2),
  Duration(seconds: 4),
  Duration(seconds: 8),
  Duration(seconds: 16),
];

class ForwardState {
  const ForwardState(
    this.rule, {
    this.phase = ForwardPhase.stopped,
    this.port,
    this.error,
    this.detail = '',
    this.connections = 0,
  });
  final ForwardRule rule;
  final ForwardPhase phase;

  /// The port actually listened on, which differs from the rule's when that is 0.
  final int? port;

  /// A [ForwardErrors] or connection failure code. While running it is the latest error of a single connection.
  final String? error;
  final String detail;
  final int connections;

  /// Holds a listener or a lease, or is working towards one; such a rule cannot be edited or deleted.
  bool get active =>
      phase == ForwardPhase.starting ||
      phase == ForwardPhase.running ||
      phase == ForwardPhase.reconnecting ||
      phase == ForwardPhase.stopping ||
      phase == ForwardPhase.stopFailed;

  Map<String, Object?> toJson() => {
    ...rule.toJson(),
    'phase': phase.name,
    if (port != null) 'port': port,
    if (error != null) 'error': error,
    'connections': connections,
  };
}

/// Codes in [ForwardState.error] and [ForwardError.code]. Failures to connect to the server use the
/// `ConnectFailure` names (network, auth, hostKeyRejected, keyFile, route).
abstract final class ForwardErrors {
  static const addressInUse = 'addressInUse';
  static const permissionDenied = 'permissionDenied';
  static const addressUnavailable = 'addressUnavailable';
  static const bindFailed = 'bindFailed';
  static const refused = 'refused';
  static const hostMissing = 'hostMissing';
  static const connectionLost = 'connectionLost';
  static const stopFailed = 'stopFailed';

  /// Of one connection: the destination could not be reached, took too long, spoke bad SOCKS5, or was over the limit.
  static const targetFailed = 'targetFailed';
  static const timeout = 'timeout';
  static const handshake = 'handshake';
  static const limit = 'limit';

  /// Of a request: the rule is unknown or busy, or listens beyond loopback without the user's yes.
  static const unknown = 'unknown';
  static const busy = 'busy';
  static const conflict = 'conflict';
  static const exposureUnconfirmed = 'exposureUnconfirmed';
}

class ForwardError implements Exception {
  const ForwardError(this.code, [this.detail = '']);
  final String code, detail;
  @override
  String toString() => 'ForwardError($code, $detail)';
}

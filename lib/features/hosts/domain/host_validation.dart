import 'host.dart';

/// Used by every save/import entry point; callers may add field-level presentation.
void validateHost(Host host) {
  bool address(String value) => value.isNotEmpty && !RegExp(r'[\s\x00-\x1f\x7f\[\]]').hasMatch(value);
  bool user(String value) => value.isNotEmpty && !RegExp(r'[\x00-\x1f\x7f]').hasMatch(value);
  bool port(int value) => value >= 1 && value <= 65535;
  if (host.id.value.isEmpty || !address(host.address) || !user(host.username) || !port(host.port)) {
    throw ArgumentError('invalid host');
  }
  if (host.jumpHostId == host.id) throw ArgumentError('jump host is self');
  if (host.proxy case final proxy?) {
    if (!address(proxy.address) ||
        !port(proxy.port) ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(proxy.username) ||
        (proxy.kind == ProxyKind.http && proxy.username.contains(':'))) {
      throw ArgumentError('invalid proxy');
    }
  }
}

import 'dart:convert';

import '../features/ai/api.dart';
import '../features/connections/api.dart';
import '../features/hosts/api.dart';
import '../foundation/ids.dart';

/// A local grant follows the complete effective route, never a label or a mutable host ID alone.
List<AiTerminalHost> aiTerminalHosts(List<Host> hosts) {
  final byId = {
    for (final host in hosts)
      if (!host.transient) host.id: host,
  };
  return [
    for (final host in byId.values)
      if (_signature(host, byId) case final signature?) AiTerminalHost(host.id, host.label, signature),
  ];
}

String? _signature(Host host, Map<HostId, Host> byId) {
  final seen = <HostId>{};
  final route = <String>[];
  Host? current = host;
  while (current != null) {
    if (!seen.add(current.id) || route.length >= 8) return null;
    route.add(ConnectionManager.keyOf(current));
    final jump = current.jumpHostId;
    if (jump == null) break;
    current = byId[jump];
    if (current == null) return null;
  }
  return jsonEncode(route);
}

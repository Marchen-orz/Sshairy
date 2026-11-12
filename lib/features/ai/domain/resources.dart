import '../../../foundation/ids.dart';

/// IDs whose actual affected objects must be resolved locally before approval.
const agentResourceCapabilities = {
  'session.close',
  'session.reconnect',
  'workspace.split',
  'workspace.renameTab',
  'workspace.closeTabs',
  'transfer.cancel',
  'forward.start',
  'forward.stop',
  'forward.delete',
  'forward.save',
  'host.update',
  'host.move',
  'host.delete',
};

class AgentResourceSnapshot {
  AgentResourceSnapshot({
    required Iterable<HostId> hosts,
    required this.binding,
    Map<String, Object?> details = const {},
  }) : hosts = List.unmodifiable(hosts.toSet()),
       details = Map.unmodifiable(details);

  final List<HostId> hosts;

  /// Local identity only; never included in model messages or persisted history.
  final String binding;
  final Map<String, Object?> details;
}

abstract interface class AgentResourceReader {
  /// Resolves without connecting, executing or reading terminal/file contents. Null refuses the operation.
  AgentResourceSnapshot? resolve(String capability, Map<String, Object?> args);
}

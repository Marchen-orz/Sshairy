import 'dart:typed_data';

import '../../../foundation/cancellation.dart';
import '../../../foundation/ids.dart';

enum AgentPhase {
  idle,
  preparing,
  streaming,
  awaitingApproval,
  executing,
  awaitingData,
  completed,
  stopping,
  cancelled,
  failed,
  outcomeUnknown,
}

enum OperationState { intent, completed, failed, outcomeUnknown }

class AgentHost {
  const AgentHost(this.id, this.label);
  final HostId id;
  final String label;
}

class AgentScope {
  AgentScope({Iterable<HostId> hosts = const [], this.revision = 0, this.discoverHosts = false})
    : hosts = Set.unmodifiable(hosts);
  final Set<HostId> hosts;
  final int revision;
  final bool discoverHosts;
}

/// Only the app's connection adapter can supply a prepared target. No shell or transport escapes this port.
abstract interface class AgentTarget {
  HostId get hostId;
  String get identity;
  String get display;
  bool get current;
  Future<bool> supportsPosix(CancellationToken cancel);
  Future<int?> execute(
    String command,
    void Function(bool stderr, Uint8List bytes) output, {
    required Duration timeout,
    required CancellationToken cancel,
  });
  void release();
}

abstract interface class AgentBackend {
  List<AgentHost> get hosts;
  Future<AgentTarget> prepare(HostId host, CancellationToken cancel);
}

class OperationRecord {
  const OperationRecord(this.id, this.host, this.capability, this.at, this.state);
  final OperationId id;
  final HostId host;
  final String capability;
  final DateTime at;
  final OperationState state;
  OperationRecord withState(OperationState value) => OperationRecord(id, host, capability, at, value);
}

/// Implementations persist only operation metadata. Intent durability precedes every arbitrary command.
abstract interface class OperationJournal {
  Future<List<OperationRecord>> load();
  Future<void> record(OperationRecord record);
  Future<void> get saved;
}

class AgentFailure implements Exception {
  const AgentFailure(this.code);
  final String code;
  @override
  String toString() => 'AgentFailure($code)';
}

import 'dart:convert';
import 'dart:typed_data';

import '../features/ai/api.dart';
import '../features/connections/api.dart';
import '../features/hosts/api.dart';
import '../foundation/cancellation.dart';
import '../foundation/ids.dart';

/// Agent connections use the same trust and authentication path as terminals, without answering challenges.
class SshAgentBackend implements AgentBackend {
  SshAgentBackend(this._connections, this._hosts);

  final ConnectionManager _connections;
  final List<Host> Function() _hosts;

  @override
  List<AgentHost> get hosts => List.unmodifiable([
    for (final host in _hosts())
      if (!host.transient) AgentHost(host.id, host.label),
  ]);

  @override
  Future<AgentTarget> prepare(HostId host, CancellationToken cancel) async {
    if (cancel.isCancelled) throw const AgentFailure('cancelled');
    final resolved = _hosts().where((entry) => !entry.transient && entry.id == host).firstOrNull;
    if (resolved == null) throw const AgentFailure('hostUnavailable');
    final prompts = _RefuseChallenges();
    TransportLease? lease;
    try {
      lease = await _connections.acquire(resolved, prompts, purpose: LeasePurpose.exec, cancel: cancel);
      final target = _SshAgentTarget(lease, () => _hosts().any((entry) => !entry.transient && entry.id == host));
      if (cancel.isCancelled) throw const AgentFailure('cancelled');
      if (!target.current) throw const AgentFailure('scopeChanged');
      return target;
    } on Object catch (error) {
      lease?.release();
      if (error is AgentFailure) rethrow;
      if (cancel.isCancelled || error is ConnectError && error.kind == ConnectFailure.cancelled) {
        throw const AgentFailure('cancelled');
      }
      if (prompts.trustRequested || error is ConnectError && error.kind == ConnectFailure.hostKeyRejected) {
        throw const AgentFailure('hostTrustRequired');
      }
      if (prompts.secretRequested || error is ConnectError && error.kind == ConnectFailure.auth) {
        throw const AgentFailure('authenticationRequired');
      }
      throw const AgentFailure('connectionFailed');
    }
  }
}

class _RefuseChallenges implements ConnectPrompts {
  var trustRequested = false, secretRequested = false;

  @override
  Future<TrustChoice> hostKey(HostKeyPrompt prompt) async {
    trustRequested = true;
    return TrustChoice.reject;
  }

  @override
  Future<SecretAnswer?> secret(SecretRequest request) async {
    secretRequested = true;
    return null;
  }
}

class _SshAgentTarget implements AgentTarget {
  _SshAgentTarget(this._lease, this._exists);

  final TransportLease _lease;
  final bool Function() _exists;
  var _released = false;
  bool? _supported;

  // Fixed code checks only the adapter's prerequisites; it does not establish a particular Linux distribution.
  static const _probe =
      'sh -c \'[ "\$(uname -s)" = Linux ] && command -v sh >/dev/null 2>&1 && printf sshairy-posix-v1\'';

  @override
  HostId get hostId => _lease.identity.hostId;

  @override
  String get identity => jsonEncode([_lease.identity.transportId.value, _lease.identity.configKey]);

  @override
  String get display {
    final identity = _lease.identity;
    final address = identity.address.contains(':') ? '[${identity.address}]' : identity.address;
    return '${identity.username}@$address:${identity.port}';
  }

  @override
  bool get current => !_released && _exists() && _lease.isCurrent;

  void _check(CancellationToken cancel) {
    if (cancel.isCancelled) throw const AgentFailure('cancelled');
    if (!current) throw const AgentFailure('scopeChanged');
  }

  @override
  Future<bool> supportsPosix(CancellationToken cancel) async {
    _check(cancel);
    if (_supported case final cached?) return cached;
    final result = await _lease.exec(_probe, limit: 64, timeout: const Duration(seconds: 10), cancel: cancel);
    _check(cancel);
    return _supported =
        result.exitCode == 0 &&
        !result.truncated &&
        utf8.decode(result.stdout, allowMalformed: true) == 'sshairy-posix-v1' &&
        result.stderr.isEmpty;
  }

  @override
  Future<int?> execute(
    String command,
    void Function(bool stderr, Uint8List bytes) output, {
    required Duration timeout,
    required CancellationToken cancel,
  }) async {
    _check(cancel);
    if (command.trim().isEmpty ||
        command.length > 32768 ||
        utf8.encode(command).length > 65536 ||
        command.contains('\x00')) {
      throw const AgentFailure('invalidCommand');
    }
    if (timeout <= Duration.zero || timeout > const Duration(seconds: 300)) {
      throw const AgentFailure('invalidCommand');
    }
    if (!await supportsPosix(cancel)) throw const AgentFailure('unsupported');
    _check(cancel);
    return _lease.execStreaming(
      command,
      onOutput: (chunk) => output(chunk.stream == ExecStream.stderr, chunk.bytes),
      timeout: timeout,
      cancel: cancel,
    );
  }

  @override
  void release() {
    if (_released) return;
    _released = true;
    _lease.release();
  }
}

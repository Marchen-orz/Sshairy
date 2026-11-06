import '../../../foundation/cancellation.dart';
import '../../../foundation/ids.dart';
import '../../../foundation/result.dart';

/// What a capability does, for policy; one static level cannot describe every argument (docs/CONTRACTS.md §3).
enum Effect { query, localChange, connect, remoteWrite, security }

/// Who asked. Set by the caller's wiring, never taken from arguments, so an agent cannot claim to be the UI.
enum Origin { ui, palette, agent }

class RequestContext {
  RequestContext(this.origin, {OperationId? operationId, this.cancellation})
      : operationId = operationId ?? OperationId(newId());

  final Origin origin;
  final OperationId operationId;
  final CancellationToken? cancellation;
}

/// A business action that the command palette, and later the AI, can call by ID.
/// Typed façades in the UI and [invoke] must reach the same handler.
abstract class Capability {
  const Capability();

  /// `noun.verb`, for example `host.update`.
  String get id;
  int get version => 1;
  Effect get effect;

  /// Off by default; M4 opts capabilities in after review.
  bool get agentExposed => false;

  /// JSON Schema of the arguments, used to validate calls and to describe the tool to a model.
  Map<String, Object?> get inputSchema => const {'type': 'object', 'properties': {}};

  Future<Result<Object?>> invoke(Map<String, Object?> args, RequestContext context);
}

/// A capability whose handler is a function; most capabilities need nothing more.
class FunctionCapability extends Capability {
  const FunctionCapability(
    this.id,
    this.effect,
    this._handler, {
    this.inputSchema = const {'type': 'object', 'properties': {}},
    this.agentExposed = false,
  });

  @override
  final String id;
  @override
  final Effect effect;
  @override
  final Map<String, Object?> inputSchema;
  @override
  final bool agentExposed;
  final Future<Result<Object?>> Function(Args args, RequestContext context) _handler;

  @override
  Future<Result<Object?>> invoke(Map<String, Object?> args, RequestContext context) => _handler(Args(args), context);
}

/// Reads typed arguments; a missing or mistyped value becomes an `invalidArgument` error rather than an exception.
class Args {
  Args(this._map);

  final Map<String, Object?> _map;

  bool has(String key) => _map.containsKey(key);

  T require<T>(String key) {
    final v = _map[key];
    if (v is T) return v;
    throw ArgumentError.value(v, key, 'expected $T');
  }

  T? optional<T>(String key) {
    final v = _map[key];
    if (v == null || v is T) return v as T?;
    throw ArgumentError.value(v, key, 'expected $T');
  }
}

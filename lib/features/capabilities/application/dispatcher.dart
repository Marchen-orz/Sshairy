import '../../../foundation/result.dart';
import '../domain/capability.dart';

/// The one path from the palette and the AI to business actions: resolves the ID, applies policy, runs the handler.
class CapabilityDispatcher {
  CapabilityDispatcher(Iterable<Capability> capabilities) : _byId = {for (final c in capabilities) c.id: c};

  final Map<String, Capability> _byId;

  Iterable<Capability> get all => _byId.values;

  Capability? operator [](String id) => _byId[id];

  Future<Result<Object?>> dispatch(String id, Map<String, Object?> args, RequestContext context) async {
    final capability = _byId[id];
    if (capability == null) return Err(AppError('unknownCapability', detail: id));
    // Decided here in code, not in a prompt (CLAUDE.md rule 6).
    if (context.origin == Origin.agent && !capability.agentExposed) {
      return Err(AppError('notExposed', detail: id));
    }
    if (context.cancellation?.isCancelled ?? false) return const Err(AppError('cancelled'));
    try {
      return await capability.invoke(args, context);
    } on ArgumentError catch (e) {
      return Err(AppError('invalidArgument', detail: '${e.name}: ${e.message}'));
    }
  }
}

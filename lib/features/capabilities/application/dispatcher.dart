import 'dart:async';

import '../../../foundation/result.dart';
import '../domain/capability.dart';
import '../domain/schema.dart';

/// The one path from the palette and the AI to business actions: resolves the ID, applies policy, runs the handler.
class CapabilityDispatcher {
  CapabilityDispatcher(Iterable<Capability> capabilities) : _byId = {for (final c in capabilities) c.id: c};

  final Map<String, Capability> _byId;

  Iterable<Capability> get all => _byId.values;

  Capability? operator [](String id) => _byId[id];

  Future<Result<Object?>> dispatch(String id, Map<String, Object?> args, RequestContext context) async {
    final agent = context.origin == Origin.agent;
    final capability = _byId[id];
    if (capability == null) return Err(AppError('unknownCapability', detail: agent ? '' : id));
    // Exposure and authority are separate gates; adding a tool never grants it to every agent turn.
    if (agent && (!capability.agentExposed || capability.effect == Effect.security)) {
      return Err(AppError('notExposed', detail: id));
    }
    final stopped = _stopped(context);
    if (stopped != null) return Err(stopped);
    try {
      if (agent) {
        final authority = context.authority;
        if (authority == null) return const Err(AppError('unauthorized'));
        final checked = CapabilitySchema.validate(capability.inputSchema, args);
        if (checked case Err<Map<String, Object?>>(:final error)) return Err(error);
        args = (checked as Ok<Map<String, Object?>>).value;
        final beforeApproval = _stopped(context);
        if (beforeApproval != null) return Err(beforeApproval);
        final authorized = await _waitPolicy(authority.authorize(capability, args, context), context);
        if (authorized case Err<void>(:final error)) return Err(error);
        final afterApproval = _stopped(context);
        if (afterApproval != null) return Err(afterApproval);
        final current = await _waitPolicy(authority.revalidate(capability, args, context), context);
        if (current case Err<void>(:final error)) return Err(error);
      }
      final beforeInvoke = _stopped(context);
      if (beforeInvoke != null) return Err(beforeInvoke);
      final authority = context.authority;
      return await (agent && authority is AgentInvocation
          ? (authority as AgentInvocation).invokeAuthorized(capability, args, context)
          : capability.invoke(args, context));
    } on ArgumentError catch (e) {
      // An invalid model argument can contain a secret; never include it or an adapter's message in the result.
      return agent
          ? const Err(AppError('invalidArgument'))
          : Err(AppError('invalidArgument', detail: '${e.name}: ${e.message}'));
    }
  }
}

AppError? _stopped(RequestContext context) {
  if (context.cancellation?.isCancelled ?? false) return const AppError('cancelled');
  if (context.deadline case final deadline? when !DateTime.now().isBefore(deadline)) {
    return const AppError('deadlineExceeded');
  }
  if (!context.isCurrent) return const AppError('scopeChanged');
  return null;
}

Future<Result<void>> _waitPolicy(Future<Result<void>> work, RequestContext context) {
  final waiter = _PolicyWaiter();
  final result = waiter.future;
  work.then(waiter.complete, onError: waiter.fail);
  final stopped = _stopped(context);
  if (stopped != null) {
    waiter.complete(Err(stopped));
  } else {
    if (context.cancellation case final token?) {
      // The token keeps only this cleared waiter after completion, not arguments or the authority.
      token.whenCancelled.then((_) => waiter.complete(const Err(AppError('cancelled'))));
    }
    if (context.deadline case final deadline?) {
      waiter.timer = Timer(
        deadline.difference(DateTime.now()),
        () => waiter.complete(const Err(AppError('deadlineExceeded'))),
      );
    }
  }
  return result;
}

class _PolicyWaiter {
  Completer<Result<void>>? _result = Completer<Result<void>>();
  Timer? timer;
  Future<Result<void>> get future => _result!.future;

  void complete(Result<void> result) {
    final pending = _clear();
    pending?.complete(result);
  }

  void fail(Object error, StackTrace stack) {
    final pending = _clear();
    pending?.completeError(error, stack);
  }

  Completer<Result<void>>? _clear() {
    timer?.cancel();
    timer = null;
    final pending = _result;
    _result = null;
    return pending;
  }
}

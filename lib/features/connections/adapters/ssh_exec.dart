import 'dart:async';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import '../../../foundation/cancellation.dart';
import '../domain/transport.dart';

class _ExecCancellation {
  void Function()? action;

  void cancel() {
    final callback = action;
    action = null;
    callback?.call();
  }
}

void _watchCancellation(CancellationToken token, _ExecCancellation cancellation) {
  unawaited(token.whenCancelled.then((_) => cancellation.cancel()));
}

/// Collects one SSH execution and closes only its channel on every terminal path.
Future<ExecResult> runSshExec(
  Future<SSHSession> Function() open, {
  int limit = 1 << 20,
  Duration? timeout,
  CancellationToken? cancel,
}) async {
  if (limit < 0 || (timeout?.isNegative ?? false)) throw ArgumentError('Invalid execution limits');
  if (cancel?.isCancelled ?? false) throw const ExecError(ExecFailure.cancelled);
  if (timeout == Duration.zero) throw const ExecError(ExecFailure.timedOut);

  final result = Completer<ExecResult>();
  final cancellation = _ExecCancellation();
  final out = BytesBuilder(copy: false), err = BytesBuilder(copy: false);
  final subscriptions = <StreamSubscription<Uint8List>>[];
  SSHSession? session;
  Timer? timer;
  var finished = false, truncated = false, channelDone = false;
  var streamsDone = 0;

  void finish([Object? error, StackTrace? stack]) {
    if (finished) return;
    finished = true;
    timer?.cancel();
    cancellation.action = null;
    final current = session;
    session = null;
    try {
      current?.channel.destroy();
    } catch (cleanupError, cleanupStack) {
      error ??= cleanupError;
      stack ??= cleanupStack;
    }
    for (final subscription in subscriptions) {
      unawaited(subscription.cancel().catchError((Object _) {}));
    }
    subscriptions.clear();
    if (error != null) {
      result.completeError(error, stack);
    } else {
      result.complete(ExecResult(out.takeBytes(), err.takeBytes(), current?.exitCode, truncated: truncated));
    }
  }

  void maybeFinish() {
    if (streamsDone == 2 && channelDone) finish();
  }

  void collect(BytesBuilder into, Uint8List data) {
    if (finished) return;
    final room = limit - into.length;
    if (data.length > room) truncated = true;
    if (room > 0) into.add(data.length > room ? Uint8List.sublistView(data, 0, room) : data);
  }

  void listen(Stream<Uint8List> stream, BytesBuilder into) {
    subscriptions.add(
      stream.listen(
        (data) => collect(into, data),
        onError: (Object error, StackTrace stack) => finish(error, stack),
        onDone: () {
          streamsDone++;
          maybeFinish();
        },
      ),
    );
  }

  cancellation.action = () => finish(const ExecError(ExecFailure.cancelled));
  if (cancel != null) _watchCancellation(cancel, cancellation);
  if (timeout != null) timer = Timer(timeout, () => finish(const ExecError(ExecFailure.timedOut)));
  final callerZone = Zone.current;
  // SSHSession does not forward errors from its internal channel subscription to stdout/stderr.
  runZonedGuarded(() {
    final opening = open();
    // An opening future supplied by the caller must receive its errors in the caller's error zone.
    callerZone.run(() {
      unawaited(
        opening.then((opened) {
          try {
            // shortcut: execute hides opening channels; upgrade when dartssh2 exposes cancellable channel opening.
            if (finished) {
              opened.channel.destroy();
              return;
            }
            session = opened;
            listen(opened.stdout, out);
            listen(opened.stderr, err);
            unawaited(
              opened.done.then((_) {
                channelDone = true;
                maybeFinish();
              }, onError: (Object error, StackTrace stack) => finish(error, stack)),
            );
          } catch (error, stack) {
            finish(error, stack);
          }
        }, onError: (Object error, StackTrace stack) => finish(error, stack)),
      );
    });
  }, (error, stack) => finish(error, stack));
  return result.future;
}

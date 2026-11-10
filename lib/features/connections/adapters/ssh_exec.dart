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
  if (limit < 0) throw ArgumentError('Invalid execution limits');
  final out = BytesBuilder(copy: false), err = BytesBuilder(copy: false);
  var truncated = false;
  final code = await _runSshExec(
    open,
    onOutput: (stream, data) {
      final into = stream == ExecStream.stdout ? out : err;
      final room = limit - into.length;
      if (data.length > room) truncated = true;
      if (room > 0) into.add(Uint8List.fromList(data.length > room ? data.sublist(0, room) : data));
    },
    timeout: timeout,
    cancel: cancel,
  );
  return ExecResult(out.takeBytes(), err.takeBytes(), code, truncated: truncated);
}

/// Delivers each stream as it arrives; the caller consumes it synchronously into its own bounded storage.
Future<int?> runSshExecStreaming(
  Future<SSHSession> Function() open, {
  required void Function(ExecChunk) onOutput,
  Duration? timeout,
  CancellationToken? cancel,
}) => _runSshExec(
  open,
  onOutput: (stream, data) => onOutput(ExecChunk(stream, Uint8List.fromList(data))),
  timeout: timeout,
  cancel: cancel,
);

Future<int?> _runSshExec(
  Future<SSHSession> Function() open, {
  required void Function(ExecStream, Uint8List) onOutput,
  Duration? timeout,
  CancellationToken? cancel,
}) async {
  if (timeout?.isNegative ?? false) throw ArgumentError('Invalid execution limits');
  if (cancel?.isCancelled ?? false) throw const ExecError(ExecFailure.cancelled);
  if (timeout == Duration.zero) throw const ExecError(ExecFailure.timedOut);

  final result = Completer<int?>();
  final cancellation = _ExecCancellation();
  final subscriptions = <StreamSubscription<Uint8List>>[];
  SSHSession? session;
  Timer? timer;
  var finished = false, channelDone = false;
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
      result.complete(current?.exitCode);
    }
  }

  void maybeFinish() {
    if (streamsDone == 2 && channelDone) finish();
  }

  void listen(Stream<Uint8List> stream, ExecStream source) {
    subscriptions.add(
      stream.listen(
        (data) {
          if (finished) return;
          try {
            onOutput(source, data);
          } catch (error, stack) {
            finish(error, stack);
          }
        },
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
            listen(opened.stdout, ExecStream.stdout);
            listen(opened.stderr, ExecStream.stderr);
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

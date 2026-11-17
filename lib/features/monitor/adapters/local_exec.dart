import 'dart:async';
import 'dart:io' as io;
import 'dart:io' show Platform;
import 'dart:typed_data' show BytesBuilder;

import '../../../foundation/cancellation.dart';
import '../../connections/api.dart';
import '../application/monitor.dart';

/// Runs the monitor probe on this computer with the same `/bin/sh` a local terminal uses. Only macOS and Linux
/// provide the POSIX tools the probe reads; elsewhere callers do not offer the panel.
class LocalMonitorExec implements MonitorExec {
  const LocalMonitorExec();

  static bool get supported => Platform.isMacOS || Platform.isLinux;

  /// Goes in the panel header and the process window: the machine, not the shell.
  String get name => Platform.localHostname;

  @override
  Future<ExecResult> exec(String command, {required int limit, Duration? timeout, CancellationToken? cancel}) async {
    if (cancel?.isCancelled ?? false) throw const ExecError(ExecFailure.cancelled);
    final process = await io.Process.start('/bin/sh', ['-c', command]);
    final out = BytesBuilder(copy: false), err = BytesBuilder(copy: false);
    var outSize = 0, errSize = 0, truncated = false;

    // The rest keeps being drained after the cap, so the child never blocks on a full pipe.
    void collect(BytesBuilder into, List<int> chunk, int used) {
      final room = limit - used;
      if (room <= 0) {
        truncated = true;
        return;
      }
      if (chunk.length > room) {
        into.add(chunk.sublist(0, room));
        truncated = true;
      } else {
        into.add(chunk);
      }
    }

    final stdoutDone = process.stdout.listen((chunk) {
      collect(out, chunk, outSize);
      outSize += chunk.length;
    }).asFuture<void>();
    final stderrDone = process.stderr.listen((chunk) {
      collect(err, chunk, errSize);
      errSize += chunk.length;
    }).asFuture<void>();

    var stopped = false, cancelled = false, timedOut = false;
    void stop() {
      if (stopped) return;
      stopped = true;
      process.kill(io.ProcessSignal.sigkill);
    }

    final timer = timeout == null
        ? null
        : Timer(timeout, () {
            timedOut = true;
            stop();
          });
    if (cancel != null) {
      unawaited(
        cancel.whenCancelled.then((_) {
          cancelled = true;
          stop();
        }),
      );
    }
    try {
      final code = await process.exitCode;
      await stdoutDone;
      await stderrDone;
      if (cancelled) throw const ExecError(ExecFailure.cancelled);
      if (timedOut) throw const ExecError(ExecFailure.timedOut);
      return ExecResult(out.takeBytes(), err.takeBytes(), code, truncated: truncated);
    } finally {
      timer?.cancel();
    }
  }
}

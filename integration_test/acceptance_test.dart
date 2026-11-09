// Real Ubuntu acceptance; credentials are read only from the process environment (docs/TESTING.md §2).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sshairy/app/composition.dart';
import 'package:sshairy/features/connections/api.dart';
import 'package:sshairy/features/credentials/api.dart';
import 'package:sshairy/features/hosts/api.dart';
import 'package:sshairy/features/monitor/application/monitor.dart';
import 'package:sshairy/features/terminal/api.dart';
import 'package:sshairy/foundation/cancellation.dart';
import 'package:sshairy/foundation/data_dir.dart';
import 'package:sshairy/foundation/ids.dart';
import 'package:sshairy/foundation/secret.dart';

import 'support/server.dart';

class _NoSavedCredentials implements ConnectionCredentials {
  @override
  int get revision => 0;
  @override
  Future<Secret?> read(SecretRef ref) async => null;
  @override
  Future<void> remember(SecretRef ref, Secret value) async => throw StateError('test must not save credentials');
}

class _Harness {
  _Harness(this.data, this.container, this.host, this.prompts);

  final Directory data;
  final ProviderContainer container;
  final Host host;
  final ScriptedPrompts prompts;
  ConnectionManager get manager => container.read(connectionManagerProvider);

  static Future<_Harness> create() async {
    final server = TestServer.fromEnvironment();
    final data = await Directory.systemTemp.createTemp('sshairy-acceptance-');
    final container = ProviderContainer(
      overrides: [
        dataDirProvider.overrideWithValue(data.path),
        ...appOverrides(),
        connectionCredentialsProvider.overrideWithValue(_NoSavedCredentials()),
      ],
    );
    final host = server.host('acceptance', const AuthPolicy());
    await container.read(hostsProvider.notifier).save(host);
    return _Harness(data, container, host, ScriptedPrompts(server));
  }

  Future<TransportLease> acquire({LeasePurpose purpose = LeasePurpose.exec}) async {
    final cancel = CancellationToken();
    final timer = Timer(const Duration(seconds: 30), cancel.cancel);
    try {
      return await manager.acquire(host, prompts, purpose: purpose, cancel: cancel);
    } on Object catch (error) {
      fail('Acceptance connection failed (${error.runtimeType})');
    } finally {
      timer.cancel();
    }
  }

  Future<void> close() async {
    manager.closeAll();
    container.dispose();
    for (var attempt = 0; ; attempt++) {
      try {
        await data.delete(recursive: true);
        return;
      } on FileSystemException {
        if (attempt == 19) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
  }
}

String _quote(String value) => "'${value.replaceAll("'", r"'\''")}'";
String _sh(String script) => 'sh -c ${_quote(script)}';
String _nonce() => List.generate(8, (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0')).join();

Future<ExecResult> _run(TransportLease lease, String command, {int limit = 4096}) async {
  final ExecResult result;
  try {
    result = await lease.exec(command, limit: limit, timeout: const Duration(seconds: 10));
  } on Object catch (error) {
    fail('Acceptance execution failed (${error.runtimeType})');
  }
  expect(result.exitCode, 0);
  return result;
}

Future<void> _until(bool Function() ready, String failure, {Duration timeout = const Duration(seconds: 12)}) async {
  final elapsed = Stopwatch()..start();
  while (!ready()) {
    if (elapsed.elapsed >= timeout) fail(failure);
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}

class _OwnedScope {
  _OwnedScope(this.path);
  final String path;
  String get nested => '$path/nested with space';
  List<String> get records => [for (var i = 0; i < 4; i++) '$path/exec-$i'];

  static Future<_OwnedScope> create(TransportLease lease) async {
    final name = 'accept-${_nonce()}';
    final result = await _run(
      lease,
      _sh(
        'umask 077; mkdir -p "\$HOME/sshairy-test" && '
        'mkdir "\$HOME/sshairy-test/$name" && cd "\$HOME/sshairy-test/$name" && pwd -P',
      ),
    );
    final path = utf8.decode(result.stdout).trim();
    expect(
      path.startsWith('/') && path.endsWith('/sshairy-test/$name') && !path.contains('\n'),
      isTrue,
      reason: 'The remote scope must be an owned absolute directory',
    );
    return _OwnedScope(path);
  }

  Future<void> remove(TransportLease lease) async {
    // Only known test files and empty directories are removed, including on assertion failure.
    final result = await _run(
      lease,
      _sh(
        'rm -f -- ${records.map(_quote).join(' ')} && '
        'if [ -d ${_quote(nested)} ]; then rmdir -- ${_quote(nested)} || exit 1; fi; '
        'rmdir -- ${_quote(path)} && [ ! -e ${_quote(path)} ] && printf 1',
      ),
    );
    expect(utf8.decode(result.stdout).trim() == '1', isTrue, reason: 'The owned remote directory must be removed');
  }
}

Future<int> _expectFailure(Future<ExecResult> execution, ExecFailure kind, {Stopwatch? elapsed}) async {
  elapsed ??= Stopwatch()..start();
  try {
    await execution;
  } on ExecError catch (error) {
    expect(error.kind, kind);
    return elapsed.elapsedMilliseconds;
  } on Object catch (error) {
    fail('Unexpected execution failure (${error.runtimeType})');
  }
  fail('Execution completed instead of reporting its cancellation or deadline');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('exec deadlines and cancellation preserve the shared shell and transport', (tester) async {
    final h = await _Harness.create();
    TransportLease? shellLease, execLease;
    ShellChannel? shell;
    StreamSubscription<List<int>>? stdout, stderr;
    _OwnedScope? scope;
    try {
      shellLease = await h.acquire(purpose: LeasePurpose.terminal);
      try {
        shell = await shellLease.openShell(cols: 80, rows: 24);
      } on Object catch (error) {
        fail('Acceptance shell failed (${error.runtimeType})');
      }
      var text = '', shellEnded = false, streamFailed = false;
      stdout = shell.stdout.listen(
        (bytes) {
          text += utf8.decode(bytes, allowMalformed: true);
          if (text.length > 8192) text = text.substring(text.length - 8192);
        },
        onError: (Object _) {
          streamFailed = true;
        },
      );
      stderr = shell.stderr.listen(
        (_) {},
        onError: (Object _) {
          streamFailed = true;
        },
      );
      unawaited(
        shell.done.then(
          (_) {
            shellEnded = true;
          },
          onError: (Object _) {
            shellEnded = true;
          },
        ),
      );
      execLease = await h.acquire();
      expect(execLease.reused, isTrue);
      scope = await _OwnedScope.create(execLease);
      await _run(execLease, 'printf 1');

      final deadlines = <int>[], cancellations = <int>[];
      for (var i = 0; i < 4; i++) {
        // exec replaces this shell with a finite sleep while retaining its PID and /proc start time.
        final command = _sh(
          'pid=\$\$; start=\$(awk \'{print \$22}\' "/proc/\$pid/stat"); '
          'printf "%s %s\\n" "\$pid" "\$start" > ${_quote(scope.records[i])}; exec sleep 2',
        );
        if (i.isEven) {
          deadlines.add(
            await _expectFailure(
              execLease.exec(command, timeout: const Duration(milliseconds: 200)),
              ExecFailure.timedOut,
            ),
          );
        } else {
          final cancel = CancellationToken();
          final execution = execLease.exec(command, timeout: const Duration(seconds: 10), cancel: cancel);
          final responseElapsed = Stopwatch();
          // Attach the error handler before probing; the marker confirms execution reached our finite command.
          final cancelled = _expectFailure(execution, ExecFailure.cancelled, elapsed: responseElapsed);
          var started = false;
          try {
            final elapsed = Stopwatch()..start();
            while (!started && elapsed.elapsed < const Duration(seconds: 5)) {
              final result = await _run(
                execLease,
                _sh('if [ -f ${_quote(scope.records[i])} ]; then printf 1; else printf 0; fi'),
              );
              started = utf8.decode(result.stdout) == '1';
              if (!started) await Future<void>.delayed(const Duration(milliseconds: 25));
            }
            expect(started, isTrue, reason: 'The cancellation scenario must reach its own remote command');
            await Future<void>.delayed(const Duration(milliseconds: 200));
          } finally {
            responseElapsed.start();
            cancel.cancel();
          }
          cancellations.add(await cancelled);
        }
        expect(execLease.lost, isFalse);
        expect(shellEnded || streamFailed, isFalse);
        final alive = await _run(execLease, 'printf 1');
        expect(utf8.decode(alive.stdout) == '1', isTrue);
      }
      expect(deadlines.every((ms) => ms < 1800), isTrue);
      expect(cancellations.every((ms) => ms < 1800), isTrue);

      final bounded = await _run(execLease, _sh('printf 1234567890; printf abcdefghij >&2'), limit: 8);
      expect(bounded.truncated, isTrue);
      expect(bounded.stdout.length, 8);
      expect(bounded.stderr.length, 8);

      final marker = _nonce();
      shell.write(utf8.encode("printf '%s%s\\n' 'accept-' '$marker'\r"));
      await _until(() => text.contains('accept-$marker'), 'The original shell did not respond after exec cancellation');
      expect(shellEnded || streamFailed, isFalse);

      // Cancellation returns before this wait. This separate probe checks only our recorded finite commands.
      await Future<void>.delayed(const Duration(seconds: 3));
      final probe = await _run(
        execLease,
        _sh(
          'tracked=0; active=0; for f in ${scope.records.map(_quote).join(' ')}; do '
          '[ -f "\$f" ] || continue; read -r pid start < "\$f" || exit 1; '
          'case "\$pid:\$start" in *[!0-9:]*|:*|*:) exit 1;; esac; tracked=\$((tracked + 1)); '
          'current=\$(awk \'\$3 != "Z" {print \$22}\' "/proc/\$pid/stat" 2>/dev/null); '
          '[ "\$current" = "\$start" ] && active=\$((active + 1)); '
          'done; printf "%s %s\\n" "\$tracked" "\$active"',
        ),
      );
      final counts = utf8.decode(probe.stdout).trim().split(RegExp(r'\s+')).map(int.parse).toList();
      expect(counts.length, 2);
      expect(counts[1], 0, reason: 'Recorded finite commands must finish without sending process signals');
      print(
        'REPORT execDeadlines=${deadlines.length} execCancellations=${cancellations.length} '
        'deadlineMaxMs=${deadlines.reduce(max)} cancelMaxMs=${cancellations.reduce(max)} '
        'trackedCommands=${counts[0]} activeTrackedCommands=${counts[1]} '
        'boundedBytes=${bounded.stdout.length + bounded.stderr.length} shellResponsive=1',
      );
    } finally {
      try {
        if (scope != null && execLease != null) await scope.remove(execLease);
      } finally {
        shell?.close();
        execLease?.release();
        shellLease?.release();
        await stdout?.cancel();
        await stderr?.cancel();
        await h.close();
      }
    }
  });

  testWidgets('monitor samples on authentication, stops and restarts on a real connection', (tester) async {
    final h = await _Harness.create();
    final monitor = ServerMonitor(h.manager, h.host, interval: const Duration(seconds: 30));
    final stopProcesses = monitor.watchProcesses();
    TransportLease? lease;
    try {
      monitor.start();
      await _until(() => monitor.state == MonitorState.offline, 'Offline monitoring did not settle');
      expect(h.manager.hosts.length, 0, reason: 'Starting the monitor must not dial');
      lease = await h.acquire(purpose: LeasePurpose.terminal);
      final firstElapsed = Stopwatch()..start();
      await _until(
        () => monitor.snapshot != null && monitor.state == MonitorState.live,
        'The authentication event did not produce a live monitor sample',
      );
      final firstMs = firstElapsed.elapsedMilliseconds;
      final first = monitor.snapshot!;
      expect(first.sample.cpu != null && first.sample.cpu!.total > 0, isTrue);
      expect(first.sample.memTotalKib, greaterThan(0));
      expect(first.sample.disks.length, greaterThan(0));
      expect(first.sample.processes.length, greaterThan(0));
      expect(first.processes.length, greaterThan(0));

      monitor.refresh();
      await _until(() => !identical(monitor.snapshot, first), 'The second monitor sample did not arrive');
      final second = monitor.snapshot!;
      expect(second.cpu != null && second.cpu! >= 0 && second.cpu! <= 1, isTrue);
      expect(second.coreUsage.length, greaterThan(0));
      expect(second.memory >= 0 && second.memory <= 1, isTrue);

      monitor.stop();
      expect(monitor.running, isFalse);
      final history = monitor.memory.length;
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(identical(monitor.snapshot, second), isTrue);
      expect(monitor.memory.length, history);
      expect(lease.lost, isFalse);
      expect(utf8.decode((await _run(lease, 'printf 1')).stdout) == '1', isTrue);

      final restartElapsed = Stopwatch()..start();
      monitor.start();
      await _until(
        () => !identical(monitor.snapshot, second) && monitor.state == MonitorState.live,
        'Restarting the monitor did not produce an immediate sample',
      );
      print(
        'REPORT monitorFirstMs=$firstMs monitorRestartMs=${restartElapsed.elapsedMilliseconds} '
        'cpuCores=${second.coreUsage.length} disks=${second.sample.disks.length} '
        'processes=${second.processes.length} retainedSamples=$history monitorRestarts=1',
      );
    } finally {
      stopProcesses();
      monitor.dispose();
      lease?.release();
      await h.close();
    }
  });

  testWidgets('terminal directory following resolves real shell changes and spaces', (tester) async {
    final h = await _Harness.create();
    TransportLease? lease;
    TerminalSession? session;
    Future<void>? connected;
    _OwnedScope? scope;
    void directoryChanged() {}
    try {
      lease = await h.acquire();
      scope = await _OwnedScope.create(lease);
      await _run(lease, _sh('mkdir -- ${_quote(scope.nested)}'));
      final terminal = session = TerminalSession(const SessionId('acceptance-directory'), h.host, h.manager);
      terminal.directory.addListener(directoryChanged);
      connected = terminal.connect(h.prompts);
      await _until(() => terminal.canInsert, 'The directory-following terminal did not connect');
      for (final path in [scope.path, scope.nested, scope.path]) {
        expect(
          await terminal.insert('cd -- ${_quote(path)}', run: true, confirm: (_) async => true),
          InsertResult.sent,
        );
        await _until(
          () => terminal.directory.value == path,
          'The real shell directory was not resolved; server marker acceptance or OSC 7 needs checking',
        );
      }
      expect(terminal.status, SessionStatus.connected);
      expect(lease.lost, isFalse);
      print('REPORT directoryChanges=3 directoryWithSpaces=1 directoryResolved=1');
    } finally {
      try {
        session?.directory.removeListener(directoryChanged);
        session?.close();
        if (connected != null) await connected.timeout(const Duration(seconds: 5));
      } finally {
        try {
          if (scope != null && lease != null) await scope.remove(lease);
        } finally {
          lease?.release();
          await h.close();
        }
      }
    }
  });
}

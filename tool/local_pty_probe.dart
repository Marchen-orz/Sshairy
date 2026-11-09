import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:sshairy/features/terminal/adapters/local_shells.dart';
import 'package:sshairy/features/terminal/adapters/windows_pty.dart';
import 'package:sshairy/features/terminal/domain/terminal_target.dart';
import 'package:sshairy/foundation/cancellation.dart';

// Own processes only, no SSH, no user configuration/profile, bounded output and temporary cwd.
class _ProbeShell extends LocalShell {
  _ProbeShell(LocalShell shell) : super(kind: shell.kind, executable: shell.executable);
  @override
  List<String> get arguments => switch (kind) {
    LocalShellKind.cmd => const ['/d'],
    LocalShellKind.powershell || LocalShellKind.pwsh => const ['-NoLogo', '-NoProfile'],
    LocalShellKind.gitBash => const ['--noprofile', '--norc', '-i'],
  };
}

String _echo(LocalShell shell, String value) => switch (shell.kind) {
  LocalShellKind.cmd =>
    'set SSHAIRY_PROBE=${value.substring(0, value.length - 2)}\r\necho %SSHAIRY_PROBE%${value.substring(value.length - 2)}\r',
  LocalShellKind.powershell || LocalShellKind.pwsh =>
    "Write-Output ('${value.substring(0, value.length - 2)}' + '${value.substring(value.length - 2)}')\r",
  LocalShellKind.gitBash =>
    "printf '${value.substring(0, value.length - 2)}%s\\n' ${value.substring(value.length - 2)}\r",
};

bool _promptReady(LocalShell shell, String text) {
  final plain = text
      .replaceAll(RegExp(r'\x1b\[[0-?]*[ -/]*[@-~]'), '')
      .replaceAll(RegExp(r'\x1b\][^\x07]*(?:\x07|\x1b\\)'), '');
  return switch (shell.kind) {
    LocalShellKind.cmd => RegExp(r'[A-Za-z]:\\[^\r\n]*>').hasMatch(plain),
    LocalShellKind.powershell || LocalShellKind.pwsh => RegExp(r'PS [^\r\n]*> ').hasMatch(plain),
    LocalShellKind.gitBash => RegExp(r'bash-[\d.]+\$ ').hasMatch(plain),
  };
}

int _handles() {
  final kernel = DynamicLibrary.open('kernel32.dll');
  final current = kernel.lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>('GetCurrentProcess');
  final get = kernel
      .lookupFunction<Int32 Function(Pointer<Void>, Pointer<Uint32>), int Function(Pointer<Void>, Pointer<Uint32>)>(
        'GetProcessHandleCount',
      );
  final count = calloc<Uint32>();
  try {
    if (get(current(), count) == 0) throw StateError('Cannot count own handles');
    return count.value;
  } finally {
    calloc.free(count);
  }
}

Future<void> _gitResizeRegression(String directory, LocalShell shell) async {
  for (final mode in ['no-resize', 'resize-immediate', 'resize-rapid', 'resize-without-input']) {
    for (var round = 0; round < 5; round++) {
      final pty = await WindowsPtyFactory(workingDirectory: directory).start(shell, cols: 100, rows: 30);
      var text = '';
      final prompt = Completer<void>(),
          redraw = Completer<void>(),
          response = Completer<void>(),
          second = Completer<void>();
      final subscription = pty.output.cast<List<int>>().transform(utf8.decoder).listen((part) {
        text += part;
        if (text.length > 32768) text = text.substring(text.length - 32768);
        if (_promptReady(shell, text) && !prompt.isCompleted) prompt.complete();
        if (text.contains('\x1b[8;35;120t') && !redraw.isCompleted) redraw.complete();
        if (text.contains('SSHAIRY_NATIVE_OK') && !response.isCompleted) response.complete();
        if (text.contains('SSHAIRY_SECOND_OK') && !second.isCompleted) second.complete();
      });
      try {
        await prompt.future.timeout(const Duration(seconds: 10));
        if (mode == 'resize-rapid') {
          for (var size = 105; size <= 115; size++) {
            pty.resize(size, 32);
          }
        }
        if (mode != 'no-resize') pty.resize(120, 35);
        if (mode == 'resize-without-input') {
          await redraw.future.timeout(const Duration(seconds: 10));
          // Send a command to the empty prompt without typing anything first: no compatibility key may enter it.
          pty.write(utf8.encode('\r'));
          pty.write(utf8.encode(_echo(shell, 'SSHAIRY_NATIVE_OK')));
        } else {
          pty.write(utf8.encode(_echo(shell, 'SSHAIRY_NATIVE_OK')));
        }
        await response.future.timeout(const Duration(seconds: 10));
        pty.write(utf8.encode(_echo(shell, 'SSHAIRY_SECOND_OK')));
        await second.future.timeout(const Duration(seconds: 10));
        if (text.contains('command not found')) throw StateError('Unexpected input after resize in $mode');
      } finally {
        pty.close();
        await pty.exitCode.timeout(const Duration(seconds: 10));
        await subscription.cancel();
      }
      if (round == 4) stdout.writeln('Git Bash $mode: 5 successful shells');
    }
  }
}

Future<void> main() async {
  final temporary = await Directory.systemTemp.createTemp('sshairy-pty-');
  final shells = discoverLocalShells().map(_ProbeShell.new).toList();
  if (shells.isEmpty) throw StateError('No supported shells found');
  try {
    final gitBash = shells.where((s) => s.kind == LocalShellKind.gitBash).firstOrNull;
    if (gitBash != null) await _gitResizeRegression(temporary.path, gitBash);
    for (final shell in shells) {
      final pty = await WindowsPtyFactory(workingDirectory: temporary.path).start(shell, cols: 100, rows: 30);
      var text = '';
      final ready = Completer<void>(), seen = Completer<void>(), tail = Completer<void>(), eof = Completer<void>();
      var protocolTail = '';
      final subscription = pty.output.cast<List<int>>().transform(utf8.decoder).listen((part) {
        protocolTail = '$protocolTail$part';
        if (protocolTail.contains('\x1b[6n') || protocolTail.contains('\x1b[?6n')) {
          // Real TerminalSession answers this through xterm; a raw probe must provide its own cursor report.
          pty.write(utf8.encode('\x1b[1;1R'));
          protocolTail = '';
        }
        if (protocolTail.length > 16) protocolTail = protocolTail.substring(protocolTail.length - 16);
        text = '$text$part';
        if (text.length > 32768) text = text.substring(text.length - 32768);
        if (_promptReady(shell, text) && !ready.isCompleted) ready.complete();
        if (text.contains('SSHAIRY_NATIVE_OK') && !seen.isCompleted) seen.complete();
        if (text.contains('SSHAIRY_FINAL_TAIL') && !tail.isCompleted) tail.complete();
      }, onDone: eof.complete);
      try {
        await ready.future.timeout(const Duration(seconds: 12));
        pty.resize(120, 35);
        pty.write(utf8.encode(_echo(shell, 'SSHAIRY_NATIVE_OK')));
        try {
          await seen.future.timeout(const Duration(seconds: 12));
        } on TimeoutException {
          stdout.writeln('${shell.name} response missing; last VT ${jsonEncode(text)}');
          rethrow;
        }
        pty.write(utf8.encode('${_echo(shell, 'SSHAIRY_FINAL_TAIL')}exit\r'));
        final exit = await pty.exitCode.timeout(const Duration(seconds: 12));
        await eof.future.timeout(const Duration(seconds: 12));
        if (exit != 0 || !tail.isCompleted) throw StateError('Exit/tail failure for ${shell.name}');
        stdout.writeln('${shell.name}: actual output/resize/final tail/exit complete');
      } finally {
        pty.close();
        await pty.exitCode.timeout(const Duration(seconds: 12));
        await subscription.cancel();
      }
    }

    // A finite command writes a few MiB. Pausing must stop native delivery without losing its final frame.
    final powershell = shells.where((s) => s.kind == LocalShellKind.pwsh || s.kind == LocalShellKind.powershell).first;
    final pressure = await WindowsPtyFactory(workingDirectory: temporary.path).start(powershell, cols: 120, rows: 35);
    var received = 0, pressureTail = '';
    final pressureReady = Completer<void>(), reached = Completer<void>();
    final pressureSub = pressure.output.cast<List<int>>().transform(utf8.decoder).listen((part) {
      received += part.length;
      pressureTail = '$pressureTail$part';
      if (pressureTail.length > 32768) pressureTail = pressureTail.substring(pressureTail.length - 32768);
      if (_promptReady(powershell, pressureTail) && !pressureReady.isCompleted) pressureReady.complete();
      if (received >= 128 * 1024 && !reached.isCompleted) reached.complete();
    });
    try {
      await pressureReady.future.timeout(const Duration(seconds: 12));
      pressure.write(
        utf8.encode(
          "1..25000 | ForEach-Object { 'SSHAIRY_BOUNDED_' + ('x' * 100) }; Write-Output ('SSHAIRY_PRESSURE_' + 'TAIL'); exit\r",
        ),
      );
      await reached.future.timeout(const Duration(seconds: 20));
      pressureSub.pause();
      final paused = received;
      await Future<void>.delayed(const Duration(milliseconds: 350));
      if (received != paused) throw StateError('Output delivered while paused');
      pressureSub.resume();
      final exit = await pressure.exitCode.timeout(const Duration(seconds: 35));
      if (exit != 0 || !pressureTail.contains('SSHAIRY_PRESSURE_TAIL')) throw StateError('High output tail missing');
      stdout.writeln('Backpressure/resume/final tail complete: $received chars');
    } finally {
      pressure.close();
      await pressure.exitCode.timeout(const Duration(seconds: 12));
      await pressureSub.cancel();
    }

    final cmd = shells.firstWhere((s) => s.kind == LocalShellKind.cmd);
    final factory = WindowsPtyFactory(workingDirectory: temporary.path);
    final baseline = _handles();
    for (var i = 0; i < 8; i++) {
      final pty = await factory.start(cmd, cols: 80, rows: 24);
      final subscription = pty.output.listen((_) {});
      if (i.isEven) subscription.pause();
      pty.close();
      await pty.exitCode.timeout(const Duration(seconds: 12));
      await subscription.cancel();
    }
    for (var i = 0; i < 4; i++) {
      final cancel = CancellationToken();
      final starting = factory.start(cmd, cols: 80, rows: 24, cancel: cancel);
      cancel.cancel();
      try {
        final pty = await starting.timeout(const Duration(seconds: 12));
        pty.close();
        await pty.exitCode;
        throw StateError('Cancelled startup returned a live PTY');
      } on StateError catch (e) {
        if (e.message != 'Local terminal cancelled') rethrow;
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final retained = _handles() - baseline;
    if (retained > 4) throw StateError('Native handles retained after repeated close: $retained');
    stdout.writeln('8 repeated closes + 4 cancelled starts complete; own handle delta $retained');
    stdout.writeln('Native PTY probe complete: ${shells.length} shells');
  } finally {
    await temporary.delete(recursive: true);
  }
}

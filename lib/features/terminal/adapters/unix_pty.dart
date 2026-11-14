import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import '../../../foundation/cancellation.dart';
import '../domain/local_pty.dart';
import '../domain/terminal_target.dart';

/// The bundled single-threaded helper owns fork/exec, the PTY and the shell's process session.
class UnixPtyFactory implements LocalPtyFactory {
  const UnixPtyFactory({this.helperExecutable, this.workingDirectory});

  final String? helperExecutable, workingDirectory;

  static String bundledHelper(String executable, {required bool macos}) {
    final directory = File(executable).parent.path;
    return '$directory/${macos ? '' : 'lib/'}sshairy_pty';
  }

  @override
  Future<LocalPty> start(LocalShell shell, {required int cols, required int rows, CancellationToken? cancel}) async {
    if ((!Platform.isLinux && !Platform.isMacOS) ||
        !shell.executable.startsWith('/') ||
        !LocalShell.validExecutable(shell.executable)) {
      throw StateError('Local terminal unavailable');
    }
    if (cancel?.isCancelled ?? false) throw StateError('Local terminal cancelled');
    final Process process;
    try {
      process = await Process.start(
        helperExecutable ?? bundledHelper(Platform.resolvedExecutable, macos: Platform.isMacOS),
        [
          '${cols.clamp(1, 32767)}',
          '${rows.clamp(1, 32767)}',
          workingDirectory ?? Platform.environment['HOME'] ?? Directory.current.path,
          '--',
          shell.executable,
          ...shell.arguments,
        ],
        environment: const {'TERM': 'xterm-256color', 'COLORTERM': 'truecolor'},
      );
    } on Object {
      throw StateError('Local terminal start failed');
    }
    final pty = _UnixPty(process);
    if (cancel != null) {
      var settled = false;
      void finish([Object? _]) {
        settled = true;
      }

      unawaited(pty.exitCode.then(finish, onError: finish));
      final stop = pty.close;
      unawaited(
        cancel.whenCancelled.then((_) {
          if (!settled) stop();
        }),
      );
    }
    try {
      if (cancel?.isCancelled ?? false) pty.close();
      await pty.ready.timeout(const Duration(seconds: 8));
      if (cancel?.isCancelled ?? false) throw StateError('Local terminal cancelled');
      return pty;
    } on Object {
      pty.close();
      await pty.exitCode;
      rethrow;
    }
  }
}

class _UnixPty implements LocalPty {
  _UnixPty(this._process) {
    unawaited(_process.stdin.done.catchError((Object _) {}));
    _process.stderr.listen(
      (bytes) {
        if (_ready.isCompleted) return;
        _startup.addAll(bytes);
        if (_startup.length > 8 || (_startup.isNotEmpty && _startup.first != 82)) {
          _ready.completeError(StateError('Local terminal start failed'));
          close();
        } else if (_startup.length >= 2 && _startup[0] == 82 && _startup[1] == 10) {
          _ready.complete();
          _startup.clear();
        }
      },
      onError: (Object _) => _failed(),
      onDone: () {
        if (!_ready.isCompleted) _failed();
      },
    );
    _process.exitCode.then(
      (code) {
        _code = code;
        _kill?.cancel();
        // The stderr handshake may still be queued when a short-lived shell has already exited.
        _finish();
      },
      onError: (Object _) {
        _code = -1;
        _failed();
        _finish();
      },
    );
  }

  final Process _process;
  final _ready = Completer<void>(), _exit = Completer<int>();
  final _startup = <int>[];
  final _input = Queue<Uint8List>();
  late final StreamController<Uint8List> _output = StreamController<Uint8List>(
    sync: true,
    onListen: _listen,
    onPause: () => _reader?.pause(),
    onResume: () => _reader?.resume(),
    onCancel: close,
  );
  StreamSubscription<List<int>>? _reader;
  Timer? _kill;
  ({int cols, int rows})? _size;
  int? _code;
  var _closed = false, _eof = false, _writing = false;
  var _pendingInput = 0;

  Future<void> get ready => _ready.future;
  @override
  Stream<Uint8List> get output => _output.stream;
  @override
  Future<int> get exitCode => _exit.future;

  void _listen() {
    if (_reader != null) return;
    _reader = _process.stdout.listen(
      (data) {
        if (!_closed && !_output.isClosed) _output.add(Uint8List.fromList(data));
      },
      onError: (Object _) {
        _failed();
      },
      onDone: () {
        _eof = true;
        if (!_output.isClosed) unawaited(_output.close());
        _finish();
      },
    );
  }

  void _finish() {
    if (!_eof || _code == null || _exit.isCompleted) return;
    _kill?.cancel();
    _input.clear();
    _pendingInput = 0;
    _exit.complete(_code!);
    unawaited(_process.stdin.close().catchError((Object _) {}));
  }

  void _failed() {
    if (!_ready.isCompleted) {
      _ready.completeError(StateError('Local terminal start failed'));
    } else if (!_closed && !_output.isClosed) {
      _output.addError(StateError('Local terminal I/O failed'));
    }
    close();
  }

  static Uint8List _frame(int type, Uint8List payload) {
    final frame = Uint8List(payload.length + 5);
    frame[0] = type;
    ByteData.sublistView(frame).setUint32(1, payload.length);
    frame.setRange(5, frame.length, payload);
    return frame;
  }

  Future<void> _pump() async {
    if (_writing || _closed) return;
    _writing = true;
    try {
      while (!_closed && (_size != null || _input.isNotEmpty)) {
        final size = _size;
        Uint8List payload;
        if (size != null) {
          _size = null;
          payload = Uint8List(4);
          ByteData.sublistView(payload)
            ..setUint16(0, size.cols)
            ..setUint16(2, size.rows);
        } else {
          payload = _input.removeFirst();
        }
        _process.stdin.add(_frame(size != null ? 2 : 1, payload));
        await _process.stdin.flush();
        if (size == null) _pendingInput = (_pendingInput - payload.length).clamp(0, 1024 * 1024);
      }
    } on Object {
      if (_code == null) _failed();
    } finally {
      _writing = false;
    }
  }

  @override
  void write(Uint8List data) {
    if (_closed || _code != null || data.isEmpty) return;
    if (_pendingInput + data.length > 1024 * 1024) {
      close();
      return;
    }
    _pendingInput += data.length;
    for (var offset = 0; offset < data.length; offset += 16384) {
      _input.add(Uint8List.fromList(data.sublist(offset, (offset + 16384).clamp(0, data.length))));
    }
    unawaited(_pump());
  }

  @override
  void resize(int cols, int rows) {
    if (_closed || _code != null || cols < 1 || rows < 1) return;
    _size = (cols: cols.clamp(1, 32767), rows: rows.clamp(1, 32767));
    unawaited(_pump());
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    if (!_ready.isCompleted) _ready.completeError(StateError('Local terminal cancelled'));
    _input.clear();
    _pendingInput = 0;
    _size = null;
    _listen();
    _reader?.resume();
    // SIGTERM asks the helper to hang up only its own shell session and reap it before exiting.
    if (_code == null) {
      _process.kill(ProcessSignal.sigterm);
      _kill = Timer(const Duration(seconds: 2), () {
        if (_code == null) _process.kill(ProcessSignal.sigkill);
      });
    }
    unawaited(_process.stdin.close().catchError((Object _) {}));
  }
}

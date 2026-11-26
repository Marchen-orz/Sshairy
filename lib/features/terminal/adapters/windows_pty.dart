import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../../../foundation/cancellation.dart';
import '../domain/local_pty.dart';
import '../domain/terminal_target.dart';

/// ConPTY's blocking reads, writes and shutdown each stay off the Flutter isolate.
class WindowsPtyFactory implements LocalPtyFactory {
  const WindowsPtyFactory({this.workingDirectory});

  final String? workingDirectory;

  @override
  Future<LocalPty> start(
    LocalShell shell, {
    required int cols,
    required int rows,
    String? directory,
    CancellationToken? cancel,
  }) async {
    if (!Platform.isWindows || !LocalShell.validExecutable(shell.executable)) {
      throw StateError('Local terminal unavailable');
    }
    if (cancel?.isCancelled ?? false) throw StateError('Local terminal cancelled');
    final pty = _WindowsPty();
    try {
      unawaited(cancel?.whenCancelled.then((_) => pty.close()));
      await pty.start(shell, cols, rows, directory ?? workingDirectory);
      if (cancel?.isCancelled ?? false) {
        pty.close();
        await pty.exitCode;
        throw StateError('Local terminal cancelled');
      }
      return pty;
    } on Object {
      pty.close();
      rethrow;
    }
  }
}

class _WindowsPty implements LocalPty {
  final _events = ReceivePort();
  final _ready = Completer<void>();
  final _exit = Completer<int>();
  late final StreamController<Uint8List> _output = StreamController<Uint8List>(
    sync: true,
    onListen: () {
      _listening = true;
      _acknowledge();
    },
    onPause: () => _paused = true,
    onResume: () {
      _paused = false;
      _acknowledge();
    },
    onCancel: close,
  );
  SendPort? _control, _reader;
  var _paused = false, _pendingAck = false, _closed = false, _eof = false, _listening = false;
  int? _code;
  var _pendingInput = 0;

  Future<void> start(LocalShell shell, int cols, int rows, String? workingDirectory) async {
    _events.listen(_message);
    await Isolate.spawn(
      _runPty,
      [
        _events.sendPort,
        shell.executable,
        shell.arguments,
        cols,
        rows,
        workingDirectory,
        shell.kind == LocalShellKind.gitBash,
      ],
      onError: _events.sendPort,
      onExit: _events.sendPort,
    );
    return _ready.future;
  }

  void _message(dynamic message) {
    if (message == null) {
      if (_code == null && !_exit.isCompleted) _message(['failed']);
      return;
    }
    if (message is List &&
        message.length == 2 &&
        message[0] != 'output' &&
        message[0] != 'exit' &&
        message[0] != 'inputDone' &&
        message[0] != 'control') {
      _message(['failed']);
      return;
    }
    final data = message as List;
    switch (data[0]) {
      case 'control':
        _control = data[1] as SendPort;
        if (_closed) _control!.send(['close']);
      case 'ready':
        _reader = data[1] as SendPort;
        if (_closed) {
          _reader!.send('drain');
          _control?.send(['close']);
        }
        if (!_ready.isCompleted) _ready.complete();
      case 'output':
        if (_closed) {
          _reader?.send('ack');
        } else {
          _pendingAck = true;
          _output.add(data[1] as Uint8List);
          _acknowledge();
        }
      case 'ioError':
        if (!_closed && !_output.isClosed) _output.addError(StateError('Local terminal I/O failed'));
      case 'inputDone':
        _pendingInput -= data[1] as int;
      case 'eof':
        _eof = true;
        if (!_output.isClosed) unawaited(_output.close());
        _finish();
      case 'exit':
        _code = data[1] as int;
        _finish();
      case 'failed':
        if (!_ready.isCompleted) {
          _ready.completeError(StateError('Local terminal start failed'));
        } else if (!_closed && !_output.isClosed) {
          _output.addError(StateError('Local terminal failed'));
        }
        _code = -1;
        _eof = true;
        if (!_output.isClosed) unawaited(_output.close());
        _finish();
    }
  }

  void _acknowledge() {
    if (!_pendingAck || _paused || !_listening) return;
    _pendingAck = false;
    _reader?.send('ack');
  }

  void _finish() {
    if (!_eof || _code == null || _exit.isCompleted) return;
    _exit.complete(_code!);
    _events.close();
    _control = _reader = null;
  }

  @override
  Stream<Uint8List> get output => _output.stream;
  @override
  Future<int> get exitCode => _exit.future;
  @override
  void write(Uint8List data) {
    if (_closed || _code != null || data.isEmpty) return;
    // A stalled local process must not turn unbounded paste events into an isolate mailbox.
    if (_pendingInput + data.length > 1024 * 1024) {
      close();
      return;
    }
    _pendingInput += data.length;
    _control?.send(['input', Uint8List.fromList(data)]);
  }

  @override
  void resize(int cols, int rows) {
    if (!_closed && cols > 0 && rows > 0) _control?.send(['resize', cols.clamp(1, 32767), rows.clamp(1, 32767)]);
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _reader?.send('drain');
    _control?.send(['close']);
  }
}

// The worker owns the process, job, pseudoconsole and all handles until handed to its I/O workers.
Future<void> _runPty(List<Object?> request) async {
  final main = request[0] as SendPort;
  final commands = ReceivePort();
  main.send(['control', commands.sendPort]);
  final api = _Kernel();
  Pointer<Void> process = nullptr, job = nullptr, console = nullptr;
  Pointer<Void> input = nullptr, output = nullptr, thread = nullptr;
  SendPort? reader, writer;
  Timer? poll;
  var closing = false, started = false, requestedClose = false;
  final readerDone = Completer<void>(), writerDone = Completer<void>();
  int? code;
  Future<void> stop() async {
    requestedClose = true;
    if (closing || !started) return;
    closing = true;
    poll?.cancel();
    if (code == null && process != nullptr) {
      api.terminateJob(job, 1);
      api.terminateProcess(process, 1);
    }
    writer?.send(null);
    // ClosePseudoConsole can wait for its output pipe. The separate reader continues draining with main-isolate ACKs.
    if (console != nullptr) {
      api.closeConsole(console);
      console = nullptr;
    }
    if (reader != null) await readerDone.future;
    if (writer != null) await writerDone.future;
    if (process != nullptr) api.close(process);
    if (job != nullptr) api.close(job);
    process = job = nullptr;
    main.send(['exit', code ?? -1]);
    commands.close();
  }

  commands.listen((dynamic message) {
    final event = message as List;
    switch (event[0]) {
      case 'readerReady':
        reader = event[1] as SendPort;
        if (requestedClose) reader!.send('drain');
      case 'writerReady':
        writer = event[1] as SendPort;
      case 'readerDone':
        if (!readerDone.isCompleted) readerDone.complete();
      case 'writerDone':
        if (!writerDone.isCompleted) writerDone.complete();
      case 'close':
        reader?.send('drain');
        unawaited(stop());
      case 'input':
        if (!closing) writer?.send([event[1], (event[1] as Uint8List).length]);
      case 'resize':
        if (!closing && console != nullptr) {
          api.resizeConsole(console, _coord(event[1] as int, event[2] as int));
          if (request[6] == true) {
            // shortcut: MSYS 3.4.10 can discard the first KEY_EVENT after SIGWINCH while resuming an old input
            // snapshot. A characterless key-up is ignored normally and absorbs that stale discard. Remove when
            // an upgraded Git runtime passes the concurrent resize/input probe without this compatibility record.
            writer?.send([utf8.encode('\x1b[0;0;0;0;0;1_'), 0]);
          }
        }
      case 'ioFailed':
        if (!closing) main.send(['ioError']);
        reader?.send('drain');
        unawaited(stop());
    }
  });
  try {
    final native = _spawn(
      api,
      request[1] as String,
      (request[2] as List).cast<String>(),
      request[3] as int,
      request[4] as int,
      request[5] as String?,
    );
    process = native.process;
    thread = native.thread;
    job = native.job;
    console = native.console;
    input = native.input;
    output = native.output;
    await Isolate.spawn(_readPipe, [output.address, main, commands.sendPort]);
    output = nullptr;
    while (reader == null) {
      await Future<void>.delayed(Duration.zero);
    }
    await Isolate.spawn(_writePipe, [input.address, main, commands.sendPort]);
    input = nullptr;
    while (writer == null) {
      await Future<void>.delayed(Duration.zero);
    }
    started = true;
    main.send(['ready', reader!, writer!]);
    // Child starts suspended: its output reader is present before shell startup can fill the console pipe.
    if (!requestedClose && api.resumeThread(native.thread) == 0xffffffff) {
      throw StateError('Local terminal resume failed');
    }
    api.close(thread);
    thread = nullptr;
    if (requestedClose) {
      await stop();
      return;
    }
    poll = Timer.periodic(const Duration(milliseconds: 20), (_) {
      final status = calloc<Uint32>();
      try {
        final queried = api.getExitCode(process, status) != 0;
        if (!queried || status.value != 259) {
          code = queried ? status.value : -1;
          unawaited(stop());
        }
      } finally {
        calloc.free(status);
      }
    });
  } on Object {
    reader?.send('drain');
    writer?.send(null);
    if (job != nullptr) api.terminateJob(job, 1);
    if (process != nullptr) api.terminateProcess(process, 1);
    if (console != nullptr) api.closeConsole(console);
    if (input != nullptr) api.close(input);
    if (output != nullptr) api.close(output);
    if (reader != null) await readerDone.future;
    if (writer != null) await writerDone.future;
    if (process != nullptr) api.close(process);
    if (thread != nullptr) api.close(thread);
    if (job != nullptr) api.close(job);
    main.send(['failed']);
    commands.close();
  }
}

Future<void> _readPipe(List<Object> request) async {
  final handle = Pointer<Void>.fromAddress(request[0] as int);
  final main = request[1] as SendPort, owner = request[2] as SendPort;
  final commands = ReceivePort();
  _Kernel? ownedApi;
  Pointer<Uint8> buffer = nullptr;
  Pointer<Uint32> count = nullptr;
  var drain = false;
  Completer<void>? ack;
  owner.send(['readerReady', commands.sendPort]);
  try {
    final api = ownedApi = _Kernel();
    buffer = calloc<Uint8>(8192);
    count = calloc<Uint32>();
    commands.listen((dynamic message) {
      if (message == 'drain') drain = true;
      final waiting = ack;
      if (waiting != null && !waiting.isCompleted) waiting.complete();
    });
    while (api.read(handle, buffer.cast(), 8192, count, nullptr) != 0 && count.value > 0) {
      ack = Completer<void>();
      main.send(['output', Uint8List.fromList(buffer.asTypedList(count.value))]);
      if (!drain) await ack.future;
      ack = null;
    }
  } on Object {
    owner.send(['ioFailed']);
  } finally {
    ownedApi?.close(handle);
    if (buffer != nullptr) calloc.free(buffer);
    if (count != nullptr) calloc.free(count);
    main.send(['eof']);
    owner.send(['readerDone']);
    commands.close();
  }
}

Future<void> _writePipe(List<Object> request) async {
  final handle = Pointer<Void>.fromAddress(request[0] as int);
  final main = request[1] as SendPort, owner = request[2] as SendPort;
  final commands = ReceivePort();
  _Kernel? ownedApi;
  Pointer<Uint32> count = nullptr;
  owner.send(['writerReady', commands.sendPort]);
  try {
    final api = ownedApi = _Kernel();
    count = calloc<Uint32>();
    await for (final message in commands) {
      if (message == null) break;
      final data = (message as List)[0] as Uint8List;
      final tracked = message[1] as int;
      final buffer = calloc<Uint8>(data.length);
      try {
        buffer.asTypedList(data.length).setAll(0, data);
        var offset = 0;
        while (offset < data.length) {
          if (api.write(handle, (buffer + offset).cast(), data.length - offset, count, nullptr) == 0 ||
              count.value == 0) {
            owner.send(['ioFailed']);
            return;
          }
          offset += count.value;
        }
      } finally {
        calloc.free(buffer);
        if (tracked != 0) main.send(['inputDone', tracked]);
      }
    }
  } on Object {
    owner.send(['ioFailed']);
  } finally {
    ownedApi?.close(handle);
    if (count != nullptr) calloc.free(count);
    owner.send(['writerDone']);
    commands.close();
  }
}

int _coord(int cols, int rows) => (cols.clamp(1, 32767) & 0xffff) | (rows.clamp(1, 32767) << 16);

class _NativePty {
  _NativePty(this.process, this.thread, this.job, this.console, this.input, this.output);
  final Pointer<Void> process, thread, job, console, input, output;
}

_NativePty _spawn(
  _Kernel api,
  String executable,
  List<String> arguments,
  int cols,
  int rows,
  String? workingDirectory,
) {
  final inRead = calloc<Pointer<Void>>(), inWrite = calloc<Pointer<Void>>();
  final outRead = calloc<Pointer<Void>>(), outWrite = calloc<Pointer<Void>>();
  final console = calloc<Pointer<Void>>(), size = calloc<UintPtr>();
  final startup = calloc<_StartupInfo>(), process = calloc<_ProcessInfo>();
  Pointer<Void> attributes = nullptr, job = nullptr;
  final exe = executable.toNativeUtf16();
  final command = [executable, ...arguments].map(_quote).join(' ').toNativeUtf16();
  final directory = (workingDirectory ?? Platform.environment['USERPROFILE'])?.toNativeUtf16();
  var success = false;
  try {
    if (api.createPipe(inRead, inWrite, nullptr, 0) == 0 || api.createPipe(outRead, outWrite, nullptr, 0) == 0) {
      throw StateError('Local terminal pipe failed');
    }
    if (api.createConsole(_coord(cols, rows), inRead.value, outWrite.value, 0, console) < 0) {
      throw StateError('Local terminal console failed');
    }
    api.initializeAttributes(nullptr, 1, 0, size);
    attributes = calloc<Uint8>(size.value).cast();
    if (api.initializeAttributes(attributes, 1, 0, size) == 0 ||
        api.updateAttributes(attributes, 0, 0x00020016, console.value, sizeOf<IntPtr>(), nullptr, nullptr) == 0) {
      throw StateError('Local terminal attributes failed');
    }
    startup.ref.cb = sizeOf<_StartupInfo>();
    startup.ref.flags = 0x00000100; // Explicitly keep parent console handles out of this ConPTY child.
    startup.ref.attributes = attributes;
    if (api.createProcess(
          exe,
          command,
          nullptr,
          nullptr,
          0,
          0x00080000 | 0x00000004,
          nullptr,
          directory ?? nullptr,
          startup,
          process,
        ) ==
        0) {
      throw StateError('Local terminal process failed');
    }
    api.close(inRead.value);
    inRead.value = nullptr;
    api.close(outWrite.value);
    outWrite.value = nullptr;
    job = api.createJob(nullptr, nullptr);
    if (job == nullptr) throw StateError('Local terminal job failed');
    final limits = calloc<Uint8>(144);
    try {
      ByteData.sublistView(limits.asTypedList(144)).setUint32(16, 0x00002000, Endian.little);
      if (api.setJobInfo(job, 9, limits.cast(), 144) == 0 || api.assignJob(job, process.ref.process) == 0) {
        throw StateError('Local terminal job failed');
      }
    } finally {
      calloc.free(limits);
    }
    success = true;
    return _NativePty(process.ref.process, process.ref.thread, job, console.value, inWrite.value, outRead.value);
  } finally {
    if (attributes != nullptr) {
      api.deleteAttributes(attributes);
      calloc.free(attributes);
    }
    if (!success) {
      if (process.ref.process != nullptr) api.terminateProcess(process.ref.process, 1);
      if (console.value != nullptr) api.closeConsole(console.value);
      for (final handle in [
        inRead.value,
        inWrite.value,
        outRead.value,
        outWrite.value,
        process.ref.process,
        process.ref.thread,
        job,
      ]) {
        if (handle != nullptr) api.close(handle);
      }
    }
    for (final pointer in [inRead, inWrite, outRead, outWrite, console, size, startup, process, exe, command]) {
      calloc.free(pointer);
    }
    if (directory != null) calloc.free(directory);
  }
}

String _quote(String value) {
  final result = StringBuffer('"');
  var slashes = 0;
  for (final unit in value.codeUnits) {
    if (unit == 92) {
      slashes++;
      continue;
    }
    if (unit == 34) {
      result.write(r'\' * (slashes * 2 + 1));
    } else {
      result.write(r'\' * slashes);
    }
    slashes = 0;
    result.writeCharCode(unit);
  }
  result.write(r'\' * (slashes * 2));
  return '${result.toString()}"';
}

final class _StartupInfo extends Struct {
  @Uint32()
  external int cb;
  external Pointer<Void> reserved;
  external Pointer<Void> desktop;
  external Pointer<Void> title;
  @Uint32()
  external int x;
  @Uint32()
  external int y;
  @Uint32()
  external int xSize;
  @Uint32()
  external int ySize;
  @Uint32()
  external int xChars;
  @Uint32()
  external int yChars;
  @Uint32()
  external int fill;
  @Uint32()
  external int flags;
  @Uint16()
  external int show;
  @Uint16()
  external int reservedSize;
  external Pointer<Void> reserved2;
  external Pointer<Void> stdinHandle;
  external Pointer<Void> stdoutHandle;
  external Pointer<Void> stderrHandle;
  external Pointer<Void> attributes;
}

final class _ProcessInfo extends Struct {
  external Pointer<Void> process;
  external Pointer<Void> thread;
  @Uint32()
  external int pid;
  @Uint32()
  external int tid;
}

class _Kernel {
  final _dll = DynamicLibrary.open('kernel32.dll');
  late final createPipe = _dll
      .lookupFunction<
        Int32 Function(Pointer<Pointer<Void>>, Pointer<Pointer<Void>>, Pointer<Void>, Uint32),
        int Function(Pointer<Pointer<Void>>, Pointer<Pointer<Void>>, Pointer<Void>, int)
      >('CreatePipe');
  late final createConsole = _dll
      .lookupFunction<
        Int32 Function(Int32, Pointer<Void>, Pointer<Void>, Uint32, Pointer<Pointer<Void>>),
        int Function(int, Pointer<Void>, Pointer<Void>, int, Pointer<Pointer<Void>>)
      >('CreatePseudoConsole');
  late final closeConsole = _dll.lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>(
    'ClosePseudoConsole',
  );
  late final resizeConsole = _dll
      .lookupFunction<Int32 Function(Pointer<Void>, Int32), int Function(Pointer<Void>, int)>('ResizePseudoConsole');
  late final initializeAttributes = _dll
      .lookupFunction<
        Int32 Function(Pointer<Void>, Uint32, Uint32, Pointer<UintPtr>),
        int Function(Pointer<Void>, int, int, Pointer<UintPtr>)
      >('InitializeProcThreadAttributeList');
  late final updateAttributes = _dll
      .lookupFunction<
        Int32 Function(Pointer<Void>, Uint32, UintPtr, Pointer<Void>, UintPtr, Pointer<Void>, Pointer<UintPtr>),
        int Function(Pointer<Void>, int, int, Pointer<Void>, int, Pointer<Void>, Pointer<UintPtr>)
      >('UpdateProcThreadAttribute');
  late final deleteAttributes = _dll.lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>(
    'DeleteProcThreadAttributeList',
  );
  late final createProcess = _dll
      .lookupFunction<
        Int32 Function(
          Pointer<Utf16>,
          Pointer<Utf16>,
          Pointer<Void>,
          Pointer<Void>,
          Int32,
          Uint32,
          Pointer<Void>,
          Pointer<Utf16>,
          Pointer<_StartupInfo>,
          Pointer<_ProcessInfo>,
        ),
        int Function(
          Pointer<Utf16>,
          Pointer<Utf16>,
          Pointer<Void>,
          Pointer<Void>,
          int,
          int,
          Pointer<Void>,
          Pointer<Utf16>,
          Pointer<_StartupInfo>,
          Pointer<_ProcessInfo>,
        )
      >('CreateProcessW');
  late final createJob = _dll
      .lookupFunction<
        Pointer<Void> Function(Pointer<Void>, Pointer<Utf16>),
        Pointer<Void> Function(Pointer<Void>, Pointer<Utf16>)
      >('CreateJobObjectW');
  late final setJobInfo = _dll
      .lookupFunction<
        Int32 Function(Pointer<Void>, Int32, Pointer<Void>, Uint32),
        int Function(Pointer<Void>, int, Pointer<Void>, int)
      >('SetInformationJobObject');
  late final assignJob = _dll
      .lookupFunction<Int32 Function(Pointer<Void>, Pointer<Void>), int Function(Pointer<Void>, Pointer<Void>)>(
        'AssignProcessToJobObject',
      );
  late final terminateJob = _dll
      .lookupFunction<Int32 Function(Pointer<Void>, Uint32), int Function(Pointer<Void>, int)>('TerminateJobObject');
  late final terminateProcess = _dll
      .lookupFunction<Int32 Function(Pointer<Void>, Uint32), int Function(Pointer<Void>, int)>('TerminateProcess');
  late final resumeThread = _dll.lookupFunction<Uint32 Function(Pointer<Void>), int Function(Pointer<Void>)>(
    'ResumeThread',
  );
  late final getExitCode = _dll
      .lookupFunction<Int32 Function(Pointer<Void>, Pointer<Uint32>), int Function(Pointer<Void>, Pointer<Uint32>)>(
        'GetExitCodeProcess',
      );
  late final close = _dll.lookupFunction<Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>('CloseHandle');
  late final read = _dll
      .lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<Void>, Uint32, Pointer<Uint32>, Pointer<Void>),
        int Function(Pointer<Void>, Pointer<Void>, int, Pointer<Uint32>, Pointer<Void>)
      >('ReadFile');
  late final write = _dll
      .lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<Void>, Uint32, Pointer<Uint32>, Pointer<Void>),
        int Function(Pointer<Void>, Pointer<Void>, int, Pointer<Uint32>, Pointer<Void>)
      >('WriteFile');
}

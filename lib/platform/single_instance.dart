import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// One Sshairy per user: a second launch asks the running copy to come forward instead of opening a window.
///
/// A lock beside the app data decides the owner; the owner publishes a loopback port in the same folder, and a
/// later process asks it to show the window. Nothing about credentials or sessions travels over that socket.
class SingleInstance {
  SingleInstance._(this._lock, this._server, this._clients);

  final RandomAccessFile? _lock;
  final ServerSocket? _server;
  final StreamSubscription<Socket>? _clients;

  // Reading the lock here keeps AOT from dropping an otherwise unread field, whose handle the GC would then close.
  bool get isPrimary => _lock != null && _server != null;

  static const _lockName = 'instance.lock', _portName = 'instance.port';
  static const _retry = Duration(milliseconds: 80);

  static String _path(String dir, String name) => '$dir${Platform.pathSeparator}$name';

  /// Takes the lock or, when another copy holds it, brings that copy forward. [wait] lets a second launch race a
  /// first one that is still binding its port.
  static Future<SingleInstance> acquire(
    String dir, {
    required Future<void> Function() show,
    Future<void> Function(int ownerPid)? allowForeground,
    Duration wait = const Duration(seconds: 3),
  }) async {
    final dirHandle = Directory(dir);
    if (!await dirHandle.exists()) await dirHandle.create(recursive: true);
    final lockFile = File(_path(dir, _lockName));
    final handle = await lockFile.open(mode: FileMode.append);
    try {
      await handle.lock(FileLock.exclusive);
    } on FileSystemException {
      await handle.close();
      await _forward(dir, wait, allowForeground);
      return SingleInstance._(null, null, null);
    }

    try {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      await File(_path(dir, _portName)).writeAsString('${server.port}\n', flush: true);
      final clients = server.listen((client) {
        unawaited(_serve(client, show));
      });
      return SingleInstance._(handle, server, clients);
    } on Object {
      await handle.unlock();
      await handle.close();
      rethrow;
    }
  }

  /// A local client only gets to ask for the window; malformed or unrelated traffic is dropped.
  static Future<void> _serve(Socket client, Future<void> Function() show) async {
    try {
      final lines = StreamIterator(client.cast<List<int>>().transform(utf8.decoder).transform(const LineSplitter()));
      Future<bool> next() => lines.moveNext().timeout(const Duration(seconds: 2));
      if (!await next()) return;
      final handoff = lines.current == 'pid';
      if (handoff) {
        client.writeln(pid);
        await client.flush();
        if (!await next()) return;
      }
      if (lines.current.trim() != 'show') return;
      await show();
      if (handoff) {
        client.writeln('shown');
        await client.flush();
      }
    } on Object {
      // A stray connection is not an error worth surfacing.
    } finally {
      client.destroy();
    }
  }

  /// Follows a port the owner may not have written yet; a refused connection is retried until [wait] ends.
  static Future<void> _forward(String dir, Duration wait, Future<void> Function(int)? allowForeground) async {
    final deadline = DateTime.now().add(wait);
    final portFile = File(_path(dir, _portName));
    while (true) {
      final port = _port(await _read(portFile));
      if (port != null) {
        if (allowForeground != null && await _connect(port, allowForeground: allowForeground)) return;
        if (await _connect(port)) return;
      }
      if (!DateTime.now().isBefore(deadline)) return;
      await Future<void>.delayed(_retry);
    }
  }

  static Future<String?> _read(File file) async {
    try {
      return await file.readAsString();
    } on FileSystemException {
      return null;
    }
  }

  static int? _port(String? raw) {
    final port = int.tryParse(raw?.trim() ?? '');
    return port != null && port > 0 && port <= 65535 ? port : null;
  }

  static Future<bool> _connect(int port, {Future<void> Function(int)? allowForeground}) async {
    Socket? socket;
    try {
      const timeout = Duration(milliseconds: 500);
      final client = socket = await Socket.connect(InternetAddress.loopbackIPv4, port, timeout: timeout);
      if (allowForeground == null) {
        client.writeln('show');
        await client.flush();
        return true;
      }
      final lines = StreamIterator(client.cast<List<int>>().transform(utf8.decoder).transform(const LineSplitter()));
      client.writeln('pid');
      await client.flush();
      if (!await lines.moveNext().timeout(timeout)) return false;
      final ownerPid = int.tryParse(lines.current);
      if (ownerPid == null || ownerPid <= 0 || ownerPid >= 0xFFFFFFFF) return false;
      await allowForeground(ownerPid);
      client.writeln('show');
      await client.flush();
      // Keep this process alive until the owner has attempted to use the foreground grant.
      await lines.moveNext().timeout(timeout);
      return true;
    } on Object {
      return false;
    } finally {
      socket?.destroy();
    }
  }

  Future<void> close() async {
    await _clients?.cancel();
    await _server?.close();
    final lock = _lock;
    if (lock != null) {
      await lock.unlock();
      await lock.close();
    }
  }
}

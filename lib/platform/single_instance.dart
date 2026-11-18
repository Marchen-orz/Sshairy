import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// One Sshairy per user: a second launch asks the running copy to come forward instead of opening a window.
///
/// A lock beside the app data decides the owner; the owner publishes a loopback port in the same folder, and a
/// later process only sends `show` there. Nothing about credentials or sessions travels over that socket.
class SingleInstance {
  SingleInstance._(this._lock, this._server, this._clients);

  final RandomAccessFile? _lock;
  final ServerSocket? _server;
  final StreamSubscription<Socket>? _clients;

  bool get isPrimary => _server != null;

  static const _lockName = 'instance.lock', _portName = 'instance.port';
  static const _retry = Duration(milliseconds: 80);

  static String _path(String dir, String name) => '$dir${Platform.pathSeparator}$name';

  /// Takes the lock or, when another copy holds it, brings that copy forward. [wait] lets a second launch race a
  /// first one that is still binding its port.
  static Future<SingleInstance> acquire(
    String dir, {
    required Future<void> Function() show,
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
      await _forward(dir, wait);
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
      final line = await client
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first
          .timeout(const Duration(seconds: 2));
      if (line.trim() == 'show') await show();
    } on Object {
      // A stray connection is not an error worth surfacing.
    } finally {
      client.destroy();
    }
  }

  /// Follows a port the owner may not have written yet; a refused connection is retried until [wait] ends.
  static Future<void> _forward(String dir, Duration wait) async {
    final deadline = DateTime.now().add(wait);
    final portFile = File(_path(dir, _portName));
    while (true) {
      final port = _port(await _read(portFile));
      if (port != null && await _connect(port)) return;
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

  static Future<bool> _connect(int port) async {
    try {
      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        port,
        timeout: const Duration(milliseconds: 500),
      );
      socket.write('show\n');
      await socket.flush();
      socket.destroy();
      return true;
    } on Object {
      return false;
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

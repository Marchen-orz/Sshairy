import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../../../foundation/cancellation.dart';
import '../../../foundation/file_system.dart';
import '../../connections/api.dart' show TransportLease;
import '../domain/directory.dart';
import '../domain/terminal_paths.dart';
import '../domain/terminal_target.dart';

/// Queries the working directory of one marked SSH shell over its existing lease.
class SshShellDirectory {
  final _marker = [for (var i = 0; i < 8; i++) Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0')].join();

  Map<String, String> get environment => {directoryVariable: _marker};

  Future<String?> read(TransportLease lease, CancellationToken cancel) async {
    final result = await lease.exec(
      directoryQuery(_marker),
      limit: 4096,
      timeout: const Duration(seconds: 5),
      cancel: cancel,
    );
    return parseDirectoryQuery(utf8.decode(result.stdout, allowMalformed: true));
  }
}

/// Path completion over the SFTP channel of a lease the terminal already holds (docs/TERMINAL_ASSISTANCE.md). One
/// instance per lease and connection [generation]; [dispose] closes its channel and leaves the lease to its owner.
/// It never acquires a lease or dials, so everything it reads went through host verification.
class LeaseRemotePathSource extends RemotePathBrowser {
  LeaseRemotePathSource(TransportLease lease, {required super.generation, super.timeout = const Duration(seconds: 3)})
    : super(SftpDirectoryReader(lease.openFiles, isLost: () => lease.lost, limit: timeout));
}

/// Path completion over the files of a non-SSH shell, such as a Sshairy Link mirror or desktop-proxied terminal.
/// [open] supplies the terminal's own file system; a lost or forbidden mount fails as unavailable.
class LinkedRemotePathSource extends RemotePathBrowser {
  LinkedRemotePathSource(
    Future<FileSystem> Function() open, {
    required int generation,
    PathStyle style = PathStyle.posix,
    Duration timeout = const Duration(seconds: 5),
  }) : this._(
         SftpDirectoryReader(open, style: style, limit: timeout),
         generation: generation,
         style: style,
         timeout: timeout,
       );

  LinkedRemotePathSource._(this._reader, {required super.generation, required super.style, required super.timeout})
    : super(_reader);

  final SftpDirectoryReader _reader;

  Future<String?> workingDirectory(CancellationToken cancel) => _reader._use(
    cancel,
    (fs, _) async => fs is ShellWorkingDirectory ? (fs as ShellWorkingDirectory).workingDirectory() : null,
  );
}

/// Path completion over the local machine's filesystem for a local terminal session.
class LocalPathSource extends RemotePathBrowser {
  LocalPathSource(LocalShell shell, {required super.generation, super.timeout = const Duration(seconds: 3)})
    : super(
        LocalDirectoryReader(windows: shell.kind.isWindowsShell, msys: shell.kind == LocalShellKind.gitBash),
        style: shell.kind.isWindowsShell ? PathStyle.windows : PathStyle.posix,
      );
}

/// [RemoteDirectoryReader] over the local machine's filesystem using `dart:io`.
class LocalDirectoryReader implements RemoteDirectoryReader {
  const LocalDirectoryReader({required this.windows, required this.msys});

  final bool windows;
  final bool msys;

  static final _msysPath = RegExp(r'^/([A-Za-z])(?:/(.*))?$');
  static final _winDrive = RegExp(r'^([A-Za-z]):[\\/]?(.*)$');

  static String? toMsysPath(String native) {
    final m = _winDrive.firstMatch(native);
    if (m == null) return native.startsWith('/') ? native : null;
    final drive = m.group(1)!.toLowerCase();
    final rest = m.group(2)!.replaceAll(r'\', '/');
    return rest.isEmpty ? '/$drive' : '/$drive/$rest';
  }

  static String? fromMsysPath(String msysPath) {
    final m = _msysPath.firstMatch(msysPath);
    if (m == null) return null;
    final drive = m.group(1)!.toUpperCase();
    final rest = (m.group(2) ?? '').replaceAll('/', r'\');
    return rest.isEmpty ? '$drive:\\' : '$drive:\\$rest';
  }

  @override
  Future<String> home(CancellationToken cancel) async {
    if (cancel.isCancelled) throw const RemotePathException(RemotePathFailure.cancelled);
    if (windows) {
      final dir = Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'] ?? Directory.current.path;
      return dir.replaceAll('/', r'\');
    }
    if (msys) {
      final raw = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? Directory.current.path;
      final converted = toMsysPath(raw);
      if (converted == null) throw const RemotePathException(RemotePathFailure.unavailable);
      return converted;
    }
    return Platform.environment['HOME'] ?? Directory.current.path;
  }

  @override
  Future<RemoteDirectoryListing> list(String directory, CancellationToken cancel) async {
    if (cancel.isCancelled) throw const RemotePathException(RemotePathFailure.cancelled);
    if (msys && directory == '/') {
      final drives = <RemoteDirectoryItem>[];
      for (var code = 65; code <= 90; code++) {
        if (cancel.isCancelled) throw const RemotePathException(RemotePathFailure.cancelled);
        final letter = String.fromCharCode(code);
        if (await Directory('$letter:\\').exists()) {
          drives.add(RemoteDirectoryItem(letter.toLowerCase(), RemotePathKind.directory));
        }
      }
      return RemoteDirectoryListing(drives, complete: true);
    }
    final native = msys ? fromMsysPath(directory) : directory;
    if (native == null) throw const RemotePathException(RemotePathFailure.notFound);
    final style = windows ? PathStyle.windows : PathStyle.posix;
    final items = <RemoteDirectoryItem>[];
    var scanned = 0;
    try {
      await for (final entity in Directory(native).list(followLinks: false)) {
        if (cancel.isCancelled) throw const RemotePathException(RemotePathFailure.cancelled);
        if (scanned == RemotePaths.maxScanned) {
          return RemoteDirectoryListing(items, complete: false);
        }
        scanned++;
        final path = entity.path;
        final sep = path.lastIndexOf(Platform.pathSeparator);
        final name = sep < 0 ? path : path.substring(sep + 1);
        if (!RemotePaths.validName(name, style: style)) continue;
        if (entity is Link) {
          var linkToDir = false;
          try {
            linkToDir = await FileSystemEntity.isDirectory(path);
          } on Object {
            linkToDir = false;
          }
          items.add(RemoteDirectoryItem(name, RemotePathKind.symlink, linkToDirectory: linkToDir));
        } else if (entity is Directory) {
          items.add(RemoteDirectoryItem(name, RemotePathKind.directory));
        } else {
          items.add(RemoteDirectoryItem(name, RemotePathKind.file));
        }
      }
    } on RemotePathException {
      rethrow;
    } on FileSystemException catch (e) {
      throw _mapFsError(e);
    } on Object {
      throw const RemotePathException(RemotePathFailure.failed);
    }
    return RemoteDirectoryListing(items, complete: true);
  }

  @override
  void close() {}

  static RemotePathException _mapFsError(FileSystemException e) {
    final code = e.osError?.errorCode;
    if (Platform.isWindows) {
      if (code == 2 || code == 3) return const RemotePathException(RemotePathFailure.notFound);
      if (code == 5) return const RemotePathException(RemotePathFailure.denied);
    } else {
      if (code == 2 || code == 20) return const RemotePathException(RemotePathFailure.notFound);
      if (code == 13 || code == 1) return const RemotePathException(RemotePathFailure.denied);
    }
    return const RemotePathException(RemotePathFailure.failed);
  }
}

/// [RemoteDirectoryReader] over an SFTP channel that [_open] provides on demand. The channel is opened by the first
/// request, closed after [idle] without one, and closed at once when a request is cancelled, times out or the lease is
/// lost: closing it is what stops a request that cannot be interrupted otherwise.
///
/// A file system with [BoundedFileListing] is read through it, at most [RemotePaths.maxScanned] names. Its directory
/// stays open on the server when the scan stops early, so the channel is closed after an incomplete or failed scan and
/// reopened by the next request. Any other file system is read with [FileSystem.list], all of it at once, and cut to
/// the same limit afterwards; only [limit] bounds that read.
class SftpDirectoryReader implements RemoteDirectoryReader {
  SftpDirectoryReader(
    this._open, {
    bool Function()? isLost,
    this.style = PathStyle.posix,
    this.idle = const Duration(seconds: 10),
    this.limit = const Duration(seconds: 3),
  }) : _isLost = isLost ?? (() => false);

  final Future<FileSystem> Function() _open;
  final bool Function() _isLost;
  final PathStyle style;
  final Duration idle;

  /// Longest wait for one request, which closes the channel and fails with [RemotePathFailure.timeout].
  final Duration limit;
  Future<FileSystem>? _channel;
  Timer? _idleTimer;
  var _busy = 0;
  var _closed = false;

  @override
  Future<String> home(CancellationToken cancel) => _use(cancel, (fs, _) => fs.home());

  @override
  Future<RemoteDirectoryListing> list(String directory, CancellationToken cancel) => _use(cancel, (fs, retire) async {
    if (fs case final BoundedFileListing bounded) {
      try {
        final listing = await bounded.listBounded(
          directory,
          maxScanned: RemotePaths.maxScanned,
          accept: (name) => RemotePaths.validName(name, style: style),
          cancel: cancel,
        );
        if (!listing.complete) retire();
        return RemoteDirectoryListing([for (final e in listing.entries) _item(e)], complete: listing.complete);
      } on Object catch (e) {
        // Refusing to open a directory leaves nothing open on the server; any other failure may.
        if (!(e is FsError && (e.kind == FsFailure.notFound || e.kind == FsFailure.permission))) retire();
        rethrow;
      }
    }
    final all = await fs.list(directory);
    final read = all.length > RemotePaths.maxScanned ? all.sublist(0, RemotePaths.maxScanned) : all;
    return RemoteDirectoryListing([for (final e in read) _item(e)], complete: read.length == all.length);
  });

  @override
  void close() {
    _closed = true;
    _idleTimer?.cancel();
    _idleTimer = null;
    _drop();
  }

  static RemoteDirectoryItem _item(FileEntry e) => RemoteDirectoryItem(e.name, switch (e.kind) {
    FileKind.directory => RemotePathKind.directory,
    FileKind.link => RemotePathKind.symlink,
    FileKind.file || FileKind.other => RemotePathKind.file,
  }, linkToDirectory: e.kind == FileKind.link && e.linkToDir);

  /// Runs [work] on the channel; it calls the second argument to have the channel closed afterwards.
  Future<T> _use<T>(CancellationToken cancel, Future<T> Function(FileSystem fs, void Function() retire) work) async {
    if (_closed || _isLost()) throw const RemotePathException(RemotePathFailure.unavailable);
    if (cancel.isCancelled) throw const RemotePathException(RemotePathFailure.cancelled);
    _idleTimer?.cancel();
    _idleTimer = null;
    _busy++;
    final channel = _channelOrOpen();
    var retired = false;
    final running = channel.then((fs) {
      // The channel may open only after this request was cancelled or timed out, the reader was closed or the lease
      // was lost; it has been dropped by then, which closes it, and must not be used.
      if (cancel.isCancelled) throw const RemotePathException(RemotePathFailure.cancelled);
      if (_closed || _isLost() || !identical(_channel, channel)) {
        retired = true;
        throw const RemotePathException(RemotePathFailure.unavailable);
      }
      return work(fs, () => retired = true);
    });
    var settled = false;
    running.then<void>(
      (_) {
        settled = true;
      },
      onError: (Object _) {
        settled = true;
      },
    );
    final stopped = Completer<T>();
    cancel.whenCancelled.then((_) {
      if (!settled && !stopped.isCompleted) {
        stopped.completeError(const RemotePathException(RemotePathFailure.cancelled));
      }
    });
    final deadline = Timer(limit, () {
      if (!settled && !stopped.isCompleted) {
        stopped.completeError(const RemotePathException(RemotePathFailure.timeout));
      }
    });
    try {
      return await Future.any([running, stopped.future]);
    } on RemotePathException {
      rethrow;
    } on FsError catch (e) {
      throw _failure(e);
    } on Object {
      throw const RemotePathException(RemotePathFailure.unavailable);
    } finally {
      deadline.cancel();
      _busy--;
      // Stopped waiting while the server may still be answering: nothing more can be learned from that channel.
      if (!settled || retired) _drop(channel);
      if (_busy == 0 && !_closed && _channel != null) {
        _idleTimer = Timer(idle, () {
          if (_busy == 0) _drop();
        });
      }
    }
  }

  Future<FileSystem> _channelOrOpen() {
    final existing = _channel;
    if (existing != null) return existing;
    // The lease throws at once when it is already released, so the call is wrapped.
    final opening = Future<FileSystem>.sync(_open);
    _channel = opening;
    opening.then<void>(
      (_) {},
      onError: (Object _) {
        if (identical(_channel, opening)) _channel = null;
      },
    );
    return opening;
  }

  /// Closes the channel, or only [only] when that is still the current one.
  void _drop([Future<FileSystem>? only]) {
    final channel = _channel;
    if (channel == null || (only != null && !identical(channel, only))) return;
    _channel = null;
    channel.then<void>((fs) => fs.close(), onError: (Object _) {}).ignore();
  }

  static RemotePathException _failure(FsError e) => RemotePathException(switch (e.kind) {
    FsFailure.notFound => RemotePathFailure.notFound,
    FsFailure.permission => RemotePathFailure.denied,
    FsFailure.lost => RemotePathFailure.unavailable,
    _ => RemotePathFailure.failed,
  });
}

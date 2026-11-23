import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../../../foundation/cancellation.dart';
import '../../../foundation/file_system.dart';
import '../../../foundation/ids.dart';
import '../domain/protocol.dart';

const _chunkSize = 96 * 1024;
const _timeout = Duration(seconds: 30);
const _maxMounts = 8;
const _maxEntries = 20000;

/// An authorized file system and the lifetime and path checks of the grant that opened it.
class LinkFsHandle {
  const LinkFsHandle(this.fs, this.release, {this.isCurrent, this.checkPath, this.readWorkingDirectory});

  final FileSystem fs;
  final Future<void> Function() release;
  final bool Function()? isCurrent;
  final Future<void> Function(String path)? checkPath;
  final Future<String?> Function(CancellationToken cancel)? readWorkingDirectory;
}

/// One file protocol per authenticated connection, in both directions.
class LinkFiles {
  LinkFiles({required this.send, required this.isConnected, required this.openTarget, required this.canOpen});

  final Future<void> Function(Map<String, Object?>) send;
  final bool Function() isConnected;
  final Future<LinkFsHandle> Function(String target, CancellationToken cancel) openTarget;
  final bool Function(String target) canOpen;
  final _mounts = <String, _Mount>{};
  final _pending = <String, Completer<Map<String, dynamic>>>{};
  bool _closed = false;

  bool get current => !_closed && isConnected();

  bool handle(Map<String, dynamic> message) {
    switch (message['type']) {
      case 'fs.res':
        final waiter = _pending.remove(message['reqId']);
        if (waiter != null) waiter.complete(message);
      case 'fs.req':
        unawaited(_respond(message));
      case 'fs.close':
        final mount = _mounts.remove(message['mount']);
        if (mount != null) unawaited(mount.close());
      default:
        return false;
    }
    return true;
  }

  void revoke() {
    for (final entry in _mounts.entries.toList()) {
      if (!canOpen(entry.value.target)) {
        _mounts.remove(entry.key);
        unawaited(entry.value.close());
      }
    }
  }

  void close() {
    _closed = true;
    for (final mount in _mounts.values) {
      unawaited(mount.close());
    }
    _mounts.clear();
    for (final waiter in _pending.values) {
      waiter.completeError(const FsError(FsFailure.lost));
    }
    _pending.clear();
  }

  Future<FileSystem> open(String target) async {
    final id = newId();
    try {
      final response = await _request(id, 'open', {'target': target});
      return _RemoteFileSystem(
        this,
        id,
        PathStyle.values.byName(response['style'] as String),
        response['home'] as String,
        canReplace: response['canReplace'] == true,
      );
    } on Object {
      await _closeRemote(id);
      rethrow;
    }
  }

  Future<Map<String, dynamic>> _request(String mount, String op, [Map<String, Object?> args = const {}]) async {
    if (!current) throw const FsError(FsFailure.lost);
    final id = newId();
    final waiter = Completer<Map<String, dynamic>>();
    _pending[id] = waiter;
    try {
      final response = await Future.wait([
        waiter.future,
        send({'type': 'fs.req', 'reqId': id, 'mount': mount, 'op': op, ...args}),
      ], eagerError: true).timeout(_timeout);
      final result = response.first as Map<String, dynamic>;
      if (result['error'] case final String error) {
        throw FsError(FsFailure.values.asNameMap()[error] ?? FsFailure.failed);
      }
      return result;
    } on FsError {
      rethrow;
    } on Object {
      throw const FsError(FsFailure.lost);
    } finally {
      _pending.remove(id);
    }
  }

  Future<void> _closeRemote(String mount) async {
    if (current) await send({'type': 'fs.close', 'mount': mount}).catchError((Object _) {});
  }

  Future<void> _respond(Map<String, dynamic> message) async {
    final req = message['reqId'], id = message['mount'], op = message['op'];
    if (!current || req is! String || req.length > 64 || id is! String || id.length > 64 || op is! String) return;
    final reply = <String, Object?>{'type': 'fs.res', 'reqId': req};
    try {
      if (op == 'open') {
        final target = message['target'];
        if (target is! String || !canOpen(target)) throw const FsError(FsFailure.permission);
        if (_mounts.length >= _maxMounts || _mounts.containsKey(id)) throw const FsError(FsFailure.failed);
        final mount = _Mount(target, () => current && canOpen(target));
        _mounts[id] = mount;
        try {
          final handle = await openTarget(target, mount.lifetime);
          if (mount.lifetime.isCancelled) {
            await handle.release();
            throw const FsError(FsFailure.lost);
          }
          mount.handle = handle;
          mount.check();
          final fs = handle.fs;
          // PathStyle.name(path) shadows the enum name.
          reply.addAll({'style': EnumName(fs.style).name, 'home': await fs.home(), 'canReplace': fs.canReplace});
          mount.check();
        } on Object {
          if (identical(_mounts[id], mount)) _mounts.remove(id);
          await mount.close();
          rethrow;
        }
      } else {
        final mount = _mounts[id];
        if (mount == null) throw const FsError(FsFailure.lost);
        reply.addAll(await mount.run(op, message));
        mount.check();
      }
    } on Object catch (error) {
      reply.removeWhere((key, _) => key != 'type' && key != 'reqId');
      reply['error'] = (error is FsError ? error.kind : FsFailure.failed).name;
    }
    if (current) await send(reply).catchError((Object _) {});
  }
}

class _Mount {
  _Mount(this.target, this.allowed);

  final String target;
  final bool Function() allowed;
  final lifetime = CancellationToken();
  LinkFsHandle? handle;
  Future<Map<String, Object?>>? _operation;
  _Read? _read;
  _Write? _write;
  List<Map<String, Object?>>? _listing;
  int _next = 0;

  void check() {
    if (lifetime.isCancelled || handle == null || handle!.isCurrent?.call() == false) {
      throw const FsError(FsFailure.lost);
    }
    if (!allowed()) throw const FsError(FsFailure.permission);
  }

  Future<Map<String, Object?>> run(String op, Map<String, dynamic> args) async {
    check();
    if (_operation != null) throw const FsError(FsFailure.failed);
    final work = _run(op, args);
    _operation = work;
    try {
      return await work;
    } finally {
      _operation = null;
    }
  }

  Future<Map<String, Object?>> _run(String op, Map<String, dynamic> args) async {
    final fs = handle!.fs;
    Future<String> path(String key) async {
      final value = args[key];
      if (value is! String || value.length > 4096 || value.contains('\x00')) {
        throw const FsError(FsFailure.permission);
      }
      if (fs.style == PathStyle.windows) {
        final absoluteDrive = RegExp(r'^[A-Za-z]:[\\/]').hasMatch(value);
        if (value.isNotEmpty && (!absoluteDrive || value.substring(2).contains(':'))) {
          throw const FsError(FsFailure.permission);
        }
        for (final part in value.split(RegExp(r'[\\/]')).skip(1)) {
          if (part.isEmpty) continue;
          if (part.endsWith(' ') ||
              part.endsWith('.') ||
              RegExp(r'^(?:CON|PRN|AUX|NUL|COM[0-9¹²³]|LPT[0-9¹²³]) *(?:\.|$)', caseSensitive: false).hasMatch(part)) {
            throw const FsError(FsFailure.permission);
          }
        }
      } else if (!value.startsWith('/') || value.split('/').contains('..')) {
        throw const FsError(FsFailure.permission);
      }
      await handle!.checkPath?.call(value);
      check();
      return value;
    }

    switch (op) {
      case 'cwd':
        final cwd = await handle!.readWorkingDirectory?.call(lifetime);
        if (cwd == null || !cwd.startsWith('/') || cwd.length > 4096 || cwd.contains('\x00')) return const {};
        await handle!.checkPath?.call(cwd);
        return {'path': cwd};
      case 'resolve':
        final resolved = await fs.resolve(await path('path'));
        await handle!.checkPath?.call(resolved);
        return {'path': resolved};
      case 'stat':
        final entry = await fs.stat(await path('path'));
        return {if (entry != null) 'entry': _encodeEntry(entry)};
      case 'list':
        final cursor = args['cursor'];
        if (cursor == null) {
          final dir = await path('path');
          final entries = await fs.list(dir);
          if (entries.length > _maxEntries) throw const FsError(FsFailure.unsupported);
          _listing = [for (final entry in entries) _encodeEntry(entry)];
          _next = 0;
        } else if (cursor != _next || _listing == null) {
          throw const FsError(FsFailure.failed);
        }
        final list = _listing!;
        final page = <Map<String, Object?>>[];
        var bytes = 0;
        while (_next < list.length) {
          final entry = list[_next];
          bytes += utf8.encode(jsonEncode(entry)).length + 1;
          if (bytes > linkMaxFrameBytes ~/ 2) {
            if (page.isEmpty) throw const FsError(FsFailure.unsupported);
            break;
          }
          _next++;
          page.add(entry);
        }
        if (_next == list.length) _listing = null;
        return {'entries': page, if (_listing != null) 'cursor': _next};
      case 'mkdir':
        await fs.mkdir(await path('path'));
      case 'rename' || 'replace':
        final from = await path('from');
        final to = await path('to');
        if (op == 'replace') {
          if (!fs.canReplace) throw const FsError(FsFailure.unsupported);
          await fs.replace(from, to, checkCurrent: check);
        } else {
          await fs.rename(from, to, checkCurrent: check);
        }
      case 'delete':
        await fs.delete(await path('path'));
      case 'rmdir':
        await fs.rmdir(await path('path'));
      case 'read.open':
        final filename = await path('path');
        final offset = args['offset'];
        if (_read != null || offset is! int || offset < 0 || (await fs.stat(filename))?.kind != FileKind.file) {
          throw const FsError(FsFailure.unsupported);
        }
        check();
        _read = _Read(fs.read(filename, offset: offset));
      case 'read.next':
        final read = _read;
        if (read == null) throw const FsError(FsFailure.lost);
        final bytes = await read.next();
        if (bytes == null) _read = null;
        return {if (bytes != null) 'data': base64Encode(bytes)};
      case 'read.close':
        await _read?.iterator.cancel();
        _read = null;
      case 'write.open':
        final filename = await path('path');
        final offset = args['offset'];
        if (_write != null || (offset != null && (offset is! int || offset < 0))) {
          throw const FsError(FsFailure.unsupported);
        }
        if (offset != null && (await fs.stat(filename))?.kind != FileKind.file) {
          throw const FsError(FsFailure.unsupported);
        }
        check();
        _write = _Write(fs, filename, offset as int?, check);
      case 'write.chunk':
        final encoded = args['data'];
        if (encoded is! String || encoded.isEmpty || encoded.length > _chunkSize * 4 ~/ 3) {
          throw const FsError(FsFailure.unsupported);
        }
        final write = _write;
        if (write == null) throw const FsError(FsFailure.lost);
        await write.add(base64Decode(encoded));
      case 'write.finish':
        final write = _write;
        if (write == null) throw const FsError(FsFailure.lost);
        try {
          return {'written': await write.finish()};
        } finally {
          _write = null;
        }
      case 'write.cancel':
        final write = _write;
        _write = null;
        await write?.cancel();
      default:
        throw const FsError(FsFailure.unsupported);
    }
    return const {};
  }

  Future<void> close() async {
    lifetime.cancel();
    final read = _read, write = _write, owned = handle;
    await Future.wait([?read?.iterator.cancel(), ?write?.cancel()]).then((_) {}, onError: (Object _) {});
    if (_operation case final operation?) await operation.then((_) {}, onError: (Object _) {});
    await owned?.release().catchError((Object _) {});
  }
}

Map<String, Object?> _encodeEntry(FileEntry entry) => {
  'name': entry.name,
  'kind': entry.kind.name,
  'size': entry.size,
  'modified': entry.modified?.millisecondsSinceEpoch,
  'mode': entry.mode,
  'linkToDir': entry.linkToDir,
};

FileEntry _decodeEntry(Map<String, dynamic> entry) => FileEntry(
  entry['name'] as String,
  FileKind.values.byName(entry['kind'] as String),
  size: entry['size'] as int?,
  modified: switch (entry['modified']) {
    final int millis => DateTime.fromMillisecondsSinceEpoch(millis),
    _ => null,
  },
  mode: entry['mode'] as int?,
  linkToDir: entry['linkToDir'] == true,
);

class _Read {
  _Read(Stream<Uint8List> stream) : iterator = StreamIterator(stream);

  final StreamIterator<Uint8List> iterator;
  Uint8List _remaining = Uint8List(0);

  Future<Uint8List?> next() async {
    while (_remaining.isEmpty) {
      if (!await iterator.moveNext()) return null;
      _remaining = iterator.current;
    }
    final end = _remaining.length.clamp(0, _chunkSize);
    final chunk = Uint8List.sublistView(_remaining, 0, end);
    _remaining = Uint8List.sublistView(_remaining, end);
    return chunk;
  }
}

class _Write {
  _Write(this.fs, this.path, int? offset, void Function() check) : _created = offset == null {
    void progress(int written) {
      _written = written;
      final ack = _ack;
      if (written >= _expected && ack != null && !ack.isCompleted) ack.complete();
    }

    _done = offset == null
        ? fs.create(path, _data.stream, cancel: _stop, checkCurrent: check, onProgress: progress)
        : fs.append(path, _data.stream, offset: offset, cancel: _stop, checkCurrent: check, onProgress: progress);
    // One listener for the whole write, rather than one per chunk.
    _done.then<void>((_) => _end(const FsError(FsFailure.lost)), onError: _end).ignore();
  }

  void _end(Object error) {
    _ended = error;
    final ack = _ack;
    if (ack != null && !ack.isCompleted) ack.completeError(error);
  }

  final FileSystem fs;
  final String path;
  final bool _created;
  final _stop = CancellationToken();
  final _data = StreamController<Uint8List>();
  late final Future<int> _done;
  Completer<void>? _ack;
  Object? _ended;
  int _expected = 0, _written = 0;
  Future<void>? _cancelling;

  Future<void> add(Uint8List chunk) async {
    if (_stop.isCancelled) throw const FsError(FsFailure.lost);
    if (_ended case final error?) throw error;
    final ack = _ack = Completer<void>();
    _expected += chunk.length;
    _data.add(chunk);
    try {
      await ack.future;
    } finally {
      _ack = null;
    }
  }

  Future<int> finish() {
    unawaited(_data.close());
    return _done;
  }

  Future<void> cancel() => _cancelling ??= _cancel();

  Future<void> _cancel() async {
    _stop.cancel();
    if (!_data.isClosed) unawaited(_data.close());
    var ownsPath = _written > 0;
    try {
      await _done;
      ownsPath = true;
    } on Object {
      // An exclusive create may fail before this stream owns the path.
    }
    if (_created && ownsPath) await fs.delete(path).catchError((Object _) {});
  }
}

class _RemoteFileSystem implements FileSystem, ShellWorkingDirectory {
  _RemoteFileSystem(this._link, this._id, this.style, this._home, {required this.canReplace});

  final LinkFiles _link;
  final String _id, _home;
  bool _closed = false;
  Future<List<FileEntry>>? _listing;

  @override
  final PathStyle style;
  @override
  final bool canReplace;
  @override
  bool get canChmod => false;

  Future<Map<String, dynamic>> _rpc(String op, [Map<String, Object?> args = const {}]) {
    if (_closed) throw const FsError(FsFailure.lost);
    return _link._request(_id, op, args);
  }

  @override
  Future<String> home() async => _home;

  @override
  Future<String?> workingDirectory() async {
    try {
      return (await _rpc('cwd'))['path'] as String?;
    } on FsError catch (e) {
      if (e.kind == FsFailure.unsupported) return null; // Older peers have no cwd operation.
      rethrow;
    }
  }

  @override
  Future<String> resolve(String path) async =>
      (await _rpc('resolve', {'path': path == '~' ? _home : path}))['path'] as String;

  @override
  Future<List<FileEntry>> list(String dir) async {
    // One directory cursor belongs to each mount.
    while (true) {
      final previous = _listing;
      if (previous == null) break;
      await previous.then((_) {}, onError: (Object _) {});
    }
    final work = _listing = _list(dir);
    try {
      return await work;
    } finally {
      _listing = null;
    }
  }

  Future<List<FileEntry>> _list(String dir) async {
    final entries = <FileEntry>[];
    int? cursor;
    do {
      final page = await _rpc('list', {'path': dir, 'cursor': cursor});
      for (final raw in page['entries'] as List) {
        final e = _decodeEntry((raw as Map).cast());
        final drive = style == PathStyle.windows && dir.isEmpty && RegExp(r'^[A-Z]:\\$').hasMatch(e.name);
        if (!drive &&
            (e.name.isEmpty ||
                e.name == '.' ||
                e.name == '..' ||
                e.name.contains('\x00') ||
                style.name(e.name) != e.name ||
                (style == PathStyle.windows && e.name.contains(':')))) {
          throw const FsError(FsFailure.failed);
        }
        entries.add(e);
        if (entries.length > _maxEntries) throw const FsError(FsFailure.unsupported);
      }
      final next = page['cursor'] as int?;
      if (next != null && next <= (cursor ?? 0)) throw const FsError(FsFailure.failed);
      cursor = next;
    } while (cursor != null);
    return entries;
  }

  @override
  Future<FileEntry?> stat(String path) async {
    final res = await _rpc('stat', {'path': path});
    final entry = res['entry'];
    return entry == null ? null : _decodeEntry((entry as Map).cast());
  }

  @override
  Future<void> mkdir(String path) async => _rpc('mkdir', {'path': path});
  @override
  Future<void> delete(String path) async => _rpc('delete', {'path': path});
  @override
  Future<void> rmdir(String path) async => _rpc('rmdir', {'path': path});
  @override
  Future<void> chmod(String path, int mode) async => throw const FsError(FsFailure.unsupported);

  @override
  Future<void> rename(String from, String to, {void Function()? checkCurrent}) async {
    checkCurrent?.call();
    await _rpc('rename', {'from': from, 'to': to});
  }

  @override
  Future<void> replace(String from, String to, {void Function()? checkCurrent}) async {
    checkCurrent?.call();
    await _rpc('replace', {'from': from, 'to': to});
  }

  @override
  Stream<Uint8List> read(String path, {int offset = 0}) async* {
    await _rpc('read.open', {'path': path, 'offset': offset});
    var ended = false;
    try {
      while (true) {
        final page = await _rpc('read.next');
        final encoded = page['data'] as String?;
        if (encoded == null) {
          ended = true;
          return;
        }
        if (encoded.isEmpty || encoded.length > _chunkSize * 4 ~/ 3) throw const FsError(FsFailure.failed);
        yield base64Decode(encoded);
      }
    } finally {
      if (!ended && !_closed && _link.current) await _rpc('read.close').then((_) {}, onError: (Object _) {});
    }
  }

  @override
  Future<int> create(
    String path,
    Stream<Uint8List> data, {
    void Function(int)? onProgress,
    CancellationToken? cancel,
    void Function()? checkCurrent,
  }) => _write(path, data, null, onProgress, cancel, checkCurrent);

  @override
  Future<int> append(
    String path,
    Stream<Uint8List> data, {
    required int offset,
    void Function(int)? onProgress,
    CancellationToken? cancel,
    void Function()? checkCurrent,
  }) => _write(path, data, offset, onProgress, cancel, checkCurrent);

  Future<int> _write(
    String path,
    Stream<Uint8List> data,
    int? offset,
    void Function(int)? onProgress,
    CancellationToken? cancel,
    void Function()? checkCurrent,
  ) async {
    checkCurrent?.call();
    if (cancel?.isCancelled ?? false) return 0;
    await _rpc('write.open', {'path': path, 'offset': offset});
    var written = 0;
    var finished = false;
    try {
      await for (final bytes in data) {
        for (var start = 0; start < bytes.length; start += _chunkSize) {
          if (cancel?.isCancelled ?? false) return written;
          checkCurrent?.call();
          final end = (start + _chunkSize).clamp(0, bytes.length);
          await _rpc('write.chunk', {'data': base64Encode(Uint8List.sublistView(bytes, start, end))});
          written += end - start;
          onProgress?.call(written);
        }
      }
      if (cancel?.isCancelled ?? false) return written;
      checkCurrent?.call();
      final result = await _rpc('write.finish');
      finished = true;
      return result['written'] as int;
    } finally {
      if (!finished && !_closed && _link.current) await _rpc('write.cancel').then((_) {}, onError: (Object _) {});
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _link._closeRemote(_id);
  }
}

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../foundation/cancellation.dart';
import '../../../foundation/file_system.dart';
import '../../../foundation/ids.dart';
import '../../connections/api.dart';
import '../../hosts/api.dart';
import '../adapters/local_fs.dart';

const localFiles = LocalFileSystem();

enum FileLocationKind { phone, computer, server }

/// A file browser target tied to a platform picker or an authenticated device connection.
class FileLocation {
  const FileLocation({
    required this.id,
    required this.label,
    required this.open,
    this.isCurrent,
    this.kind = FileLocationKind.phone,
  });

  final String id, label;
  final Future<FileSystem> Function() open;
  final bool Function()? isCurrent;
  final FileLocationKind kind;

  bool get current => isCurrent?.call() ?? true;

  Future<FsHandle> acquire() async {
    if (!current) throw const FsError(FsFailure.lost);
    final fs = await open();
    if (!current) {
      await fs.close();
      throw const FsError(FsFailure.lost);
    }
    return FsHandle(fs, () => fs.close().ignore(), isCurrent: isCurrent);
  }
}

/// Linked devices' folders a pane can open besides this device and saved hosts; the composition root fills it.
final fileLocationsProvider = Provider<List<FileLocation>>((ref) => const []);

/// A file system in use; [release] once done with it.
class FsHandle {
  FsHandle(this.fs, this._release, {bool Function()? isCurrent})
    : _isCurrent = isCurrent; // ignore: prefer_initializing_formals

  final FileSystem fs;
  final void Function() _release;
  final bool Function()? _isCurrent;
  var _released = false;

  bool get isCurrent => !_released && (_isCurrent?.call() ?? true);

  void release() {
    if (_released) return;
    _released = true;
    _release();
  }
}

/// Answers nothing: work started without a window to ask in fails rather than waits.
class NoPrompts implements ConnectPrompts {
  const NoPrompts();

  @override
  Future<TrustChoice> hostKey(HostKeyPrompt prompt) async => TrustChoice.reject;

  @override
  Future<SecretAnswer?> secret(SecretRequest request) async => null;
}

final fileSystemsProvider = Provider<FileSystems>((ref) {
  final pool = FileSystems(ref.read(connectionManagerProvider), (id) => ref.read(hostsProvider.notifier).byId(id));
  ref.onDispose(pool.closeAll);
  return pool;
});

/// File systems for background work (transfers, edits, capabilities): one SFTP channel per host, apart from the
/// channels browsers open, closed when its last user lets go. Browsing keeps its own so a long queue never
/// holds up a directory listing.
class FileSystems {
  FileSystems(this._connections, this._savedHost);

  final ConnectionManager _connections;
  final Host? Function(HostId id) _savedHost;

  /// Quick-connect hosts are not saved; whoever queues work for one tells us about it.
  final _known = <HostId, Host>{};
  final _links = <HostId, _Link>{};
  final _retired = <_Link>{};
  var _closed = false;

  void remember(Host host) {
    if (host.transient) _known[host.id] = host;
  }

  Host? host(HostId id) => _known[id] ?? _savedHost(id);

  Future<FsHandle> acquire(
    HostId? id,
    ConnectPrompts prompts, {
    CancellationToken? cancel,
    DateTime? deadline,
    bool Function()? isAuthorized,
  }) async {
    void check() {
      if (cancel?.isCancelled ?? false) throw const FsError(FsFailure.failed, 'cancelled');
      if (deadline != null && !DateTime.now().isBefore(deadline)) {
        throw const FsError(FsFailure.failed, 'deadlineExceeded');
      }
      if (isAuthorized?.call() == false) throw const FsError(FsFailure.failed, 'scopeChanged');
      if (_closed) throw const FsError(FsFailure.lost);
    }

    check();
    if (id == null) return FsHandle(localFiles, () {});
    for (var attempt = 0; attempt < 3; attempt++) {
      check();
      final host = this.host(id);
      if (host == null) throw const FsError(FsFailure.notFound, 'host');
      var link = _links[id];
      if (link != null &&
          (link.hostKey != ConnectionManager.keyOf(host) || link.lease != null && !link.lease!.isCurrent)) {
        _retire(id, link);
        link = null;
      }
      final acquired = link ?? _open(id, host, prompts);
      acquired.users++;
      try {
        final waiting = cancel == null
            ? acquired.ready
            : Future.any([
                acquired.ready,
                cancel.whenCancelled.then<FileSystem>((_) => throw const FsError(FsFailure.failed, 'cancelled')),
              ]);
        final fs = deadline == null
            ? await waiting
            : await waiting.timeout(
                deadline.difference(DateTime.now()),
                onTimeout: () => throw const FsError(FsFailure.failed, 'deadlineExceeded'),
              );
        check();
        if (acquired.lease?.isCurrent != true) {
          _retire(id, acquired);
          _release(id, acquired);
          continue;
        }
        return FsHandle(fs, () => _release(id, acquired), isCurrent: () => acquired.lease?.isCurrent == true);
      } on Object {
        _release(id, acquired);
        rethrow;
      }
    }
    throw const FsError(FsFailure.lost, 'scopeChanged');
  }

  void _retire(HostId id, _Link link) {
    if (_links[id] == link) _links.remove(id);
    _retired.add(link);
    if (link.users <= 0) _drop(id, link);
  }

  _Link _open(HostId id, Host host, ConnectPrompts prompts) {
    final link = _Link(ConnectionManager.keyOf(host));
    _links[id] = link;
    link.ready = _connections
        .open(host, prompts, (lease) => lease.openFiles(), purpose: LeasePurpose.files, cancel: link.cancel)
        .then((opened) async {
          final (lease, fs) = opened;
          if (link.closed) {
            try {
              await fs.close();
            } finally {
              lease.release();
            }
            throw const FsError(FsFailure.lost);
          }
          link.lease = lease;
          link.fs = fs;
          lease.done.whenComplete(() => _drop(id, link)).ignore();
          return fs;
        });
    link.ready.then((_) {}, onError: (Object _) => _drop(id, link));
    return link;
  }

  void _release(HostId id, _Link link) {
    link.users--;
    if (link.users <= 0) _drop(id, link);
  }

  void _drop(HostId id, _Link link) {
    if (_links[id] == link) _links.remove(id);
    _retired.remove(link);
    link.close();
  }

  void closeAll() {
    _closed = true;
    for (final l in {..._links.values, ..._retired}) {
      l.close();
    }
    _links.clear();
    _retired.clear();
  }
}

class _Link {
  _Link(this.hostKey);

  final String hostKey;
  final cancel = CancellationToken();
  var closed = false;
  late final Future<FileSystem> ready;
  TransportLease? lease;
  FileSystem? fs;
  var users = 0;

  void close() {
    if (closed) return;
    closed = true;
    cancel.cancel();
    final fs = this.fs, lease = this.lease;
    this.fs = null;
    this.lease = null;
    if (fs != null) fs.close().whenComplete(() => lease?.release()).ignore();
  }
}

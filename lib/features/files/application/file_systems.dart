import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../foundation/file_system.dart';
import '../../../foundation/ids.dart';
import '../../connections/api.dart';
import '../../hosts/api.dart';
import '../adapters/local_fs.dart';

const localFiles = LocalFileSystem();

/// A file system in use; [release] once done with it.
class FsHandle {
  FsHandle(this.fs, this._release);

  final FileSystem fs;
  final void Function() _release;
  var _released = false;

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

  void remember(Host host) {
    if (host.transient) _known[host.id] = host;
  }

  Host? host(HostId id) => _known[id] ?? _savedHost(id);

  Future<FsHandle> acquire(HostId? id, ConnectPrompts prompts) async {
    if (id == null) return FsHandle(localFiles, () {});
    final host = this.host(id);
    if (host == null) throw const FsError(FsFailure.notFound, 'host');
    var link = _links[id];
    if (link != null && (link.lease?.lost ?? false)) {
      _drop(id, link);
      link = null;
    }
    link ??= _open(id, host, prompts);
    link.users++;
    try {
      final fs = await link.ready;
      return FsHandle(fs, () => _release(id, link!));
    } on Object {
      link.users--;
      rethrow;
    }
  }

  _Link _open(HostId id, Host host, ConnectPrompts prompts) {
    final link = _Link();
    _links[id] = link;
    link.ready = _connections
        .open(host, prompts, (lease) => lease.openFiles(), purpose: LeasePurpose.files)
        .then((opened) {
      final (lease, fs) = opened;
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
    link.close();
  }

  void closeAll() {
    for (final l in _links.values) {
      l.close();
    }
    _links.clear();
  }
}

class _Link {
  late final Future<FileSystem> ready;
  TransportLease? lease;
  FileSystem? fs;
  var users = 0;

  void close() {
    final fs = this.fs, lease = this.lease;
    this.fs = null;
    this.lease = null;
    if (fs != null) fs.close().whenComplete(() => lease?.release()).ignore();
  }
}

import 'dart:io';

import '../../../foundation/json_file.dart';
import '../domain/protocol.dart';

/// Persists trusted paired devices in `link_peers.json`. Contains public keys and permissions only — never secrets.
class LinkPeerStore {
  LinkPeerStore(String dir)
    : _dir = dir,
      _file = JsonFile('$dir/link_peers.json', backups: true, validate: _validate);

  final String _dir;
  final JsonFile _file;
  Future<void> _pending = Future.value();

  static void _validate(Map<String, dynamic> json) {
    final peers = json['peers'];
    if (peers is! List) throw const FormatException('peers must be a list');
    final ids = <String>{};
    for (final entry in peers) {
      if (entry is! Map) throw const FormatException('peer must be an object');
      final peer = LinkPeer.fromJson(entry.cast<String, dynamic>());
      if (!ids.add(peer.deviceId)) throw const FormatException('duplicate peer id');
    }
  }

  List<LinkPeer> load() {
    final json = _file.read();
    if (json == null) return const [];
    return [
      for (final item in json['peers'] as List<dynamic>? ?? const [])
        LinkPeer.fromJson((item as Map).cast<String, dynamic>()),
    ];
  }

  Future<void> save(List<LinkPeer> peers) {
    final next = _pending.then((_) async {
      await Directory(_dir).create(recursive: true);
      await _file.write({
        'schemaVersion': 1,
        'peers': [for (final p in peers) p.toJson()],
      });
    });
    _pending = next.catchError((Object _) {});
    return next;
  }

  Future<void> get saved => _pending.then((_) => _file.idle);
}

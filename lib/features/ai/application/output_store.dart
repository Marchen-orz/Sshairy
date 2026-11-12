import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../../../foundation/ids.dart';

class StoredOutput {
  StoredOutput(this.id, this.owner, this.host, this.destination, this.revision, this.created);
  final String id, owner, destination;
  final HostId host;
  final int revision;
  final DateTime created;
  final _out = BytesBuilder(copy: false), _err = BytesBuilder(copy: false);
  int dropped = 0;
  String? _shared;
  int get length => _out.length + _err.length;
  bool get truncated => dropped > 0;
  String get stdout => utf8.decode(_out.toBytes(), allowMalformed: true);
  String get stderr => utf8.decode(_err.toBytes(), allowMalformed: true);
  String get preview => '$stdout${_err.isNotEmpty ? '\n[stderr]\n$stderr' : ''}';
  String get excerpt {
    final out = _out.toBytes(), err = _err.toBytes();
    final data = <int>[
      ...out.take(err.isEmpty ? 8192 : 4096),
      if (err.isNotEmpty) ...utf8.encode('\n[stderr]\n'),
      ...err.take(4000),
    ];
    return utf8.decode(data, allowMalformed: true).replaceAll('�', '');
  }
}

/// Handles carry access provenance; tools can read only bounded projections of approved operations.
class OutputStore {
  OutputStore({this.totalLimit = 8 << 20, this.itemLimit = 2 << 20, this.ttl = const Duration(minutes: 30)});
  final int totalLimit, itemLimit;
  final Duration ttl;
  final _items = <String, StoredOutput>{};
  int get length => _items.values.fold(0, (sum, item) => sum + item.length);
  int get count => _items.length;

  StoredOutput create(String owner, HostId host, String destination, int revision) {
    _expire();
    final item = StoredOutput(newId(), owner, host, destination, revision, DateTime.now());
    _items[item.id] = item;
    return item;
  }

  void append(StoredOutput item, bool stderr, Uint8List bytes) {
    if (!identical(_items[item.id], item)) return;
    final room = max(0, min(itemLimit - item.length, totalLimit - length));
    final kept = min(bytes.length, room);
    if (kept > 0) (stderr ? item._err : item._out).add(Uint8List.fromList(bytes.sublist(0, kept)));
    item.dropped += bytes.length - kept;
  }

  /// Shares the approved operation's bounded projection, never its raw buffers.
  void share(StoredOutput item, String text) {
    if (!identical(_items[item.id], item) || utf8.encode(text).length > 8192) throw ArgumentError('output projection');
    item._shared = text;
  }

  String? read(
    String id, {
    required String owner,
    required HostId host,
    required String destination,
    required int revision,
  }) {
    _expire();
    final item = _items[id];
    if (item == null ||
        item.owner != owner ||
        item.host != host ||
        item.destination != destination ||
        item.revision != revision) {
      return null;
    }
    return item._shared;
  }

  void _expire() => _items.removeWhere((_, item) => DateTime.now().difference(item.created) >= ttl);
  void clear() => _items.clear();
}

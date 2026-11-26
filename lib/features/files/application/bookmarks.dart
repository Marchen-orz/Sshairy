import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../foundation/data_dir.dart';
import '../../../foundation/json_file.dart';

final bookmarksProvider = NotifierProvider<Bookmarks, Map<String, List<String>>>(Bookmarks.new);

/// Owns bookmarks.json: folders saved per host id, or under [local] for this computer.
class Bookmarks extends Notifier<Map<String, List<String>>> {
  static const local = 'local';
  static const maxPerHost = 50;

  late final _file = JsonFile(
    '${ref.read(dataDirProvider)}/bookmarks.json',
    backups: true,
    validate: (json) {
      final hosts = json['bookmarks'];
      if (hosts is! Map) throw const FormatException('invalid bookmarks');
      for (final paths in hosts.values) {
        if (paths is! List || paths.any((p) => p is! String || p.isEmpty)) {
          throw const FormatException('invalid bookmarks');
        }
      }
    },
  );
  Future<void> _pending = Future.value();

  @override
  Map<String, List<String>> build() => Map.unmodifiable({
    for (final MapEntry(:key, :value) in ((_file.read()?['bookmarks'] as Map?) ?? const {}).entries)
      key as String: List<String>.unmodifiable((value as List).cast<String>()),
  });

  Future<void> toggle(String key, String path) {
    final next = _pending.then((_) async {
      final paths = [...?state[key]];
      if (!paths.remove(path)) {
        if (paths.length >= maxPerHost) return;
        paths.add(path);
      }
      final items = {...state, key: List<String>.unmodifiable(paths)}..removeWhere((_, v) => v.isEmpty);
      await _file.write({'schemaVersion': 1, 'bookmarks': items});
      state = Map.unmodifiable(items);
    });
    _pending = next.catchError((Object _) {});
    return next;
  }
}

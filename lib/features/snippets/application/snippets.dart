import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../foundation/cancellation.dart';
import '../../../foundation/data_dir.dart';
import '../../../foundation/json_file.dart';
import '../../terminal/api.dart';
import '../domain/snippet.dart';

typedef InsertSnippet = Future<InsertResult> Function(String text, {required bool run, CancellationToken? cancel});
final snippetInsertionProvider = Provider<InsertSnippet>(
  (_) =>
      (text, {required run, cancel}) async => InsertResult.unavailable,
);
final snippetsProvider = NotifierProvider<Snippets, List<Snippet>>(Snippets.new);

class Snippets extends Notifier<List<Snippet>> {
  late final _file = JsonFile(
    '${ref.read(dataDirProvider)}/snippets.json',
    backups: true,
    validate: (json) {
      if (json['snippets'] is! List) throw const FormatException('invalid snippets');
      final ids = <String>{};
      for (final entry in json['snippets'] as List) {
        final snippet = Snippet.fromJson((entry as Map).cast<String, dynamic>());
        snippet.validate();
        if (!ids.add(snippet.id)) throw const FormatException('duplicate snippet');
      }
    },
  );
  Future<void> _pending = Future.value();

  @override
  List<Snippet> build() => [
    for (final entry in _file.read()?['snippets'] as List<dynamic>? ?? const [])
      Snippet.fromJson(entry as Map<String, dynamic>),
  ];

  Future<void> get saved => _pending.then((_) => _file.idle);
  Snippet? byId(String id) => state.where((s) => s.id == id).firstOrNull;

  Future<void> _change(List<Snippet> Function() change) {
    final next = _pending.then((_) async {
      final items = change();
      await _file.write({
        'schemaVersion': 1,
        'snippets': [for (final s in items) s.toJson()],
      });
      state = List.unmodifiable(items);
    });
    _pending = next.catchError((Object _) {});
    return next;
  }

  Future<void> save(Snippet snippet) => _change(() {
    snippet.validate();
    final index = state.indexWhere((s) => s.id == snippet.id);
    return index < 0 ? [...state, snippet] : ([...state]..[index] = snippet);
  });

  Future<void> delete(String id) => _change(() => state.where((s) => s.id != id).toList());

  /// Merges snippets synced from a paired desktop without deleting local-only snippets.
  Future<int> mergeSynced(List<Snippet> incoming) async {
    var count = 0;
    await _change(() {
      final byId = {for (final s in state) s.id: s};
      for (final s in incoming) {
        s.validate();
        byId[s.id] = s;
        count++;
      }
      return byId.values.toList();
    });
    return count;
  }

  Future<InsertResult> insert(String id, {bool run = false, CancellationToken? cancel}) {
    final snippet = byId(id);
    if (snippet == null) return Future.value(InsertResult.unavailable);
    return ref.read(snippetInsertionProvider)(snippet.text, run: run, cancel: cancel);
  }
}

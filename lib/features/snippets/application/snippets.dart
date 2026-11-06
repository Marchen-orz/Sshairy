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
  late final _file = JsonFile('${ref.read(dataDirProvider)}/snippets.json');
  Future<void> _pending = Future.value();

  @override
  List<Snippet> build() => [
    for (final entry in _file.read()?['snippets'] as List<dynamic>? ?? const [])
      Snippet.fromJson(entry as Map<String, dynamic>),
  ];

  Future<void> get saved => _pending;
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

  Future<InsertResult> insert(String id, {bool run = false, CancellationToken? cancel}) {
    final snippet = byId(id);
    if (snippet == null) return Future.value(InsertResult.unavailable);
    return ref.read(snippetInsertionProvider)(snippet.text, run: run, cancel: cancel);
  }
}

import 'dart:convert';

import 'package:flutter/services.dart';

import '../domain/spec_completion.dart';

/// Loads the static projection only. No upstream JavaScript or generators run in the client.
class CompletionSpecs {
  CompletionSpecs({AssetBundle? bundle}) : _bundle = bundle ?? rootBundle;

  static final shared = CompletionSpecs();
  final AssetBundle _bundle;
  Future<void>? _manifest;
  Map<String, String> _commands = const {}, _nested = const {};
  final _cache = <String, CompletionSpec?>{};
  final _pending = <String, Future<CompletionSpec?>>{};
  final _costs = <String, int>{};
  var _bytes = 0;

  Future<void> _index() => _manifest ??= () async {
    try {
      final json = jsonDecode(await _bundle.loadString('assets/completions/manifest.json')) as Map;
      Map<String, String> paths(Object? value) => value is Map
          ? {
              for (final entry in value.entries)
                if (entry.key is String && entry.value is String) entry.key as String: entry.value as String,
            }
          : const {};
      _commands = paths(json['commands']);
      _nested = paths(json['nested']);
    } on Object {
      // A missing optional data asset leaves the small offline catalog available.
    }
  }();

  Future<List<String>> commandNames() async {
    await _index();
    return _commands.keys.toList()..sort();
  }

  Future<CompletionSpec?> load(String name) async {
    await _index();
    final path = _commands[name] ?? _nested[name];
    if (path == null) return null;
    if (_cache.containsKey(path)) {
      final value = _cache.remove(path);
      _cache[path] = value;
      return value;
    }
    return _pending[path] ??= _read(path).whenComplete(() {
      _pending.remove(path);
    });
  }

  Future<CompletionSpec?> _read(String path) async {
    CompletionSpec? spec;
    var cost = 0;
    try {
      final text = await _bundle.loadString(path, cache: false);
      cost = text.length * 2;
      spec = CompletionSpec.tryParse(jsonDecode(text));
    } on Object {
      spec = null;
    }
    _cache[path] = spec;
    _costs[path] = cost;
    _bytes += cost;
    while (_cache.length > 32 || _bytes > 16 * 1024 * 1024) {
      final key = _cache.keys.first;
      _cache.remove(key);
      _bytes -= _costs.remove(key) ?? 0;
    }
    return spec;
  }

  Future<({SpecCompletionResult result, bool available})> complete(String draft) async {
    final context = CompletionContext.parse(draft);
    final names = await commandNames();
    final choices = [for (final name in names) CompletionChoice(name)];
    final command = context.words.isEmpty ? context.current.value : context.words.first.value;
    final spec = await load(command);
    final resolved = <String, CompletionSpec?>{};
    SpecCompletionResult result;
    // The pure interpreter requests only references on the active command branch.
    // Keep a per-request map so a large reference chain cannot churn the shared LRU forever.
    for (var round = 0; ; round++) {
      final missing = <String>{};
      result = completeSpecInContext(
        spec,
        context,
        config: SpecCompletionConfig(
          limit: 200,
          commands: choices,
          includeOptionsForEmptyToken: true,
          nested: (name) {
            if (!resolved.containsKey(name)) missing.add(name);
            return resolved[name];
          },
          command: (name) {
            if (!resolved.containsKey(name)) missing.add(name);
            return resolved[name];
          },
        ),
      );
      if (missing.isEmpty || round >= 15) break;
      for (final name in missing.take(32)) {
        resolved[name] = await load(name);
      }
    }
    return (result: result, available: spec != null);
  }
}

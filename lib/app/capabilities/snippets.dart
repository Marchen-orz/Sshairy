import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../foundation/result.dart';
import '../../features/capabilities/api.dart';
import '../../features/terminal/api.dart';
import '../../features/snippets/api.dart';

List<Capability> snippetCapabilities(Ref ref) {
  Snippets snippets() => ref.read(snippetsProvider.notifier);
  return [
    FunctionCapability(
      'snippet.list',
      Effect.query,
      (a, context) async => Ok([for (final s in ref.read(snippetsProvider)) s.toJson()]),
    ),
    FunctionCapability(
      'snippet.save',
      Effect.localChange,
      (a, context) async {
        final tags = a.optional<List<dynamic>>('tags') ?? const [];
        if (tags.any((t) => t is! String)) throw ArgumentError('tags');
        final snippet = Snippet(
          id: a.require<String>('id'),
          label: a.require<String>('label'),
          text: a.require<String>('text'),
          tags: tags.cast<String>(),
        );
        await snippets().save(snippet);
        return Ok(snippet.toJson());
      },
      inputSchema: const {
        'type': 'object',
        'properties': {
          'id': {'type': 'string'},
          'label': {'type': 'string'},
          'text': {'type': 'string'},
          'tags': {
            'type': 'array',
            'items': {'type': 'string'},
          },
        },
        'required': ['id', 'label', 'text'],
      },
    ),
    FunctionCapability(
      'snippet.delete',
      Effect.localChange,
      (a, context) async {
        await snippets().delete(a.require<String>('id'));
        return const Ok(null);
      },
      inputSchema: const {
        'type': 'object',
        'properties': {
          'id': {'type': 'string'},
        },
        'required': ['id'],
      },
    ),
    FunctionCapability(
      'snippet.insert',
      Effect.remoteWrite,
      (a, context) async {
        final result = await snippets().insert(
          a.require<String>('id'),
          run: a.optional<bool>('run') ?? false,
          cancel: context.cancellation,
        );
        return result == InsertResult.sent ? const Ok(null) : Err(AppError(result.name));
      },
      inputSchema: const {
        'type': 'object',
        'properties': {
          'id': {'type': 'string'},
          'run': {'type': 'boolean'},
        },
        'required': ['id'],
      },
    ),
  ];
}

List<PaletteEntry> snippetPaletteEntries(PaletteContext c) => [
  for (final s in c.ref.read(snippetsProvider))
    PaletteEntry(
      section: PaletteSection.actions,
      title: '${c.l.insertSnippet} · ${s.label}',
      subtitle: s.tags.join(' · '),
      keywords: s.text,
      icon: Icons.code,
      run: () => c.dispatch('snippet.insert', {'id': s.id}),
    ),
];

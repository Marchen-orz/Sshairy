import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../foundation/file_system.dart';
import '../../foundation/ids.dart';
import '../../foundation/result.dart';
import '../../features/capabilities/api.dart';
import '../../features/hosts/api.dart';
import '../../features/files/api.dart';

Map<String, Object?> fileEntryDto(FileEntry e) => {
  'name': e.name,
  'kind': e.kind.name,
  if (e.size != null) 'size': e.size,
  if (e.modified != null) 'modified': e.modified!.toIso8601String(),
  if (e.mode != null) 'mode': e.mode!.toRadixString(8),
  if (e.owner != null) 'owner': e.owner,
  if (e.linkToDir) 'linkToDir': true,
};

Map<String, Object?> transferDto(Transfer t) => {
  'id': t.id.value,
  'state': t.state.name,
  'source': t.source.toJson(),
  'target': t.target.toJson(),
  'bytes': t.bytes,
  if (t.total != null) 'total': t.total,
  'files': t.files,
  if (t.totalFiles != null) 'totalFiles': t.totalFiles,
  if (t.skipped > 0) 'skipped': t.skipped,
  if (t.error != null) 'error': t.error,
};

const _hostProp = {'type': 'string', 'description': 'saved host ID; the agent always requires one'};
const _pathProp = {'type': 'string', 'description': 'absolute path'};

/// File and transfer use cases for the palette and, after review, the agent. Remote writes are separate
/// capabilities with their own effect, so policy can tell a listing from a delete (docs/CONTRACTS.md §3).
List<Capability> fileCapabilities(Ref ref) {
  FileSystems pool() => ref.read(fileSystemsProvider);
  TransferManager transfers() => ref.read(transfersProvider.notifier);

  /// Runs [body] on the file system of `hostId` (none for this computer), mapping file errors to results.
  Future<Result<Object?>> on(Args a, Future<Object?> Function(FileSystem fs) body) async {
    final id = a.optional<String>('hostId');
    if (id != null && pool().host(HostId(id)) == null) return const Err(AppError('notFound', detail: 'host'));
    final FsHandle handle;
    try {
      handle = await pool().acquire(id == null ? null : HostId(id), transfers().ui?.prompts ?? const NoPrompts());
    } on FsError catch (e) {
      return Err(AppError(e.kind.name, detail: e.detail));
    } on Object catch (e) {
      return Err(AppError('connect', detail: '$e'));
    }
    try {
      return Ok(await body(handle.fs));
    } on FsError catch (e) {
      return Err(AppError(e.kind.name, detail: e.detail, retryable: e.kind == FsFailure.lost));
    } on OpFailure catch (e) {
      return Err(AppError(e.code, detail: e.detail));
    } finally {
      handle.release();
    }
  }

  Host? hostArg(Args a, String key) {
    final id = a.optional<String>(key);
    return id == null ? null : pool().host(HostId(id));
  }

  TransferId transferArg(Args a) => TransferId(a.require<String>('transferId'));

  return [
    FunctionCapability(
      'file.list',
      Effect.query,
      inputSchema: const {
        'type': 'object',
        'properties': {
          'hostId': _hostProp,
          'path': _pathProp,
          'offset': {'type': 'integer', 'minimum': 0},
        },
        'required': ['path'],
      },
      agentExposed: true,
      (a, c) => on(a, (fs) async {
        final entries = await fs.list(a.require<String>('path'));
        if (c.origin != Origin.agent) return [for (final e in entries) fileEntryDto(e)];
        final offset = a.optional<int>('offset') ?? 0;
        final page = <Map<String, Object?>>[];
        var bytes = 2;
        for (final entry in entries.skip(offset)) {
          final dto = fileEntryDto(entry), size = utf8.encode(jsonEncode(dto)).length + 1;
          if (page.length == 200 || page.isNotEmpty && bytes + size > 24000) break;
          page.add(dto);
          bytes += size;
        }
        return {
          'entries': page,
          'total': entries.length,
          'nextOffset': offset + page.length < entries.length ? offset + page.length : null,
        };
      }),
    ),
    FunctionCapability(
      'file.stat',
      Effect.query,
      inputSchema: const {
        'type': 'object',
        'properties': {'hostId': _hostProp, 'path': _pathProp},
        'required': ['path'],
      },
      agentExposed: true,
      (a, _) => on(a, (fs) async {
        final e = await fs.stat(a.require<String>('path'));
        return e == null ? null : fileEntryDto(e);
      }),
    ),
    FunctionCapability(
      'file.read',
      Effect.query,
      inputSchema: const {
        'type': 'object',
        'properties': {
          'hostId': _hostProp,
          'path': _pathProp,
          'offset': {'type': 'integer', 'minimum': 0, 'maximum': 262144},
        },
        'required': ['path'],
      },
      agentExposed: true,
      (a, _) => on(a, (fs) => readTextFile(fs, a)),
    ),
    FunctionCapability(
      'file.write',
      Effect.remoteWrite,
      inputSchema: const {
        'type': 'object',
        'properties': {
          'hostId': _hostProp,
          'path': _pathProp,
          'text': {'type': 'string', 'maxLength': 262144},
          'overwrite': {'type': 'boolean'},
        },
        'required': ['path', 'text'],
      },
      agentExposed: true,
      (a, _) => on(a, (fs) => writeTextFile(fs, a)),
    ),
    FunctionCapability(
      'file.mkdir',
      Effect.remoteWrite,
      inputSchema: const {
        'type': 'object',
        'properties': {'hostId': _hostProp, 'path': _pathProp},
        'required': ['path'],
      },
      agentExposed: true,
      (a, _) => on(a, (fs) => fs.mkdir(a.require<String>('path'))),
    ),
    FunctionCapability(
      'file.rename',
      Effect.remoteWrite,
      inputSchema: const {
        'type': 'object',
        'properties': {'hostId': _hostProp, 'from': _pathProp, 'to': _pathProp},
        'required': ['from', 'to'],
      },
      agentExposed: true,
      (a, _) => on(a, (fs) => fs.rename(a.require<String>('from'), a.require<String>('to'))),
    ),
    FunctionCapability(
      'file.delete',
      Effect.remoteWrite,
      inputSchema: const {
        'type': 'object',
        'properties': {'hostId': _hostProp, 'path': _pathProp},
        'required': ['path'],
      },
      agentExposed: true,
      (a, _) => on(a, (fs) async {
        final path = a.require<String>('path');
        final e = await fs.stat(path);
        if (e == null) throw const FsError(FsFailure.notFound);
        await deleteTree(fs, path, e);
        return null;
      }),
    ),
    FunctionCapability(
      'transfer.list',
      Effect.query,
      (_, c) async => Ok([
        for (final t in ref.read(transfersProvider))
          c.origin == Origin.agent
              ? {
                  'id': t.id.value,
                  'state': t.state.name,
                  'bytes': t.bytes,
                  if (t.total != null) 'total': t.total,
                  'files': t.files,
                  if (t.totalFiles != null) 'totalFiles': t.totalFiles,
                  if (t.skipped > 0) 'skipped': t.skipped,
                  if (t.error != null) 'error': t.error,
                }
              : transferDto(t),
      ]),
      agentExposed: true,
    ),
    FunctionCapability(
      'transfer.enqueue',
      Effect.remoteWrite,
      inputSchema: const {
        'type': 'object',
        'properties': {
          'fromHostId': _hostProp,
          'paths': {
            'type': 'array',
            'items': {'type': 'string'},
          },
          'toHostId': _hostProp,
          'targetDir': _pathProp,
        },
        'required': ['paths', 'targetDir'],
      },
      agentExposed: true,
      (a, _) async {
        final from = hostArg(a, 'fromHostId'), to = hostArg(a, 'toHostId');
        if ((a.has('fromHostId') && from == null) || (a.has('toHostId') && to == null)) {
          return const Err(AppError('notFound', detail: 'host'));
        }
        final paths = a.require<List<Object?>>('paths');
        if (paths.isEmpty || paths.any((p) => p is! String)) throw ArgumentError.value(paths, 'paths', 'strings');
        final ids = transfers().enqueue(
          from: from,
          paths: paths.cast<String>(),
          to: to,
          targetDir: a.require<String>('targetDir'),
        );
        return Ok({
          'transferIds': [for (final id in ids) id.value],
        });
      },
    ),
    FunctionCapability(
      'transfer.cancel',
      Effect.localChange,
      inputSchema: const {
        'type': 'object',
        'properties': {
          'transferId': {'type': 'string'},
        },
        'required': ['transferId'],
      },
      agentExposed: true,
      (a, _) async {
        final id = transferArg(a);
        if (transfers().byId(id) == null) return const Err(AppError('notFound', detail: 'transfer'));
        await transfers().cancel(id);
        return const Ok(null);
      },
    ),
    FunctionCapability(
      'transfer.retry',
      Effect.remoteWrite,
      inputSchema: const {
        'type': 'object',
        'properties': {
          'transferId': {'type': 'string'},
        },
        'required': ['transferId'],
      },
      (a, _) async {
        final id = transferArg(a);
        final t = transfers().byId(id);
        if (t == null) return const Err(AppError('notFound', detail: 'transfer'));
        if (!t.state.canRetry) return const Err(AppError('cannotRetry'));
        await transfers().retry(id);
        return const Ok(null);
      },
    ),
    FunctionCapability(
      'transfer.pause',
      Effect.localChange,
      inputSchema: const {
        'type': 'object',
        'properties': {
          'transferId': {'type': 'string'},
        },
        'required': ['transferId'],
      },
      (a, _) async {
        final id = transferArg(a);
        if (transfers().byId(id) == null) return const Err(AppError('notFound', detail: 'transfer'));
        transfers().pause(id);
        return const Ok(null);
      },
    ),
    FunctionCapability(
      'transfer.resume',
      Effect.remoteWrite,
      inputSchema: const {
        'type': 'object',
        'properties': {
          'transferId': {'type': 'string'},
        },
        'required': ['transferId'],
      },
      (a, _) async {
        final id = transferArg(a);
        final t = transfers().byId(id);
        if (t == null) return const Err(AppError('notFound', detail: 'transfer'));
        if (t.state != TransferState.paused &&
            !(t.state == TransferState.interrupted && t.checkpoint?.settled == true)) {
          return const Err(AppError('cannotResume'));
        }
        transfers().resume(id);
        return const Ok(null);
      },
    ),
  ];
}

// 12 KiB keeps JSON escaping (tabs, newlines) inside the agent's per-call result budget.
const _maxTextBytes = 256 * 1024, _pageBytes = 12 * 1024;

/// One bounded, paginated UTF-8 page. Binary and oversized files are refused instead of mangled.
Future<Object?> readTextFile(FileSystem fs, Args a) async {
  final path = a.require<String>('path');
  final offset = a.optional<int>('offset') ?? 0;
  if (offset < 0 || offset > _maxTextBytes) throw const FsError(FsFailure.unsupported, 'offset');
  final entry = await fs.stat(path);
  if (entry == null) throw const FsError(FsFailure.notFound);
  if (entry.kind != FileKind.file) throw const FsError(FsFailure.unsupported, 'notFile');
  if (entry.size case final size? when size > _maxTextBytes) {
    throw const FsError(FsFailure.unsupported, 'tooLarge');
  }
  final bytes = BytesBuilder(copy: false);
  var eof = true;
  if (entry.size == null || offset < entry.size!) {
    await for (final chunk in fs.read(path, offset: offset)) {
      final room = _pageBytes - bytes.length;
      if (chunk.length > room) {
        bytes.add(chunk.sublist(0, room));
        eof = false;
        break;
      }
      bytes.add(chunk);
    }
  }
  final raw = bytes.takeBytes();
  var end = raw.length;
  // Never split a UTF-8 sequence at a page boundary; nextOffset resumes at the same byte.
  if (!eof) {
    var lead = end - 1;
    while (lead >= 0 && end - lead <= 4 && (raw[lead] & 0xC0) == 0x80) {
      lead--;
    }
    if (lead >= 0) {
      final value = raw[lead];
      final length = value >= 0xF0
          ? 4
          : value >= 0xE0
          ? 3
          : value >= 0xC0
          ? 2
          : 1;
      if (end - lead < length) end = lead;
    }
  }
  final page = raw.sublist(0, end);
  if (page.contains(0)) throw const FsError(FsFailure.unsupported, 'binary');
  return {
    'path': path,
    'text': utf8.decode(page, allowMalformed: true),
    'offset': offset,
    'nextOffset': eof ? null : offset + end,
    'eof': eof,
    if (entry.size != null) 'size': entry.size,
  };
}

/// Writes UTF-8 through a sibling temporary file so a replacement is atomic; never truncates in place.
Future<Object?> writeTextFile(FileSystem fs, Args a) async {
  final path = a.require<String>('path');
  final text = a.require<String>('text');
  final bytes = utf8.encode(text);
  if (text.contains('\x00')) throw const FsError(FsFailure.unsupported, 'nul');
  if (bytes.length > _maxTextBytes) throw const FsError(FsFailure.unsupported, 'tooLarge');
  final existing = await fs.stat(path);
  if (existing != null && existing.kind != FileKind.file) {
    throw const FsError(FsFailure.unsupported, 'notFile');
  }
  if (existing != null && !(a.optional<bool>('overwrite') ?? false)) {
    throw const FsError(FsFailure.exists);
  }
  if (existing != null && !fs.canReplace) {
    throw const FsError(FsFailure.unsupported, 'atomicReplace');
  }
  final temp = '$path.sshairy-tmp-${DateTime.now().microsecondsSinceEpoch}';
  try {
    await fs.create(temp, Stream.value(Uint8List.fromList(bytes)));
    if (existing == null) {
      await fs.rename(temp, path);
    } else {
      await fs.replace(temp, path);
    }
    return {'path': path, 'bytes': bytes.length, 'created': existing == null};
  } catch (_) {
    try {
      if (await fs.stat(temp) != null) await fs.delete(temp);
    } on Object {
      // The partial temporary file is left for the user; the target was not modified.
    }
    rethrow;
  }
}

List<PaletteEntry> filesPaletteEntries(PaletteContext c) {
  final l = c.l;
  return [
    PaletteEntry(
      section: PaletteSection.actions,
      title: l.sftp,
      keywords: l.files,
      icon: Icons.folder_copy_outlined,
      run: () => c.dispatch('workspace.focus', {'view': 'files'}),
    ),
    PaletteEntry(
      section: PaletteSection.actions,
      title: l.transfers,
      icon: Icons.swap_vert,
      run: () => showTransfers(c.context),
    ),
  ];
}

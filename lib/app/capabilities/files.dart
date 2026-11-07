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

const _hostProp = {'type': 'string', 'description': 'omit for this computer'};
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
        'properties': {'hostId': _hostProp, 'path': _pathProp},
        'required': ['path'],
      },
      (a, _) => on(a, (fs) async => [for (final e in await fs.list(a.require<String>('path'))) fileEntryDto(e)]),
    ),
    FunctionCapability(
      'file.stat',
      Effect.query,
      inputSchema: const {
        'type': 'object',
        'properties': {'hostId': _hostProp, 'path': _pathProp},
        'required': ['path'],
      },
      (a, _) => on(a, (fs) async {
        final e = await fs.stat(a.require<String>('path'));
        return e == null ? null : fileEntryDto(e);
      }),
    ),
    FunctionCapability(
      'file.mkdir',
      Effect.remoteWrite,
      inputSchema: const {
        'type': 'object',
        'properties': {'hostId': _hostProp, 'path': _pathProp},
        'required': ['path'],
      },
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
      (_, _) async => Ok([for (final t in ref.read(transfersProvider)) transferDto(t)]),
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

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
import '../../features/terminal/api.dart' show terminalAiSensitiveText;

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
  Future<Result<Object?>> on(
    Args a,
    RequestContext c,
    Future<Object?> Function(FileSystem fs, RequestContext current) body,
  ) async {
    try {
      _checkRequest(c);
    } on OpFailure catch (e) {
      return Err(AppError(e.code));
    }
    final id = a.optional<String>('hostId');
    if (c.origin == Origin.agent && id == null) return const Err(AppError('denied'));
    if (id != null && pool().host(HostId(id)) == null) return const Err(AppError('notFound', detail: 'host'));
    final FsHandle handle;
    try {
      handle = await pool().acquire(
        id == null ? null : HostId(id),
        transfers().ui?.prompts ?? const NoPrompts(),
        cancel: c.cancellation,
        deadline: c.deadline,
        isAuthorized: () => c.isCurrent,
      );
    } on FsError catch (e) {
      try {
        _checkRequest(c);
      } on OpFailure catch (stopped) {
        return Err(AppError(stopped.code));
      }
      return Err(AppError(e.kind.name, detail: c.origin == Origin.agent ? '' : e.detail));
    } on Object catch (e) {
      return Err(AppError('connect', detail: c.origin == Origin.agent ? '' : '$e'));
    }
    final current = c.origin == Origin.agent ? c.withAuthorization(() => handle.isCurrent) : c;
    try {
      _checkRequest(current);
      if (c.origin == Origin.agent) {
        for (final key in ['path', 'from', 'to']) {
          final path = a.optional<String>(key);
          if (path != null) await _checkedPath(handle.fs, path, context: current, mayBeMissing: true);
        }
      }
      _checkRequest(current);
      return Ok(await body(handle.fs, current));
    } on FsError catch (e) {
      return Err(
        AppError(e.kind.name, detail: c.origin == Origin.agent ? '' : e.detail, retryable: e.kind == FsFailure.lost),
      );
    } on OpFailure catch (e) {
      return Err(AppError(e.code, detail: c.origin == Origin.agent ? '' : e.detail));
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
      (a, c) => on(a, c, (fs, c) => listFiles(fs, a, c)),
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
      (a, c) => on(a, c, (fs, c) async {
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
      (a, c) => on(a, c, (fs, c) => readTextFile(fs, a, context: c)),
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
          'expectedSha256': {
            'type': 'string',
            'minLength': 64,
            'maxLength': 64,
            'pattern': r'^[0-9a-f]{64}$',
            'description': 'Full-file sha256 returned by files_read; required when replacing an existing file',
          },
        },
        'required': ['path', 'text'],
      },
      agentExposed: true,
      (a, c) => on(a, c, (fs, c) => writeTextFile(fs, a, context: c)),
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
      (a, c) => on(a, c, (fs, c) => fs.mkdir(a.require<String>('path'))),
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
      (a, c) => on(
        a,
        c,
        (fs, c) => fs.rename(a.require<String>('from'), a.require<String>('to'), checkCurrent: () => _checkRequest(c)),
      ),
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
      (a, c) => on(a, c, (fs, c) async {
        final path = a.require<String>('path');
        final e = await fs.stat(path);
        if (e == null) throw const FsError(FsFailure.notFound);
        _checkRequest(c);
        await deleteTree(
          fs,
          path,
          e,
          cancel: c.cancellation,
          deadline: c.deadline,
          checkCurrent: () => _checkRequest(c),
        );
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
      (a, c) async {
        _checkRequest(c);
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
          cancel: c.origin == Origin.agent ? c.cancellation : null,
          deadline: c.origin == Origin.agent ? c.deadline : null,
          isAuthorized: c.origin == Origin.agent ? () => c.isCurrent : null,
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
const _maxDirectoryScan = 10000;

void _checkRequest(RequestContext? context) {
  if (context?.cancellation?.isCancelled ?? false) throw const OpFailure('cancelled');
  if (context?.deadline case final deadline? when !DateTime.now().isBefore(deadline)) {
    throw const OpFailure('deadlineExceeded');
  }
  if (context != null && !context.isCurrent) throw const OpFailure('scopeChanged');
}

void _checkAgentPath(String path) {
  if (!path.startsWith('/') || path.contains('\x00')) throw const OpFailure('invalidArgument');
  final parts = path.toLowerCase().split('/').where((p) => p.isNotEmpty).toList();
  if (parts.any((p) => p == '.' || p == '..')) throw const OpFailure('invalidArgument');
  const privateParts = {
    '.ssh',
    '.gnupg',
    '.aws',
    '.azure',
    '.kube',
    '.docker',
    '.netrc',
    '.npmrc',
    '.pypirc',
    '.git-credentials',
    '.bash_history',
    '.zsh_history',
    '.python_history',
    '.mysql_history',
    '.psql_history',
  };
  if (parts.any((p) => privateParts.contains(p) || p == '.env' || p.startsWith('.env.')) ||
      parts.isNotEmpty && {'proc', 'sys', 'dev'}.contains(parts.first) ||
      RegExp(r'^/etc/(?:shadow|gshadow|ssh)(?:/|$)').hasMatch(path.toLowerCase()) ||
      RegExp(r'\.(?:pem|key|p12|pfx|kdbx)$').hasMatch(path.toLowerCase()) ||
      RegExp(r'/\.config/(?:gcloud|gh|rclone)(?:/|$)').hasMatch(path.toLowerCase()) ||
      RegExp(r'/id_(?:rsa|dsa|ecdsa|ed25519)(?:\.|$)').hasMatch(path.toLowerCase())) {
    throw const OpFailure('denied');
  }
}

Future<String> _checkedPath(FileSystem fs, String path, {RequestContext? context, bool mayBeMissing = false}) async {
  _checkRequest(context);
  _checkAgentPath(path);
  final entry = await fs.stat(path);
  _checkRequest(context);
  final String canonical;
  if (entry == null && mayBeMissing) {
    canonical = fs.style.join(await fs.resolve(fs.style.parent(path)), fs.style.name(path));
  } else {
    if (entry == null) throw const FsError(FsFailure.notFound);
    canonical = await fs.resolve(path);
  }
  _checkRequest(context);
  _checkAgentPath(canonical);
  return canonical;
}

Future<Object?> listFiles(FileSystem fs, Args a, RequestContext c) async {
  final path = a.require<String>('path');
  if (c.origin != Origin.agent) return [for (final e in await fs.list(path)) fileEntryDto(e)];
  final offset = a.optional<int>('offset') ?? 0;
  if (offset < 0 || offset >= _maxDirectoryScan) throw const OpFailure('invalidArgument');
  if (fs is! BoundedFileListing) throw const FsError(FsFailure.unsupported, 'boundedListing');
  _checkRequest(c);
  final listing = await (fs as BoundedFileListing).listBounded(
    path,
    maxScanned: _maxDirectoryScan,
    cancel: c.cancellation,
  );
  _checkRequest(c);
  final entries = listing.entries, page = <Map<String, Object?>>[];
  var bytes = 2;
  for (final entry in entries.skip(offset)) {
    final dto = fileEntryDto(entry), size = utf8.encode(jsonEncode(dto)).length + 1;
    if (size > 24000) throw const FsError(FsFailure.unsupported, 'entryTooLarge');
    if (page.length == 200 || bytes + size > 24000) break;
    page.add(dto);
    bytes += size;
  }
  return {
    'entries': page,
    'total': listing.complete ? entries.length : null,
    'scanned': listing.scanned,
    'complete': listing.complete,
    'nextOffset': offset + page.length < entries.length ? offset + page.length : null,
  };
}

Future<Uint8List> _readTextBytes(FileSystem fs, String path, RequestContext? context) async {
  _checkRequest(context);
  final entry = await fs.stat(path);
  _checkRequest(context);
  if (entry == null) throw const FsError(FsFailure.notFound);
  if (entry.kind != FileKind.file) throw const FsError(FsFailure.unsupported, 'notFile');
  if (entry.size case final size? when size > _maxTextBytes) {
    throw const FsError(FsFailure.unsupported, 'tooLarge');
  }
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in fs.read(path)) {
    _checkRequest(context);
    if (bytes.length + chunk.length > _maxTextBytes) throw const FsError(FsFailure.unsupported, 'tooLarge');
    bytes.add(chunk);
  }
  _checkRequest(context);
  final raw = bytes.takeBytes();
  if (raw.any((byte) => byte < 32 && byte != 9 && byte != 10 && byte != 13 || byte == 127)) {
    throw const FsError(FsFailure.unsupported, 'binary');
  }
  final String text;
  try {
    text = utf8.decode(raw);
  } on FormatException {
    throw const FsError(FsFailure.unsupported, 'encoding');
  }
  if (terminalAiSensitiveText(text)) throw const OpFailure('denied');
  return raw;
}

/// Validates the whole bounded file before returning a page, so secrets cannot hide across page boundaries.
Future<Object?> readTextFile(FileSystem fs, Args a, {RequestContext? context}) async {
  final path = a.require<String>('path');
  final canonical = await _checkedPath(fs, path, context: context);
  final offset = a.optional<int>('offset') ?? 0;
  final raw = await _readTextBytes(fs, canonical, context);
  if (offset < 0 || offset > raw.length || offset < raw.length && (raw[offset] & 0xC0) == 0x80) {
    throw const OpFailure('invalidArgument');
  }
  var end = (offset + _pageBytes).clamp(0, raw.length);
  while (end < raw.length && end > offset && (raw[end] & 0xC0) == 0x80) {
    end--;
  }
  return {
    'path': path,
    'text': utf8.decode(raw.sublist(offset, end)),
    'sha256': fileTextSha256(raw),
    'offset': offset,
    'nextOffset': end < raw.length ? end : null,
    'eof': end == raw.length,
    'size': raw.length,
  };
}

/// Empty staging is made private before any content is written; replacements preserve the original mode.
Future<Object?> writeTextFile(FileSystem fs, Args a, {RequestContext? context}) async {
  final path = a.require<String>('path');
  final canonical = await _checkedPath(fs, path, context: context, mayBeMissing: true);
  final text = a.require<String>('text'), bytes = utf8.encode(a.require<String>('text'));
  if (text.contains('\x00')) throw const FsError(FsFailure.unsupported, 'nul');
  if (bytes.length > _maxTextBytes) throw const FsError(FsFailure.unsupported, 'tooLarge');
  final existing = await fs.stat(path);
  _checkRequest(context);
  if (existing != null && existing.kind != FileKind.file) throw const FsError(FsFailure.unsupported, 'notFile');
  if (existing != null && !(a.optional<bool>('overwrite') ?? false)) throw const FsError(FsFailure.exists);
  if (existing != null && !fs.canReplace) throw const FsError(FsFailure.unsupported, 'atomicReplace');
  if (!fs.canChmod || existing != null && existing.mode == null) {
    throw const FsError(FsFailure.unsupported, 'privateStaging');
  }
  final expected = a.optional<String>('expectedSha256');
  if (existing != null && (expected == null || !RegExp(r'^[0-9a-f]{64}$').hasMatch(expected))) {
    throw const OpFailure('invalidArgument');
  }
  Future<void> checkBaseline() async {
    _checkRequest(context);
    final now = await fs.stat(path);
    _checkRequest(context);
    if (existing == null) {
      if (now != null) throw const OpFailure('conflict');
    } else {
      if (now == null || !existing.sameAs(now) || now.mode != existing.mode) throw const OpFailure('conflict');
      if (fileTextSha256(await _readTextBytes(fs, canonical, context)) != expected) {
        throw const OpFailure('conflict');
      }
    }
    if (await _checkedPath(fs, path, context: context, mayBeMissing: true) != canonical) {
      throw const OpFailure('conflict');
    }
    _checkRequest(context);
  }

  await checkBaseline();
  final temp = '$canonical.sshairy-tmp-${newId()}';
  // The unique name makes anything created under it ours, even when a revoked check interrupts the create.
  var owned = true;
  try {
    _checkRequest(context);
    await fs.create(
      temp,
      const Stream<Uint8List>.empty(),
      cancel: context?.cancellation,
      checkCurrent: () => _checkRequest(context),
    );
    _checkRequest(context);
    await fs.chmod(temp, 0x180);
    final private = await fs.stat(temp);
    if (private?.mode != 0x180) throw const FsError(FsFailure.permission, 'privateStaging');
    _checkRequest(context);
    final written = await fs.append(
      temp,
      Stream.value(Uint8List.fromList(bytes)),
      offset: 0,
      cancel: context?.cancellation,
      checkCurrent: () => _checkRequest(context),
    );
    _checkRequest(context);
    final staged = await fs.stat(temp);
    if (written != bytes.length || staged?.size != bytes.length) throw const OpFailure('sizeMismatch');
    if (existing?.mode case final mode?) {
      _checkRequest(context);
      await fs.chmod(temp, mode);
      if ((await fs.stat(temp))?.mode != mode) throw const FsError(FsFailure.permission, 'preserveMode');
    }
    await checkBaseline();
    _checkRequest(context);
    if (existing == null) {
      await fs.rename(temp, canonical, checkCurrent: () => _checkRequest(context));
    } else {
      await fs.replace(temp, canonical, checkCurrent: () => _checkRequest(context));
    }
    owned = false;
    return {'path': path, 'bytes': bytes.length, 'created': existing == null, 'sha256': fileTextSha256(bytes)};
  } finally {
    if (owned) {
      await fs.delete(temp).timeout(const Duration(seconds: 5)).then((_) {}, onError: (Object _) {});
    }
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

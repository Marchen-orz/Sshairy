import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/ai/api.dart';
import '../../features/capabilities/api.dart';
import '../../features/files/api.dart';
import '../../foundation/file_system.dart';
import '../../foundation/result.dart';
import '../mcp/controller.dart';
import 'files.dart';

/// The conversation's local grant behind an agent request; null when the caller is not the current Agent turn.
LocalGrant? agentLocalGrant(Ref ref, RequestContext c, String id) {
  final authority = c.authority;
  if (c.origin == Origin.externalAgent && authority is McpCall) return authority.localGrant(id);
  if (!c.origin.isAgent || authority is! AgentRuntime || !identical(authority, ref.read(agentRuntimeProvider))) {
    return null;
  }
  return authority.localGrant(id);
}

bool _inside(PathStyle style, String root, String path) {
  final windows = style == PathStyle.windows;
  final r = windows ? root.toLowerCase() : root, p = windows ? path.toLowerCase() : path;
  final separator = windows ? r'\' : '/';
  return p == r || p.startsWith(r.endsWith(separator) ? r : '$r$separator');
}

/// Resolves [relative] inside [grant] on this computer. The real path, after links and junctions, must stay inside
/// the granted root; a file grant reaches only that file. Credential locations stay refused (docs/AI.md §7.1).
Future<String> resolveGrantPath(FileSystem fs, LocalGrant grant, String relative, {bool directory = false}) async {
  final parts = localRelativeParts(relative);
  if (parts == null) throw const OpFailure('invalidArgument');
  if (!grant.directory && parts.isNotEmpty) throw const OpFailure('outsideScope');
  if (localSensitivePath([grant.label, ...parts])) throw const OpFailure('denied');
  final root = await fs.resolve(grant.root);
  final rootEntry = await fs.stat(root);
  if (rootEntry == null || rootEntry.isDir != grant.directory) throw const FsError(FsFailure.notFound);
  final joined = parts.fold(root, fs.style.join);
  final entry = await fs.stat(joined);
  if (entry == null) throw const FsError(FsFailure.notFound);
  final canonical = parts.isEmpty ? root : await fs.resolve(joined);
  if (!_inside(fs.style, root, canonical)) throw const OpFailure('denied');
  final inner = canonical.substring(root.length).split(RegExp(r'[\\/]')).where((part) => part.isNotEmpty).toList();
  if (localSensitivePath(inner)) throw const OpFailure('denied');
  if (directory && !(await fs.stat(canonical))!.isDir) throw const FsError(FsFailure.unsupported, 'notDirectory');
  return canonical;
}

const _grant = {'type': 'string', 'minLength': 1, 'maxLength': 128};
const _relative = {
  'type': 'string',
  'maxLength': 4096,
  'description': 'path relative to the grant root using "/"; empty for the root',
};

/// Agent-only access to folders and files the user granted to the conversation.
List<Capability> localFileCapabilities(Ref ref) {
  Future<Result<Object?>> on(
    Args a,
    RequestContext c,
    Future<Object?> Function(FileSystem fs, LocalGrant grant, String relative) body,
  ) async {
    final grant = agentLocalGrant(ref, c, a.require<String>('grantId'));
    if (grant == null) return const Err(AppError('expired'));
    if (!c.isCurrent) return const Err(AppError('scopeChanged'));
    final handle = await ref.read(fileSystemsProvider).acquire(null, const NoPrompts());
    try {
      return Ok(await body(handle.fs, grant, a.optional<String>('path') ?? ''));
    } on FsError catch (e) {
      return Err(AppError(e.kind.name));
    } on OpFailure catch (e) {
      return Err(AppError(e.code));
    } finally {
      handle.release();
    }
  }

  return [
    FunctionCapability(
      'local.requestAccess',
      Effect.query,
      inputSchema: const {
        'type': 'object',
        'properties': {
          'purpose': {'type': 'string', 'minLength': 1, 'maxLength': 160},
          'kind': {
            'type': 'string',
            'enum': ['directory', 'file'],
          },
          'write': {'type': 'boolean'},
        },
        'required': ['purpose', 'kind'],
        'additionalProperties': false,
      },
      agentExposed: true,
      externalAgentExposed: true,
      (a, c) async {
        final authority = c.authority;
        if (c.origin == Origin.externalAgent && authority is McpCall) return authority.requestLocalAccess(a.raw);
        if (!c.origin.isAgent || authority is! AgentRuntime || !identical(authority, ref.read(agentRuntimeProvider))) {
          return const Err(AppError('notExposed'));
        }
        return authority.requestLocalAccess(a.raw);
      },
    ),
    FunctionCapability(
      'local.list',
      Effect.query,
      inputSchema: const {
        'type': 'object',
        'properties': {
          'grantId': _grant,
          'path': _relative,
          'offset': {'type': 'integer', 'minimum': 0},
        },
        'required': ['grantId'],
        'additionalProperties': false,
      },
      agentExposed: true,
      externalAgentExposed: true,
      (a, c) => on(a, c, (fs, grant, relative) async {
        final at = await resolveGrantPath(fs, grant, relative, directory: true);
        final listing = await listFiles(fs, a, c, at: at) as Map<String, Object?>;
        // Credential names inside the folder are not even listed.
        return {
          ...listing,
          'entries': [
            for (final entry in listing['entries'] as List)
              if (!localSensitivePath([(entry as Map)['name'] as String])) entry,
          ],
        };
      }),
    ),
    FunctionCapability(
      'local.stat',
      Effect.query,
      inputSchema: const {
        'type': 'object',
        'properties': {'grantId': _grant, 'path': _relative},
        'required': ['grantId'],
        'additionalProperties': false,
      },
      agentExposed: true,
      externalAgentExposed: true,
      (a, c) => on(a, c, (fs, grant, relative) async {
        final entry = await fs.stat(await resolveGrantPath(fs, grant, relative));
        return entry == null ? null : {...fileEntryDto(entry), 'path': relative};
      }),
    ),
    FunctionCapability(
      'local.read',
      Effect.query,
      inputSchema: const {
        'type': 'object',
        'properties': {
          'grantId': _grant,
          'path': _relative,
          'offset': {'type': 'integer', 'minimum': 0, 'maximum': 262144},
        },
        'required': ['grantId'],
        'additionalProperties': false,
      },
      agentExposed: true,
      externalAgentExposed: true,
      (a, c) => on(
        a,
        c,
        (fs, grant, relative) async => readTextPage(
          fs,
          await resolveGrantPath(fs, grant, relative),
          relative,
          a.optional<int>('offset') ?? 0,
          context: c,
        ),
      ),
    ),
  ];
}

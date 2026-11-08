import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../foundation/ids.dart';
import '../../foundation/result.dart';
import '../../features/capabilities/api.dart';
import '../../features/credentials/api.dart';
import '../../features/hosts/api.dart';

/// A refused call with a stable code; handlers throw it and [guarded] turns it into an `Err`.
class Rejected implements Exception {
  const Rejected(this.code, [this.detail = '']);
  final String code, detail;
}

Future<Result<Object?>> Function(Args, RequestContext) guarded(Future<Object?> Function(Args a) body) =>
    (args, _) async {
      try {
        return Ok(await body(args));
      } on Rejected catch (e) {
        return Err(AppError(e.code, detail: e.detail));
      } on IdentityInUse catch (e) {
        return Err(AppError('inUse', detail: e.references.join(', ')));
      } on HostInUse catch (e) {
        return Err(AppError('inUse', detail: e.references.join(', ')));
      }
    };

const connectionFieldNames = ['port', 'login', 'jump', 'proxy', 'legacy'];
const _loginKeys = ['identityId', 'username', 'auth', 'methods', 'keyId', 'keyPath', 'allowInteractive'];

/// Connection settings shared by hosts, groups and the global defaults; a field that is not given stays as it is.
const connectionFields = {
  'port': {'type': 'integer', 'minimum': 1, 'maximum': 65535},
  'identityId': {
    'type': 'string',
    'description': 'An identity from identity.list; replaces username and every authentication field.',
  },
  'username': {'type': 'string'},
  'auth': {
    'type': 'string',
    'enum': ['password', 'key'],
    'description': 'A single method; methods gives the order.',
  },
  'methods': {
    'type': 'array',
    'items': {
      'type': 'string',
      'enum': ['password', 'key'],
    },
    'description': 'In order of use: [password], [key] or [key, password].',
  },
  'keyPath': {'type': 'string'},
  'keyId': {'type': 'string', 'description': 'An imported key from key.list; used instead of keyPath.'},
  'allowInteractive': {'type': 'boolean', 'description': 'Allow keyboard-interactive prompts.'},
  'jumpHostId': {'type': 'string', 'description': 'Saved jump host ID; empty means a direct route.'},
  'proxy': {
    'type': ['object', 'null'],
    'properties': {
      'kind': {
        'type': 'string',
        'enum': ['socks5', 'http'],
      },
      'address': {'type': 'string'},
      'port': {'type': 'integer', 'minimum': 1, 'maximum': 65535},
      'username': {'type': 'string'},
    },
    'required': ['kind', 'address', 'port'],
    'additionalProperties': false,
    'description': 'null means no proxy.',
  },
  'legacy': {'type': 'boolean'},
  'inherit': {
    'type': 'array',
    'items': {'type': 'string', 'enum': connectionFieldNames},
    'description': 'Fields that take the group or global value again.',
  },
};

Map<String, Object?> policyDto(AuthPolicy p) => {
  'methods': [for (final m in p.methods) m.name],
  if (p.keyId != null) 'keyId': p.keyId,
  'allowInteractive': p.allowInteractive,
};

/// The fields that take their value from a group or the global defaults.
List<String> inheritedFields(ConnectionOverrides o) => [
  if (o.port.mode == OverrideMode.inherit) 'port',
  if (o.authentication.mode == OverrideMode.inherit) 'login',
  if (o.jump.mode == OverrideMode.inherit) 'jump',
  if (o.proxy.mode == OverrideMode.inherit) 'proxy',
  if (o.legacy.mode == OverrideMode.inherit) 'legacy',
];

/// What [patchConnection] accepts, so a result can be fed back as an update; no key paths and no secrets.
Map<String, Object?> connectionDto(ConnectionOverrides o) {
  final login = o.authentication.value;
  return {
    if (o.port.value != null) 'port': o.port.value,
    if (login?.identityId != null) 'identityId': login!.identityId,
    if (login != null && login.identityId == null) ...{'username': login.username, ...policyDto(login.policy!)},
    if (o.jump.mode != OverrideMode.inherit) 'jumpHostId': o.jump.value?.value ?? '',
    if (o.proxy.mode != OverrideMode.inherit) 'proxy': o.proxy.value?.toJson(),
    if (o.legacy.value != null) 'legacy': o.legacy.value,
    'inherit': inheritedFields(o),
  };
}

Map<String, Object?> groupDto(HostLibrary library, HostGroup g) => {
  'id': g.id,
  'path': library.groupPath(g.id),
  ...connectionDto(g.defaults),
};

Map<String, Object?> identityDto(HostLibrary library, HostIdentity i) => {
  'id': i.id,
  'label': i.label,
  'username': i.username,
  ...policyDto(i.policy),
  'revision': i.revision,
  'usedBy': library.identityReferences(i.id),
};

Proxy _proxy(Object? raw) {
  if (raw is Map && raw['kind'] is String && raw['address'] is String && raw['port'] is int) {
    final kind = ProxyKind.values.asNameMap()[raw['kind']];
    final address = (raw['address'] as String).trim();
    final port = raw['port'] as int;
    if (kind != null &&
        address.isNotEmpty &&
        port >= 1 &&
        port <= 65535 &&
        (raw['username'] == null || raw['username'] is String)) {
      return Proxy(kind, address, port, username: raw['username'] as String? ?? '');
    }
  }
  throw const Rejected('invalidArgument', 'proxy');
}

/// A username with an authentication policy, taking what is not given from [base].
Login inlineLogin(Ref ref, Args a, Login? base) {
  final username = a.optional<String>('username')?.trim() ?? base?.username ?? '';
  if (username.isEmpty) throw const Rejected('invalidArgument', 'username');
  if (a.has('auth') && a.has('methods')) throw const Rejected('invalidArgument', 'auth, methods');
  final List<AuthKind> methods;
  if (a.has('methods')) {
    final raw = a.raw['methods'];
    if (raw is! List || raw.any((m) => AuthKind.values.asNameMap()[m] == null)) {
      throw const Rejected('invalidArgument', 'methods');
    }
    methods = [for (final m in raw) AuthKind.values.byName(m as String)];
  } else if (a.has('auth')) {
    final kind = AuthKind.values.asNameMap()[a.optional<String>('auth')];
    if (kind == null) throw const Rejected('invalidArgument', 'auth');
    methods = [kind];
  } else {
    methods = base?.policy.methods ?? const [AuthKind.password];
  }

  String? clean(String? value) => value == null || value.trim().isEmpty ? null : value.trim();
  var keyId = base?.policy.keyId, keyPath = base?.policy.keyPath;
  // Naming one way to find the key drops the other.
  if (a.has('keyPath') || a.has('keyId')) {
    keyPath = a.has('keyPath') ? clean(a.optional<String>('keyPath')) : null;
    keyId = a.has('keyId') ? clean(a.optional<String>('keyId')) : null;
    if (keyId != null && keyPath != null) throw const Rejected('invalidArgument', 'keyId, keyPath');
  }
  if (!methods.contains(AuthKind.key)) {
    keyId = null;
    keyPath = null;
  } else if (keyId == null && keyPath == null) {
    throw const Rejected('invalidArgument', 'keyPath');
  }
  if (keyId != null && ref.read(keysProvider.notifier).byId(keyId) == null) throw const Rejected('notFound', 'keyId');
  final policy = AuthPolicy(
    methods: methods,
    keyId: keyId,
    keyPath: keyPath,
    allowInteractive: a.optional<bool>('allowInteractive') ?? base?.policy.allowInteractive ?? true,
  );
  try {
    policy.validate();
  } on ArgumentError {
    throw const Rejected('invalidArgument', 'methods');
  }
  return (username: username, policy: policy);
}

/// The new authentication when the call names any login field, else null.
Authentication? patchAuthentication(Ref ref, Args a, Login? base) {
  if (!_loginKeys.any(a.has)) return null;
  final identityId = a.optional<String>('identityId');
  if (identityId != null && identityId.isNotEmpty) {
    if (_loginKeys.where((k) => k != 'identityId').any(a.has)) throw const Rejected('invalidArgument', 'identityId');
    if (ref.read(hostsProvider.notifier).library.identityById(identityId) == null) {
      throw const Rejected('notFound', 'identityId');
    }
    return Authentication.identity(identityId);
  }
  final login = inlineLogin(ref, a, base);
  return Authentication.inline(login.username, login.policy);
}

/// Applies the connection fields of a call on top of [base]. A given field becomes an own value (an empty
/// `jumpHostId` or a null `proxy` means none), one listed in `inherit` is inherited again, the rest is kept.
ConnectionOverrides patchConnection(Ref ref, Args a, ConnectionOverrides base, {Login? login, HostId? self}) {
  final raw = a.raw['inherit'];
  if (raw != null && (raw is! List || raw.any((f) => !connectionFieldNames.contains(f)))) {
    throw const Rejected('invalidArgument', 'inherit');
  }
  final inherit = <String>{if (raw is List) ...raw.cast<String>()};
  void exclusive(String field, List<String> keys) {
    if (inherit.contains(field) && keys.any(a.has)) throw Rejected('invalidArgument', 'inherit: $field');
  }

  exclusive('port', ['port']);
  exclusive('login', _loginKeys);
  exclusive('jump', ['jumpHostId']);
  exclusive('proxy', ['proxy']);
  exclusive('legacy', ['legacy']);

  var port = base.port;
  if (inherit.contains('port')) {
    port = const OverrideValue.inherit();
  } else if (a.optional<int>('port') case final value?) {
    if (value < 1 || value > 65535) throw const Rejected('invalidArgument', 'port');
    port = OverrideValue.value(value);
  }

  var authentication = base.authentication;
  if (inherit.contains('login')) {
    authentication = const OverrideValue.inherit();
  } else if (patchAuthentication(ref, a, login) case final value?) {
    authentication = OverrideValue.value(value);
  }

  var jump = base.jump;
  if (inherit.contains('jump')) {
    jump = const OverrideValue.inherit();
  } else if (a.optional<String>('jumpHostId') case final value?) {
    if (value.isEmpty) {
      jump = const OverrideValue.disabled();
    } else {
      final id = HostId(value);
      if (ref.read(hostsProvider.notifier).byId(id) == null || id == self) {
        throw const Rejected('invalidArgument', 'jumpHostId');
      }
      jump = OverrideValue.value(id);
    }
  }

  var proxy = base.proxy;
  if (inherit.contains('proxy')) {
    proxy = const OverrideValue.inherit();
  } else if (a.has('proxy')) {
    proxy = a.raw['proxy'] == null ? const OverrideValue.disabled() : OverrideValue.value(_proxy(a.raw['proxy']));
  }

  var legacy = base.legacy;
  if (inherit.contains('legacy')) {
    legacy = const OverrideValue.inherit();
  } else if (a.optional<bool>('legacy') case final value?) {
    legacy = OverrideValue.value(value);
  }

  return ConnectionOverrides(port: port, authentication: authentication, jump: jump, proxy: proxy, legacy: legacy);
}

/// The login a connection setting layer currently stands for, if it has one.
Login? loginOf(HostLibrary library, ConnectionOverrides o) {
  final selected = o.authentication.value;
  return selected == null ? null : library.login(selected);
}

/// Groups, identities and the global defaults; the palette and a later AI call them through the same dispatcher as the UI.
List<Capability> hostLibraryCapabilities(Ref ref) {
  HostsNotifier notifier() => ref.read(hostsProvider.notifier);
  HostLibrary library() => notifier().library;

  HostGroup findGroup(Args a) =>
      library().groupById(a.require<String>('groupId')) ?? (throw const Rejected('notFound', 'group'));
  HostIdentity findIdentity(Args a) =>
      library().identityById(a.require<String>('identityId')) ?? (throw const Rejected('notFound', 'identity'));

  const groupProperties = {
    'path': {'type': 'string', 'description': 'Slash-separated, for example prod/web.'},
    ...connectionFields,
  };
  const identityProperties = {
    'label': {'type': 'string'},
    'username': {'type': 'string'},
    'auth': {
      'type': 'string',
      'enum': ['password', 'key'],
    },
    'methods': {
      'type': 'array',
      'items': {
        'type': 'string',
        'enum': ['password', 'key'],
      },
    },
    'keyPath': {'type': 'string'},
    'keyId': {'type': 'string'},
    'allowInteractive': {'type': 'boolean'},
  };

  return [
    FunctionCapability(
      'group.list',
      Effect.query,
      guarded((_) async => [for (final g in library().orderedGroups) groupDto(library(), g)]),
    ),
    FunctionCapability(
      'group.create',
      Effect.localChange,
      inputSchema: const {
        'type': 'object',
        'properties': groupProperties,
        'required': ['path'],
      },
      guarded((a) async {
        final defaults = patchConnection(ref, a, const ConnectionOverrides());
        final id = await notifier().createGroup(a.require<String>('path'), defaults: defaults);
        return groupDto(library(), library().groupById(id)!);
      }),
    ),
    FunctionCapability(
      'group.update',
      Effect.localChange,
      inputSchema: const {
        'type': 'object',
        'properties': {
          'groupId': {'type': 'string'},
          ...groupProperties,
        },
        'required': ['groupId'],
      },
      guarded((a) async {
        final group = findGroup(a);
        final defaults = patchConnection(ref, a, group.defaults, login: loginOf(library(), group.defaults));
        await notifier().updateGroup(group.id, path: a.optional<String>('path'), defaults: defaults);
        return groupDto(library(), library().groupById(group.id)!);
      }),
    ),
    FunctionCapability(
      'group.reorder',
      Effect.localChange,
      inputSchema: const {
        'type': 'object',
        'properties': {
          'groupId': {'type': 'string'},
          'beforeId': {
            'type': ['string', 'null'],
            'description': 'A group under the same parent to go in front of; null puts the group last.',
          },
        },
        'required': ['groupId', 'beforeId'],
      },
      guarded((a) async {
        if (!a.has('beforeId')) throw const Rejected('invalidArgument', 'beforeId');
        final group = findGroup(a);
        final beforeId = a.optional<String>('beforeId');
        if (beforeId != null) {
          final before = library().groupById(beforeId) ?? (throw const Rejected('notFound', 'beforeId'));
          if (before.parentId != group.parentId) throw const Rejected('invalidArgument', 'beforeId');
        }
        await notifier().reorderGroup(group.id, beforeId);
        return [for (final g in library().groupChildren(group.parentId)) groupDto(library(), g)];
      }),
    ),
    FunctionCapability(
      'group.delete',
      Effect.localChange,
      inputSchema: const {
        'type': 'object',
        'properties': {
          'groupId': {'type': 'string', 'description': 'Hosts and subgroups move up; the group defaults are dropped.'},
        },
        'required': ['groupId'],
      },
      guarded((a) async {
        await notifier().deleteGroup(findGroup(a).id);
        return null;
      }),
    ),
    FunctionCapability(
      'identity.list',
      Effect.query,
      guarded((_) async => [for (final i in library().identities) identityDto(library(), i)]),
    ),
    FunctionCapability(
      'identity.create',
      Effect.localChange,
      inputSchema: const {
        'type': 'object',
        'properties': identityProperties,
        'required': ['label', 'username'],
      },
      guarded((a) async {
        final label = a.optional<String>('label')?.trim() ?? '';
        if (label.isEmpty) throw const Rejected('invalidArgument', 'label');
        final login = inlineLogin(ref, a, null);
        final id = HostsNotifier.newIdentityId();
        await notifier().saveIdentity(
          HostIdentity(id: id, label: label, username: login.username, policy: login.policy),
        );
        return identityDto(library(), library().identityById(id)!);
      }),
    ),
    FunctionCapability(
      'identity.update',
      Effect.localChange,
      inputSchema: const {
        'type': 'object',
        'properties': {
          'identityId': {'type': 'string'},
          ...identityProperties,
        },
        'required': ['identityId'],
      },
      guarded((a) async {
        final identity = findIdentity(a);
        final label = a.optional<String>('label')?.trim() ?? identity.label;
        if (label.isEmpty) throw const Rejected('invalidArgument', 'label');
        final login = inlineLogin(ref, a, (username: identity.username, policy: identity.policy));
        await notifier().saveIdentity(identity.copyWith(label: label, username: login.username, policy: login.policy));
        return identityDto(library(), library().identityById(identity.id)!);
      }),
    ),
    FunctionCapability(
      'identity.delete',
      Effect.localChange,
      inputSchema: const {
        'type': 'object',
        'properties': {
          'identityId': {'type': 'string', 'description': 'Refused while a host, group or the defaults use it.'},
        },
        'required': ['identityId'],
      },
      guarded((a) async {
        await notifier().deleteIdentity(findIdentity(a).id);
        return null;
      }),
    ),
    FunctionCapability('hostDefaults.get', Effect.query, guarded((_) async => connectionDto(library().defaults))),
    FunctionCapability(
      'hostDefaults.update',
      Effect.localChange,
      inputSchema: const {'type': 'object', 'properties': connectionFields},
      guarded((a) async {
        final current = library().defaults;
        final defaults = patchConnection(ref, a, current, login: loginOf(library(), current));
        await notifier().saveDefaults(defaults);
        return connectionDto(library().defaults);
      }),
    ),
  ];
}

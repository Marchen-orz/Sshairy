import '../../../foundation/ids.dart';
import 'host.dart';
import 'host_validation.dart';

class HostGroup {
  const HostGroup({
    required this.id,
    required this.name,
    this.parentId,
    this.order = 0,
    this.defaults = const ConnectionOverrides(),
  });
  final String id, name;
  final String? parentId;
  final int order;
  final ConnectionOverrides defaults;
  factory HostGroup.fromJson(Map<String, dynamic> j) => HostGroup(
    id: j['id'] as String,
    name: j['name'] as String,
    parentId: j['parentId'] as String?,
    order: j['order'] as int? ?? 0,
    defaults: ConnectionOverrides.fromJson((j['defaults'] as Map?)?.cast() ?? {}),
  );
  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    if (parentId != null) 'parentId': parentId,
    'order': order,
    'defaults': defaults.toJson(),
  };
  HostGroup copyWith({String? name, String? Function()? parentId, int? order, ConnectionOverrides? defaults}) =>
      HostGroup(
        id: id,
        name: name ?? this.name,
        parentId: parentId == null ? this.parentId : parentId(),
        order: order ?? this.order,
        defaults: defaults ?? this.defaults,
      );
}

class HostIdentity {
  const HostIdentity({
    required this.id,
    required this.label,
    required this.username,
    required this.policy,
    this.revision = 0,
  });
  final String id, label, username;
  final AuthPolicy policy;
  final int revision;
  factory HostIdentity.fromJson(Map<String, dynamic> j) => HostIdentity(
    id: j['id'] as String,
    label: j['label'] as String,
    username: j['username'] as String,
    policy: AuthPolicy.fromJson((j['policy'] as Map).cast()),
    revision: j['revision'] as int? ?? 0,
  );
  Map<String, Object?> toJson() => {
    'id': id,
    'label': label,
    'username': username,
    'policy': policy.toJson(),
    'revision': revision,
  };
  HostIdentity copyWith({String? label, String? username, AuthPolicy? policy, int? revision}) => HostIdentity(
    id: id,
    label: label ?? this.label,
    username: username ?? this.username,
    policy: policy ?? this.policy,
    revision: revision ?? this.revision,
  );
}

/// A username with the way to authenticate it; no secret is part of it.
typedef Login = ({String username, AuthPolicy policy});

/// An identity that hosts or defaults still use cannot be removed.
class IdentityInUse implements Exception {
  const IdentityInUse(this.references);
  final List<String> references;
}

/// A host that is somebody's jump host cannot be removed: dropping it would send them straight to their target,
/// or leave a route that no longer exists.
class HostInUse implements Exception {
  const HostInUse(this.references);
  final List<String> references;
}

/// Where each effective value came from: `''` is the built-in default, `global`, `group:<id>` or `host`.
class ResolvedConnection {
  const ResolvedConnection({
    required this.port,
    required this.authentication,
    required this.jump,
    required this.proxy,
    required this.legacy,
    required this.sources,
  });
  final int port;
  final Authentication? authentication;
  final HostId? jump;
  final Proxy? proxy;
  final bool legacy;
  final Map<String, String> sources;
}

class ResolvedHost {
  const ResolvedHost(this.host, this.sources);
  final Host host;
  final Map<String, String> sources;
}

ConnectionOverrides explicitConnection(Host host) => ConnectionOverrides(
  port: OverrideValue.value(host.port),
  authentication: OverrideValue.value(Authentication.inline(host.username, host.policy)),
  jump: host.jumpHostId == null ? const OverrideValue.disabled() : OverrideValue.value(host.jumpHostId!),
  proxy: host.proxy == null ? const OverrideValue.disabled() : OverrideValue.value(host.proxy!),
  legacy: OverrideValue.value(host.legacy),
);

final _control = RegExp(r'[\x00-\x1f\x7f]');

/// One immutable consistency snapshot; display paths and effective connections are derived, never written separately.
class HostLibrary {
  HostLibrary({
    Iterable<Host> hosts = const [],
    Iterable<HostGroup> groups = const [],
    Iterable<HostIdentity> identities = const [],
    this.defaults = const ConnectionOverrides(),
  }) : hosts = List.unmodifiable(hosts),
       groups = List.unmodifiable(groups),
       identities = List.unmodifiable(identities);

  /// Hosts that only know a `/` group path (older files, tests): groups are made from the paths and every
  /// connection setting becomes an explicit host value, so nothing starts inheriting by accident.
  factory HostLibrary.fromHosts(Iterable<Host> source, {String Function(int index)? groupId}) {
    final list = source.toList();
    final paths = allGroups(list);
    final ids = {for (var i = 0; i < paths.length; i++) paths[i]: groupId?.call(i) ?? newId()};
    return HostLibrary(
      hosts: [
        for (final host in list)
          host.copyWith(
            groupId: () => host.groupId ?? ids[host.group],
            overrides: () => host.overrides ?? explicitConnection(host),
          ),
      ],
      groups: [
        for (final path in paths)
          HostGroup(
            id: ids[path]!,
            name: path.split('/').last,
            parentId: path.contains('/') ? ids[path.substring(0, path.lastIndexOf('/'))] : null,
          ),
      ],
    ).normalized();
  }

  final List<Host> hosts;
  final List<HostGroup> groups;
  final List<HostIdentity> identities;
  final ConnectionOverrides defaults;

  HostLibrary copyWith({
    Iterable<Host>? hosts,
    Iterable<HostGroup>? groups,
    Iterable<HostIdentity>? identities,
    ConnectionOverrides? defaults,
  }) => HostLibrary(
    hosts: hosts ?? this.hosts,
    groups: groups ?? this.groups,
    identities: identities ?? this.identities,
    defaults: defaults ?? this.defaults,
  );

  Host? hostById(HostId id) => hosts.where((h) => h.id == id).firstOrNull;
  HostGroup? groupById(String? id) => groups.where((g) => g.id == id).firstOrNull;
  HostIdentity? identityById(String id) => identities.where((i) => i.id == id).firstOrNull;

  List<HostGroup> ancestors(String? id) {
    final chain = <HostGroup>[];
    final seen = <String>{};
    while (id != null) {
      if (!seen.add(id)) throw ArgumentError('group cycle');
      final group = groupById(id);
      if (group == null) throw ArgumentError('missing group');
      chain.add(group);
      id = group.parentId;
    }
    return chain.reversed.toList();
  }

  String groupPath(String? id) => ancestors(id).map((g) => g.name).join('/');
  String? groupIdFor(String path) => groups.where((g) => groupPath(g.id) == path).firstOrNull?.id;

  /// Full paths of every group, including empty ones, sorted.
  List<String> get groupPaths => [for (final g in groups) groupPath(g.id)]..sort();

  /// What a connection gets from the built-in defaults, [defaults], and the groups above and including [groupId],
  /// then [own] on top. A null [own] answers "what would a host here inherit".
  ResolvedConnection resolveConnection(String? groupId, ConnectionOverrides? own) {
    var port = 22, legacy = false;
    HostId? jump;
    Proxy? proxy;
    Authentication? authentication;
    final sources = <String, String>{
      for (final field in ['port', 'authentication', 'jump', 'proxy', 'legacy']) field: '',
    };
    void apply(ConnectionOverrides values, String source) {
      if (values.port.mode != OverrideMode.inherit) {
        if (values.port.mode == OverrideMode.disabled) throw ArgumentError('port cannot be disabled');
        port = values.port.value!;
        sources['port'] = source;
      }
      if (values.authentication.mode != OverrideMode.inherit) {
        if (values.authentication.mode == OverrideMode.disabled) {
          throw ArgumentError('authentication cannot be disabled');
        }
        authentication = values.authentication.value!;
        sources['authentication'] = source;
      }
      if (values.jump.mode != OverrideMode.inherit) {
        jump = values.jump.value;
        sources['jump'] = source;
      }
      if (values.proxy.mode != OverrideMode.inherit) {
        proxy = values.proxy.value;
        sources['proxy'] = source;
      }
      if (values.legacy.mode != OverrideMode.inherit) {
        if (values.legacy.mode == OverrideMode.disabled) throw ArgumentError('legacy cannot be disabled');
        legacy = values.legacy.value!;
        sources['legacy'] = source;
      }
    }

    apply(defaults, 'global');
    for (final group in ancestors(groupId)) {
      apply(group.defaults, 'group:${group.id}');
    }
    if (own != null) apply(own, 'host');
    return ResolvedConnection(
      port: port,
      authentication: authentication,
      jump: jump,
      proxy: proxy,
      legacy: legacy,
      sources: Map.unmodifiable(sources),
    );
  }

  /// The login an [Authentication] stands for: an identity's, or the inline one.
  Login login(Authentication selected) {
    final identity = selected.identityId == null ? null : identityById(selected.identityId!);
    if (selected.identityId != null && identity == null) throw ArgumentError('missing identity');
    return (username: identity?.username ?? selected.username!, policy: identity?.policy ?? selected.policy!);
  }

  ResolvedHost resolve(Host host) {
    final own = host.overrides ?? explicitConnection(host);
    final connection = resolveConnection(host.groupId, own);
    final selected = connection.authentication;
    if (selected == null) throw ArgumentError('missing authentication');
    final (:username, :policy) = login(selected);
    policy.validate();
    return ResolvedHost(
      Host(
        id: host.id,
        label: host.label,
        address: host.address,
        port: connection.port,
        username: username,
        auth: policy.methods.first,
        keyId: policy.keyId,
        keyPath: policy.keyPath,
        authPolicy: policy,
        group: groupPath(host.groupId),
        groupId: host.groupId,
        tags: host.tags,
        pinned: host.pinned,
        lastUsed: host.lastUsed,
        jumpHostId: connection.jump,
        proxy: connection.proxy,
        legacy: connection.legacy,
        overrides: own,
      ),
      connection.sources,
    );
  }

  /// Every stored host carries its effective values and its group path, so readers never resolve for themselves.
  HostLibrary normalized() => copyWith(hosts: [for (final host in hosts) resolve(host).host]);

  Iterable<ConnectionOverrides> get allOverrides sync* {
    yield defaults;
    yield* groups.map((g) => g.defaults);
    yield* hosts.map((h) => h.overrides ?? explicitConnection(h));
  }

  Iterable<AuthPolicy> get _policies sync* {
    for (final identity in identities) {
      yield identity.policy;
    }
    for (final values in allOverrides) {
      if (values.authentication.value?.policy case final policy?) yield policy;
    }
  }

  Set<String> get keyIds => {
    for (final policy in _policies)
      if (policy.keyId != null) policy.keyId!,
  };

  /// Who still uses the stored key [id]; labels for display, never secrets.
  List<String> keyReferences(String id) => [
    for (final identity in identities)
      if (identity.policy.keyId == id) identity.label,
    if (defaults.authentication.value?.policy?.keyId == id) 'global',
    for (final group in groups)
      if (group.defaults.authentication.value?.policy?.keyId == id) groupPath(group.id),
    for (final host in hosts)
      if ((host.overrides ?? explicitConnection(host)).authentication.value?.policy?.keyId == id) host.title,
  ];

  List<String> identityReferences(String id) => [
    if (defaults.authentication.value?.identityId == id) 'global',
    for (final group in groups)
      if (group.defaults.authentication.value?.identityId == id) groupPath(group.id),
    for (final host in hosts)
      if ((host.overrides ?? explicitConnection(host)).authentication.value?.identityId == id) host.title,
  ];

  /// Structural checks; routes are separate because older files may name jump hosts that were deleted since.
  void validate() {
    final groupIds = <String>{}, identityIds = <String>{}, hostIds = <HostId>{}, paths = <String>{};
    for (final group in groups) {
      if (group.id.isEmpty ||
          !groupIds.add(group.id) ||
          group.name.trim().isEmpty ||
          group.name.contains('/') ||
          group.name != group.name.trim() ||
          _control.hasMatch(group.name)) {
        throw ArgumentError('invalid group');
      }
    }
    for (final group in groups) {
      if (!paths.add(groupPath(group.id))) throw ArgumentError('invalid group');
    }
    for (final identity in identities) {
      if (identity.id.isEmpty ||
          !identityIds.add(identity.id) ||
          identity.revision < 0 ||
          identity.label.trim().isEmpty ||
          identity.username.isEmpty ||
          _control.hasMatch(identity.username)) {
        throw ArgumentError('invalid identity');
      }
      identity.policy.validate();
    }
    for (final values in allOverrides) {
      if (values.port.mode == OverrideMode.disabled ||
          values.authentication.mode == OverrideMode.disabled ||
          values.legacy.mode == OverrideMode.disabled) {
        throw ArgumentError('invalid disabled override');
      }
      if (values.port.value case final port? when port < 1 || port > 65535) {
        throw ArgumentError('invalid port');
      }
      if (values.authentication.value case final selected?) {
        if (selected.identityId != null) {
          if (identityById(selected.identityId!) == null) throw ArgumentError('missing identity');
        } else {
          if (selected.username!.isEmpty || _control.hasMatch(selected.username!)) {
            throw ArgumentError('invalid username');
          }
          selected.policy!.validate();
        }
      }
      if (values.proxy.value case final proxy?) {
        validateHost(
          Host(id: const HostId('_validation'), label: '', address: 'validation', username: 'validation', proxy: proxy),
        );
      }
    }
    for (final host in hosts) {
      if (!hostIds.add(host.id)) throw ArgumentError('duplicate host');
      validateHost(resolve(host).host);
    }
  }

  /// Hosts whose route cannot be walked: a jump host that is gone, a loop, or more than eight hops.
  Set<HostId> routeProblems() {
    final resolved = {for (final host in hosts) host.id: resolve(host).host};
    final problems = <HostId>{};
    for (final host in resolved.values) {
      final seen = <HostId>{};
      Host? current = host;
      while (current != null) {
        if (!seen.add(current.id) || seen.length > 8) {
          problems.add(host.id);
          break;
        }
        final jump = current.jumpHostId;
        if (jump == null) break;
        current = resolved[jump];
        if (current == null) problems.add(host.id);
      }
    }
    return problems;
  }

  /// The id of the group at [path], creating it and any missing parents.
  (HostLibrary, String?) withGroupPath(String path, {String Function() newGroupId = newId}) {
    var library = this;
    String? parent;
    for (final name in normalizeGroup(path).split('/').where((s) => s.isNotEmpty)) {
      final existing = library.groups.where((g) => g.parentId == parent && g.name == name).firstOrNull;
      if (existing != null) {
        parent = existing.id;
        continue;
      }
      final group = HostGroup(id: newGroupId(), name: name, parentId: parent);
      library = library.copyWith(groups: [...library.groups, group]);
      parent = group.id;
    }
    return (library, parent);
  }

  /// Adds or replaces [host]. A host without a group ID goes to the group its path names; one without overrides
  /// keeps every setting it carries as an explicit value.
  HostLibrary withHost(Host host, {String Function() newGroupId = newId}) {
    var library = this;
    var groupId = host.groupId;
    if (groupId == null && host.group.isNotEmpty) {
      (library, groupId) = library.withGroupPath(host.group, newGroupId: newGroupId);
    }
    if (groupId != null && library.groupById(groupId) == null) throw ArgumentError('missing group');
    final stored = host.copyWith(groupId: () => groupId, overrides: () => host.overrides ?? explicitConnection(host));
    final i = library.hosts.indexWhere((h) => h.id == host.id);
    return library.copyWith(hosts: i < 0 ? [...library.hosts, stored] : ([...library.hosts]..[i] = stored));
  }

  /// Who names [id] as a jump host: the global defaults, groups and hosts that set it themselves. A host that
  /// only inherits the jump is covered by the layer it inherits from.
  List<String> jumpReferences(HostId id) => [
    if (defaults.jump.value == id) 'global',
    for (final group in groups)
      if (group.defaults.jump.value == id) groupPath(group.id),
    for (final host in hosts)
      if (host.id != id && (host.overrides ?? explicitConnection(host)).jump.value == id) host.title,
  ];

  /// Throws [HostInUse] while something still routes through it.
  HostLibrary withoutHost(HostId id) {
    final references = jumpReferences(id);
    if (references.isNotEmpty) throw HostInUse(references);
    return copyWith(hosts: hosts.where((h) => h.id != id));
  }

  /// Removes a selection together; references between its members disappear with them.
  HostLibrary withoutHosts(Iterable<HostId> ids) {
    final wanted = ids.toSet();
    if (wanted.any((id) => hostById(id) == null)) throw ArgumentError('missing host');
    final next = copyWith(hosts: hosts.where((host) => !wanted.contains(host.id)));
    final references = {for (final id in wanted) ...next.jumpReferences(id)};
    if (references.isNotEmpty) throw HostInUse(references.toList());
    return next;
  }

  HostLibrary withGroup(HostGroup group) {
    final i = groups.indexWhere((g) => g.id == group.id);
    return copyWith(groups: i < 0 ? [...groups, group] : ([...groups]..[i] = group));
  }

  /// Gives group [id] the full path [path], creating parents; it keeps its defaults and members.
  HostLibrary withGroupMoved(String id, String path, {String Function() newGroupId = newId}) {
    final group = groupById(id);
    final names = normalizeGroup(path).split('/').where((s) => s.isNotEmpty).toList();
    if (group == null || names.isEmpty) throw ArgumentError('invalid group');
    final (library, parent) = withGroupPath(names.take(names.length - 1).join('/'), newGroupId: newGroupId);
    return library.withGroup(group.copyWith(name: names.last, parentId: () => parent));
  }

  /// Removes a group and keeps what it held: subgroups and hosts move to its parent, and its defaults are gone.
  HostLibrary withoutGroup(String id) {
    final group = groupById(id);
    if (group == null) return this;
    return copyWith(
      groups: [
        for (final g in groups)
          if (g.id != id) g.parentId == id ? g.copyWith(parentId: () => group.parentId) : g,
      ],
      hosts: [for (final h in hosts) h.groupId == id ? h.copyWith(groupId: () => group.parentId) : h],
    );
  }

  HostLibrary withIdentity(HostIdentity identity) {
    final i = identities.indexWhere((x) => x.id == identity.id);
    return copyWith(identities: i < 0 ? [...identities, identity] : ([...identities]..[i] = identity));
  }

  HostLibrary withoutIdentity(String id) {
    final references = identityReferences(id);
    if (references.isNotEmpty) throw IdentityInUse(references);
    return copyWith(identities: identities.where((i) => i.id != id));
  }

  HostLibrary withDefaults(ConnectionOverrides values) => copyWith(defaults: values);

  factory HostLibrary.fromJson(Map<String, dynamic> j) => HostLibrary(
    hosts: [for (final item in j['hosts'] as List) Host.fromJson((item as Map).cast())],
    groups: [for (final item in j['groups'] as List? ?? []) HostGroup.fromJson((item as Map).cast())],
    identities: [for (final item in j['identities'] as List? ?? []) HostIdentity.fromJson((item as Map).cast())],
    defaults: ConnectionOverrides.fromJson((j['defaults'] as Map?)?.cast() ?? {}),
  );

  Map<String, dynamic> toJson() => {
    'schemaVersion': 2,
    'hosts': [for (final h in hosts) h.toJson()],
    'groups': [for (final g in groups) g.toJson()],
    'identities': [for (final i in identities) i.toJson()],
    'defaults': defaults.toJson(),
  };

  /// schema 1 to 2: `/` paths become groups with stable IDs, and every host keeps its settings as explicit values.
  static Map<String, dynamic> migrateV1(Map<String, dynamic> source) {
    final library = HostLibrary.fromHosts([
      for (final item in source['hosts'] as List) Host.fromJson((item as Map).cast()),
    ], groupId: (index) => 'legacy-group-$index');
    return {...source, ...library.toJson()};
  }
}

import '../../../foundation/ids.dart';
import 'host.dart';
import 'host_validation.dart';
import 'ssh_config.dart';

class SshImportDraft {
  const SshImportDraft(this.source, {this.host, this.existing, this.additions = const [], this.issues = const []});

  final SshConfigHost source;
  final Host? host, existing;
  final List<Host> additions;
  final List<SshConfigIssue> issues;
  bool get selectable => host != null && existing == null && issues.isEmpty;
}

class SshImportPlan {
  const SshImportPlan(this.drafts, this.issues);

  final List<SshImportDraft> drafts;
  final List<SshConfigIssue> issues;

  /// Dependency jumps are included once, before their dependents, even when their own checkbox was not selected.
  List<Host> additions(Set<String> selected) => {
    for (final draft in drafts)
      if (draft.selectable && selected.contains(draft.source.alias))
        for (final host in draft.additions) host.id: host,
  }.values.toList();
}

String _endpoint(String address, int port, String user) => '${address.toLowerCase()}\u0000$port\u0000$user';

class _Jump {
  const _Jump(this.address, this.username, this.port);
  final String address;
  final String? username;
  final int? port;
}

_Jump? _jump(String text) {
  final match = RegExp(r'^(?:([^@\s]+)@)?(\[[0-9a-fA-F:.]+\]|[^@\s:\[\]/%$]+)(?::([0-9]+))?$').firstMatch(text);
  if (match == null) return null;
  final raw = match[2]!;
  final port = match[3] == null ? null : int.tryParse(match[3]!);
  if (port != null && (port < 1 || port > 65535)) return null;
  return _Jump(raw.startsWith('[') ? raw.substring(1, raw.length - 1) : raw, match[1], port);
}

/// Produces new metadata only. Existing hosts are reused as jumps or shown as conflicts, never edited.
SshImportPlan planSshConfig(SshConfig config, List<Host> saved, {required HostId Function() newId}) {
  final sources = {for (final host in config.hosts) host.alias.toLowerCase(): host};
  final generated = <String, Host>{};
  final newHosts = <HostId, Host>{};
  final drafts = <SshImportDraft>[];

  List<Host> existing(String address, int port, String username) => [
    for (final host in saved)
      if (_endpoint(host.address, host.port, host.username) == _endpoint(address, port, username)) host,
  ];
  SshConfigIssue issue(SshConfigHost source, SshConfigIssueKind kind) =>
      SshConfigIssue(kind, source.file, source.line, 'proxyjump');

  Host create(SshConfigHost source, HostId? upstream, {Host? clone}) {
    final signature = '${_endpoint(source.address, source.port, source.username)}\u0000${upstream?.value ?? ''}';
    if (generated[signature] case final known?) return known;
    final host = Host(
      id: newId(),
      label: clone == null
          ? source.alias
          : '${source.alias} → ${upstream == null ? source.address : (newHosts[upstream] ?? saved.where((h) => h.id == upstream).firstOrNull)?.title ?? source.address}',
      address: source.address,
      port: source.port,
      username: source.username,
      auth: clone?.auth ?? (source.keyPath == null ? AuthKind.password : AuthKind.key),
      keyPath: clone?.keyPath ?? source.keyPath,
      keyId: clone?.keyId,
      group: clone?.group ?? '',
      tags: clone?.tags ?? const [],
      jumpHostId: upstream,
      proxy: upstream == null ? clone?.proxy : null,
      legacy: clone?.legacy ?? false,
    );
    validateHost(host);
    generated[signature] = host;
    newHosts[host.id] = host;
    return host;
  }

  late Host Function(SshConfigHost, Set<String>, int, {HostId? upstream, bool replaceUpstream}) resolve;
  Host resolveJump(String value, SshConfigHost owner, Set<String> visited, int depth, HostId? upstream) {
    final parsed = _jump(value);
    if (parsed == null) throw issue(owner, SshConfigIssueKind.jump);
    final source = sources[parsed.address.toLowerCase()];
    if (source != null) {
      return resolve(
        SshConfigHost(
          alias: source.alias,
          address: source.address,
          username: parsed.username ?? source.username,
          port: parsed.port ?? source.port,
          keyPath: source.keyPath,
          jumps: source.jumps,
          file: source.file,
          line: source.line,
          issues: source.issues,
        ),
        visited,
        depth,
        upstream: upstream,
        replaceUpstream: upstream != null,
      );
    }
    final matches = [
      for (final host in saved)
        if ((host.address.toLowerCase() == parsed.address.toLowerCase() ||
                host.label.toLowerCase() == parsed.address.toLowerCase()) &&
            (parsed.username == null || host.username == parsed.username) &&
            host.port == (parsed.port ?? 22))
          host,
    ];
    if (matches.length != 1) {
      throw issue(owner, matches.isEmpty ? SshConfigIssueKind.jump : SshConfigIssueKind.ambiguous);
    }
    final host = matches.single;
    if (upstream == null || host.jumpHostId == upstream) return host;
    return create(
      SshConfigHost(
        alias: host.title,
        address: host.address,
        username: host.username,
        port: host.port,
        file: owner.file,
        line: owner.line,
      ),
      upstream,
      clone: host,
    );
  }

  resolve = (source, visited, depth, {upstream, replaceUpstream = false}) {
    if (source.blocked) throw source.issues.first;
    final identity = source.alias.toLowerCase();
    if (depth >= 8 || visited.contains(identity)) throw issue(source, SshConfigIssueKind.jumpCycle);
    final nextVisited = {...visited, identity};
    var jump = upstream;
    if (!replaceUpstream) {
      for (final entry in source.jumps) {
        jump = resolveJump(entry, source, nextVisited, depth + 1, jump).id;
      }
    }
    final matches = existing(source.address, source.port, source.username);
    if (matches.length > 1) throw issue(source, SshConfigIssueKind.ambiguous);
    if (matches.length == 1) {
      final host = matches.single;
      if (host.jumpHostId == jump) return host;
      return create(source, jump, clone: host);
    }
    return create(source, jump);
  };

  List<Host> dependencies(Host target) {
    final result = <Host>[];
    final visited = <HostId>{};
    void visit(Host host) {
      if (!visited.add(host.id) || visited.length > 8) throw const FormatException('jump chain');
      if (host.jumpHostId case final id?) {
        final parent = newHosts[id] ?? saved.where((h) => h.id == id).firstOrNull;
        if (parent == null) throw const FormatException('jump host');
        visit(parent);
      }
      if (newHosts.containsKey(host.id)) result.add(host);
    }

    visit(target);
    return result;
  }

  for (final source in config.hosts) {
    if (source.blocked) {
      drafts.add(SshImportDraft(source, issues: source.issues));
      continue;
    }
    try {
      // The same endpoint counts as saved only when the route is the saved one too; a different jump chain
      // stays a separate draft instead of silently dropping the route.
      final host = resolve(source, {}, 0);
      final match = existing(source.address, source.port, source.username).singleOrNull;
      if (match != null && identical(host, match)) {
        drafts.add(SshImportDraft(source, existing: match));
      } else {
        drafts.add(SshImportDraft(source, host: host, additions: dependencies(host)));
      }
    } on SshConfigIssue catch (error) {
      drafts.add(SshImportDraft(source, issues: [error]));
    } on FormatException {
      drafts.add(SshImportDraft(source, issues: [issue(source, SshConfigIssueKind.jumpCycle)]));
    } on ArgumentError {
      drafts.add(SshImportDraft(source, issues: [issue(source, SshConfigIssueKind.invalid)]));
    }
  }
  return SshImportPlan(drafts, config.issues);
}

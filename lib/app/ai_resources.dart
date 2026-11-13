import 'dart:convert';

import '../features/ai/api.dart';
import '../features/connections/api.dart';
import '../features/files/api.dart';
import '../features/forwarding/api.dart';
import '../features/hosts/api.dart';
import '../features/terminal/api.dart';
import '../features/workspace/api.dart';
import '../foundation/ids.dart';

/// Resolves object IDs locally; none of the resource fingerprints or connection configuration go to the model.
class AppAgentResources implements AgentResourceReader {
  AppAgentResources({
    required this.workspace,
    required this.sessions,
    required this.forwards,
    required this.forwardBinding,
    required this.transfers,
    required this.transferBinding,
    required this.hosts,
    required this.hostRevision,
  });

  final WorkspaceState Function() workspace;
  final Map<SessionId, TerminalSession> Function() sessions;
  final List<ForwardState> Function() forwards;
  final Object? Function(ForwardId id) forwardBinding;
  final List<Transfer> Function() transfers;
  final Object? Function(TransferId id) transferBinding;
  final List<Host> Function() hosts;
  final int Function() hostRevision;
  final _identities = Expando<String>();

  String _identity(Object value) => _identities[value] ??= newId();

  @override
  AgentResourceSnapshot? resolve(String capability, Map<String, Object?> args) {
    if (capability.startsWith('forward.')) return _forward(capability, args);
    if (capability == 'transfer.cancel') return _transfer(args);
    if (capability.startsWith('host.')) return _host(capability, args);
    return _workspace(capability, args);
  }

  AgentResourceSnapshot? _forward(String capability, Map<String, Object?> args) {
    final raw = args['id'];
    final saved = raw is String ? forwards().where((s) => s.rule.id == ForwardId(raw)).firstOrNull : null;
    if (capability != 'forward.save' && saved == null) return null;
    if (capability == 'forward.start' && args['hostId'] != saved!.rule.hostId.value) return null;
    final proposedHost = args['hostId'];
    final affected = <HostId>{if (saved != null) saved.rule.hostId, if (proposedHost is String) HostId(proposedHost)};
    if (affected.isEmpty || affected.any((id) => !hosts().any((h) => h.id == id))) return null;
    final identity = saved == null ? null : forwardBinding(saved.rule.id);
    return AgentResourceSnapshot(
      hosts: affected,
      binding: jsonEncode([
        saved?.rule.toJson(),
        if (saved != null) _identity(saved.rule),
        if (identity != null) _identity(identity),
        saved?.phase.name,
        saved?.port,
      ]),
      details: {
        if (saved != null) 'rule': saved.rule.toJson(),
        if (capability == 'forward.save')
          'proposed': {
            'id': raw,
            'hostId': proposedHost,
            'label': args['label'] ?? '',
            'kind': args['kind'],
            'listenAddress': args['listenAddress'] ?? '127.0.0.1',
            'listenPort': args['listenPort'],
            if (args['kind'] != 'dynamic') ...{
              'destinationAddress': args['destinationAddress'] ?? '127.0.0.1',
              'destinationPort': args['destinationPort'] ?? 0,
            },
            'autoStart': args['autoStart'] ?? false,
            'autoReconnect': args['autoReconnect'] ?? false,
          },
      },
    );
  }

  AgentResourceSnapshot? _transfer(Map<String, Object?> args) {
    final raw = args['transferId'];
    final transfer = raw is String ? transfers().where((t) => t.id == TransferId(raw)).firstOrNull : null;
    // Local transfers require a user-selected resource grant, which these tools do not provide.
    if (transfer == null || transfer.source.local || transfer.target.local) return null;
    final attempt = transferBinding(transfer.id);
    if (attempt == null) return null;
    return AgentResourceSnapshot(
      hosts: [transfer.source.host!, transfer.target.host!],
      binding: jsonEncode([
        _identity(attempt),
        transfer.id.value,
        transfer.batch,
        transfer.created.toIso8601String(),
        transfer.source.toJson(),
        transfer.target.toJson(),
      ]),
      details: {
        'transferId': transfer.id.value,
        'fromHostId': transfer.source.host!.value,
        'toHostId': transfer.target.host!.value,
        'from': transfer.source.path,
        'to': transfer.target.path,
      },
    );
  }

  AgentResourceSnapshot? _host(String capability, Map<String, Object?> args) {
    final raw = capability == 'host.move' ? args['hostIds'] : [args['hostId']];
    if (raw is! List || raw.isEmpty || raw.any((id) => id is! String)) return null;
    final affected = [for (final id in raw) HostId(id as String)];
    if (affected.any((id) => !hosts().any((h) => h.id == id))) return null;
    return AgentResourceSnapshot(
      hosts: affected,
      binding: jsonEncode([
        hostRevision(),
        [for (final id in affected) id.value],
      ]),
      details: {
        'hostIds': [for (final id in affected) id.value],
      },
    );
  }

  AgentResourceSnapshot? _workspace(String capability, Map<String, Object?> args) {
    final state = workspace(), current = sessions();
    final rawTab = args['tabId'], rawPane = args['paneId'];
    final focus = capability == 'workspace.focus';
    if (focus && rawTab == null && rawPane == null) {
      return AgentResourceSnapshot(
        hosts: const [],
        binding: jsonEncode(['view', args['view'] ?? 'vault']),
        details: {'view': args['view'] ?? 'vault'},
      );
    }
    final tab = rawTab is String ? state.tabs.where((t) => t.id == TabId(rawTab)).firstOrNull : state.activeTab;
    if (tab == null) return null;
    final tabTargets = capability == 'workspace.closeTabs'
        ? state.tabsToClose(tab.id, TabCloseScope.values.asNameMap()[args['scope']] ?? TabCloseScope.others)
        : [tab];
    final leafTargets = <Leaf>[];
    if (capability == 'workspace.closeTabs' || capability == 'session.close' && rawTab != null && rawPane == null) {
      leafTargets.addAll(tabTargets.expand((t) => t.layout.leaves));
    } else {
      final leaf = rawPane is String
          ? tab.layout.leaves.where((l) => l.pane == PaneId(rawPane)).firstOrNull
          : tab.layout.focusedLeaf;
      if (leaf == null) return null;
      leafTargets.add(leaf);
    }
    final affected = <HostId>{};
    final bindings = <Object?>[];
    final details = <Map<String, Object?>>[];
    for (final leaf in leafTargets) {
      final session = current[leaf.session];
      if (session == null) return null;
      final createsShell = capability == 'workspace.split' || capability == 'session.reconnect';
      if (createsShell && session.isLocal) return null;
      final host = session.sshHost;
      if (host != null && !focus) {
        final saved = hosts().where((h) => h.id == host.id).firstOrNull;
        if (saved == null || host.transient) return null;
        if (createsShell && ConnectionManager.keyOf(host) != ConnectionManager.keyOf(saved)) return null;
        affected.add(host.id);
      }
      bindings.add([
        leaf.pane.value,
        session.id.value,
        _identity(session),
        session.shellGeneration,
        session.status.name,
      ]);
      details.add({
        'paneId': leaf.pane.value,
        'sessionId': session.id.value,
        'targetKind': session.isLocal ? 'local' : 'ssh',
        if (host != null) 'hostId': host.id.value,
      });
    }
    return AgentResourceSnapshot(
      hosts: affected,
      binding: jsonEncode([
        if (rawTab == null) state.active?.value,
        if (capability == 'workspace.closeTabs') [for (final t in state.tabs) t.id.value],
        tab.id.value,
        _identity(tab.layout),
        tab.layout.toJson(),
        [
          for (final target in tabTargets) [target.id.value, _identity(target.layout), target.layout.toJson()],
        ],
        bindings,
      ]),
      details: {
        'tabId': tab.id.value,
        if (capability == 'workspace.closeTabs') 'tabIds': [for (final target in tabTargets) target.id.value],
        'sessions': details,
      },
    );
  }
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/dialog.dart';
import '../design/theme.dart';
import '../features/ai/api.dart';
import '../features/connections/api.dart';
import '../features/credentials/api.dart';
import '../features/files/api.dart';
import '../features/hosts/api.dart';
import '../features/link/api.dart';
import '../features/snippets/api.dart';
import '../features/terminal/api.dart';
import '../features/workspace/api.dart';
import '../foundation/cancellation.dart';
import '../foundation/file_system.dart';
import '../foundation/ids.dart';
import '../foundation/result.dart';
import '../foundation/secret.dart';
import '../l10n/app_localizations.dart';
import '../platform/desktop_window.dart';
import '../platform/device_form_factor.dart';
import 'mcp/controller.dart';

/// Composition-layer bridge connecting desktop [LinkHostController] to local terminals, SSH, hosts,
/// snippets, trust store, opt-in credentials, and Airy Agent / MCP approvals (docs/MOBILE.md §4, §6).
class AppLinkDesktopBridge implements LinkDesktopBridge {
  AppLinkDesktopBridge(this._ref) {
    _sessionsSub = _ref.listen<Map<SessionId, TerminalSession>>(
      terminalSessionsProvider,
      (_, sessions) => _syncSessionListeners(sessions),
      fireImmediately: true,
    );
    _hostsSub = _ref.listen<List<Host>>(hostsProvider, (_, _) {
      if (!_hostsChanged.isClosed) _hostsChanged.add(null);
    });
    _agent = _ref.read(agentRuntimeProvider);
    _agent.addListener(_onApprovalsChanged);
    _mcp = _ref.read(mcpControllerProvider);
    _mcp.addListener(_onApprovalsChanged);
  }

  final Ref _ref;
  late final ProviderSubscription<Map<SessionId, TerminalSession>> _sessionsSub;
  late final ProviderSubscription<List<Host>> _hostsSub;
  late final AgentRuntime _agent;
  late final McpController _mcp;

  final _sessionsChanged = StreamController<void>.broadcast();
  final _hostsChanged = StreamController<void>.broadcast();
  final _approvalsChanged = StreamController<void>.broadcast();
  final _watchedSessions = <SessionId, TerminalSession>{};

  // Stable unique IDs bound to the exact pending approval object instances so stale mobile clicks cannot
  // accidentally approve a newer request (first-responder wins between Desktop and Mobile).
  final _approvalIds = Expando<String>();
  final _approvalObjects = <String, Object>{};

  String _idFor(Object obj) {
    final existing = _approvalIds[obj];
    if (existing != null) {
      _approvalObjects[existing] = obj;
      return existing;
    }
    final fresh = newId();
    _approvalIds[obj] = fresh;
    _approvalObjects[fresh] = obj;
    return fresh;
  }

  void _syncSessionListeners(Map<SessionId, TerminalSession> sessions) {
    for (final entry in _watchedSessions.entries.toList()) {
      if (!identical(sessions[entry.key], entry.value)) {
        entry.value.removeListener(_emitSessionsChanged);
        _watchedSessions.remove(entry.key);
      }
    }
    for (final entry in sessions.entries) {
      if (entry.value.isRemote) continue;
      if (!_watchedSessions.containsKey(entry.key)) {
        _watchedSessions[entry.key] = entry.value;
        entry.value.addListener(_emitSessionsChanged);
      }
    }
    _emitSessionsChanged();
  }

  void _emitSessionsChanged() {
    if (!_sessionsChanged.isClosed) _sessionsChanged.add(null);
  }

  void _onApprovalsChanged() {
    if (!_approvalsChanged.isClosed) _approvalsChanged.add(null);
  }

  @override
  Stream<void> get sessionsChanged => _sessionsChanged.stream;

  @override
  Stream<void> get hostsChanged => _hostsChanged.stream;

  @override
  Stream<void> get approvalsChanged => _approvalsChanged.stream;

  @override
  List<LinkSessionSummary> listSessions() {
    final sessions = _ref.read(terminalSessionsProvider);
    return [
      for (final entry in sessions.entries)
        if (!entry.value.isRemote)
          LinkSessionSummary(
            sessionId: entry.key.value,
            title: entry.value.title,
            targetLabel: entry.value.targetLabel,
            isLocal: entry.value.isLocal,
            status: entry.value.status.name,
            cols: entry.value.cols,
            rows: entry.value.rows,
            hostId: entry.value.sshHost?.id.value,
          ),
    ];
  }

  @override
  MirrorAttachment? attachMirror(String sessionId, void Function(Uint8List chunk) onOutput) {
    final session = _ref.read(terminalSessionsProvider)[SessionId(sessionId)];
    if (session == null || session.isRemote) return null;
    final snapshot = session.captureMirrorSnapshot(maxBytes: linkSnapshotMaxBytes);
    final sub = session.mirrorOutput.listen(onOutput, onError: (Object _) {});
    return MirrorAttachment(
      snapshot: snapshot,
      write: session.sendRemoteInput,
      resize: session.resizeFromRemote,
      detach: () => unawaited(sub.cancel()),
    );
  }

  @override
  List<LinkHostSummary> listHosts() => [
    for (final h in _ref.read(hostsProvider))
      if (!h.transient)
        LinkHostSummary(
          hostId: h.id.value,
          label: h.label,
          targetLabel: h.target,
          group: h.group,
          tags: h.tags,
          pinned: h.pinned,
        ),
  ];

  @override
  Future<ShellChannel> openProxyShell(String hostId, {required int cols, required int rows}) async {
    final host = _ref.read(hostsProvider).where((h) => !h.transient && h.id.value == hostId).firstOrNull;
    if (host == null) throw const LinkException(LinkErrorKind.hostUnavailable);
    final connections = _ref.read(connectionManagerProvider);
    final prompts = _NonInteractiveProxyPrompts();
    try {
      final (lease, channel) = await connections.open(
        host,
        prompts,
        (lease) => lease.openShell(cols: cols, rows: rows),
        purpose: LeasePurpose.terminal,
      );
      return _LeasedShellChannel(lease, channel);
    } on ConnectError catch (e) {
      throw LinkException(LinkErrorKind.hostUnavailable, e.kind.name);
    } on Object {
      throw const LinkException(LinkErrorKind.hostUnavailable);
    }
  }

  @override
  Future<LinkFsHandle> openFiles(String target, CancellationToken cancel) async {
    if (target == 'local') return LinkFsHandle(localFiles, localFiles.close);
    if (!target.startsWith('host:')) throw const FsError(FsFailure.unsupported);
    final id = HostId(target.substring(5));
    final hosts = _ref.read(hostsProvider.notifier);
    final host = hosts.byId(id);
    if (host == null || host.transient) throw const FsError(FsFailure.notFound);
    final route = ConnectionManager.keyOf(host);
    bool currentRoute() {
      final current = hosts.byId(id);
      return current != null && !current.transient && ConnectionManager.keyOf(current) == route;
    }

    final (lease, fs) = await _ref
        .read(connectionManagerProvider)
        .open(host, const NoPrompts(), (lease) => lease.openFiles(), cancel: cancel, purpose: LeasePurpose.files);
    return LinkFsHandle(
      fs,
      () => fs.close().whenComplete(lease.release),
      isCurrent: () => currentRoute() && lease.isCurrent,
    );
  }

  @override
  LinkSyncBundle exportSyncBundle() {
    final library = _ref.read(hostsProvider.notifier).library;
    final snippets = _ref.read(snippetsProvider);
    final trust = _ref.read(hostTrustProvider);
    final ai = _ref.read(aiConfigurationProvider);
    final aiMap = ai.profile == null
        ? null
        : <String, dynamic>{
            'enabled': ai.enabled,
            'profile': ai.profile!.toJson(),
            'inlineEnabled': ai.inlineEnabled,
            'completionEnabled': ai.completionEnabled,
            if (ai.inlineModel != null) 'inlineModel': ai.inlineModel,
            if (ai.completionModel != null) 'completionModel': ai.completionModel,
            if (ai.reviewModel != null) 'reviewModel': ai.reviewModel,
          };
    return LinkSyncBundle(
      hostsLibrary: library.toJson(),
      snippets: [for (final s in snippets) s.toJson()],
      knownHosts: trust.entries,
      exportedAt: DateTime.now().toUtc(),
      aiConfig: aiMap,
    );
  }

  @override
  Future<List<({String id, String label})>> listHostsWithSavedPasswords() async {
    final hosts = _ref.read(hostsProvider).where((h) => !h.transient).toList();
    final editor = _ref.read(hostPasswordEditorProvider);
    final result = <({String id, String label})>[];
    for (final h in hosts) {
      final secret = await editor.readPassword(h.id);
      if (secret != null && secret.reveal().isNotEmpty) {
        result.add((id: h.id.value, label: h.label.isEmpty ? h.target : h.label));
      }
    }
    return result;
  }

  @override
  Future<LinkCredentialBundle> exportOptInCredentials({
    required Set<String> hostIds,
    required Set<String> keyIds,
    bool includeAiKey = false,
  }) async {
    final passwords = <String, String>{};
    if (hostIds.isNotEmpty) {
      final editor = _ref.read(hostPasswordEditorProvider);
      for (final id in hostIds) {
        final secret = await editor.readPassword(HostId(id));
        if (secret != null && secret.reveal().isNotEmpty) {
          passwords[id] = secret.reveal();
        }
      }
    }
    final keys = <({String label, String pem, String? passphrase})>[];
    if (keyIds.isNotEmpty) {
      final allKeys = _ref.read(keysProvider);
      final creds = _ref.read(connectionCredentialsProvider);
      for (final key in allKeys) {
        if (!keyIds.contains(key.id)) continue;
        final pem = await creds.read(key.privateRef);
        if (pem == null || pem.reveal().isEmpty) continue;
        final pass = key.encrypted ? await creds.read(key.passphraseRef) : null;
        keys.add((label: key.label, pem: pem.reveal(), passphrase: pass?.reveal()));
      }
    }
    ({String identity, String secret})? aiApiKey;
    if (includeAiKey) {
      final profile = _ref.read(aiConfigurationProvider).profile;
      if (profile != null) {
        final secret = await _ref.read(aiCredentialsProvider).read(profile.identity);
        if (secret != null && secret.reveal().isNotEmpty) {
          aiApiKey = (identity: profile.identity, secret: secret.reveal());
        }
      }
    }
    return LinkCredentialBundle(hostPasswords: passwords, privateKeys: keys, aiApiKey: aiApiKey);
  }

  @override
  List<LinkApprovalItem> listApprovals() {
    final items = <LinkApprovalItem>[];
    final activeIds = <String>{};
    final now = DateTime.now().toUtc();

    final action = _agent.approval;
    if (action != null) {
      final id = _idFor(action);
      activeIds.add(id);
      items.add(
        LinkApprovalItem(
          approvalId: id,
          source: LinkApprovalSource.agentAction,
          title: action.purpose.isNotEmpty ? action.purpose : action.capability,
          target: action.target,
          command: action.command,
          cwd: action.cwd,
          actionable: true,
          createdAt: now,
        ),
      );
    }

    final hostApproval = _agent.hostApproval;
    if (hostApproval != null) {
      final id = _idFor(hostApproval);
      activeIds.add(id);
      items.add(
        LinkApprovalItem(
          approvalId: id,
          source: LinkApprovalSource.agentHost,
          title: 'Airy Agent',
          target: hostApproval.target,
          actionable: true,
          createdAt: now,
        ),
      );
    }

    final localReq = _agent.localAccessRequest;
    if (localReq != null) {
      final id = _idFor(localReq);
      activeIds.add(id);
      items.add(
        LinkApprovalItem(
          approvalId: id,
          source: LinkApprovalSource.agentLocalNotice,
          title: 'Airy Agent',
          target: '',
          detail: localReq.purpose,
          actionable: false,
          createdAt: now,
        ),
      );
    }

    final mcpApproval = _mcp.approval;
    if (mcpApproval is McpHostApproval) {
      final id = _idFor(mcpApproval);
      activeIds.add(id);
      items.add(
        LinkApprovalItem(
          approvalId: id,
          source: LinkApprovalSource.mcpHost,
          title: 'MCP · ${mcpApproval.client.name}',
          target: mcpApproval.host.label,
          actionable: true,
          createdAt: now,
        ),
      );
    }

    _approvalObjects.removeWhere((id, _) => !activeIds.contains(id));
    return items;
  }

  @override
  bool decideApproval(String approvalId, bool allowed) {
    final obj = _approvalObjects.remove(approvalId);
    if (obj == null) return false;
    if (obj is AgentApproval && identical(_agent.approval, obj)) {
      _agent.approve(allowed, expected: obj);
      return true;
    }
    if (obj is AgentHostApproval && identical(_agent.hostApproval, obj)) {
      _agent.decideHost(obj, allowed);
      return true;
    }
    if (obj is McpHostApproval && identical(_mcp.approval, obj)) {
      _mcp.decide(obj, allowed);
      return true;
    }
    return false;
  }

  @override
  bool handoffHost(String hostId) {
    final host = _ref.read(hostsProvider).where((h) => !h.transient && h.id.value == hostId).firstOrNull;
    if (host == null) return false;
    _ref.read(workspaceProvider.notifier).openHost(host);
    return true;
  }

  @override
  Future<void> receiveClipboard(String text) => Clipboard.setData(ClipboardData(text: text));

  void dispose() {
    _sessionsSub.close();
    _hostsSub.close();
    for (final s in _watchedSessions.values) {
      s.removeListener(_emitSessionsChanged);
    }
    _watchedSessions.clear();
    _agent.removeListener(_onApprovalsChanged);
    _mcp.removeListener(_onApprovalsChanged);
    unawaited(_sessionsChanged.close());
    unawaited(_hostsChanged.close());
    unawaited(_approvalsChanged.close());
  }
}

/// Composition-layer bridge wired on Mobile to apply synced config/credentials
/// and open mirrored or desktop-proxied terminal tabs in the workspace.
class AppLinkMobileBridge implements LinkMobileBridge {
  AppLinkMobileBridge(this._ref);

  final Ref _ref;

  @override
  Future<LinkFsHandle> openFiles() async {
    final fs = await openMobileStorage(sharedOnly: true);
    return LinkFsHandle(fs, fs.close);
  }

  @override
  Future<LinkSyncSummary> applySyncBundle(LinkSyncBundle bundle) async {
    var hostsSynced = 0;
    if (bundle.hostsLibrary.isNotEmpty) {
      final incoming = HostLibrary.fromJson(bundle.hostsLibrary);
      hostsSynced = await _ref.read(hostsProvider.notifier).mergeSyncedLibrary(incoming);
    }
    var snippetsSynced = 0;
    if (bundle.snippets.isNotEmpty) {
      final incomingSnippets = [for (final j in bundle.snippets) Snippet.fromJson(j)];
      snippetsSynced = await _ref.read(snippetsProvider.notifier).mergeSynced(incomingSnippets);
    }
    final trustResult = bundle.knownHosts.isEmpty
        ? const TrustImportResult()
        : await _ref.read(hostTrustProvider).importKeys(bundle.knownHosts);
    var aiSynced = false;
    final rawAi = bundle.aiConfig;
    if (rawAi != null && rawAi['profile'] is Map) {
      try {
        final profile = ModelProfile.fromJson((rawAi['profile'] as Map).cast<String, Object?>());
        await _ref
            .read(aiConfigurationProvider.notifier)
            .save(
              enabled: rawAi['enabled'] as bool? ?? true,
              profile: profile,
              inlineEnabled: rawAi['inlineEnabled'] as bool?,
              completionEnabled: rawAi['completionEnabled'] as bool?,
              inlineModel: rawAi['inlineModel'] as String?,
              completionModel: rawAi['completionModel'] as String?,
              reviewModel: rawAi['reviewModel'] as String?,
            );
        aiSynced = true;
      } on Object {
        // Ignore malformed AI config without breaking host/snippet sync.
      }
    }
    return LinkSyncSummary(
      hostsSynced: hostsSynced,
      snippetsSynced: snippetsSynced,
      knownHostsAdded: trustResult.added,
      knownHostsConflicts: trustResult.conflicts.length,
      aiSynced: aiSynced,
    );
  }

  @override
  Future<int> importOptInCredentials(LinkCredentialBundle bundle) async {
    var imported = 0;
    if (bundle.hostPasswords.isNotEmpty) {
      final editor = _ref.read(hostPasswordEditorProvider);
      for (final entry in bundle.hostPasswords.entries) {
        if (entry.value.isEmpty) continue;
        await editor.savePassword(HostId(entry.key), Secret(entry.value));
        imported++;
      }
    }
    if (bundle.privateKeys.isNotEmpty) {
      final keys = _ref.read(keysProvider.notifier);
      for (final item in bundle.privateKeys) {
        if (item.pem.trim().isEmpty) continue;
        final pass = item.passphrase;
        final result = await keys.import(
          item.label,
          item.pem,
          passphrase: pass == null || pass.isEmpty ? null : Secret(pass),
          remember: pass != null && pass.isNotEmpty,
        );
        if (result is Ok) imported++;
      }
    }
    final aiKey = bundle.aiApiKey;
    if (aiKey != null && aiKey.identity.isNotEmpty && aiKey.secret.isNotEmpty) {
      await _ref.read(aiCredentialsProvider).save(aiKey.identity, Secret(aiKey.secret));
      imported++;
    }
    return imported;
  }

  @override
  void openRemoteTerminal({
    required String peerId,
    required String peerName,
    required String remoteId,
    required String title,
    required String targetLabel,
    required bool isMirror,
    required Future<ShellChannel> Function(int cols, int rows) openChannel,
  }) {
    _ref
        .read(workspaceProvider.notifier)
        .openRemote(
          LinkTerminalTarget(
            peerId: peerId,
            peerName: peerName,
            remoteId: remoteId,
            title: title,
            targetLabel: targetLabel,
            kind: isMirror ? LinkTerminalKind.mirror : LinkTerminalKind.proxy,
          ),
          openChannel,
        );
  }
}

class _NonInteractiveProxyPrompts implements ConnectPrompts {
  @override
  Future<TrustChoice> hostKey(HostKeyPrompt prompt) async => TrustChoice.reject;

  @override
  Future<SecretAnswer?> secret(SecretRequest request) async => null;
}

class _LeasedShellChannel implements ShellChannel {
  _LeasedShellChannel(this._lease, this._inner) {
    unawaited(_inner.done.whenComplete(_lease.release));
  }

  final TransportLease _lease;
  final ShellChannel _inner;

  @override
  Stream<Uint8List> get stdout => _inner.stdout;

  @override
  Stream<Uint8List> get stderr => _inner.stderr;

  @override
  Future<void> get done => _inner.done;

  @override
  void write(Uint8List data) => _inner.write(data);

  @override
  void resize(int cols, int rows) => _inner.resize(cols, rows);

  @override
  void close() {
    _inner.close();
    _lease.release();
  }
}

/// Ensures desktop [LinkHostController] starts/stops with the application lifecycle when enabled in settings,
/// and raises the desktop window to confirm mobile-requested server password syncs.
class LinkHostLifecycle extends ConsumerStatefulWidget {
  const LinkHostLifecycle({super.key, required this.child, this.window});

  final Widget child;
  final DesktopWindow? window;

  @override
  ConsumerState<LinkHostLifecycle> createState() => _LinkHostLifecycleState();
}

class _LinkHostLifecycleState extends ConsumerState<LinkHostLifecycle> {
  LinkHostController? _host;
  LinkPasswordSyncRequest? _shown;
  DialogRoute<bool>? _route;
  NavigatorState? _navigator;

  DesktopWindow get _window => widget.window ?? DesktopWindow.instance;

  void _attach(LinkHostController host) {
    if (identical(_host, host)) return;
    _host?.removeListener(_onHostChanged);
    _host = host;
    host.addListener(_onHostChanged);
    _onHostChanged();
  }

  void _onHostChanged() {
    if (!mounted) return;
    final host = _host;
    final req = host?.pendingPasswordSync;
    if (req == null || identical(_shown, req)) return;
    _shown = req;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && host != null) unawaited(_confirmPasswordSync(host, req));
    });
    // Ensure a frame actually runs even when the desktop window is idle or minimized in the background.
    WidgetsBinding.instance.scheduleFrame();
  }

  void _dismiss() {
    final route = _route, navigator = _navigator;
    if (route != null && route.isActive && navigator != null && navigator.mounted) {
      navigator.removeRoute(route, false);
    }
  }

  Future<void> _confirmPasswordSync(LinkHostController host, LinkPasswordSyncRequest request) async {
    if (!mounted || !identical(_host, host) || !identical(host.pendingPasswordSync, request)) {
      _shown = null;
      return;
    }
    await _window.show();
    await _window.setAlwaysOnTop(true);
    if (!mounted || !identical(_host, host) || !identical(host.pendingPasswordSync, request)) {
      await _window.setAlwaysOnTop(false);
      _shown = null;
      return;
    }
    final navigator = Navigator.of(context);
    final route = DialogRoute<bool>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: Theme.of(context).brightness == Brightness.dark ? .5 : .28),
      builder: (context) {
        final l = AppLocalizations.of(context);
        final scheme = Theme.of(context).colorScheme;
        return AppDialog(
          key: const ValueKey('link-password-sync-dialog'),
          title: Text(l.linkPasswordSyncConfirmTitle),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 240),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(l.linkPasswordSyncConfirmBody(request.peerName, request.hosts.length)),
                  const SizedBox(height: Space.sm),
                  for (final h in request.hosts)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Row(
                        children: [
                          Icon(Icons.key_outlined, size: 14, color: scheme.onSurfaceVariant),
                          const SizedBox(width: Space.xs),
                          Expanded(child: Text(h.label, overflow: TextOverflow.ellipsis)),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              key: const ValueKey('link-password-sync-deny'),
              autofocus: true,
              onPressed: () => Navigator.pop(context, false),
              child: Text(l.linkPasswordSyncSkip),
            ),
            FilledButton(
              key: const ValueKey('link-password-sync-allow'),
              onPressed: () => Navigator.pop(context, true),
              child: Text(l.linkPasswordSyncAllow),
            ),
          ],
        );
      },
    );
    _navigator = navigator;
    _route = route;
    void changed() {
      if (!identical(host.pendingPasswordSync, request) && route.isActive && navigator.mounted) {
        navigator.removeRoute(route, false);
      }
    }

    host.addListener(changed);
    try {
      final allowed = await navigator.push(route) ?? false;
      if (identical(host.pendingPasswordSync, request)) {
        await host.decidePasswordSync(request, allowed && identical(_host, host));
      }
    } finally {
      host.removeListener(changed);
      _shown = null;
      _route = null;
      _navigator = null;
      await _window.setAlwaysOnTop(false);
      if (mounted) _onHostChanged();
    }
  }

  @override
  void dispose() {
    _host?.removeListener(_onHostChanged);
    _dismiss();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (isDesktopPlatform) {
      _attach(ref.watch(linkHostControllerProvider));
    }
    return widget.child;
  }
}

/// The linked devices' folders for file panes: phones sharing theirs on a computer; the computer's folders and the
/// servers it reaches on a phone. Rebuilt only when that set changes; a reconnect gives new IDs.
List<FileLocation> linkFileLocations(Ref ref) {
  List<FileLocation> places() {
    if (!isMobilePlatform) {
      final host = ref.read(linkHostControllerProvider);
      return [
        for (final phone in host.sharedPhones)
          if (host.phoneFilesBinding(phone.id) case final binding?)
            FileLocation(
              id: 'link:${phone.id}:${identityHashCode(binding)}',
              label: phone.name,
              open: () => host.openPhoneFiles(phone.id, binding),
              isCurrent: () => identical(host.phoneFilesBinding(phone.id), binding),
            ),
      ];
    }
    final client = ref.read(linkClientControllerProvider);
    final local = client.desktopFilesBinding(), proxy = client.desktopFilesBinding(proxy: true);
    return [
      if (local != null)
        FileLocation(
          id: 'link:local:${identityHashCode(local)}',
          label: client.connectedDesktopName ?? '',
          open: () => client.openFiles(local),
          isCurrent: () => identical(client.desktopFilesBinding(), local),
          kind: FileLocationKind.computer,
        ),
      if (proxy != null)
        for (final h in client.desktopHosts)
          FileLocation(
            id: 'link:host:${h.hostId}:${identityHashCode(proxy)}',
            label: h.label,
            open: () => client.openFiles(proxy, hostId: h.hostId),
            isCurrent: () => identical(client.desktopFilesBinding(proxy: true), proxy),
            kind: FileLocationKind.server,
          ),
    ];
  }

  String keyOf(List<FileLocation> all) => [for (final l in all) '${l.id}\u0000${l.label}'].join('\n');
  final Listenable controller = isMobilePlatform
      ? ref.watch(linkClientControllerProvider)
      : ref.watch(linkHostControllerProvider);
  final current = places();
  final key = keyOf(current);
  void changed() {
    if (keyOf(places()) != key) ref.invalidateSelf();
  }

  controller.addListener(changed);
  ref.onDispose(() => controller.removeListener(changed));
  return current;
}

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../foundation/cancellation.dart';
import '../../../foundation/data_dir.dart';
import '../../../foundation/file_system.dart';
import '../../../foundation/ids.dart';
import '../../../foundation/secret.dart';
import '../../connections/api.dart';
import '../../credentials/api.dart';
import '../../settings/api.dart';
import '../adapters/crypto.dart';
import '../adapters/link_storage.dart';
import '../adapters/ws_transport.dart';
import '../domain/protocol.dart';
import '../domain/transport.dart';
import 'link_fs.dart';

/// Handle to a mirrored desktop terminal session.
class MirrorAttachment {
  const MirrorAttachment({required this.snapshot, required this.write, required this.resize, required this.detach});

  final Uint8List snapshot;
  final void Function(Uint8List data) write;
  final void Function(int cols, int rows) resize;
  final VoidCallback detach;
}

/// Composition-layer bridge wired on Desktop to connect Sshairy Link to workspace, SSH, hosts, snippets, trust & AI/MCP.
abstract interface class LinkDesktopBridge {
  List<LinkSessionSummary> listSessions();
  Stream<void> get sessionsChanged;

  MirrorAttachment? attachMirror(String sessionId, void Function(Uint8List chunk) onOutput);

  List<LinkHostSummary> listHosts();
  Stream<void> get hostsChanged;

  Future<ShellChannel> openProxyShell(String hostId, {required int cols, required int rows});

  LinkSyncBundle exportSyncBundle();

  /// Lists saved non-transient hosts that currently have a stored password on desktop (no secrets returned).
  Future<List<({String id, String label})>> listHostsWithSavedPasswords();

  Future<LinkCredentialBundle> exportOptInCredentials({
    required Set<String> hostIds,
    required Set<String> keyIds,
    bool includeAiKey = false,
  });

  List<LinkApprovalItem> listApprovals();
  Stream<void> get approvalsChanged;
  bool decideApproval(String approvalId, bool allowed);

  /// Opens a saved host directly on the desktop workspace (Mobile -> Desktop Handoff).
  bool handoffHost(String hostId);

  /// Writes text pushed over E2EE Link from a paired mobile peer to the desktop clipboard.
  Future<void> receiveClipboard(String text);

  Future<LinkFsHandle> openFiles(String target, CancellationToken cancel);
}

/// Composition-layer bridge wired on Mobile to apply synced data and open mirrored/proxied terminal tabs.
abstract interface class LinkMobileBridge {
  Future<LinkSyncSummary> applySyncBundle(LinkSyncBundle bundle);
  Future<int> importOptInCredentials(LinkCredentialBundle bundle);
  void openRemoteTerminal({
    required String peerId,
    required String peerName,
    required String remoteId,
    required String title,
    required String targetLabel,
    required bool isMirror,
    required Future<ShellChannel> Function(int cols, int rows) openChannel,
  });

  Future<LinkFsHandle> openFiles();
}

class _NullDesktopBridge implements LinkDesktopBridge {
  const _NullDesktopBridge();
  @override
  List<LinkSessionSummary> listSessions() => const [];
  @override
  Stream<void> get sessionsChanged => const Stream.empty();
  @override
  MirrorAttachment? attachMirror(String sessionId, void Function(Uint8List chunk) onOutput) => null;
  @override
  List<LinkHostSummary> listHosts() => const [];
  @override
  Stream<void> get hostsChanged => const Stream.empty();
  @override
  Future<ShellChannel> openProxyShell(String hostId, {required int cols, required int rows}) async =>
      throw const LinkException(LinkErrorKind.hostUnavailable);
  @override
  LinkSyncBundle exportSyncBundle() => LinkSyncBundle(
    hostsLibrary: const {},
    snippets: const [],
    knownHosts: const {},
    exportedAt: DateTime.now().toUtc(),
  );
  @override
  Future<List<({String id, String label})>> listHostsWithSavedPasswords() async => const [];

  @override
  Future<LinkCredentialBundle> exportOptInCredentials({
    required Set<String> hostIds,
    required Set<String> keyIds,
    bool includeAiKey = false,
  }) async => const LinkCredentialBundle();
  @override
  List<LinkApprovalItem> listApprovals() => const [];
  @override
  Stream<void> get approvalsChanged => const Stream.empty();
  @override
  bool decideApproval(String approvalId, bool allowed) => false;
  @override
  bool handoffHost(String hostId) => false;
  @override
  Future<void> receiveClipboard(String text) async {}
  @override
  Future<LinkFsHandle> openFiles(String target, CancellationToken cancel) async => throw const FsError(FsFailure.unsupported);
}

class _NullMobileBridge implements LinkMobileBridge {
  const _NullMobileBridge();
  @override
  Future<LinkSyncSummary> applySyncBundle(LinkSyncBundle bundle) async =>
      const LinkSyncSummary(hostsSynced: 0, snippetsSynced: 0, knownHostsAdded: 0, knownHostsConflicts: 0);
  @override
  Future<int> importOptInCredentials(LinkCredentialBundle bundle) async => 0;
  @override
  void openRemoteTerminal({
    required String peerId,
    required String peerName,
    required String remoteId,
    required String title,
    required String targetLabel,
    required bool isMirror,
    required Future<ShellChannel> Function(int cols, int rows) openChannel,
  }) {}
  @override
  Future<LinkFsHandle> openFiles() async => throw const FsError(FsFailure.unsupported);
}

final linkDesktopBridgeProvider = Provider<LinkDesktopBridge>((_) => const _NullDesktopBridge());
final linkMobileBridgeProvider = Provider<LinkMobileBridge>((_) => const _NullMobileBridge());

/// A desktop-side active connection from one paired mobile peer.
class _ConnectedPeer {
  _ConnectedPeer(this.deviceId, this.name, this.session, this.files);

  final String deviceId;
  final String name;
  final LinkCipherSession session;
  final LinkFiles files;
  Object? sharedFilesBinding;
  final mirrors = <String, MirrorAttachment>{};
  final proxyChannels =
      <String, ({ShellChannel channel, StreamSubscription<Uint8List> outSub, StreamSubscription<Uint8List> errSub})>{};

  void cleanup() {
    files.close();
    for (final m in mirrors.values) {
      m.detach();
    }
    mirrors.clear();
    for (final p in proxyChannels.values) {
      unawaited(p.outSub.cancel());
      unawaited(p.errSub.cancel());
      p.channel.close();
    }
    proxyChannels.clear();
  }
}

/// Active short-lived pairing session on the desktop.
class _ActivePairing {
  _ActivePairing(this.code, this.expiresAt);
  final String code;
  final DateTime expiresAt;
  int attempts = 0;

  bool get expired => DateTime.now().isAfter(expiresAt);
  bool get locked => attempts >= 5;
}

/// Desktop-side Sshairy Link host controller (docs/MOBILE.md §4-5).
class LinkHostController extends ChangeNotifier {
  LinkHostController({
    required this.credentials,
    required this.store,
    required this.bridge,
    this.listenerFactory,
    this.enableDiscovery = true,
  }) {
    _peers = store.load();
    _sessionsSub = bridge.sessionsChanged.listen((_) => _broadcastSessions());
    _hostsSub = bridge.hostsChanged.listen((_) => _broadcastHosts());
    _approvalsSub = bridge.approvalsChanged.listen((_) => _broadcastApprovals());
  }

  final LinkCredentials credentials;
  final LinkPeerStore store;
  final LinkDesktopBridge bridge;
  final Future<LinkListener> Function(int port)? listenerFactory;
  final bool enableDiscovery;

  LinkIdentity? _identity;
  LinkListener? _listener;
  LanDiscoveryResponder? _discovery;
  StreamSubscription<LinkTransport>? _acceptSub;
  StreamSubscription<void>? _sessionsSub;
  StreamSubscription<void>? _hostsSub;
  StreamSubscription<void>? _approvalsSub;
  Timer? _pairingTimer;

  List<LinkPeer> _peers = const [];
  final _connected = <String, _ConnectedPeer>{};
  final _passwordSyncQueue = <LinkPasswordSyncRequest>[];
  _ActivePairing? _pairing;
  List<String> _addresses = const [];
  bool _enabled = false;
  bool _discoveryEnabled = true;
  int _port = linkDefaultPort;
  String _deviceName = '';
  bool _failed = false;
  bool _disposed = false;
  Future<void> _sync = Future.value();

  bool get running => _listener != null;
  bool get failed => _failed;
  int get port => _listener?.port ?? _port;
  String get deviceId => _identity?.deviceId ?? '';
  String get deviceName => _deviceName.isNotEmpty ? _deviceName : _defaultDeviceName();
  List<String> get addresses => List.unmodifiable(_addresses);
  List<LinkPeer> get peers => List.unmodifiable(_peers);
  Set<String> get connectedDeviceIds => Set.unmodifiable(_connected.keys);
  List<({String id, String name})> get sharedPhones => [
    for (final peer in _connected.values)
      if (peer.sharedFilesBinding != null && peer.files.current) (id: peer.deviceId, name: peer.name),
  ];
  Object? phoneFilesBinding(String id) {
    final peer = _connected[id];
    return peer != null && peer.files.current ? peer.sharedFilesBinding : null;
  }
  int get connectedCount => _connected.length;
  LinkPasswordSyncRequest? get pendingPasswordSync => _passwordSyncQueue.firstOrNull;

  LinkPairingInfo? get activePairing {
    final p = _pairing;
    final id = _identity;
    if (p == null || id == null || p.expired || p.locked || !running) return null;
    final host = _addresses.isNotEmpty ? _addresses.first : '127.0.0.1';
    return LinkPairingInfo(
      code: p.code,
      deviceId: id.deviceId,
      deviceName: deviceName,
      publicKey: id.publicKeyBase64,
      host: host,
      port: port,
      expiresAt: p.expiresAt,
    );
  }

  static String _defaultDeviceName() {
    try {
      final host = Platform.localHostname.trim();
      if (host.isNotEmpty) return host;
    } on Object {
      // ignore
    }
    return 'Sshairy Desktop';
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<LinkIdentity> _ensureIdentity() async {
    if (_identity != null) return _identity!;
    final saved = await credentials.readIdentity();
    if (saved != null && saved.reveal().isNotEmpty) {
      try {
        _identity = LinkIdentity.fromSeedBase64(saved.reveal());
        return _identity!;
      } on Object {
        // corrupt seed -> regenerate
      }
    }
    final fresh = LinkIdentity.generate();
    await credentials.saveIdentity(Secret(fresh.seedBase64));
    _identity = fresh;
    return fresh;
  }

  Future<void> configure({required bool enabled, required int port, required bool discovery, String? deviceName}) {
    final name = deviceName?.trim() ?? '';
    final restart = enabled != _enabled || (enabled && port != _port);
    final discoveryChanged = discovery != _discoveryEnabled;
    _enabled = enabled;
    _port = port;
    _discoveryEnabled = discovery;
    _deviceName = name;
    if (!restart && !discoveryChanged) {
      _notify();
      return _sync;
    }
    _sync = _sync.then((_) => _applyConfig());
    return _sync;
  }

  Future<void> _applyConfig() async {
    if (_disposed) return;
    _failed = false;
    await _stopServer();
    if (!_enabled) {
      _notify();
      return;
    }
    try {
      await _ensureIdentity();
      _addresses = await localLinkAddresses();
      final bind = listenerFactory ?? (p) => DirectWsLinkListener.bind(p);
      final listener = await bind(_port);
      if (_disposed || !_enabled) {
        await listener.close();
        return;
      }
      _listener = listener;
      _acceptSub = listener.connections.listen((transport) {
        unawaited(_handleConnection(transport));
      });
      if (enableDiscovery && _discoveryEnabled) {
        _discovery = await LanDiscoveryResponder.start(
          deviceId: () => deviceId,
          deviceName: () => deviceName,
          wsPort: () => port,
        );
      }
    } on Object {
      _failed = true;
    }
    _notify();
  }

  Future<void> _stopServer() async {
    cancelPairing();
    _discovery?.close();
    _discovery = null;
    await _acceptSub?.cancel();
    _acceptSub = null;
    final listener = _listener;
    _listener = null;
    for (final peer in _connected.values.toList()) {
      peer.cleanup();
      unawaited(peer.session.close());
    }
    _connected.clear();
    _passwordSyncQueue.clear();
    if (listener != null) await listener.close();
  }

  /// Generates a fresh 6-digit single-use pairing code valid for 3 minutes.
  Future<LinkPairingInfo?> startPairing() async {
    if (!running) return null;
    await _ensureIdentity();
    _addresses = await localLinkAddresses();
    final rng = Random.secure();
    final code = List<int>.generate(6, (_) => rng.nextInt(10)).join();
    _pairing = _ActivePairing(code, DateTime.now().add(const Duration(minutes: 3)));
    _pairingTimer?.cancel();
    _pairingTimer = Timer(const Duration(minutes: 3), () {
      _pairing = null;
      _notify();
    });
    _notify();
    return activePairing;
  }

  void cancelPairing() {
    _pairingTimer?.cancel();
    _pairingTimer = null;
    if (_pairing != null) {
      _pairing = null;
      _notify();
    }
  }

  Future<void> updatePermissions(String deviceId, LinkPeerPermissions permissions) async {
    _peers = [
      for (final p in _peers)
        if (p.deviceId == deviceId) p.copyWith(permissions: permissions) else p,
    ];
    final saved = store.save(_peers);
    // Clean up disallowed active mirrors/proxies immediately
    final active = _connected[deviceId];
    if (active != null) {
      if (!permissions.allowMirror) {
        for (final m in active.mirrors.values) {
          m.detach();
        }
        active.mirrors.clear();
      }
      if (!permissions.allowProxy) {
        for (final ch in active.proxyChannels.values) {
          unawaited(ch.outSub.cancel());
          unawaited(ch.errSub.cancel());
          ch.channel.close();
        }
        active.proxyChannels.clear();
      }
      active.files.revoke();
      _pushFileAccess(active);
      if (permissions.allowApproval) {
        _pushApprovalsTo(active);
      } else {
        unawaited(active.session.sendMessage({'type': 'approvals.list', 'items': const <Object?>[]}));
      }
      if (!permissions.allowSync) {
        final removed = _passwordSyncQueue.where((r) => r.deviceId == deviceId).toList();
        _passwordSyncQueue.removeWhere((r) => r.deviceId == deviceId);
        for (final req in removed) {
          unawaited(
            active.session
                .sendMessage({'type': 'sync.passwords.declined', 'reqId': req.reqId})
                .catchError((Object _) {}),
          );
        }
      }
    }
    _notify();
    await saved;
  }

  Future<void> revokePeer(String deviceId) async {
    _peers = _peers.where((p) => p.deviceId != deviceId).toList();
    final saved = store.save(_peers);
    _passwordSyncQueue.removeWhere((r) => r.deviceId == deviceId);
    final active = _connected.remove(deviceId);
    if (active != null) {
      active.cleanup();
      unawaited(active.session.close());
    }
    _notify();
    await saved;
  }

  void disconnectPeer(String deviceId) {
    _passwordSyncQueue.removeWhere((r) => r.deviceId == deviceId);
    final active = _connected.remove(deviceId);
    if (active != null) {
      active.cleanup();
      unawaited(active.session.close());
      _notify();
    }
  }

  /// Resolves a desktop confirmation dialog for a mobile-requested server password sync.
  Future<bool> decidePasswordSync(LinkPasswordSyncRequest request, bool allowed) async {
    final index = _passwordSyncQueue.indexWhere((r) => identical(r, request));
    if (index == -1) return false;
    _passwordSyncQueue.removeAt(index);
    _notify();
    final active = _connected[request.deviceId];
    final record = _findPeer(request.deviceId);
    if (active == null || active.session.isClosed || record == null || !record.permissions.allowSync) {
      return false;
    }
    if (!allowed) {
      await active.session
          .sendMessage({'type': 'sync.passwords.declined', 'reqId': request.reqId})
          .catchError((Object _) {});
      return false;
    }
    final bundle = await bridge.exportOptInCredentials(
      hostIds: {for (final h in request.hosts) h.id},
      keyIds: const {},
      includeAiKey: false,
    );
    if (bundle.hostPasswords.isEmpty) {
      await active.session
          .sendMessage({'type': 'sync.passwords.declined', 'reqId': request.reqId})
          .catchError((Object _) {});
      return false;
    }
    await active.session.sendMessage({
      'type': 'sync.credentials.offer',
      'reqId': request.reqId,
      'bundle': bundle.toJson(),
    });
    return true;
  }

  /// Explicitly pushes user-confirmed credentials to a single connected paired mobile device over E2EE.
  Future<bool> pushOptInCredentials(
    String deviceId, {
    required Set<String> hostIds,
    required Set<String> keyIds,
    bool includeAiKey = false,
  }) async {
    final active = _connected[deviceId];
    if (active == null || active.session.isClosed) return false;
    final bundle = await bridge.exportOptInCredentials(hostIds: hostIds, keyIds: keyIds, includeAiKey: includeAiKey);
    if (bundle.isEmpty) return false;
    await active.session.sendMessage({'type': 'sync.credentials.offer', 'bundle': bundle.toJson()});
    return true;
  }

  Future<FileSystem> openPhoneFiles(String id, Object binding) async {
    final peer = _connected[id];
    if (peer == null || !identical(phoneFilesBinding(id), binding)) throw const FsError(FsFailure.lost);
    return peer.files.open('local');
  }

  LinkPeer? _findPeer(String id) => _peers.where((p) => p.deviceId == id).firstOrNull;

  Future<void> _handleConnection(LinkTransport transport) async {
    final identity = _identity;
    if (identity == null || _disposed) {
      await transport.close();
      return;
    }
    _ConnectedPeer? connection;
    try {
      final handshake = await performLinkServerHandshake(
        transport: transport,
        identity: identity,
        deviceName: deviceName,
        verifyPeer:
            ({
              required mode,
              required clientDeviceId,
              required clientName,
              required clientPublicKey,
              required transcriptHash,
              required pairProof,
            }) async {
              if (mode == 'pair') {
                final p = _pairing;
                if (p == null) return (accepted: false, error: LinkErrorKind.pairingExpired, newlyPaired: false);
                if (p.expired) {
                  cancelPairing();
                  return (accepted: false, error: LinkErrorKind.pairingExpired, newlyPaired: false);
                }
                if (p.locked) return (accepted: false, error: LinkErrorKind.pairingLocked, newlyPaired: false);
                final expected = computePairingProof(p.code, transcriptHash);
                if (pairProof == null || !constantTimeEquals(expected, pairProof)) {
                  p.attempts++;
                  if (p.locked) cancelPairing();
                  return (
                    accepted: false,
                    error: p.locked ? LinkErrorKind.pairingLocked : LinkErrorKind.invalidPairingCode,
                    newlyPaired: false,
                  );
                }
                // Single-use pairing code consumed immediately
                cancelPairing();
                final now = DateTime.now().toUtc();
                final existing = _findPeer(clientDeviceId);
                final updated = existing == null
                    ? LinkPeer(
                        deviceId: clientDeviceId,
                        name: clientName,
                        publicKey: clientPublicKey,
                        pairedAt: now,
                        lastSeen: now,
                      )
                    : existing.copyWith(name: clientName, lastSeen: now);
                _peers = [..._peers.where((x) => x.deviceId != clientDeviceId), updated];
                await store.save(_peers);
                return (accepted: true, error: null, newlyPaired: true);
              } else {
                final existing = _findPeer(clientDeviceId);
                if (existing == null) return (accepted: false, error: LinkErrorKind.peerRevoked, newlyPaired: false);
                if (existing.publicKey != clientPublicKey) {
                  return (accepted: false, error: LinkErrorKind.authFailed, newlyPaired: false);
                }
                final updated = existing.copyWith(name: clientName, lastSeen: DateTime.now().toUtc());
                _peers = [..._peers.where((x) => x.deviceId != clientDeviceId), updated];
                await store.save(_peers);
                return (accepted: true, error: null, newlyPaired: false);
              }
            },
      );

      final peerId = handshake.session.peerDeviceId;
      // Replace any stale connection from the same device
      final previous = _connected.remove(peerId);
      if (previous != null) {
        previous.cleanup();
        unawaited(previous.session.close());
      }
      final session = handshake.session;
      final files = LinkFiles(
        send: session.sendMessage,
        isConnected: () => !session.isClosed,
        canOpen: (target) {
          final permissions = _findPeer(peerId)?.permissions;
          return permissions?.allowFiles == true &&
              (target == 'local' || (target.startsWith('host:') && permissions!.allowProxy));
        },
        openTarget: bridge.openFiles,
      );
      final active = connection = _ConnectedPeer(peerId, session.peerName, session, files);
      _connected[peerId] = active;
      _notify();

      // Push initial state snapshot according to permissions
      _pushSessionsTo(active);
      _pushHostsTo(active);
      _pushApprovalsTo(active);
      _pushFileAccess(active);

      await for (final msg in handshake.incoming) {
        await _handleMessage(active, msg);
      }
    } on Object {
      // Handshake or transport closed
    } finally {
      final active = connection;
      if (active != null && identical(_connected[active.deviceId], active)) {
        _connected.remove(active.deviceId);
        _passwordSyncQueue.removeWhere((r) => r.deviceId == active.deviceId);
        active.cleanup();
        _notify();
      }
      await transport.close();
    }
  }

  Future<void> _handleMessage(_ConnectedPeer peer, Map<String, dynamic> msg) async {
    final type = msg['type'] as String? ?? '';
    final record = _findPeer(peer.deviceId);
    if (record == null) {
      await peer.session.close();
      return;
    }
    final perms = record.permissions;

    switch (type) {
      case 'sessions.list':
        _pushSessionsTo(peer);
      case 'hosts.list':
        _pushHostsTo(peer);
      case 'approvals.list':
        _pushApprovalsTo(peer);

      case 'mirror.attach':
        final channelId = msg['channelId'] as String? ?? '';
        final sessionId = msg['sessionId'] as String? ?? '';
        if (!perms.allowMirror) {
          await peer.session.sendMessage({
            'type': 'mirror.error',
            'channelId': channelId,
            'code': LinkErrorKind.permissionDenied.name,
          });
          return;
        }
        peer.mirrors.remove(channelId)?.detach();
        final attachment = bridge.attachMirror(sessionId, (chunk) {
          if (peer.session.isClosed || !peer.mirrors.containsKey(channelId)) return;
          unawaited(
            peer.session
                .sendMessage({'type': 'mirror.output', 'channelId': channelId, 'data': base64Encode(chunk)})
                .catchError((Object _) {}),
          );
        });
        if (attachment == null) {
          await peer.session.sendMessage({
            'type': 'mirror.error',
            'channelId': channelId,
            'code': LinkErrorKind.hostUnavailable.name,
          });
          return;
        }
        peer.mirrors[channelId] = attachment;
        await peer.session.sendMessage({
          'type': 'mirror.snapshot',
          'channelId': channelId,
          'sessionId': sessionId,
          'data': base64Encode(attachment.snapshot),
        });

      case 'mirror.detach':
        final channelId = msg['channelId'] as String? ?? '';
        peer.mirrors.remove(channelId)?.detach();

      case 'mirror.input':
        if (!perms.allowMirror) return;
        final channelId = msg['channelId'] as String? ?? '';
        final data = msg['data'] as String?;
        if (data != null) peer.mirrors[channelId]?.write(base64Decode(data));

      case 'mirror.resize':
        if (!perms.allowMirror) return;
        final channelId = msg['channelId'] as String? ?? '';
        final cols = (msg['cols'] as num?)?.toInt();
        final rows = (msg['rows'] as num?)?.toInt();
        if (cols != null && rows != null && cols > 0 && rows > 0) {
          peer.mirrors[channelId]?.resize(cols, rows);
        }

      case 'proxy.open':
        final channelId = msg['channelId'] as String? ?? '';
        final hostId = msg['hostId'] as String? ?? '';
        final cols = ((msg['cols'] as num?)?.toInt() ?? 80).clamp(10, 500);
        final rows = ((msg['rows'] as num?)?.toInt() ?? 24).clamp(4, 200);
        if (!perms.allowProxy) {
          await peer.session.sendMessage({
            'type': 'proxy.error',
            'channelId': channelId,
            'code': LinkErrorKind.permissionDenied.name,
          });
          return;
        }
        if (peer.proxyChannels.length >= linkMaxProxyChannelsPerPeer) {
          await peer.session.sendMessage({
            'type': 'proxy.error',
            'channelId': channelId,
            'code': LinkErrorKind.channelLimit.name,
          });
          return;
        }
        try {
          final shell = await bridge.openProxyShell(hostId, cols: cols, rows: rows);
          if (peer.session.isClosed) {
            shell.close();
            return;
          }
          void sendBytes(Uint8List bytes) {
            if (peer.session.isClosed || bytes.isEmpty) return;
            unawaited(
              peer.session
                  .sendMessage({'type': 'proxy.output', 'channelId': channelId, 'data': base64Encode(bytes)})
                  .catchError((Object _) {}),
            );
          }

          final outSub = shell.stdout.listen(sendBytes, onError: (Object _) {});
          final errSub = shell.stderr.listen(sendBytes, onError: (Object _) {});
          peer.proxyChannels[channelId] = (channel: shell, outSub: outSub, errSub: errSub);
          await peer.session.sendMessage({'type': 'proxy.opened', 'channelId': channelId});
          unawaited(
            shell.done.whenComplete(() {
              final entry = peer.proxyChannels.remove(channelId);
              if (entry != null) {
                unawaited(entry.outSub.cancel());
                unawaited(entry.errSub.cancel());
              }
              if (!peer.session.isClosed) {
                unawaited(
                  peer.session.sendMessage({'type': 'proxy.closed', 'channelId': channelId}).catchError((Object _) {}),
                );
              }
            }),
          );
        } on Object catch (e) {
          await peer.session.sendMessage({
            'type': 'proxy.error',
            'channelId': channelId,
            'code': LinkErrorKind.hostUnavailable.name,
            'message': '$e',
          });
        }

      case 'proxy.input':
        if (!perms.allowProxy) return;
        final channelId = msg['channelId'] as String? ?? '';
        final data = msg['data'] as String?;
        if (data != null) peer.proxyChannels[channelId]?.channel.write(base64Decode(data));

      case 'proxy.resize':
        if (!perms.allowProxy) return;
        final channelId = msg['channelId'] as String? ?? '';
        final cols = (msg['cols'] as num?)?.toInt();
        final rows = (msg['rows'] as num?)?.toInt();
        if (cols != null && rows != null && cols > 0 && rows > 0) {
          peer.proxyChannels[channelId]?.channel.resize(cols, rows);
        }

      case 'proxy.close':
        final channelId = msg['channelId'] as String? ?? '';
        final entry = peer.proxyChannels.remove(channelId);
        if (entry != null) {
          unawaited(entry.outSub.cancel());
          unawaited(entry.errSub.cancel());
          entry.channel.close();
        }

      case 'sync.pull':
        final reqId = msg['reqId'] as String? ?? '';
        final includePasswords = msg['includePasswords'] == true;
        if (!perms.allowSync) {
          await peer.session.sendMessage({
            'type': 'sync.error',
            'reqId': reqId,
            'code': LinkErrorKind.permissionDenied.name,
          });
          return;
        }
        final bundle = bridge.exportSyncBundle();
        final passwordHosts = includePasswords
            ? await bridge.listHostsWithSavedPasswords()
            : const <({String id, String label})>[];
        if (peer.session.isClosed) return;
        await peer.session.sendMessage({
          'type': 'sync.bundle',
          'reqId': reqId,
          'bundle': bundle.toJson(),
          if (passwordHosts.isNotEmpty) 'awaitingPasswordApproval': true,
        });
        if (passwordHosts.isNotEmpty) {
          _passwordSyncQueue.removeWhere((r) => r.deviceId == peer.deviceId);
          _passwordSyncQueue.add(
            LinkPasswordSyncRequest(reqId: reqId, deviceId: peer.deviceId, peerName: record.name, hosts: passwordHosts),
          );
          _notify();
        }

      case 'approval.decide':
        if (!perms.allowApproval) return;
        final approvalId = msg['approvalId'] as String? ?? '';
        final allowed = msg['allowed'] == true;
        bridge.decideApproval(approvalId, allowed);
        _broadcastApprovals();

      case 'handoff.host':
        if (!perms.allowMirror && !perms.allowProxy) return;
        final hostId = msg['hostId'] as String? ?? '';
        if (hostId.isNotEmpty) {
          bridge.handoffHost(hostId);
          _broadcastSessions();
        }

      case 'clipboard.push':
        final text = msg['text'] as String? ?? '';
        if (text.isNotEmpty && text.length <= 64 * 1024) {
          await bridge.receiveClipboard(text);
        }

      case 'fs.access':
        peer.sharedFilesBinding = msg['local'] == true ? peer.sharedFilesBinding ?? Object() : null;
        _notify();

      default:
        peer.files.handle(msg);
    }
  }

  void _pushFileAccess(_ConnectedPeer peer) {
    final permissions = _findPeer(peer.deviceId)?.permissions;
    final local = permissions?.allowFiles == true;
    unawaited(peer.session.sendMessage({
      'type': 'fs.access', 'local': local, 'proxy': local && permissions!.allowProxy,
    }).catchError((Object _) {}));
  }

  void _pushSessionsTo(_ConnectedPeer peer) {
    final record = _findPeer(peer.deviceId);
    if (record == null || !record.permissions.allowMirror || peer.session.isClosed) return;
    final items = [for (final s in bridge.listSessions()) s.toJson()];
    unawaited(peer.session.sendMessage({'type': 'sessions.list', 'items': items}).catchError((Object _) {}));
  }

  void _pushHostsTo(_ConnectedPeer peer) {
    final record = _findPeer(peer.deviceId);
    if (record == null || !record.permissions.allowProxy || peer.session.isClosed) return;
    final items = [for (final h in bridge.listHosts()) h.toJson()];
    unawaited(peer.session.sendMessage({'type': 'hosts.list', 'items': items}).catchError((Object _) {}));
  }

  void _pushApprovalsTo(_ConnectedPeer peer) {
    final record = _findPeer(peer.deviceId);
    if (record == null || !record.permissions.allowApproval || peer.session.isClosed) return;
    final items = [for (final a in bridge.listApprovals()) a.toJson()];
    unawaited(peer.session.sendMessage({'type': 'approvals.list', 'items': items}).catchError((Object _) {}));
  }

  void _broadcastSessions() {
    for (final peer in _connected.values) {
      _pushSessionsTo(peer);
    }
  }

  void _broadcastHosts() {
    for (final peer in _connected.values) {
      _pushHostsTo(peer);
    }
  }

  void _broadcastApprovals() {
    for (final peer in _connected.values) {
      _pushApprovalsTo(peer);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_sessionsSub?.cancel());
    unawaited(_hostsSub?.cancel());
    unawaited(_approvalsSub?.cancel());
    unawaited(_stopServer());
    super.dispose();
  }
}

/// Client-side [ShellChannel] backed by either a desktop mirror or a desktop-proxied SSH channel over E2EE Link.
class _LinkShellChannel implements ShellChannel {
  _LinkShellChannel({required this.onWrite, required this.onResize, required this.onClose}) {
    _stdout = StreamController<Uint8List>.broadcast(onListen: _flushPending);
  }

  final void Function(Uint8List data) onWrite;
  final void Function(int cols, int rows) onResize;
  final VoidCallback onClose;

  late final StreamController<Uint8List> _stdout;
  final _stderr = StreamController<Uint8List>.broadcast();
  final _done = Completer<void>();
  final _pending = <Uint8List>[];
  var _closed = false;

  void _flushPending() {
    if (_pending.isEmpty || _closed || _stdout.isClosed) return;
    final items = List<Uint8List>.of(_pending);
    _pending.clear();
    for (final chunk in items) {
      if (!_closed && !_stdout.isClosed) _stdout.add(chunk);
    }
  }

  void deliverOutput(Uint8List bytes) {
    if (_closed || _stdout.isClosed || bytes.isEmpty) return;
    if (_stdout.hasListener) {
      _stdout.add(bytes);
    } else {
      _pending.add(bytes);
    }
  }

  void finish() {
    if (_closed) return;
    _closed = true;
    _pending.clear();
    if (!_done.isCompleted) _done.complete();
    if (!_stdout.isClosed) unawaited(_stdout.close());
    if (!_stderr.isClosed) unawaited(_stderr.close());
  }

  @override
  Stream<Uint8List> get stdout => _stdout.stream;

  @override
  Stream<Uint8List> get stderr => _stderr.stream;

  @override
  Future<void> get done => _done.future;

  @override
  void write(Uint8List data) {
    if (!_closed) onWrite(data);
  }

  @override
  void resize(int cols, int rows) {
    if (!_closed) onResize(cols, rows);
  }

  @override
  void close() {
    if (_closed) return;
    onClose();
    finish();
  }
}

/// Mobile-side Sshairy Link client controller (docs/MOBILE.md §4).
class LinkClientController extends ChangeNotifier {
  LinkClientController({required this.credentials, required this.store, required this.bridge, this.transportFactory}) {
    _peers = store.load();
  }

  final LinkCredentials credentials;
  final LinkPeerStore store;
  final LinkMobileBridge bridge;
  final Future<LinkTransport> Function(String host, int port)? transportFactory;

  LinkIdentity? _identity;
  LinkCipherSession? _session;
  LinkFiles? _files;
  StreamSubscription<Map<String, dynamic>>? _incomingSub;

  LinkConnectionStatus _status = LinkConnectionStatus.disconnected;
  LinkErrorKind? _lastError;
  String? _connectedDesktopId;
  String? _connectedDesktopName;
  List<LinkPeer> _peers = const [];
  List<DiscoveredDesktop> _discovered = const [];
  bool _discovering = false;

  List<LinkSessionSummary> _desktopSessions = const [];
  List<LinkHostSummary> _desktopHosts = const [];
  List<LinkApprovalItem> _approvals = const [];
  LinkSyncSummary? _lastSync;
  LinkCredentialBundle? _pendingCredentialOffer;
  LinkPasswordSyncStatus _passwordSyncStatus = LinkPasswordSyncStatus.idle;
  int _lastImportedPasswordCount = 0;
  bool _sharesPhoneFiles = false;
  Object? _desktopFilesBinding, _proxyFilesBinding;
  int _attempt = 0;
  bool _disposed = false;

  final _channels = <String, _LinkShellChannel>{};
  final _openWaiters = <String, Completer<void>>{};
  final _syncWaiters = <String, Completer<({LinkSyncBundle bundle, bool awaitingPasswordApproval})>>{};
  final _requestedPasswordSyncIds = <String>{};
  final _followDesktopChannels = <String>{};

  LinkConnectionStatus get status => _status;
  bool get connected => _status == LinkConnectionStatus.connected && _session != null && !_session!.isClosed;
  LinkErrorKind? get lastError => _lastError;
  String? get connectedDesktopId => _connectedDesktopId;
  String? get connectedDesktopName => _connectedDesktopName;
  List<LinkPeer> get savedDesktops => List.unmodifiable(_peers);
  List<DiscoveredDesktop> get discoveredDesktops => List.unmodifiable(_discovered);
  bool get discovering => _discovering;
  List<LinkSessionSummary> get desktopSessions => List.unmodifiable(_desktopSessions);
  List<LinkHostSummary> get desktopHosts => List.unmodifiable(_desktopHosts);
  List<LinkApprovalItem> get pendingApprovals => List.unmodifiable(_approvals);
  LinkSyncSummary? get lastSync => _lastSync;
  LinkCredentialBundle? get pendingCredentialOffer => _pendingCredentialOffer;
  LinkPasswordSyncStatus get passwordSyncStatus => _passwordSyncStatus;
  int get lastImportedPasswordCount => _lastImportedPasswordCount;
  bool get sharesPhoneFiles => _sharesPhoneFiles;
  bool get desktopSharesFiles => desktopFilesBinding() != null;
  bool get desktopProxiesFiles => desktopFilesBinding(proxy: true) != null;
  Object? get filesBinding => connected ? _files : null;
  Object? desktopFilesBinding({bool proxy = false}) => connected ? (proxy ? _proxyFilesBinding : _desktopFilesBinding) : null;

  Future<FileSystem> openFiles(Object binding, {String? hostId}) async {
    if (!identical(desktopFilesBinding(proxy: hostId != null), binding)) throw const FsError(FsFailure.lost);
    return _files!.open(hostId == null ? 'local' : 'host:$hostId');
  }

  Future<void> sharePhoneFiles(bool enabled, Object binding) async {
    final session = _session;
    if (session == null || !identical(filesBinding, binding)) return;
    _sharesPhoneFiles = enabled;
    _files?.revoke();
    _notify();
    await session.sendMessage({'type': 'fs.access', 'local': enabled}).catchError((Object _) {});
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<LinkIdentity> _ensureIdentity() async {
    if (_identity != null) return _identity!;
    final saved = await credentials.readIdentity();
    if (saved != null && saved.reveal().isNotEmpty) {
      try {
        _identity = LinkIdentity.fromSeedBase64(saved.reveal());
        return _identity!;
      } on Object {
        // regenerate
      }
    }
    final fresh = LinkIdentity.generate();
    await credentials.saveIdentity(Secret(fresh.seedBase64));
    _identity = fresh;
    return fresh;
  }

  static String _defaultMobileName() {
    try {
      final host = Platform.localHostname.trim();
      if (host.isNotEmpty) return host;
    } on Object {
      // ignore
    }
    return 'Sshairy Mobile';
  }

  Future<void> discoverLan() async {
    if (_discovering) return;
    _discovering = true;
    _notify();
    try {
      _discovered = await discoverLanDesktops();
    } finally {
      _discovering = false;
      _notify();
    }
  }

  Future<bool> pair({
    required String host,
    required int port,
    required String pairingCode,
    String? expectedPublicKey,
    String? deviceName,
  }) => _establish(
    host: host,
    port: port,
    pairing: true,
    pairingCode: pairingCode,
    expectedPublicKey: expectedPublicKey,
    deviceName: deviceName,
  );

  Future<bool> pairFromUri(String rawUri, {String? deviceName}) async {
    final parsed = LinkPairingInfo.parseUri(rawUri);
    if (parsed == null) {
      _lastError = LinkErrorKind.protocolError;
      _status = LinkConnectionStatus.error;
      _notify();
      return false;
    }
    return pair(
      host: parsed.host,
      port: parsed.port,
      pairingCode: parsed.code,
      expectedPublicKey: parsed.publicKey.isEmpty ? null : parsed.publicKey,
      deviceName: deviceName,
    );
  }

  Future<bool> connectToPeer(LinkPeer peer, {String? hostOverride, int? portOverride, String? deviceName}) =>
      _establish(
        host: hostOverride ?? peer.lastAddress ?? '',
        port: portOverride ?? peer.lastPort ?? linkDefaultPort,
        pairing: false,
        expectedPublicKey: peer.publicKey,
        deviceName: deviceName,
      );

  Future<bool> _establish({
    required String host,
    required int port,
    required bool pairing,
    String? pairingCode,
    String? expectedPublicKey,
    String? deviceName,
  }) async {
    final attempt = ++_attempt;
    await _disconnect();
    if (_disposed || attempt != _attempt) return false;
    if (host.trim().isEmpty) {
      _lastError = LinkErrorKind.network;
      _status = LinkConnectionStatus.error;
      _notify();
      return false;
    }
    _status = LinkConnectionStatus.connecting;
    _lastError = null;
    _notify();
    try {
      final identity = await _ensureIdentity();
      final connect = transportFactory ?? (h, p) => DirectWsLinkTransport.connect(h, p);
      final transport = await connect(host.trim(), port);
      final result = await performLinkClientHandshake(
        transport: transport,
        identity: identity,
        deviceName: (deviceName?.trim().isNotEmpty ?? false) ? deviceName!.trim() : _defaultMobileName(),
        pairing: pairing,
        pairingCode: pairingCode,
        expectedServerPublicKey: expectedPublicKey,
      );

      final session = result.session;
      if (_disposed || attempt != _attempt) {
        await session.close();
        return false;
      }
      _session = session;
      _files = LinkFiles(
        send: session.sendMessage,
        isConnected: () => identical(_session, session) && !session.isClosed,
        canOpen: (target) => target == 'local' && _sharesPhoneFiles,
        openTarget: (_, _) => bridge.openFiles(),
      );
      _connectedDesktopId = result.session.peerDeviceId;
      _connectedDesktopName = result.session.peerName;
      _status = LinkConnectionStatus.connected;

      final now = DateTime.now().toUtc();
      final existing = _peers.where((p) => p.deviceId == result.session.peerDeviceId).firstOrNull;
      final savedPeer = existing == null
          ? LinkPeer(
              deviceId: result.session.peerDeviceId,
              name: result.session.peerName,
              publicKey: result.session.peerPublicKey,
              pairedAt: now,
              lastSeen: now,
              lastAddress: host.trim(),
              lastPort: port,
            )
          : existing.copyWith(name: result.session.peerName, lastSeen: now, lastAddress: host.trim(), lastPort: port);
      _peers = [..._peers.where((p) => p.deviceId != savedPeer.deviceId), savedPeer];
      await store.save(_peers);
      if (!identical(_session, session)) return false;

      void disconnected() {
        if (identical(_session, session)) unawaited(disconnect());
      }
      _incomingSub = result.incoming.listen(
        _handleMessage,
        onError: (Object _) => disconnected(),
        onDone: disconnected,
      );
      _notify();
      return true;
    } on LinkException catch (e) {
      if (_disposed || attempt != _attempt) return false;
      await _disconnect();
      if (attempt != _attempt) return false;
      _lastError = e.kind;
      _status = LinkConnectionStatus.error;
      _notify();
      return false;
    } on Object {
      if (_disposed || attempt != _attempt) return false;
      await _disconnect();
      if (attempt != _attempt) return false;
      _lastError = LinkErrorKind.network;
      _status = LinkConnectionStatus.error;
      _notify();
      return false;
    }
  }

  Future<void> disconnect() {
    _attempt++;
    return _disconnect();
  }

  Future<void> _disconnect() async {
    final incoming = _incomingSub;
    _incomingSub = null;
    final session = _session;
    _session = null;
    _files?.close();
    _files = null;
    _sharesPhoneFiles = false;
    _desktopFilesBinding = _proxyFilesBinding = null;
    for (final ch in _channels.values.toList()) {
      ch.finish();
    }
    _channels.clear();
    _followDesktopChannels.clear();
    for (final w in _openWaiters.values) {
      if (!w.isCompleted) w.completeError(const LinkException(LinkErrorKind.network));
    }
    _openWaiters.clear();
    for (final w in _syncWaiters.values) {
      if (!w.isCompleted) w.completeError(const LinkException(LinkErrorKind.network));
    }
    _syncWaiters.clear();
    _requestedPasswordSyncIds.clear();
    _connectedDesktopId = null;
    _connectedDesktopName = null;
    _desktopSessions = const [];
    _desktopHosts = const [];
    _approvals = const [];
    _pendingCredentialOffer = null;
    _passwordSyncStatus = LinkPasswordSyncStatus.idle;
    _lastImportedPasswordCount = 0;
    if (_status != LinkConnectionStatus.disconnected) {
      _status = LinkConnectionStatus.disconnected;
      _notify();
    }
    await incoming?.cancel();
    await session?.close();
  }

  Future<void> forgetDesktop(String deviceId) async {
    if (_connectedDesktopId == deviceId) await disconnect();
    _peers = _peers.where((p) => p.deviceId != deviceId).toList();
    await store.save(_peers);
    _notify();
  }

  /// Opens a live mirrored [ShellChannel] attached to a running desktop terminal session.
  Future<ShellChannel> openMirrorChannel(String desktopSessionId, {bool followDesktopSize = true}) async {
    final session = _session;
    if (!connected || session == null) throw const LinkException(LinkErrorKind.network);
    final channelId = newId();
    final waiter = Completer<void>();
    _openWaiters[channelId] = waiter;
    if (followDesktopSize) _followDesktopChannels.add(channelId);
    final channel = _LinkShellChannel(
      onWrite: (data) {
        if (!connected) return;
        unawaited(
          session
              .sendMessage({'type': 'mirror.input', 'channelId': channelId, 'data': base64Encode(data)})
              .catchError((Object _) {}),
        );
      },
      onResize: (cols, rows) {
        if (!connected || _followDesktopChannels.contains(channelId)) return;
        unawaited(
          session
              .sendMessage({'type': 'mirror.resize', 'channelId': channelId, 'cols': cols, 'rows': rows})
              .catchError((Object _) {}),
        );
      },
      onClose: () {
        _channels.remove(channelId);
        _followDesktopChannels.remove(channelId);
        if (connected) {
          unawaited(session.sendMessage({'type': 'mirror.detach', 'channelId': channelId}).catchError((Object _) {}));
        }
      },
    );
    _channels[channelId] = channel;
    await session.sendMessage({'type': 'mirror.attach', 'channelId': channelId, 'sessionId': desktopSessionId});
    try {
      await waiter.future.timeout(const Duration(seconds: 10));
      return channel;
    } on Object {
      _openWaiters.remove(channelId);
      _channels.remove(channelId);
      _followDesktopChannels.remove(channelId);
      channel.finish();
      rethrow;
    }
  }

  /// Opens a desktop-proxied SSH [ShellChannel] (desktop dials with its own keys/proxies/trust store).
  Future<ShellChannel> openProxyChannel(String desktopHostId, {required int cols, required int rows}) async {
    final session = _session;
    if (!connected || session == null) throw const LinkException(LinkErrorKind.network);
    final channelId = newId();
    final waiter = Completer<void>();
    _openWaiters[channelId] = waiter;
    final channel = _LinkShellChannel(
      onWrite: (data) {
        if (!connected) return;
        unawaited(
          session
              .sendMessage({'type': 'proxy.input', 'channelId': channelId, 'data': base64Encode(data)})
              .catchError((Object _) {}),
        );
      },
      onResize: (c, r) {
        if (!connected) return;
        unawaited(
          session
              .sendMessage({'type': 'proxy.resize', 'channelId': channelId, 'cols': c, 'rows': r})
              .catchError((Object _) {}),
        );
      },
      onClose: () {
        _channels.remove(channelId);
        if (connected) {
          unawaited(session.sendMessage({'type': 'proxy.close', 'channelId': channelId}).catchError((Object _) {}));
        }
      },
    );
    _channels[channelId] = channel;
    await session.sendMessage({
      'type': 'proxy.open',
      'channelId': channelId,
      'hostId': desktopHostId,
      'cols': cols,
      'rows': rows,
    });
    try {
      await waiter.future.timeout(const Duration(seconds: 30));
      return channel;
    } on Object {
      _openWaiters.remove(channelId);
      _channels.remove(channelId);
      channel.finish();
      rethrow;
    }
  }

  /// Pulls non-secret hosts, snippets, and known_hosts from Desktop and merges them locally.
  /// When [includePasswords] is true, Desktop will prompt the user in a topmost dialog before
  /// sending any saved server passwords back over the E2EE channel.
  Future<LinkSyncSummary> pullConfigSync({bool includePasswords = false}) async {
    final session = _session;
    if (!connected || session == null) throw const LinkException(LinkErrorKind.network);
    final reqId = newId();
    final waiter = Completer<({LinkSyncBundle bundle, bool awaitingPasswordApproval})>();
    _syncWaiters[reqId] = waiter;
    if (includePasswords) {
      _requestedPasswordSyncIds
        ..clear()
        ..add(reqId);
      _passwordSyncStatus = LinkPasswordSyncStatus.idle;
      _lastImportedPasswordCount = 0;
    }
    await session.sendMessage({'type': 'sync.pull', 'reqId': reqId, if (includePasswords) 'includePasswords': true});
    try {
      final response = await waiter.future.timeout(const Duration(seconds: 15));
      final applied = await bridge.applySyncBundle(response.bundle);
      final awaiting = includePasswords && response.awaitingPasswordApproval;
      if (!awaiting) {
        _requestedPasswordSyncIds.remove(reqId);
        if (includePasswords) _passwordSyncStatus = LinkPasswordSyncStatus.idle;
      } else if (_requestedPasswordSyncIds.contains(reqId)) {
        _passwordSyncStatus = LinkPasswordSyncStatus.awaitingDesktop;
      }
      final summary = LinkSyncSummary(
        hostsSynced: applied.hostsSynced,
        snippetsSynced: applied.snippetsSynced,
        knownHostsAdded: applied.knownHostsAdded,
        knownHostsConflicts: applied.knownHostsConflicts,
        credentialsImported: applied.credentialsImported,
        aiSynced: applied.aiSynced,
        awaitingPasswordApproval: awaiting,
      );
      _lastSync = summary;
      _notify();
      return summary;
    } on Object {
      _requestedPasswordSyncIds.remove(reqId);
      rethrow;
    } finally {
      _syncWaiters.remove(reqId);
    }
  }

  Future<void> _importRequestedPasswords(LinkCredentialBundle bundle) async {
    final count = await bridge.importOptInCredentials(bundle);
    if (_disposed) return;
    _lastImportedPasswordCount = count;
    _passwordSyncStatus = LinkPasswordSyncStatus.imported;
    if (_lastSync != null) {
      _lastSync = LinkSyncSummary(
        hostsSynced: _lastSync!.hostsSynced,
        snippetsSynced: _lastSync!.snippetsSynced,
        knownHostsAdded: _lastSync!.knownHostsAdded,
        knownHostsConflicts: _lastSync!.knownHostsConflicts,
        credentialsImported: count,
        aiSynced: _lastSync!.aiSynced,
        awaitingPasswordApproval: false,
      );
    }
    _notify();
  }

  Future<int> acceptPendingCredentials() async {
    final offer = _pendingCredentialOffer;
    if (offer == null) return 0;
    _pendingCredentialOffer = null;
    _notify();
    final count = await bridge.importOptInCredentials(offer);
    if (_lastSync != null) {
      _lastSync = LinkSyncSummary(
        hostsSynced: _lastSync!.hostsSynced,
        snippetsSynced: _lastSync!.snippetsSynced,
        knownHostsAdded: _lastSync!.knownHostsAdded,
        knownHostsConflicts: _lastSync!.knownHostsConflicts,
        credentialsImported: count,
      );
      _notify();
    }
    return count;
  }

  void dismissPendingCredentials() {
    if (_pendingCredentialOffer != null) {
      _pendingCredentialOffer = null;
      _notify();
    }
  }

  Future<void> decideApproval(String approvalId, bool allowed) async {
    final session = _session;
    if (!connected || session == null) return;
    await session.sendMessage({'type': 'approval.decide', 'approvalId': approvalId, 'allowed': allowed});
    _approvals = _approvals.where((a) => a.approvalId != approvalId).toList();
    _notify();
  }

  /// Requests Desktop to open a saved host directly on the desktop workspace (Mobile -> Desktop Handoff).
  Future<bool> handoffHostToDesktop(String hostId) async {
    final session = _session;
    if (!connected || session == null || hostId.isEmpty) return false;
    await session.sendMessage({'type': 'handoff.host', 'hostId': hostId});
    return true;
  }

  /// Pushes clipboard text to the connected Desktop over the E2EE channel.
  Future<bool> pushClipboardToDesktop(String text) async {
    final session = _session;
    if (!connected || session == null || text.isEmpty || text.length > 64 * 1024) return false;
    await session.sendMessage({'type': 'clipboard.push', 'text': text});
    return true;
  }

  /// Opens a desktop mirror tab in the local workspace via [bridge].
  void openMirroredSessionInWorkspace(LinkSessionSummary target, {bool followDesktopSize = true}) {
    if (!connected || _connectedDesktopId == null) return;
    bridge.openRemoteTerminal(
      peerId: _connectedDesktopId!,
      peerName: _connectedDesktopName ?? _connectedDesktopId!,
      remoteId: target.sessionId,
      title: target.title,
      targetLabel: '${_connectedDesktopName ?? 'Desktop'} · ${target.targetLabel}',
      isMirror: true,
      openChannel: (_, _) => openMirrorChannel(target.sessionId, followDesktopSize: followDesktopSize),
    );
  }

  /// Opens a desktop-proxied SSH tab in the local workspace via [bridge].
  void openProxiedHostInWorkspace(LinkHostSummary host) {
    if (!connected || _connectedDesktopId == null) return;
    bridge.openRemoteTerminal(
      peerId: _connectedDesktopId!,
      peerName: _connectedDesktopName ?? _connectedDesktopId!,
      remoteId: host.hostId,
      title: host.label.isEmpty ? host.targetLabel : host.label,
      targetLabel: '${_connectedDesktopName ?? 'Desktop'} ⇄ ${host.targetLabel}',
      isMirror: false,
      openChannel: (cols, rows) => openProxyChannel(host.hostId, cols: cols, rows: rows),
    );
  }

  void _handleMessage(Map<String, dynamic> msg) {
    final type = msg['type'] as String? ?? '';
    switch (type) {
      case 'sessions.list':
        _desktopSessions = [
          for (final item in msg['items'] as List<dynamic>? ?? const [])
            if (item is Map) LinkSessionSummary.fromJson(item.cast<String, dynamic>()),
        ];
        _notify();

      case 'hosts.list':
        _desktopHosts = [
          for (final item in msg['items'] as List<dynamic>? ?? const [])
            if (item is Map) LinkHostSummary.fromJson(item.cast<String, dynamic>()),
        ];
        _notify();

      case 'approvals.list':
        _approvals = [
          for (final item in msg['items'] as List<dynamic>? ?? const [])
            if (item is Map) LinkApprovalItem.fromJson(item.cast<String, dynamic>()),
        ];
        _notify();

      case 'mirror.snapshot':
        final channelId = msg['channelId'] as String? ?? '';
        final data = msg['data'] as String?;
        final waiter = _openWaiters.remove(channelId);
        if (waiter != null && !waiter.isCompleted) waiter.complete();
        if (data != null && data.isNotEmpty) {
          _channels[channelId]?.deliverOutput(base64Decode(data));
        }

      case 'mirror.output':
        final channelId = msg['channelId'] as String? ?? '';
        final data = msg['data'] as String?;
        if (data != null && data.isNotEmpty) {
          _channels[channelId]?.deliverOutput(base64Decode(data));
        }

      case 'mirror.error':
        final channelId = msg['channelId'] as String? ?? '';
        final code = msg['code'] as String? ?? '';
        final kind = LinkErrorKind.values.asNameMap()[code] ?? LinkErrorKind.hostUnavailable;
        final waiter = _openWaiters.remove(channelId);
        if (waiter != null && !waiter.isCompleted) waiter.completeError(LinkException(kind));
        _channels.remove(channelId)?.finish();

      case 'proxy.opened':
        final channelId = msg['channelId'] as String? ?? '';
        final waiter = _openWaiters.remove(channelId);
        if (waiter != null && !waiter.isCompleted) waiter.complete();

      case 'proxy.output':
        final channelId = msg['channelId'] as String? ?? '';
        final data = msg['data'] as String?;
        if (data != null && data.isNotEmpty) {
          _channels[channelId]?.deliverOutput(base64Decode(data));
        }

      case 'proxy.closed':
        final channelId = msg['channelId'] as String? ?? '';
        _channels.remove(channelId)?.finish();

      case 'proxy.error':
        final channelId = msg['channelId'] as String? ?? '';
        final code = msg['code'] as String? ?? '';
        final kind = LinkErrorKind.values.asNameMap()[code] ?? LinkErrorKind.hostUnavailable;
        final waiter = _openWaiters.remove(channelId);
        if (waiter != null && !waiter.isCompleted) {
          waiter.completeError(LinkException(kind, msg['message'] as String? ?? ''));
        }
        _channels.remove(channelId)?.finish();

      case 'sync.bundle':
        final reqId = msg['reqId'] as String? ?? '';
        final raw = msg['bundle'];
        final waiter = _syncWaiters.remove(reqId);
        if (waiter != null && !waiter.isCompleted && raw is Map) {
          waiter.complete((
            bundle: LinkSyncBundle.fromJson(raw.cast<String, dynamic>()),
            awaitingPasswordApproval: msg['awaitingPasswordApproval'] == true,
          ));
        }

      case 'sync.error':
        final reqId = msg['reqId'] as String? ?? '';
        final code = msg['code'] as String? ?? '';
        final kind = LinkErrorKind.values.asNameMap()[code] ?? LinkErrorKind.permissionDenied;
        final waiter = _syncWaiters.remove(reqId);
        if (waiter != null && !waiter.isCompleted) waiter.completeError(LinkException(kind));

      case 'sync.credentials.offer':
        final raw = msg['bundle'];
        final reqId = msg['reqId'] as String?;
        if (raw is Map) {
          final bundle = LinkCredentialBundle.fromJson(raw.cast<String, dynamic>());
          final requested = reqId != null && _requestedPasswordSyncIds.remove(reqId);
          if (requested && bundle.privateKeys.isEmpty && bundle.aiApiKey == null) {
            if (bundle.hostPasswords.isNotEmpty) {
              unawaited(_importRequestedPasswords(bundle));
            } else {
              _passwordSyncStatus = LinkPasswordSyncStatus.idle;
              _notify();
            }
          } else if (!bundle.isEmpty) {
            _pendingCredentialOffer = bundle;
            _notify();
          }
        }

      case 'sync.passwords.declined':
        final reqId = msg['reqId'] as String?;
        if (reqId != null && _requestedPasswordSyncIds.remove(reqId)) {
          _passwordSyncStatus = LinkPasswordSyncStatus.declined;
          _notify();
        }
      case 'fs.access':
        _desktopFilesBinding = msg['local'] == true ? _desktopFilesBinding ?? Object() : null;
        _proxyFilesBinding = msg['proxy'] == true ? _proxyFilesBinding ?? Object() : null;
        _notify();
      default:
        _files?.handle(msg);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(disconnect());
    super.dispose();
  }
}

final linkHostControllerProvider = Provider<LinkHostController>((ref) {
  final controller = LinkHostController(
    credentials: ref.read(linkCredentialsProvider),
    store: LinkPeerStore(ref.read(dataDirProvider)),
    bridge: ref.read(linkDesktopBridgeProvider),
  );
  ref.listen(settingsProvider, (_, settings) {
    unawaited(
      controller.configure(
        enabled: settings.get(SettingKeys.linkEnabled),
        port: settings.get(SettingKeys.linkPort),
        discovery: settings.get(SettingKeys.linkDiscovery),
        deviceName: settings.get(SettingKeys.linkDeviceName),
      ),
    );
  }, fireImmediately: true);
  ref.onDispose(controller.dispose);
  return controller;
});

final linkClientControllerProvider = Provider<LinkClientController>((ref) {
  final controller = LinkClientController(
    credentials: ref.read(linkCredentialsProvider),
    store: LinkPeerStore('${ref.read(dataDirProvider)}/link_client'),
    bridge: ref.read(linkMobileBridgeProvider),
  );
  ref.onDispose(controller.dispose);
  return controller;
});

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../foundation/app_info.dart';
import '../../../foundation/cancellation.dart';
import '../../../foundation/data_dir.dart';
import '../../../foundation/file_system.dart';
import '../../../foundation/ids.dart';
import '../../../foundation/secret.dart';
import '../../connections/api.dart';
import '../../credentials/api.dart';
import '../../monitor/api.dart';
import '../../settings/api.dart';
import '../adapters/crypto.dart';
import '../adapters/link_storage.dart';
import '../adapters/ws_transport.dart';
import '../domain/protocol.dart';
import '../domain/transport.dart';
import 'link_fs.dart';

/// Access to the exact desktop terminal that owns a Link channel.
class LinkTerminalResources {
  const LinkTerminalResources({required this.current, required this.openFiles, this.sample});

  final bool Function() current;
  final Future<LinkFsHandle> Function(CancellationToken cancel) openFiles;
  final MonitorSample? sample;
}

abstract interface class LinkProxyShell implements ShellChannel {
  LinkTerminalResources get resources;
}

/// Handle to a mirrored desktop terminal session.
class MirrorAttachment {
  const MirrorAttachment({
    required this.snapshot,
    required this.write,
    required this.resize,
    required this.detach,
    this.resources,
  });

  final Uint8List snapshot;
  final void Function(Uint8List data) write;
  final void Function(int cols, int rows) resize;
  final VoidCallback detach;
  final LinkTerminalResources? resources;
}

/// Composition-layer bridge wired on Desktop to connect Sshairy Link to workspace, SSH, hosts, snippets, trust & AI/MCP.
abstract interface class LinkDesktopBridge {
  List<LinkSessionSummary> listSessions();
  Stream<void> get sessionsChanged;

  MirrorAttachment? attachMirror(String sessionId, void Function(Uint8List chunk) onOutput, {VoidCallback? onClosed});

  List<LinkHostSummary> listHosts();
  Stream<void> get hostsChanged;

  /// Sanitized local shells available on this desktop (no host executable paths).
  List<LinkLocalShellSummary> listLocalShells();

  Future<ShellChannel> openProxyShell(String hostId, {required int cols, required int rows});

  /// Opens a dedicated desktop local PTY sized for mobile over Link.
  Future<ShellChannel> openProxyLocalShell(String shellId, {required int cols, required int rows});

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

  /// Connects an existing desktop terminal tab (idle, failed or disconnected) and waits for a live shell.
  Future<bool> connectSession(String sessionId);

  /// Opens a saved host on the desktop, waits for its shell, and returns its session summary for mirroring.
  Future<LinkSessionSummary?> handoffHostForMirror(String hostId);

  /// Opens a desktop local shell tab on the desktop, waits for its PTY, and returns its session summary for mirroring.
  Future<LinkSessionSummary?> handoffLocalForMirror(String shellId);

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
    bool isLocal = false,
    String? localShellKind,
    required Future<ShellChannel> Function(int cols, int rows) openChannel,
    Future<FileSystem> Function()? files,
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
  MirrorAttachment? attachMirror(String sessionId, void Function(Uint8List chunk) onOutput, {VoidCallback? onClosed}) =>
      null;
  @override
  List<LinkHostSummary> listHosts() => const [];
  @override
  Stream<void> get hostsChanged => const Stream.empty();
  @override
  List<LinkLocalShellSummary> listLocalShells() => const [];
  @override
  Future<ShellChannel> openProxyShell(String hostId, {required int cols, required int rows}) async =>
      throw const LinkException(LinkErrorKind.hostUnavailable);
  @override
  Future<ShellChannel> openProxyLocalShell(String shellId, {required int cols, required int rows}) async =>
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
  Future<bool> connectSession(String sessionId) async => false;
  @override
  Future<LinkSessionSummary?> handoffHostForMirror(String hostId) async => null;
  @override
  Future<LinkSessionSummary?> handoffLocalForMirror(String shellId) async => null;
  @override
  Future<void> receiveClipboard(String text) async {}
  @override
  Future<LinkFsHandle> openFiles(String target, CancellationToken cancel) async =>
      throw const FsError(FsFailure.unsupported);
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
    bool isLocal = false,
    String? localShellKind,
    required Future<ShellChannel> Function(int cols, int rows) openChannel,
    Future<FileSystem> Function()? files,
  }) {}
  @override
  Future<LinkFsHandle> openFiles() async => throw const FsError(FsFailure.unsupported);
}

final linkDesktopBridgeProvider = Provider<LinkDesktopBridge>((_) => const _NullDesktopBridge());
final linkMobileBridgeProvider = Provider<LinkMobileBridge>((_) => const _NullMobileBridge());

/// A phone that connected to the desktop, with the version it reported.
typedef LinkPeerUpdate = ({String deviceId, String name, String version});

/// Leading-edge micro-batcher for terminal output over E2EE Link: flushes the first chunk
/// immediately for zero added interactive echo latency, then coalesces rapid bursts for [window]
/// (up to [maxBytes]) into single encrypted frames.
class _OutputCoalescer {
  _OutputCoalescer(this._send);

  static const _window = Duration(milliseconds: 12);
  static const _maxBytes = 16384;

  final void Function(Uint8List chunk) _send;
  final _buffer = BytesBuilder(copy: false);
  Timer? _timer;
  var _cooling = false;
  var _closed = false;

  void add(Uint8List chunk) {
    if (_closed || chunk.isEmpty) return;
    if (!_cooling && _buffer.isEmpty && chunk.length <= _maxBytes) {
      _send(chunk);
      _cooling = true;
      _timer = Timer(_window, _onTimer);
      return;
    }
    _buffer.add(chunk);
    if (_buffer.length >= _maxBytes) {
      _flush();
      _timer?.cancel();
      _cooling = true;
      _timer = Timer(_window, _onTimer);
    } else if (_timer == null) {
      _cooling = true;
      _timer = Timer(_window, _onTimer);
    }
  }

  void _onTimer() {
    _timer = null;
    if (_closed) return;
    if (_buffer.isNotEmpty) {
      _flush();
      _cooling = true;
      _timer = Timer(_window, _onTimer);
    } else {
      _cooling = false;
    }
  }

  void _flush() {
    if (_buffer.isEmpty) return;
    final bytes = _buffer.takeBytes();
    if (!_closed && bytes.isNotEmpty) _send(bytes);
  }

  void flushAndClose() {
    if (_closed) return;
    _timer?.cancel();
    _timer = null;
    _cooling = false;
    _flush();
    _closed = true;
  }

  void cancel() {
    _closed = true;
    _timer?.cancel();
    _timer = null;
    _cooling = false;
    _buffer.clear();
  }
}

/// A desktop-side active connection from one paired mobile peer.
class _ConnectedPeer {
  _ConnectedPeer(this.deviceId, this.name, this.session, this.files);

  final String deviceId;
  final String name;
  final LinkCipherSession session;
  final LinkFiles files;
  Object? sharedFilesBinding;
  var acceptsUpdates = false;
  String? version;
  CancellationToken? updateMount;
  final mirrors = <String, ({MirrorAttachment attachment, _OutputCoalescer coalescer})>{};
  final proxyChannels =
      <
        String,
        ({
          ShellChannel channel,
          StreamSubscription<Uint8List> outSub,
          StreamSubscription<Uint8List> errSub,
          _OutputCoalescer coalescer,
        })
      >{};

  final monitorRequests = <String, ({String channelId, CancellationToken cancel})>{};

  LinkTerminalResources? resources(String channelId, LinkPeerPermissions permissions) {
    if (mirrors[channelId]?.attachment.resources case final resources? when permissions.allowMirror) return resources;
    final channel = proxyChannels[channelId]?.channel;
    return permissions.allowProxy && channel is LinkProxyShell ? channel.resources : null;
  }

  void revokeTerminalResources({String? channelId}) {
    for (final request in monitorRequests.values) {
      if (channelId == null || request.channelId == channelId) request.cancel.cancel();
    }
    files.revoke();
  }

  void cleanup() {
    for (final request in monitorRequests.values) {
      request.cancel.cancel();
    }
    files.close();
    for (final m in mirrors.values) {
      m.coalescer.cancel();
      m.attachment.detach();
    }
    mirrors.clear();
    for (final p in proxyChannels.values) {
      p.coalescer.cancel();
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
    this.openUpdateFiles,
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
  final FileSystem Function(CancellationToken lifetime)? openUpdateFiles;

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
  final _updateSuggestions = StreamController<LinkPeerUpdate>.broadcast();
  _ActivePairing? _pairing;
  List<String> _addresses = const [];
  String? _pairingHost;
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

  bool canOfferUpdate(String id) => openUpdateFiles != null && _connected[id]?.acceptsUpdates == true;

  /// Phones that connected to this desktop, for the app-version reminder.
  Stream<LinkPeerUpdate> get updateSuggestions => _updateSuggestions.stream;

  Future<bool> offerUpdate(String id) async => _sendUpdate(id, 'update.offer');

  /// Asks the phone to fetch the latest package through this desktop without another prompt there.
  Future<bool> pushUpdate(String id) async => _sendUpdate(id, 'update.push');

  Future<bool> _sendUpdate(String id, String type) async {
    final peer = _connected[id];
    if (peer == null || peer.session.isClosed || !canOfferUpdate(id)) return false;
    try {
      await peer.session.sendMessage({'type': type});
      return true;
    } on Object {
      return false;
    }
  }

  void _suggestPeerUpdate(_ConnectedPeer peer) {
    final version = peer.version;
    if (version == null || _updateSuggestions.isClosed || !canOfferUpdate(peer.deviceId)) return;
    _updateSuggestions.add((deviceId: peer.deviceId, name: peer.name, version: version));
  }

  int get connectedCount => _connected.length;
  LinkPasswordSyncRequest? get pendingPasswordSync => _passwordSyncQueue.firstOrNull;

  LinkPairingInfo? get activePairing {
    final p = _pairing;
    final id = _identity;
    if (p == null || id == null || p.expired || p.locked || !running) return null;
    final host = _addresses.contains(_pairingHost) ? _pairingHost! : _addresses.firstOrNull ?? '127.0.0.1';
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

  /// How long a pairing code stays valid.
  static const pairingLifetime = Duration(minutes: 3);

  /// Generates a fresh 6-digit single-use pairing code valid for [pairingLifetime].
  Future<LinkPairingInfo?> startPairing() async {
    if (!running) return null;
    await _ensureIdentity();
    _addresses = await localLinkAddresses();
    final rng = Random.secure();
    final code = List<int>.generate(6, (_) => rng.nextInt(10)).join();
    _pairing = _ActivePairing(code, DateTime.now().add(pairingLifetime));
    _pairingTimer?.cancel();
    _pairingTimer = Timer(pairingLifetime, () {
      _pairing = null;
      _notify();
    });
    _notify();
    return activePairing;
  }

  /// Which local address the pairing QR and URI point at, for a desktop on several networks.
  void selectPairingHost(String host) {
    _pairingHost = host;
    _notify();
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
        for (final entry in active.mirrors.entries) {
          entry.value.coalescer.cancel();
          entry.value.attachment.detach();
          _notifyClosedChannel(active, 'mirror.closed', entry.key);
        }
        active.mirrors.clear();
      }
      if (!permissions.allowProxy) {
        for (final entry in active.proxyChannels.entries) {
          final channel = entry.value;
          channel.coalescer.cancel();
          unawaited(channel.outSub.cancel());
          unawaited(channel.errSub.cancel());
          channel.channel.close();
          _notifyClosedChannel(active, 'proxy.closed', entry.key);
        }
        active.proxyChannels.clear();
      }
      for (final request in active.monitorRequests.values) {
        if (active.resources(request.channelId, permissions) == null) request.cancel.cancel();
      }
      active.files.revoke();
      _pushFileAccess(active);
      if (permissions.allowMirror) {
        _pushSessionsTo(active);
      } else {
        unawaited(active.session.sendMessage({'type': 'sessions.list', 'items': const <Object?>[]}));
      }
      if (permissions.allowProxy) {
        _pushHostsTo(active);
      } else {
        unawaited(active.session.sendMessage({'type': 'hosts.list', 'items': const <Object?>[]}));
      }
      if (permissions.allowProxy || permissions.allowMirror) {
        _pushLocalShellsTo(active);
      } else {
        unawaited(active.session.sendMessage({'type': 'localShells.list', 'items': const <Object?>[]}));
      }
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
      late final _ConnectedPeer active;
      LinkTerminalResources? terminalResources(String target) {
        final permissions = _findPeer(peerId)?.permissions;
        if (permissions == null || !permissions.allowFiles) return null;
        return active.resources(target.substring('terminal:'.length), permissions);
      }

      final files = LinkFiles(
        send: session.sendMessage,
        isConnected: () => !session.isClosed,
        canOpen: (target) {
          if (target == linkUpdateTarget) {
            return identical(_connected[peerId], active) && _findPeer(peerId) != null && active.acceptsUpdates;
          }
          if (target.startsWith('terminal:')) return terminalResources(target)?.current() == true;
          final permissions = _findPeer(peerId)?.permissions;
          return permissions?.allowFiles == true &&
              (target == 'local' || (target.startsWith('host:') && permissions!.allowProxy));
        },
        openTarget: (target, cancel) {
          if (target == linkUpdateTarget) {
            final open = openUpdateFiles;
            if (open == null || active.updateMount?.isCancelled == false) {
              throw const FsError(FsFailure.unsupported);
            }
            final fs = open(cancel);
            active.updateMount = cancel;
            return Future.value(
              LinkFsHandle(fs, () async {
                if (identical(active.updateMount, cancel)) active.updateMount = null;
                await fs.close();
              }),
            );
          }
          if (!target.startsWith('terminal:')) return bridge.openFiles(target, cancel);
          final resources = terminalResources(target);
          if (resources == null || !resources.current()) throw const FsError(FsFailure.lost);
          return resources.openFiles(cancel);
        },
      );
      active = _ConnectedPeer(peerId, session.peerName, session, files);
      connection = active;
      _connected[peerId] = active;
      _notify();

      // Push initial state snapshot according to permissions
      _pushSessionsTo(active);
      _pushHostsTo(active);
      _pushLocalShellsTo(active);
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
      case 'update.ready':
        if (msg['version'] case final String version when version.isNotEmpty && version.length <= 32) {
          peer.version = version;
        }
        if (openUpdateFiles != null && !peer.acceptsUpdates) {
          peer.acceptsUpdates = true;
          await peer.session.sendMessage({'type': 'update.relay'});
          _notify();
        }
        _suggestPeerUpdate(peer);
      case 'sessions.list':
        _pushSessionsTo(peer);
      case 'hosts.list':
        _pushHostsTo(peer);
      case 'localShells.list':
        _pushLocalShellsTo(peer);
      case 'approvals.list':
        _pushApprovalsTo(peer);

      case 'mirror.attach':
        final channelId = msg['channelId'] as String? ?? '';
        final sessionId = msg['sessionId'] as String? ?? '';
        if (!perms.allowMirror ||
            channelId.isEmpty ||
            channelId.length > 64 ||
            peer.proxyChannels.containsKey(channelId)) {
          await peer.session.sendMessage({
            'type': 'mirror.error',
            'channelId': channelId,
            'code': LinkErrorKind.permissionDenied.name,
          });
          return;
        }
        final existingMirror = peer.mirrors.remove(channelId);
        if (existingMirror != null) {
          existingMirror.coalescer.cancel();
          existingMirror.attachment.detach();
        }
        peer.revokeTerminalResources(channelId: channelId);
        final coalescer = _OutputCoalescer((chunk) {
          if (peer.session.isClosed || !peer.mirrors.containsKey(channelId)) return;
          unawaited(
            peer.session
                .sendMessage({'type': 'mirror.output', 'channelId': channelId, 'data': base64Encode(chunk)})
                .catchError((Object _) {}),
          );
        });
        MirrorAttachment? attachment;
        attachment = bridge.attachMirror(
          sessionId,
          coalescer.add,
          onClosed: () {
            final current = peer.mirrors[channelId];
            if (current == null || !identical(current.attachment, attachment)) return;
            peer.mirrors.remove(channelId);
            current.coalescer.flushAndClose();
            peer.revokeTerminalResources(channelId: channelId);
            _notifyClosedChannel(peer, 'mirror.closed', channelId);
          },
        );
        if (attachment == null) {
          coalescer.cancel();
          await peer.session.sendMessage({
            'type': 'mirror.error',
            'channelId': channelId,
            'code': LinkErrorKind.hostUnavailable.name,
          });
          return;
        }
        peer.mirrors[channelId] = (attachment: attachment, coalescer: coalescer);
        await peer.session.sendMessage({
          'type': 'mirror.snapshot',
          'channelId': channelId,
          'sessionId': sessionId,
          'data': base64Encode(attachment.snapshot),
          if (attachment.resources case final resources?) ...{'files': true, 'monitor': resources.sample != null},
        });

      case 'mirror.detach':
        final channelId = msg['channelId'] as String? ?? '';
        final existing = peer.mirrors.remove(channelId);
        if (existing != null) {
          existing.coalescer.cancel();
          existing.attachment.detach();
        }
        peer.revokeTerminalResources(channelId: channelId);

      case 'mirror.input':
        if (!perms.allowMirror) return;
        final channelId = msg['channelId'] as String? ?? '';
        final data = msg['data'] as String?;
        if (data != null) peer.mirrors[channelId]?.attachment.write(base64Decode(data));

      case 'terminal.monitor':
        unawaited(_sampleTerminal(peer, msg, perms));
      case 'terminal.monitor.cancel':
        peer.monitorRequests[msg['reqId']]?.cancel.cancel();

      case 'mirror.resize':
        if (!perms.allowMirror) return;
        final channelId = msg['channelId'] as String? ?? '';
        final cols = (msg['cols'] as num?)?.toInt();
        final rows = (msg['rows'] as num?)?.toInt();
        if (cols != null && rows != null && cols > 0 && rows > 0) {
          peer.mirrors[channelId]?.attachment.resize(cols, rows);
        }

      case 'proxy.open':
      case 'proxy.openLocal':
        final channelId = msg['channelId'] as String? ?? '';
        final isLocal = type == 'proxy.openLocal';
        final targetId = (isLocal ? msg['shellId'] : msg['hostId']) as String? ?? '';
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
        if (channelId.isEmpty ||
            channelId.length > 64 ||
            peer.mirrors.containsKey(channelId) ||
            peer.proxyChannels.containsKey(channelId) ||
            peer.proxyChannels.length >= linkMaxProxyChannelsPerPeer) {
          await peer.session.sendMessage({
            'type': 'proxy.error',
            'channelId': channelId,
            'code': LinkErrorKind.channelLimit.name,
          });
          return;
        }
        try {
          final shell = isLocal
              ? await bridge.openProxyLocalShell(targetId, cols: cols, rows: rows)
              : await bridge.openProxyShell(targetId, cols: cols, rows: rows);
          if (peer.session.isClosed) {
            shell.close();
            return;
          }
          final coalescer = _OutputCoalescer((bytes) {
            if (peer.session.isClosed || bytes.isEmpty) return;
            unawaited(
              peer.session
                  .sendMessage({'type': 'proxy.output', 'channelId': channelId, 'data': base64Encode(bytes)})
                  .catchError((Object _) {}),
            );
          });

          final outSub = shell.stdout.listen(coalescer.add, onError: (Object _) {});
          final errSub = shell.stderr.listen(coalescer.add, onError: (Object _) {});
          peer.proxyChannels[channelId] = (channel: shell, outSub: outSub, errSub: errSub, coalescer: coalescer);
          await peer.session.sendMessage({
            'type': 'proxy.opened',
            'channelId': channelId,
            if (shell is LinkProxyShell) ...{'files': true, 'monitor': shell.resources.sample != null},
          });
          unawaited(
            shell.done.whenComplete(() {
              if (!identical(peer.proxyChannels[channelId]?.channel, shell)) return;
              final entry = peer.proxyChannels.remove(channelId);
              peer.revokeTerminalResources(channelId: channelId);
              if (entry != null) {
                entry.coalescer.flushAndClose();
                unawaited(entry.outSub.cancel());
                unawaited(entry.errSub.cancel());
              }
              _notifyClosedChannel(peer, 'proxy.closed', channelId);
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
        peer.revokeTerminalResources(channelId: channelId);
        if (entry != null) {
          entry.coalescer.cancel();
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

      case 'handoff.mirror':
        if (!perms.allowMirror) return;
        final reqId = msg['reqId'] as String? ?? '';
        final hostId = msg['hostId'] as String? ?? '';
        final summary = hostId.isEmpty ? null : await bridge.handoffHostForMirror(hostId);
        if (!peer.session.isClosed) {
          await peer.session
              .sendMessage({
                'type': 'handoff.mirror.result',
                'reqId': reqId,
                if (summary != null) 'session': summary.toJson(),
              })
              .catchError((Object _) {});
        }

      case 'handoff.local.mirror':
        if (!perms.allowMirror) return;
        final reqId = msg['reqId'] as String? ?? '';
        final shellId = msg['shellId'] as String? ?? '';
        final summary = await bridge.handoffLocalForMirror(shellId);
        if (!peer.session.isClosed) {
          await peer.session
              .sendMessage({
                'type': 'handoff.mirror.result',
                'reqId': reqId,
                if (summary != null) 'session': summary.toJson(),
              })
              .catchError((Object _) {});
        }

      case 'session.connect':
        if (!perms.allowMirror) return;
        final sessionId = msg['sessionId'] as String? ?? '';
        final ok = sessionId.isNotEmpty && await bridge.connectSession(sessionId);
        if (!peer.session.isClosed) {
          await peer.session
              .sendMessage({'type': 'session.connect.result', 'sessionId': sessionId, 'ok': ok})
              .catchError((Object _) {});
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

  Future<void> _sampleTerminal(_ConnectedPeer peer, Map<String, dynamic> msg, LinkPeerPermissions permissions) async {
    final reqId = msg['reqId'], channelId = msg['channelId'];
    if (reqId is! String ||
        reqId.length > 64 ||
        channelId is! String ||
        channelId.length > 64 ||
        peer.monitorRequests.containsKey(reqId)) {
      return;
    }
    final resources = peer.resources(channelId, permissions), sample = resources?.sample;
    final reply = <String, Object?>{'type': 'terminal.monitor.result', 'reqId': reqId};
    if (sample != null &&
        resources!.current() &&
        peer.monitorRequests.length < 3 &&
        !peer.monitorRequests.values.any((request) => request.channelId == channelId)) {
      final cancel = CancellationToken();
      peer.monitorRequests[reqId] = (channelId: channelId, cancel: cancel);
      try {
        final result = await sample(processes: msg['processes'] == true, gpu: msg['gpu'] == true, cancel: cancel);
        final currentPermissions = _findPeer(peer.deviceId)?.permissions;
        if (!cancel.isCancelled &&
            resources.current() &&
            currentPermissions != null &&
            identical(peer.resources(channelId, currentPermissions), resources)) {
          final limit = min(result.stdout.length, linkMonitorMaxBytes);
          reply['output'] = base64Encode(Uint8List.sublistView(result.stdout, 0, limit));
          reply['exitCode'] = result.exitCode;
          reply['truncated'] = result.truncated || limit < result.stdout.length;
        }
      } on Object {
        // The client displays a failed sample and can retry on its next tick.
      } finally {
        peer.monitorRequests.remove(reqId);
      }
    }
    if (!peer.session.isClosed) await peer.session.sendMessage(reply).catchError((Object _) {});
  }

  void _notifyClosedChannel(_ConnectedPeer peer, String type, String channelId) {
    if (!peer.session.isClosed) {
      unawaited(peer.session.sendMessage({'type': type, 'channelId': channelId}).catchError((Object _) {}));
    }
  }

  void _pushFileAccess(_ConnectedPeer peer) {
    final permissions = _findPeer(peer.deviceId)?.permissions;
    final local = permissions?.allowFiles == true;
    unawaited(
      peer.session
          .sendMessage({'type': 'fs.access', 'local': local, 'proxy': local && permissions!.allowProxy})
          .catchError((Object _) {}),
    );
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

  void _pushLocalShellsTo(_ConnectedPeer peer) {
    final record = _findPeer(peer.deviceId);
    if (record == null ||
        (!record.permissions.allowProxy && !record.permissions.allowMirror) ||
        peer.session.isClosed) {
      return;
    }
    final items = [for (final s in bridge.listLocalShells()) s.toJson()];
    unawaited(peer.session.sendMessage({'type': 'localShells.list', 'items': items}).catchError((Object _) {}));
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
    unawaited(_updateSuggestions.close());
    unawaited(_stopServer());
    super.dispose();
  }
}

/// Client-side [ShellChannel] backed by either a desktop mirror or a desktop-proxied SSH channel over E2EE Link.
class _LinkShellChannel implements ShellChannel {
  _LinkShellChannel(this.id, {required this.onWrite, required this.onResize, required this.onClose}) {
    _stdout = StreamController<Uint8List>.broadcast(onListen: _flushPending);
  }

  final String id;
  bool hasFiles = false, hasMonitor = false;
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
  LinkClientController({
    required this.credentials,
    required this.store,
    required this.bridge,
    this.transportFactory,
    bool? acceptAndroidUpdates,
    this.autoReconnect = true,
  }) : _acceptAndroidUpdates = acceptAndroidUpdates ?? Platform.isAndroid {
    _peers = store.load();
  }

  final LinkCredentials credentials;
  final LinkPeerStore store;
  final LinkMobileBridge bridge;
  final Future<LinkTransport> Function(String host, int port)? transportFactory;
  final bool _acceptAndroidUpdates;
  final bool autoReconnect;
  final _updateOffers = StreamController<void>.broadcast();
  final _updatePushes = StreamController<void>.broadcast();
  final _reconnected = StreamController<void>.broadcast();
  var _updateRelay = false;

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
  List<LinkLocalShellSummary> _desktopLocalShells = const [];
  List<LinkApprovalItem> _approvals = const [];
  LinkSyncSummary? _lastSync;
  LinkCredentialBundle? _pendingCredentialOffer;
  LinkPasswordSyncStatus _passwordSyncStatus = LinkPasswordSyncStatus.idle;
  int _lastImportedPasswordCount = 0;
  bool _sharesPhoneFiles = false;
  Object? _desktopFilesBinding, _proxyFilesBinding;
  int _attempt = 0;
  bool _disposed = false;
  bool _manualDisconnect = false;
  bool _hadConnectedBefore = false;
  bool _reconnecting = false;
  int _reconnectAttempts = 0;
  String? _reconnectPeerId;
  Timer? _reconnectTimer;

  static const _reconnectDelays = [
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 4),
    Duration(seconds: 8),
    Duration(seconds: 15),
    Duration(seconds: 15),
  ];

  final _channels = <String, _LinkShellChannel>{};
  final _openWaiters = <String, Completer<void>>{};
  final _monitorWaiters = <String, Completer<Map<String, dynamic>>>{};
  final _connectWaiters = <String, Completer<bool>>{};
  final _handoffMirrorWaiters = <String, Completer<LinkSessionSummary?>>{};
  final _syncWaiters = <String, Completer<({LinkSyncBundle bundle, bool awaitingPasswordApproval})>>{};
  final _requestedPasswordSyncIds = <String>{};
  final _followDesktopChannels = <String>{};

  LinkConnectionStatus get status => _status;
  bool get connected => _status == LinkConnectionStatus.connected && _session != null && !_session!.isClosed;
  bool get reconnecting => _reconnecting;
  String? get reconnectingDesktopName =>
      _reconnectPeerId == null ? null : _peers.where((p) => p.deviceId == _reconnectPeerId).firstOrNull?.name;
  LinkErrorKind? get lastError => _lastError;
  String? get connectedDesktopId => _connectedDesktopId;
  String? get connectedDesktopName => _connectedDesktopName;
  List<LinkPeer> get savedDesktops => List.unmodifiable(_peers);
  List<DiscoveredDesktop> get discoveredDesktops => List.unmodifiable(_discovered);
  bool get discovering => _discovering;
  List<LinkSessionSummary> get desktopSessions => List.unmodifiable(_desktopSessions);
  List<LinkHostSummary> get desktopHosts => List.unmodifiable(_desktopHosts);
  List<LinkLocalShellSummary> get desktopLocalShells => List.unmodifiable(_desktopLocalShells);
  List<LinkApprovalItem> get pendingApprovals => List.unmodifiable(_approvals);
  LinkSyncSummary? get lastSync => _lastSync;
  LinkCredentialBundle? get pendingCredentialOffer => _pendingCredentialOffer;
  LinkPasswordSyncStatus get passwordSyncStatus => _passwordSyncStatus;
  int get lastImportedPasswordCount => _lastImportedPasswordCount;
  bool get sharesPhoneFiles => _sharesPhoneFiles;
  bool get desktopSharesFiles => desktopFilesBinding() != null;
  bool get desktopProxiesFiles => desktopFilesBinding(proxy: true) != null;
  Object? get filesBinding => connected ? _files : null;
  Object? get updateRelayBinding => _updateRelay ? filesBinding : null;
  Stream<void> get updateOffers => _updateOffers.stream;

  /// A desktop-confirmed push: fetch the latest package through the relay without another prompt.
  Stream<void> get updatePushes => _updatePushes.stream;

  /// Fires whenever Link transitions back to connected after a prior connection.
  Stream<void> get reconnected => _reconnected.stream;

  Future<FileSystem> openUpdateRelay(Object binding) async {
    if (!identical(updateRelayBinding, binding)) throw const FsError(FsFailure.lost);
    return _files!.open(linkUpdateTarget);
  }

  Object? desktopFilesBinding({bool proxy = false}) =>
      connected ? (proxy ? _proxyFilesBinding : _desktopFilesBinding) : null;

  Future<FileSystem> openFiles(Object binding, {String? hostId}) async {
    if (!identical(desktopFilesBinding(proxy: hostId != null), binding)) throw const FsError(FsFailure.lost);
    return _files!.open(hostId == null ? 'local' : 'host:$hostId');
  }

  bool _channelCurrent(_LinkShellChannel channel) =>
      connected && !channel._closed && identical(_channels[channel.id], channel);

  bool terminalFilesAvailable(ShellChannel? channel) =>
      channel is _LinkShellChannel && channel.hasFiles && desktopSharesFiles && _channelCurrent(channel);

  Future<FileSystem> openTerminalFiles(ShellChannel channel) async {
    if (!terminalFilesAvailable(channel)) throw const FsError(FsFailure.lost);
    return _files!.open('terminal:${(channel as _LinkShellChannel).id}');
  }

  MonitorSample? terminalMonitor(ShellChannel? channel) {
    if (channel is! _LinkShellChannel || !channel.hasMonitor || !_channelCurrent(channel)) return null;
    return ({required processes, required gpu, required cancel}) =>
        _sampleTerminal(channel, processes: processes, gpu: gpu, cancel: cancel);
  }

  Future<ExecResult> _sampleTerminal(
    _LinkShellChannel channel, {
    required bool processes,
    required bool gpu,
    required CancellationToken cancel,
  }) async {
    final session = _session;
    if (session == null || !_channelCurrent(channel) || cancel.isCancelled) {
      throw const ExecError(ExecFailure.cancelled);
    }
    final reqId = newId(), waiter = Completer<Map<String, dynamic>>();
    _monitorWaiters[reqId] = waiter;
    var completed = false;
    try {
      final message = await Future.any([
        Future.wait([
          waiter.future,
          session.sendMessage({
            'type': 'terminal.monitor',
            'reqId': reqId,
            'channelId': channel.id,
            'processes': processes,
            'gpu': gpu,
          }),
        ], eagerError: true).then((values) => values.first as Map<String, dynamic>),
        cancel.whenCancelled.then<Map<String, dynamic>>((_) => throw const ExecError(ExecFailure.cancelled)),
      ]).timeout(const Duration(seconds: 12));
      completed = true;
      final output = message['output'];
      if (output is! String || !_channelCurrent(channel)) throw const LinkException(LinkErrorKind.hostUnavailable);
      return ExecResult(
        base64Decode(output),
        Uint8List(0),
        message['exitCode'] as int?,
        truncated: message['truncated'] == true,
      );
    } finally {
      _monitorWaiters.remove(reqId);
      if (!completed && !session.isClosed) {
        unawaited(session.sendMessage({'type': 'terminal.monitor.cancel', 'reqId': reqId}).catchError((Object _) {}));
      }
    }
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

  Future<bool> connectToPeer(LinkPeer peer, {String? hostOverride, int? portOverride, String? deviceName}) async {
    _manualDisconnect = false;
    _cancelReconnect(notify: false);
    final host = hostOverride ?? peer.lastAddress ?? '';
    final port = portOverride ?? peer.lastPort ?? linkDefaultPort;
    final ok = await _establish(
      host: host,
      port: port,
      pairing: false,
      expectedPublicKey: peer.publicKey,
      deviceName: deviceName,
    );
    if (ok || _disposed || hostOverride != null || _lastError != LinkErrorKind.network || transportFactory != null) {
      return ok;
    }
    // Saved address failed over the network (e.g. desktop DHCP IP changed): probe LAN once for the same deviceId.
    final found = await discoverLanDesktops(wait: const Duration(milliseconds: 650));
    if (_disposed || connected || _manualDisconnect) return false;
    _discovered = found;
    final match = found.where((d) => d.deviceId == peer.deviceId).firstOrNull;
    if (match == null || (match.address == host.trim() && match.port == port)) {
      _notify();
      return false;
    }
    return _establish(
      host: match.address,
      port: match.port,
      pairing: false,
      expectedPublicKey: peer.publicKey,
      deviceName: deviceName,
    );
  }

  /// Auto-connects to the most recently used saved desktop when not manually disconnected (e.g. on startup/resume).
  Future<bool> ensureConnected() async {
    if (_disposed || connected || _status == LinkConnectionStatus.connecting || _manualDisconnect || _peers.isEmpty) {
      return connected;
    }
    final target = _mostRecentPeer();
    if (target == null) return false;
    _reconnectAttempts = 0;
    return connectToPeer(target);
  }

  LinkPeer? _mostRecentPeer() {
    if (_peers.isEmpty) return null;
    if (_reconnectPeerId != null) {
      final preferred = _peers.where((p) => p.deviceId == _reconnectPeerId).firstOrNull;
      if (preferred != null) return preferred;
    }
    final sorted = [..._peers]..sort((a, b) => (b.lastSeen ?? b.pairedAt).compareTo(a.lastSeen ?? a.pairedAt));
    return sorted.first;
  }

  void cancelReconnect() {
    _manualDisconnect = true;
    _cancelReconnect(notify: true);
  }

  void _cancelReconnect({required bool notify}) {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    final was = _reconnecting;
    _reconnecting = false;
    _reconnectAttempts = 0;
    if (notify && was) _notify();
  }

  void _scheduleReconnect() {
    if (_disposed || !autoReconnect || _manualDisconnect || connected || _reconnectPeerId == null) return;
    if (_reconnectAttempts >= _reconnectDelays.length) {
      _cancelReconnect(notify: true);
      return;
    }
    final peer = _peers.where((p) => p.deviceId == _reconnectPeerId).firstOrNull;
    if (peer == null) {
      _cancelReconnect(notify: true);
      return;
    }
    final delay = _reconnectDelays[_reconnectAttempts++];
    _reconnecting = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(delay, () => unawaited(_runScheduledReconnect(peer)));
    _notify();
  }

  Future<void> _runScheduledReconnect(LinkPeer peer) async {
    _reconnectTimer = null;
    if (_disposed || !_reconnecting || _manualDisconnect || connected) return;
    final ok = await _establish(
      host: peer.lastAddress ?? '',
      port: peer.lastPort ?? linkDefaultPort,
      pairing: false,
      expectedPublicKey: peer.publicKey,
      fromAutoReconnect: true,
    );
    if (ok || _disposed || _manualDisconnect || connected) return;
    if (_lastError == LinkErrorKind.peerRevoked || _lastError == LinkErrorKind.authFailed) {
      _manualDisconnect = true;
      _cancelReconnect(notify: true);
      return;
    }
    if (_lastError == LinkErrorKind.network && transportFactory == null && _reconnectAttempts == 2) {
      final found = await discoverLanDesktops(wait: const Duration(milliseconds: 650));
      if (_disposed || _manualDisconnect || connected) return;
      _discovered = found;
      final match = found.where((d) => d.deviceId == peer.deviceId).firstOrNull;
      if (match != null && (match.address != peer.lastAddress || match.port != peer.lastPort)) {
        final okLan = await _establish(
          host: match.address,
          port: match.port,
          pairing: false,
          expectedPublicKey: peer.publicKey,
          fromAutoReconnect: true,
        );
        if (okLan || _disposed || _manualDisconnect || connected) return;
      }
    }
    _scheduleReconnect();
  }

  Future<bool> _establish({
    required String host,
    required int port,
    required bool pairing,
    String? pairingCode,
    String? expectedPublicKey,
    String? deviceName,
    bool fromAutoReconnect = false,
  }) async {
    final attempt = ++_attempt;
    if (!fromAutoReconnect) {
      _manualDisconnect = false;
      _cancelReconnect(notify: false);
    }
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
      final wasConnectedBefore = _hadConnectedBefore;
      _hadConnectedBefore = true;
      _cancelReconnect(notify: false);
      _reconnectPeerId = result.session.peerDeviceId;
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
        if (!identical(_session, session)) return;
        unawaited(_handleUnexpectedDrop());
      }

      _incomingSub = result.incoming.listen(
        _handleMessage,
        onError: (Object _) => disconnected(),
        onDone: disconnected,
      );
      if (_acceptAndroidUpdates) {
        unawaited(session.sendMessage({'type': 'update.ready', 'version': appVersion}).catchError((Object _) {}));
      }
      _notify();
      if (wasConnectedBefore && !_reconnected.isClosed) _reconnected.add(null);
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

  Future<void> _handleUnexpectedDrop() async {
    _attempt++;
    await _disconnect();
    if (!_disposed && autoReconnect && !_manualDisconnect && _reconnectPeerId != null) {
      _scheduleReconnect();
    }
  }

  Future<void> disconnect() {
    _manualDisconnect = true;
    _cancelReconnect(notify: false);
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
    _updateRelay = false;
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
    for (final waiter in _monitorWaiters.values) {
      if (!waiter.isCompleted) waiter.completeError(const LinkException(LinkErrorKind.network));
    }
    _monitorWaiters.clear();
    for (final waiter in _connectWaiters.values) {
      if (!waiter.isCompleted) waiter.complete(false);
    }
    _connectWaiters.clear();
    for (final waiter in _handoffMirrorWaiters.values) {
      if (!waiter.isCompleted) waiter.complete(null);
    }
    _handoffMirrorWaiters.clear();
    for (final w in _syncWaiters.values) {
      if (!w.isCompleted) w.completeError(const LinkException(LinkErrorKind.network));
    }
    _syncWaiters.clear();
    _requestedPasswordSyncIds.clear();
    _connectedDesktopId = null;
    _connectedDesktopName = null;
    _desktopSessions = const [];
    _desktopHosts = const [];
    _desktopLocalShells = const [];
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
    if (_reconnectPeerId == deviceId) {
      _reconnectPeerId = null;
      _cancelReconnect(notify: false);
    }
    if (_connectedDesktopId == deviceId) await disconnect();
    _peers = _peers.where((p) => p.deviceId != deviceId).toList();
    await store.save(_peers);
    _notify();
  }

  /// Requests fresh sessions, hosts, local shells, and approvals from the connected desktop.
  Future<void> refreshRemoteState() async {
    final session = _session;
    if (!connected || session == null) return;
    await Future.wait([
      session.sendMessage({'type': 'sessions.list'}).catchError((Object _) {}),
      session.sendMessage({'type': 'hosts.list'}).catchError((Object _) {}),
      session.sendMessage({'type': 'localShells.list'}).catchError((Object _) {}),
      session.sendMessage({'type': 'approvals.list'}).catchError((Object _) {}),
    ]);
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
      channelId,
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
  Future<ShellChannel> openProxyChannel(String desktopHostId, {required int cols, required int rows}) =>
      _openProxyChannel(type: 'proxy.open', key: 'hostId', targetId: desktopHostId, cols: cols, rows: rows);

  /// Opens a desktop-proxied local shell [ShellChannel] sized directly for this mobile client.
  Future<ShellChannel> openProxyLocalChannel(String shellId, {required int cols, required int rows}) =>
      _openProxyChannel(type: 'proxy.openLocal', key: 'shellId', targetId: shellId, cols: cols, rows: rows);

  Future<ShellChannel> _openProxyChannel({
    required String type,
    required String key,
    required String targetId,
    required int cols,
    required int rows,
  }) async {
    final session = _session;
    if (!connected || session == null) throw const LinkException(LinkErrorKind.network);
    final channelId = newId();
    final waiter = Completer<void>();
    _openWaiters[channelId] = waiter;
    final channel = _LinkShellChannel(
      channelId,
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
    await session.sendMessage({'type': type, 'channelId': channelId, key: targetId, 'cols': cols, 'rows': rows});
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
    ShellChannel? opened;
    bridge.openRemoteTerminal(
      peerId: _connectedDesktopId!,
      peerName: _connectedDesktopName ?? _connectedDesktopId!,
      remoteId: target.sessionId,
      title: target.title,
      targetLabel: '${_connectedDesktopName ?? 'Desktop'} · ${target.targetLabel}',
      isMirror: true,
      isLocal: target.isLocal,
      localShellKind: target.shellKind,
      openChannel: (_, _) async =>
          opened = await openMirrorChannel(target.sessionId, followDesktopSize: followDesktopSize),
      files: () => openTerminalFiles(opened!),
    );
  }

  /// Asks the desktop to connect an existing tab; returns whether its shell is live now.
  Future<bool> connectDesktopSession(String sessionId) async {
    final session = _session;
    if (!connected || session == null || sessionId.isEmpty) return false;
    final waiter = Completer<bool>();
    _connectWaiters[sessionId] = waiter;
    try {
      await session.sendMessage({'type': 'session.connect', 'sessionId': sessionId});
      return await waiter.future.timeout(const Duration(seconds: 45), onTimeout: () => false);
    } on Object {
      return false;
    } finally {
      _connectWaiters.remove(sessionId);
    }
  }

  /// Asks the desktop to open [hostId] and returns the new session once its shell is live.
  Future<LinkSessionSummary?> openHostOnDesktopForMirror(String hostId) async {
    final session = _session;
    if (!connected || session == null || hostId.isEmpty) return null;
    final reqId = newId();
    final waiter = Completer<LinkSessionSummary?>();
    _handoffMirrorWaiters[reqId] = waiter;
    try {
      await session.sendMessage({'type': 'handoff.mirror', 'reqId': reqId, 'hostId': hostId});
      return await waiter.future.timeout(const Duration(seconds: 60), onTimeout: () => null);
    } on Object {
      return null;
    } finally {
      _handoffMirrorWaiters.remove(reqId);
    }
  }

  /// Asks the desktop to open a local shell tab and returns the new session once its PTY is live.
  Future<LinkSessionSummary?> openLocalOnDesktopForMirror(String shellId) async {
    final session = _session;
    if (!connected || session == null) return null;
    final reqId = newId();
    final waiter = Completer<LinkSessionSummary?>();
    _handoffMirrorWaiters[reqId] = waiter;
    try {
      await session.sendMessage({'type': 'handoff.local.mirror', 'reqId': reqId, 'shellId': shellId});
      return await waiter.future.timeout(const Duration(seconds: 30), onTimeout: () => null);
    } on Object {
      return null;
    } finally {
      _handoffMirrorWaiters.remove(reqId);
    }
  }

  /// Opens a desktop-proxied SSH tab in the local workspace via [bridge].
  void openProxiedHostInWorkspace(LinkHostSummary host) {
    if (!connected || _connectedDesktopId == null) return;
    ShellChannel? opened;
    bridge.openRemoteTerminal(
      peerId: _connectedDesktopId!,
      peerName: _connectedDesktopName ?? _connectedDesktopId!,
      remoteId: host.hostId,
      title: host.label.isEmpty ? host.targetLabel : host.label,
      targetLabel: '${_connectedDesktopName ?? 'Desktop'} ⇄ ${host.targetLabel}',
      isMirror: false,
      openChannel: (cols, rows) async => opened = await openProxyChannel(host.hostId, cols: cols, rows: rows),
      files: () => openTerminalFiles(opened!),
    );
  }

  /// Opens a desktop-proxied local shell tab in the local workspace via [bridge].
  void openProxiedLocalInWorkspace(LinkLocalShellSummary shell) {
    if (!connected || _connectedDesktopId == null) return;
    ShellChannel? opened;
    final desktop = _connectedDesktopName ?? 'Desktop';
    bridge.openRemoteTerminal(
      peerId: _connectedDesktopId!,
      peerName: desktop,
      remoteId: shell.shellId,
      title: shell.name,
      targetLabel: '$desktop · ${shell.name}',
      isMirror: false,
      isLocal: true,
      localShellKind: shell.kind,
      openChannel: (cols, rows) async => opened = await openProxyLocalChannel(shell.shellId, cols: cols, rows: rows),
      files: () => openTerminalFiles(opened!),
    );
  }

  void _setChannelResources(String id, Map<String, dynamic> msg) {
    if (_channels[id] case final channel?) {
      channel.hasFiles = msg['files'] == true;
      channel.hasMonitor = msg['monitor'] == true;
    }
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

      case 'localShells.list':
        _desktopLocalShells = [
          for (final item in msg['items'] as List<dynamic>? ?? const [])
            if (item is Map) LinkLocalShellSummary.fromJson(item.cast<String, dynamic>()),
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
        _setChannelResources(channelId, msg);
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

      case 'terminal.monitor.result':
        _monitorWaiters.remove(msg['reqId'])?.complete(msg);

      case 'session.connect.result':
        final waiter = _connectWaiters[msg['sessionId'] as String? ?? ''];
        if (waiter != null && !waiter.isCompleted) waiter.complete(msg['ok'] == true);

      case 'handoff.mirror.result':
        final raw = msg['session'];
        _handoffMirrorWaiters
            .remove(msg['reqId'] as String? ?? '')
            ?.complete(raw is Map ? LinkSessionSummary.fromJson(raw.cast<String, dynamic>()) : null);

      case 'proxy.opened':
        final channelId = msg['channelId'] as String? ?? '';
        _setChannelResources(channelId, msg);
        final waiter = _openWaiters.remove(channelId);
        if (waiter != null && !waiter.isCompleted) waiter.complete();

      case 'proxy.output':
        final channelId = msg['channelId'] as String? ?? '';
        final data = msg['data'] as String?;
        if (data != null && data.isNotEmpty) {
          _channels[channelId]?.deliverOutput(base64Decode(data));
        }

      case 'mirror.closed':
      case 'proxy.closed':
        final channelId = msg['channelId'] as String? ?? '';
        _followDesktopChannels.remove(channelId);
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
      case 'update.relay':
        if (_acceptAndroidUpdates) {
          _updateRelay = true;
          _notify();
        }
      case 'update.offer':
        if (updateRelayBinding != null && !_updateOffers.isClosed) _updateOffers.add(null);
      case 'update.push':
        if (updateRelayBinding != null && !_updatePushes.isClosed) _updatePushes.add(null);
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
    _cancelReconnect(notify: false);
    unawaited(disconnect());
    unawaited(_updateOffers.close());
    unawaited(_updatePushes.close());
    unawaited(_reconnected.close());
    super.dispose();
  }
}

final linkHostControllerProvider = Provider<LinkHostController>((ref) {
  final controller = LinkHostController(
    credentials: ref.read(linkCredentialsProvider),
    store: LinkPeerStore(ref.read(dataDirProvider)),
    bridge: ref.read(linkDesktopBridgeProvider),
    openUpdateFiles: GithubUpdateFiles.new,
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

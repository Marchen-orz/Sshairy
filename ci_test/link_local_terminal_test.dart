import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/features/connections/api.dart';
import 'package:sshairy/features/credentials/api.dart';
import 'package:sshairy/features/files/adapters/local_fs.dart';
import 'package:sshairy/features/link/api.dart';
import 'package:sshairy/foundation/cancellation.dart';
import 'package:sshairy/foundation/file_system.dart';
import 'package:sshairy/foundation/secret.dart';

class _MemoryLinkCredentials implements LinkCredentials {
  Secret? _seed;

  @override
  Future<Secret?> readIdentity() async => _seed;

  @override
  Future<void> saveIdentity(Secret seed) async => _seed = seed;

  @override
  Future<void> clearIdentity() async => _seed = null;
}

class _FakeLocalProxyShell implements LinkProxyShell {
  _FakeLocalProxyShell(this.resources);

  @override
  final LinkTerminalResources resources;
  final _stdout = StreamController<Uint8List>.broadcast();
  final _stderr = StreamController<Uint8List>.broadcast();
  final _done = Completer<void>();
  final written = <String>[];
  final resizes = <(int, int)>[];
  var closed = false;

  void emit(String text) {
    if (!closed) _stdout.add(Uint8List.fromList(utf8.encode(text)));
  }

  @override
  Stream<Uint8List> get stdout => _stdout.stream;

  @override
  Stream<Uint8List> get stderr => _stderr.stream;

  @override
  Future<void> get done => _done.future;

  @override
  void write(Uint8List data) => written.add(utf8.decode(data));

  @override
  void resize(int cols, int rows) => resizes.add((cols, rows));

  @override
  void close() {
    if (closed) return;
    closed = true;
    if (!_done.isCompleted) _done.complete();
    unawaited(_stdout.close());
    unawaited(_stderr.close());
  }
}

class _LocalDesktopBridge implements LinkDesktopBridge {
  final sessionsChangedController = StreamController<void>.broadcast();
  final hostsChangedController = StreamController<void>.broadcast();
  final approvalsChangedController = StreamController<void>.broadcast();

  final mirrorInputs = <String>[];
  final mirrorResizes = <(int, int)>[];
  var mirrorDetached = false;
  void Function(Uint8List)? _mirrorSink;
  void Function()? _mirrorOnClosed;

  final openedProxyLocalShellIds = <String>[];
  final handoffLocalShellIds = <String>[];
  final connectedSessionIds = <String>[];
  _FakeLocalProxyShell? lastLocalProxy;

  List<LinkSessionSummary> sessions = const [
    LinkSessionSummary(
      sessionId: 'local-1',
      title: 'PowerShell',
      targetLabel: 'PowerShell',
      isLocal: true,
      shellKind: 'powershell',
      status: 'connected',
      cols: 120,
      rows: 36,
    ),
    LinkSessionSummary(
      sessionId: 'local-idle',
      title: 'CMD',
      targetLabel: 'CMD',
      isLocal: true,
      shellKind: 'cmd',
      status: 'disconnected',
      cols: 100,
      rows: 30,
    ),
  ];

  List<LinkLocalShellSummary> localShells = const [
    LinkLocalShellSummary(shellId: 'powershell', name: 'PowerShell', kind: 'powershell'),
    LinkLocalShellSummary(shellId: 'cmd', name: 'CMD', kind: 'cmd'),
  ];

  void emitMirrorOutput(String text) => _mirrorSink?.call(Uint8List.fromList(utf8.encode(text)));

  void closeMirroredSession() {
    mirrorDetached = true;
    final cb = _mirrorOnClosed;
    _mirrorSink = null;
    _mirrorOnClosed = null;
    cb?.call();
  }

  LinkTerminalResources _resources(bool Function() current) => LinkTerminalResources(
    current: current,
    openFiles: (_) async => LinkFsHandle(const LocalFileSystem(), () async {}, isCurrent: current),
  );

  @override
  List<LinkSessionSummary> listSessions() => sessions;

  @override
  Stream<void> get sessionsChanged => sessionsChangedController.stream;

  @override
  MirrorAttachment? attachMirror(
    String sessionId,
    void Function(Uint8List chunk) onOutput, {
    void Function()? onClosed,
  }) {
    if (sessionId != 'local-1') return null;
    _mirrorSink = onOutput;
    _mirrorOnClosed = onClosed;
    mirrorDetached = false;
    return MirrorAttachment(
      resources: _resources(() => !mirrorDetached),
      snapshot: Uint8List.fromList(utf8.encode(r'PS C:\Users\Dev> ')),
      write: (bytes) => mirrorInputs.add(utf8.decode(bytes)),
      resize: (cols, rows) => mirrorResizes.add((cols, rows)),
      detach: () {
        mirrorDetached = true;
        _mirrorSink = null;
        _mirrorOnClosed = null;
      },
    );
  }

  @override
  List<LinkHostSummary> listHosts() => const [];

  @override
  Stream<void> get hostsChanged => hostsChangedController.stream;

  @override
  List<LinkLocalShellSummary> listLocalShells() => localShells;

  @override
  Future<ShellChannel> openProxyShell(String hostId, {required int cols, required int rows}) async =>
      throw const LinkException(LinkErrorKind.hostUnavailable);

  @override
  Future<ShellChannel> openProxyLocalShell(String shellId, {required int cols, required int rows}) async {
    openedProxyLocalShellIds.add(shellId);
    if (!localShells.any((s) => s.shellId == shellId)) {
      throw const LinkException(LinkErrorKind.hostUnavailable);
    }
    late final _FakeLocalProxyShell ch;
    ch = _FakeLocalProxyShell(_resources(() => !ch.closed));
    lastLocalProxy = ch;
    return ch;
  }

  @override
  LinkSyncBundle exportSyncBundle() => LinkSyncBundle(
    hostsLibrary: const {},
    snippets: const [],
    knownHosts: const {},
    exportedAt: DateTime.utc(2026, 11, 24),
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
  Stream<void> get approvalsChanged => approvalsChangedController.stream;

  @override
  bool decideApproval(String approvalId, bool allowed) => false;

  @override
  bool handoffHost(String hostId) => false;

  @override
  Future<bool> connectSession(String sessionId) async {
    connectedSessionIds.add(sessionId);
    return sessionId == 'local-idle';
  }

  @override
  Future<LinkSessionSummary?> handoffHostForMirror(String hostId) async => null;

  @override
  Future<LinkSessionSummary?> handoffLocalForMirror(String shellId) async {
    handoffLocalShellIds.add(shellId);
    if (shellId != 'cmd') return null;
    return const LinkSessionSummary(
      sessionId: 'local-2',
      title: 'CMD',
      targetLabel: 'CMD',
      isLocal: true,
      shellKind: 'cmd',
      status: 'connected',
      cols: 120,
      rows: 36,
    );
  }

  @override
  Future<void> receiveClipboard(String text) async {}

  @override
  Future<LinkFsHandle> openFiles(String target, CancellationToken cancel) async =>
      throw const FsError(FsFailure.unsupported);

  void dispose() {
    unawaited(sessionsChangedController.close());
    unawaited(hostsChangedController.close());
    unawaited(approvalsChangedController.close());
  }
}

class _OpenedTerminal {
  const _OpenedTerminal({
    required this.remoteId,
    required this.isMirror,
    required this.isLocal,
    required this.localShellKind,
    required this.openChannel,
  });

  final String remoteId;
  final bool isMirror;
  final bool isLocal;
  final String? localShellKind;
  final Future<ShellChannel> Function(int cols, int rows) openChannel;
}

class _RecordingMobileBridge implements LinkMobileBridge {
  final opened = <_OpenedTerminal>[];

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
  }) {
    opened.add(
      _OpenedTerminal(
        remoteId: remoteId,
        isMirror: isMirror,
        isLocal: isLocal,
        localShellKind: localShellKind,
        openChannel: openChannel,
      ),
    );
  }

  @override
  Future<LinkFsHandle> openFiles() async => LinkFsHandle(const LocalFileSystem(), () async {});
}

Future<void> _waitUntil(bool Function() predicate, {Duration timeout = const Duration(seconds: 5)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('condition not met within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  late Directory tempDir;
  late _LocalDesktopBridge desktopBridge;
  late _RecordingMobileBridge mobileBridge;
  late LinkHostController host;
  late LinkClientController client;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('sshairy_link_local_test_');
    desktopBridge = _LocalDesktopBridge();
    mobileBridge = _RecordingMobileBridge();
    host = LinkHostController(
      credentials: _MemoryLinkCredentials(),
      store: LinkPeerStore('${tempDir.path}/desktop'),
      bridge: desktopBridge,
      enableDiscovery: false,
    );
    client = LinkClientController(
      credentials: _MemoryLinkCredentials(),
      store: LinkPeerStore('${tempDir.path}/mobile'),
      bridge: mobileBridge,
    );
    await host.configure(enabled: true, port: 0, discovery: false, deviceName: 'Workstation');
    final pairing = (await host.startPairing())!;
    expect(await client.pair(host: '127.0.0.1', port: host.port, pairingCode: pairing.code), isTrue);
    await _waitUntil(() => client.desktopLocalShells.length == 2 && client.desktopSessions.length == 2);
  });

  tearDown(() async {
    await client.disconnect();
    client.dispose();
    host.dispose();
    desktopBridge.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test('mirrors desktop local terminal with coalesced output, input, resize, and clean exit', () async {
    final session = client.desktopSessions.firstWhere((s) => s.sessionId == 'local-1');
    expect(session.isLocal, isTrue);
    expect(session.shellKind, 'powershell');

    client.openMirroredSessionInWorkspace(session);
    expect(mobileBridge.opened, hasLength(1));
    final opened = mobileBridge.opened.single;
    expect(opened.isMirror, isTrue);
    expect(opened.isLocal, isTrue);
    expect(opened.localShellKind, 'powershell');

    final channel = await opened.openChannel(100, 32);
    final chunks = <String>[];
    final sub = channel.stdout.listen((bytes) => chunks.add(utf8.decode(bytes)));
    addTearDown(sub.cancel);

    await _waitUntil(() => chunks.join().contains(r'PS C:\Users\Dev> '));

    // Rapid burst should coalesce and arrive intact in order.
    desktopBridge.emitMirrorOutput('dir\r\n');
    desktopBridge.emitMirrorOutput('alpha\r\n');
    desktopBridge.emitMirrorOutput('beta\r\n');
    await _waitUntil(() => chunks.join().contains('beta\r\n'));
    expect(chunks.join(), contains('dir\r\nalpha\r\nbeta\r\n'));

    channel.write(Uint8List.fromList(utf8.encode('pwd\r')));
    // Mirrored workspace sessions default to followDesktopSize: true so mobile does not shrink desktop PTYs.
    channel.resize(90, 28);
    await _waitUntil(() => desktopBridge.mirrorInputs.contains('pwd\r'));
    expect(desktopBridge.mirrorResizes, isEmpty);

    // Desktop closing the mirrored local terminal finishes the mobile channel cleanly.
    desktopBridge.closeMirroredSession();
    await channel.done.timeout(const Duration(seconds: 3));
    expect(desktopBridge.mirrorDetached, isTrue);
  });

  test('opens proxied desktop local shell, hands off local shell for mirror, and connects idle session', () async {
    final ps = client.desktopLocalShells.firstWhere((s) => s.shellId == 'powershell');
    client.openProxiedLocalInWorkspace(ps);
    expect(mobileBridge.opened, hasLength(1));
    final opened = mobileBridge.opened.single;
    expect(opened.isMirror, isFalse);
    expect(opened.isLocal, isTrue);
    expect(opened.localShellKind, 'powershell');

    final channel = await opened.openChannel(110, 34);
    final received = StringBuffer();
    final sub = channel.stdout.listen((bytes) => received.write(utf8.decode(bytes)));
    addTearDown(sub.cancel);

    expect(desktopBridge.openedProxyLocalShellIds, ['powershell']);
    final proxy = desktopBridge.lastLocalProxy!;
    proxy.emit(r'PS D:\repo> ');
    proxy.emit('ready');
    await _waitUntil(() => received.toString().contains('ready'));

    channel.write(Uint8List.fromList(utf8.encode('ls\r')));
    channel.resize(80, 24);
    await _waitUntil(() => proxy.written.contains('ls\r'));
    await _waitUntil(() => proxy.resizes.contains((80, 24)));

    channel.close();
    await _waitUntil(() => proxy.closed);

    final mirrored = await client.openLocalOnDesktopForMirror('cmd');
    expect(desktopBridge.handoffLocalShellIds, ['cmd']);
    expect(mirrored, isNotNull);
    expect(mirrored!.sessionId, 'local-2');
    expect(mirrored.isLocal, isTrue);
    expect(mirrored.shellKind, 'cmd');

    expect(await client.connectDesktopSession('local-idle'), isTrue);
    expect(desktopBridge.connectedSessionIds, ['local-idle']);
  });

  test('ensureConnected reconnects after host restart and emits reconnected event', () async {
    final originalPort = host.port;
    var reconnectedCount = 0;
    final sub = client.reconnected.listen((_) => reconnectedCount++);
    addTearDown(sub.cancel);

    // Drop the host cleanly, verify client sees disconnect, then restart host on the same port.
    await host.configure(enabled: false, port: originalPort, discovery: false, deviceName: 'Workstation');
    await _waitUntil(() => !client.connected);

    await host.configure(enabled: true, port: originalPort, discovery: false, deviceName: 'Workstation');
    await client.ensureConnected();
    await _waitUntil(() => client.connected && client.desktopLocalShells.length == 2);

    expect(reconnectedCount, greaterThanOrEqualTo(1));
  });
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import '../../../foundation/cancellation.dart';
import '../../../foundation/file_system.dart';
import '../../../foundation/secret.dart';
import '../../credentials/api.dart';
import '../../hosts/api.dart';
import '../application/host_trust.dart';
import '../application/connection_manager.dart';
import '../domain/prompts.dart';
import '../domain/transport.dart';
import 'sftp_fs.dart';
import 'proxy.dart';
import 'tunnel.dart';

class _SshShell implements ShellChannel {
  _SshShell(this._session);

  final SSHSession _session;

  @override
  Stream<Uint8List> get stdout => _session.stdout;
  @override
  Stream<Uint8List> get stderr => _session.stderr;
  @override
  Future<void> get done => _session.done;
  @override
  void write(Uint8List data) => _session.write(data);
  @override
  void resize(int cols, int rows) => _session.resizeTerminal(cols, rows);
  @override
  void close() => _session.close();
}

class _SshTransport implements Transport {
  _SshTransport(this._client, this._releaseRoute) {
    _client.done.whenComplete(_releaseRoute).ignore();
  }

  final SSHClient _client;
  final void Function() _releaseRoute;

  /// MODULES §2: opening a channel waits at most this long; a late channel is closed when it arrives.
  static const _channelTimeout = Duration(seconds: 15);

  @override
  Future<void> get done => _client.done;
  @override
  bool get isClosed => _client.isClosed;

  @override
  Future<ShellChannel> openShell({required int cols, required int rows}) async => _SshShell(
    await _channel(
      _client.shell(
        pty: SSHPtyConfig(type: 'xterm-256color', width: cols, height: rows),
      ),
    ),
  );

  @override
  Future<FileSystem> openFiles() async {
    final opening = SftpFileSystem.open(_client);
    try {
      return await opening.timeout(_channelTimeout);
    } on TimeoutException {
      opening.then((fs) => fs.close()).ignore();
      throw const ConnectError(ConnectFailure.network, 'channel open timed out');
    } on FsError catch (e) {
      throw ConnectError(ConnectFailure.network, e.detail);
    }
  }

  @override
  Future<ExecResult> exec(String command, {int limit = 1 << 20}) async {
    final session = await _channel(_client.execute(command));
    final out = BytesBuilder(copy: false), err = BytesBuilder(copy: false);
    var truncated = false;
    void collect(BytesBuilder into, Uint8List data) {
      final room = limit - into.length;
      if (data.length > room) truncated = true;
      if (room > 0) into.add(data.length > room ? Uint8List.sublistView(data, 0, room) : data);
    }

    await Future.wait([session.stdout.forEach((d) => collect(out, d)), session.stderr.forEach((d) => collect(err, d))]);
    await session.done;
    return ExecResult(out.takeBytes(), err.takeBytes(), session.exitCode, truncated: truncated);
  }

  @override
  Future<Tunnel> connectTo(String host, int port) async {
    final opening = _client.forwardLocal(host, port);
    try {
      return SshTunnel(await opening.timeout(_channelTimeout));
    } on TimeoutException {
      opening.then((channel) => channel.destroy()).ignore();
      throw const ConnectError(ConnectFailure.network, 'channel open timed out');
    } on Object catch (e) {
      throw ConnectError(ConnectFailure.network, '$e');
    }
  }

  @override
  Future<RemoteListener> listen(String host, int port) async {
    final opening = _client.forwardRemote(host: host, port: port);
    try {
      final forward = await opening.timeout(_channelTimeout);
      if (forward == null) throw const ConnectError(ConnectFailure.network, 'forward refused');
      return SshRemoteListener(_client, forward);
    } on TimeoutException {
      opening.then<void>((f) async {
        if (f != null) await SshRemoteListener(_client, f).close();
      }).ignore();
      throw const ConnectError(ConnectFailure.network, 'forward open timed out');
    } on Object catch (e) {
      if (e is ConnectError) rethrow;
      throw ConnectError(ConnectFailure.network, '$e');
    }
  }

  Future<SSHSession> _channel(Future<SSHSession> opening) async {
    try {
      return await opening.timeout(_channelTimeout);
    } on TimeoutException {
      opening.then((s) => s.close()).ignore();
      throw const ConnectError(ConnectFailure.network, 'channel open timed out');
    }
  }

  @override
  void close() {
    _client.close();
    _releaseRoute();
  }
}

/// Dials and authenticates SSH transports for [ConnectionManager]. The host key is checked by [HostTrustService]
/// before any credential is sent.
class SshDialer {
  SshDialer(this._trust, this._secrets, this._options, this._keyById, this._jump);

  final Future<TransportLease> Function(List<Host>, ConnectPrompts, CancellationToken) _jump;

  final HostTrustService _trust;
  final ConnectionCredentials _secrets;
  final SshKey? Function(String id) _keyById;

  /// Read at each dial, so a changed setting applies to the next connection.
  final ({Duration timeout, Duration? keepAlive}) Function() _options;

  Future<Transport> dial(List<Host> route, ConnectPrompts prompts, CancellationToken cancel) async {
    final guarded = _AttemptPrompts(prompts, cancel);
    final attempt = _dial(route, guarded, prompts, cancel);
    try {
      return await Future.any([
        attempt,
        cancel.whenCancelled.then<Transport>((_) => throw const ConnectError(ConnectFailure.cancelled)),
      ]);
    } on Object {
      attempt.then((t) => t.close()).ignore();
      rethrow;
    }
  }

  Future<Transport> _dial(
    List<Host> route,
    ConnectPrompts prompts,
    ConnectPrompts routePrompts,
    CancellationToken cancel,
  ) async {
    final host = route.first;
    if (cancel.isCancelled) throw const ConnectError(ConnectFailure.cancelled);
    final remember = <SecretRef, Secret>{};
    // Methods are offered in dartssh2's fixed order: key, then password, then keyboard-interactive.
    final policy = host.policy;
    final identities = policy.usesKey ? await _loadKey(host, policy, prompts, remember) : null;
    final savedPassword = policy.usesPassword && !host.transient ? await _secrets.read(host.passwordRef) : null;
    var rejected = false, cancelled = false, passwordUsed = false;

    Future<String?> password() async {
      if (!policy.usesPassword || passwordUsed) return null;
      passwordUsed = true;
      if (savedPassword != null) return savedPassword.reveal();
      final a = await prompts.secret(
        SecretRequest(SecretKind.password, canRemember: !host.transient, target: host.target),
      );
      if (a == null) {
        cancelled = true;
        return null;
      }
      if (a.remember) remember[host.passwordRef] = a.value;
      return a.value.reveal();
    }

    final options = _options();
    final SSHSocket socket;
    TransportLease? jump;
    void releaseRoute() {
      jump?.release();
      jump = null;
    }

    try {
      if (route.length > 1) {
        // A shared jump dial has its own cancellation scope; one downstream waiter cannot cancel its prompts.
        jump = await _jump(route.sublist(1), routePrompts, cancel);
        socket = TunnelSocket(await jump!.connectTo(host.address, host.port));
      } else if (host.proxy case final proxy?) {
        socket = await connectViaProxy(
          proxy,
          host.address,
          host.port,
          timeout: options.timeout,
          cancel: cancel,
          password: () async {
            final saved = host.transient ? null : await _secrets.read(host.proxyRef);
            if (saved != null) return saved;
            final answer = await prompts.secret(
              SecretRequest(
                SecretKind.proxyPassword,
                target: '${proxy.username}@${proxy.address}:${proxy.port}',
                canRemember: !host.transient,
              ),
            );
            if (answer == null) return null;
            if (answer.remember) remember[host.proxyRef] = answer.value;
            return answer.value;
          },
        );
      } else {
        socket = await SSHSocket.connect(host.address, host.port, timeout: options.timeout);
      }
    } on Object catch (e) {
      releaseRoute();
      if (e is ConnectError) rethrow;
      throw ConnectError(ConnectFailure.network, '$e');
    }
    if (cancel.isCancelled) {
      socket.destroy();
      releaseRoute();
      throw const ConnectError(ConnectFailure.cancelled);
    }

    Future<List<String>?> challenge(SSHUserInfoRequest req) async {
      final answers = <String>[];
      for (final p in req.prompts) {
        // Servers with password login disabled often ask for the password this way.
        if (!p.echo && p.promptText.toLowerCase().contains('password') && !passwordUsed) {
          final value = await password();
          if (value != null) {
            answers.add(value);
            continue;
          }
          if (cancelled) return null;
        }
        final text = [req.instruction, p.promptText].where((s) => s.trim().isNotEmpty).join('\n');
        final a = await prompts.secret(
          SecretRequest(SecretKind.challenge, text: text, echo: p.echo, target: host.target),
        );
        if (a == null) {
          cancelled = true;
          return null;
        }
        answers.add(a.value.reveal());
      }
      return answers;
    }

    final client = SSHClient(
      socket,
      username: host.username,
      algorithms: host.legacy ? _legacyAlgorithms : const SSHAlgorithms(),
      identities: identities,
      keepAliveInterval: options.keepAlive,
      onVerifyHostKey: (type, fp) async {
        final ok = await _trust.verify(host.address, host.port, type, utf8.decode(fp), prompts);
        rejected = !ok;
        return ok;
      },
      onPasswordRequest: password,
      onUserInfoRequest: policy.allowInteractive ? challenge : null,
    );
    cancel.whenCancelled.then((_) {
      client.close();
      socket.destroy();
      releaseRoute();
    }).ignore();
    try {
      await client.authenticated.timeout(const Duration(seconds: 120));
      if (cancel.isCancelled) throw const ConnectError(ConnectFailure.cancelled);
      for (final e in remember.entries) {
        await _secrets.remember(e.key, e.value);
      }
      return _SshTransport(client, releaseRoute);
    } on Object catch (e) {
      client.close();
      socket.destroy();
      releaseRoute();
      if (cancel.isCancelled) throw const ConnectError(ConnectFailure.cancelled);
      if (rejected) throw const ConnectError(ConnectFailure.hostKeyRejected);
      if (cancelled) throw const ConnectError(ConnectFailure.cancelled);
      if (e is SSHAuthFailError) throw const ConnectError(ConnectFailure.auth);
      throw ConnectError(ConnectFailure.network, '$e');
    }
  }

  /// An imported key from the secure store, or else the key file; an imported key's passphrase is remembered
  /// with the key, so every host using it shares it.
  Future<List<SSHKeyPair>> _loadKey(
    Host host,
    AuthPolicy policy,
    ConnectPrompts prompts,
    Map<SecretRef, Secret> remember,
  ) async {
    final String pem;
    final SecretRef? passphraseRef;
    if (policy.keyId case final id?) {
      final key = _keyById(id);
      final stored = key == null ? null : await _secrets.read(key.privateRef);
      if (stored == null) throw const ConnectError(ConnectFailure.keyFile, 'key not found');
      pem = stored.reveal();
      passphraseRef = key!.passphraseRef;
    } else {
      var path = policy.keyPath ?? '';
      if (path.startsWith('~')) {
        path = (Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'] ?? '') + path.substring(1);
      }
      try {
        pem = await File(path).readAsString();
      } on Object catch (e) {
        throw ConnectError(ConnectFailure.keyFile, '$e');
      }
      passphraseRef = host.transient ? null : host.passphraseRef;
    }
    Secret? passphrase;
    final bool encrypted;
    try {
      encrypted = SSHKeyPair.isEncryptedPem(pem);
    } on Object catch (e) {
      throw ConnectError(ConnectFailure.keyFile, '$e');
    }
    if (encrypted) {
      passphrase = passphraseRef == null ? null : await _secrets.read(passphraseRef);
      if (passphrase == null) {
        final a = await prompts.secret(
          SecretRequest(SecretKind.passphrase, canRemember: passphraseRef != null, target: host.target),
        );
        if (a == null) throw const ConnectError(ConnectFailure.cancelled);
        passphrase = a.value;
        if (a.remember && passphraseRef != null) remember[passphraseRef] = a.value;
      }
    }
    try {
      return SSHKeyPair.fromPem(pem, passphrase?.reveal());
    } on Object catch (e) {
      throw ConnectError(ConnectFailure.keyFile, '$e');
    }
  }
}

final _legacyAlgorithms = SSHAlgorithms(
  kex: [...const SSHAlgorithms().kex, SSHKexType.dhGexSha1, SSHKexType.dh14Sha1, SSHKexType.dh1Sha1],
  hostkey: [...const SSHAlgorithms().hostkey, SSHHostkeyType.rsaSha1],
  cipher: [...const SSHAlgorithms().cipher, SSHCipherType.aes128cbc, SSHCipherType.aes192cbc, SSHCipherType.aes256cbc],
  mac: [...const SSHAlgorithms().mac, SSHMacType.hmacSha1],
);

class _AttemptPrompts implements ConnectPrompts {
  _AttemptPrompts(this._inner, this._cancel);
  final ConnectPrompts _inner;
  final CancellationToken _cancel;

  @override
  Future<TrustChoice> hostKey(HostKeyPrompt prompt) async {
    if (_cancel.isCancelled) return TrustChoice.reject;
    final choice = await Future.any([_inner.hostKey(prompt), _cancel.whenCancelled.then((_) => TrustChoice.reject)])
        .timeout(const Duration(seconds: 120), onTimeout: () => TrustChoice.reject);
    return _cancel.isCancelled ? TrustChoice.reject : choice;
  }

  @override
  Future<SecretAnswer?> secret(SecretRequest request) async {
    if (_cancel.isCancelled) return null;
    final answer = await Future.any([_inner.secret(request), _cancel.whenCancelled.then<SecretAnswer?>((_) => null)])
        .timeout(const Duration(seconds: 120), onTimeout: () => null);
    return _cancel.isCancelled ? null : answer;
  }
}

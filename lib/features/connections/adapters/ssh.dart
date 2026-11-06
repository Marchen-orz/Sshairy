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
import '../domain/prompts.dart';
import '../domain/transport.dart';
import 'sftp_fs.dart';

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
  _SshTransport(this._client);

  final SSHClient _client;

  /// MODULES §2: opening a channel waits at most this long; a late channel is closed when it arrives.
  static const _channelTimeout = Duration(seconds: 15);

  @override
  Future<void> get done => _client.done;
  @override
  bool get isClosed => _client.isClosed;

  @override
  Future<ShellChannel> openShell({required int cols, required int rows}) async =>
      _SshShell(await _channel(_client.shell(pty: SSHPtyConfig(type: 'xterm-256color', width: cols, height: rows))));

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

    await Future.wait([
      session.stdout.forEach((d) => collect(out, d)),
      session.stderr.forEach((d) => collect(err, d)),
    ]);
    await session.done;
    return ExecResult(out.takeBytes(), err.takeBytes(), session.exitCode, truncated: truncated);
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
  void close() => _client.close();
}

/// Dials and authenticates SSH transports for [ConnectionManager]. The host key is checked by [HostTrustService]
/// before any credential is sent.
class SshDialer {
  SshDialer(this._trust, this._secrets, this._options, this._keyById);

  final HostTrustService _trust;
  final SecretStore _secrets;
  final SshKey? Function(String id) _keyById;

  /// Read at each dial, so a changed setting applies to the next connection.
  final ({Duration timeout, Duration? keepAlive}) Function() _options;

  Future<Transport> dial(Host host, ConnectPrompts prompts, CancellationToken cancel) async {
    final remember = <String, Secret>{};
    final identities = host.auth == AuthKind.key ? await _loadKey(host, prompts, remember) : null;
    final savedPassword =
        host.auth == AuthKind.password && !host.transient ? await _secrets.read(host.passwordRef) : null;
    var rejected = false, cancelled = false, passwordUsed = false;

    Future<String?> password() async {
      if (host.auth != AuthKind.password || passwordUsed) return null;
      passwordUsed = true;
      if (savedPassword != null) return savedPassword.reveal();
      final a = await prompts.secret(SecretRequest(SecretKind.password, canRemember: !host.transient));
      if (a == null) {
        cancelled = true;
        return null;
      }
      if (a.remember) remember[host.passwordRef] = a.value;
      return a.value.reveal();
    }

    final options = _options();
    final SSHSocket socket;
    try {
      socket = await SSHSocket.connect(host.address, host.port, timeout: options.timeout);
    } on Object catch (e) {
      throw ConnectError(ConnectFailure.network, '$e');
    }
    if (cancel.isCancelled) {
      socket.destroy();
      throw const ConnectError(ConnectFailure.cancelled);
    }
    final client = SSHClient(
      socket,
      username: host.username,
      identities: identities,
      keepAliveInterval: options.keepAlive,
      onVerifyHostKey: (type, fp) async {
        final ok = await _trust.verify(host.address, host.port, type, utf8.decode(fp), prompts);
        rejected = !ok;
        return ok;
      },
      onPasswordRequest: password,
      onUserInfoRequest: (req) async {
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
          final a = await prompts.secret(SecretRequest(SecretKind.challenge, text: text, echo: p.echo));
          if (a == null) {
            cancelled = true;
            return null;
          }
          answers.add(a.value.reveal());
        }
        return answers;
      },
    );
    cancel.whenCancelled.then((_) => client.close()).ignore();
    try {
      await client.authenticated;
      if (cancel.isCancelled) throw const ConnectError(ConnectFailure.cancelled);
      for (final e in remember.entries) {
        await _secrets.write(e.key, e.value);
      }
      return _SshTransport(client);
    } on Object catch (e) {
      client.close();
      if (cancel.isCancelled) throw const ConnectError(ConnectFailure.cancelled);
      if (rejected) throw const ConnectError(ConnectFailure.hostKeyRejected);
      if (cancelled) throw const ConnectError(ConnectFailure.cancelled);
      if (e is SSHAuthFailError) throw const ConnectError(ConnectFailure.auth);
      throw ConnectError(ConnectFailure.network, '$e');
    }
  }

  /// An imported key from the secure store, or else the key file; an imported key's passphrase is remembered
  /// with the key, so every host using it shares it.
  Future<List<SSHKeyPair>> _loadKey(Host host, ConnectPrompts prompts, Map<String, Secret> remember) async {
    final String pem;
    final String? passphraseRef;
    if (host.keyId case final id?) {
      final key = _keyById(id);
      final stored = key == null ? null : await _secrets.read(key.privateRef);
      if (stored == null) throw const ConnectError(ConnectFailure.keyFile, 'key not found');
      pem = stored.reveal();
      passphraseRef = key!.passphraseRef;
    } else {
      var path = host.keyPath ?? '';
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
        final a = await prompts.secret(SecretRequest(SecretKind.passphrase, canRemember: passphraseRef != null));
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

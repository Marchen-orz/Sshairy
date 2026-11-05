import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import '../../../foundation/json_file.dart';
import '../../../foundation/secret.dart';
import '../../credentials/api.dart';
import '../../hosts/api.dart';
import '../domain/known_keys.dart';
import '../domain/prompts.dart';

class TrustStore {
  TrustStore(String dir) : _file = JsonFile('$dir/trust.json') {
    final saved = _file.read()?['keys'] as Map<String, dynamic>? ?? const {};
    keys = KnownKeys({for (final e in saved.entries) e.key: (e.value as Map<String, dynamic>).cast<String, String>()});
  }

  final JsonFile _file;
  late final KnownKeys keys;

  Future<void> trust(String endpoint, String type, String fingerprint) {
    keys.trust(endpoint, type, fingerprint);
    return _file.write({'schemaVersion': 1, 'keys': keys.entries});
  }
}

class SshShell {
  SshShell._(this._client, this._session);

  final SSHClient _client;
  final SSHSession _session;

  Stream<Uint8List> get stdout => _session.stdout;
  Stream<Uint8List> get stderr => _session.stderr;
  Future<void> get done => _session.done;
  void write(Uint8List data) => _session.write(data);
  void resize(int cols, int rows) => _session.resizeTerminal(cols, rows);

  void close() {
    _session.close();
    _client.close();
  }
}

/// shortcut: one transport per shell, no pool or leases (docs/MODULES.md §2); add when SFTP shares connections.
class Connector {
  Connector(this._trust, this._secrets);

  final TrustStore _trust;
  final SecretStore _secrets;

  Future<SshShell> open(Host host, ConnectPrompts prompts, {required int cols, required int rows}) async {
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

    final SSHSocket socket;
    try {
      socket = await SSHSocket.connect(host.address, host.port, timeout: const Duration(seconds: 20));
    } on Object catch (e) {
      throw ConnectError(ConnectFailure.network, '$e');
    }
    final client = SSHClient(
      socket,
      username: host.username,
      identities: identities,
      keepAliveInterval: const Duration(seconds: 30),
      onVerifyHostKey: (type, fp) async {
        final endpoint = KnownKeys.endpoint(host.address, host.port);
        final fingerprint = utf8.decode(fp);
        final check = _trust.keys.check(endpoint, type, fingerprint);
        if (check is KeyTrusted) return true;
        final choice = await prompts.hostKey(HostKeyPrompt(endpoint, type, fingerprint, check));
        if (choice == TrustChoice.save) await _trust.trust(endpoint, type, fingerprint);
        rejected = choice == TrustChoice.reject;
        return !rejected;
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
    try {
      await client.authenticated;
      final session = await client.shell(
        pty: SSHPtyConfig(type: 'xterm-256color', width: cols, height: rows),
      );
      for (final e in remember.entries) {
        await _secrets.write(e.key, e.value);
      }
      return SshShell._(client, session);
    } on Object catch (e) {
      client.close();
      if (rejected) throw const ConnectError(ConnectFailure.hostKeyRejected);
      if (cancelled) throw const ConnectError(ConnectFailure.cancelled);
      if (e is SSHAuthFailError) throw const ConnectError(ConnectFailure.auth);
      throw ConnectError(ConnectFailure.network, '$e');
    }
  }

  Future<List<SSHKeyPair>> _loadKey(Host host, ConnectPrompts prompts, Map<String, Secret> remember) async {
    var path = host.keyPath ?? '';
    if (path.startsWith('~')) {
      path = (Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'] ?? '') + path.substring(1);
    }
    final String pem;
    try {
      pem = await File(path).readAsString();
    } on Object catch (e) {
      throw ConnectError(ConnectFailure.keyFile, '$e');
    }
    Secret? passphrase;
    if (SSHKeyPair.isEncryptedPem(pem)) {
      passphrase = host.transient ? null : await _secrets.read(host.passphraseRef);
      if (passphrase == null) {
        final a = await prompts.secret(SecretRequest(SecretKind.passphrase, canRemember: !host.transient));
        if (a == null) throw const ConnectError(ConnectFailure.cancelled);
        passphrase = a.value;
        if (a.remember) remember[host.passphraseRef] = a.value;
      }
    }
    try {
      return SSHKeyPair.fromPem(pem, passphrase?.reveal());
    } on Object catch (e) {
      throw ConnectError(ConnectFailure.keyFile, '$e');
    }
  }
}

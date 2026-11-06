import '../../../foundation/json_file.dart';
import '../domain/known_keys.dart';
import '../domain/prompts.dart';

/// What [HostTrustService.importKeys] did with each key it was given.
class TrustImportResult {
  const TrustImportResult({this.added = 0, this.alreadyTrusted = 0, this.conflicts = const []});

  final int added, alreadyTrusted;

  /// Keys that differ from the one already saved for that endpoint and type; the saved one was kept.
  final List<({String endpoint, String type, String saved})> conflicts;
}

/// The single place host keys are judged; every path that dials (shell, SFTP, forwards, jump hops) asks it
/// before authenticating (docs/SECURITY.md). A changed key is blocked unless the user replaces it.
class HostTrustService {
  HostTrustService(String dir) : _file = JsonFile('$dir/trust.json') {
    final saved = _file.read()?['keys'] as Map<String, dynamic>? ?? const {};
    _keys = KnownKeys({for (final e in saved.entries) e.key: (e.value as Map<String, dynamic>).cast<String, String>()});
  }

  final JsonFile _file;
  late KnownKeys _keys;
  Future<void> _pending = Future.value();

  /// Endpoint → key type → fingerprint, for trust management.
  Map<String, Map<String, String>> get entries => {for (final e in _keys.entries.entries) e.key: {...e.value}};

  Future<bool> verify(String address, int port, String type, String fingerprint, ConnectPrompts prompts) async {
    type = KnownKeys.keyType(type);
    final endpoint = KnownKeys.endpoint(address, port);
    final check = _keys.check(endpoint, type, fingerprint);
    if (check is KeyTrusted) return true;
    final choice = await prompts.hostKey(HostKeyPrompt(endpoint, type, fingerprint, check));
    if (check is KeyChanged && choice != TrustChoice.save) return false;
    if (choice == TrustChoice.save) await _trust(endpoint, type, fingerprint);
    return choice != TrustChoice.reject;
  }

  Future<void> forget(String endpoint, [String? type]) => _change(() async {
    final next = _keys.copy();
    if (type == null) {
      next.entries.remove(endpoint);
    } else {
      next.entries[endpoint]?.remove(type);
      if (next.entries[endpoint]?.isEmpty ?? false) next.entries.remove(endpoint);
    }
    await _persist(next);
  });

  /// Adds keys from elsewhere (an OpenSSH known_hosts file); a saved key of the same endpoint and type is
  /// never replaced, only reported. Judged against what is saved when its turn comes, not when it was asked.
  Future<TrustImportResult> importKeys(Map<String, Map<String, String>> keys) => _change(() async {
    final next = _keys.copy();
    var added = 0, same = 0;
    final conflicts = <({String endpoint, String type, String saved})>[];
    for (final MapEntry(key: endpoint, value: types) in keys.entries) {
      for (final MapEntry(key: type, value: fingerprint) in types.entries) {
        switch (next.check(endpoint, type, fingerprint)) {
          case KeyUnknown():
            next.trust(endpoint, type, fingerprint);
            added++;
          case KeyTrusted():
            same++;
          case KeyChanged(:final saved):
            conflicts.add((endpoint: endpoint, type: KnownKeys.keyType(type), saved: saved));
        }
      }
    }
    if (added > 0) await _persist(next);
    return TrustImportResult(added: added, alreadyTrusted: same, conflicts: conflicts);
  });

  Future<int> import(Map<String, Map<String, String>> keys) async => (await importKeys(keys)).added;

  Future<void> _trust(String endpoint, String type, String fingerprint) => _change(() async {
    await _persist(_keys.copy()..trust(endpoint, type, fingerprint));
  });

  /// Runs mutations one at a time, each starting from what the previous one left.
  Future<T> _change<T>(Future<T> Function() action) {
    final next = _pending.then((_) => action());
    _pending = next.then<void>((_) {}, onError: (Object _) {});
    return next;
  }

  /// Saved first: if the write fails, the state everyone reads is still the old one.
  Future<void> _persist(KnownKeys next) async {
    await _file.write({'schemaVersion': 1, 'keys': next.entries});
    _keys = next;
  }
}

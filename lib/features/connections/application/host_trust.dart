import '../../../foundation/json_file.dart';
import '../domain/known_keys.dart';
import '../domain/prompts.dart';

/// The single place host keys are judged; every path that dials (shell, SFTP, forwards, jump hops) asks it
/// before authenticating (docs/SECURITY.md). A changed key is blocked unless the user replaces it.
class HostTrustService {
  HostTrustService(String dir) : _file = JsonFile('$dir/trust.json') {
    final saved = _file.read()?['keys'] as Map<String, dynamic>? ?? const {};
    _keys = KnownKeys({for (final e in saved.entries) e.key: (e.value as Map<String, dynamic>).cast<String, String>()});
  }

  final JsonFile _file;
  late final KnownKeys _keys;

  /// Endpoint → key type → fingerprint, for trust management.
  Map<String, Map<String, String>> get entries => {for (final e in _keys.entries.entries) e.key: {...e.value}};

  Future<bool> verify(String address, int port, String type, String fingerprint, ConnectPrompts prompts) async {
    final endpoint = KnownKeys.endpoint(address, port);
    final check = _keys.check(endpoint, type, fingerprint);
    if (check is KeyTrusted) return true;
    final choice = await prompts.hostKey(HostKeyPrompt(endpoint, type, fingerprint, check));
    if (choice == TrustChoice.save) await _trust(endpoint, type, fingerprint);
    return choice != TrustChoice.reject;
  }

  Future<void> forget(String endpoint, [String? type]) {
    if (type == null) {
      _keys.entries.remove(endpoint);
    } else {
      _keys.entries[endpoint]?.remove(type);
      if (_keys.entries[endpoint]?.isEmpty ?? false) _keys.entries.remove(endpoint);
    }
    return _save();
  }

  /// Adds keys from elsewhere (an OpenSSH known_hosts file) without replacing any the user already trusts.
  Future<int> import(Map<String, Map<String, String>> keys) {
    var added = 0;
    for (final MapEntry(key: endpoint, value: types) in keys.entries) {
      for (final MapEntry(key: type, value: fingerprint) in types.entries) {
        if (_keys.check(endpoint, type, fingerprint) is KeyUnknown) {
          _keys.trust(endpoint, type, fingerprint);
          added++;
        }
      }
    }
    return _save().then((_) => added);
  }

  Future<void> _trust(String endpoint, String type, String fingerprint) {
    _keys.trust(endpoint, type, fingerprint);
    return _save();
  }

  Future<void> _save() => _file.write({'schemaVersion': 1, 'keys': _keys.entries});
}

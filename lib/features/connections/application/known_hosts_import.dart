import '../adapters/host_key_codec.dart';
import '../domain/known_hosts.dart';
import '../domain/known_keys.dart';
import 'host_trust.dart';

typedef SavedEndpoint = ({String address, int port});

/// Imports the plain entries of an OpenSSH known_hosts file into the trust records. Reading is separate from saving:
/// [preview] changes nothing, and [commit] adds only what the preview called new, never replacing a saved key.
class KnownHostsImport {
  /// [savedEndpoints] are the addresses of saved hosts: the only names a hashed entry can be recognised by.
  KnownHostsImport(this._trust, this._savedEndpoints);

  final HostTrustService _trust;
  final List<SavedEndpoint> Function() _savedEndpoints;

  Future<KnownHostsPreview> preview(String text) async {
    final file = parseKnownHosts(text);
    final issues = [...file.issues];
    final saved = [
      for (final e in _savedEndpoints())
        (
          endpoint: KnownKeys.endpoint(e.address, e.port),
          name: HashedHostMatcher.nameFor(e.address.toLowerCase(), e.port),
        ),
    ];
    // endpoint → type → fingerprint → first line that says so
    final found = <String, Map<String, Map<String, int>>>{};
    var work = 0;
    for (final record in file.records) {
      if (++work % 256 == 0) await Future<void>.delayed(Duration.zero);
      final key = HostKeyCodec.inspect(record.keyType, record.keyData);
      if (key == null) {
        issues.add(KnownHostsIssueEntry(record.line, KnownHostsIssue.badKey, record.keyType));
        continue;
      }
      final endpoints = <String>{};
      for (final name in record.names) {
        switch (name) {
          case PlainName():
            endpoints.add(name.endpoint);
          case HashedName():
            final matched = [
              for (final s in saved)
                if (HashedHostMatcher.matches(name.salt, name.hash, s.name)) s.endpoint,
            ];
            if (matched.isEmpty) issues.add(KnownHostsIssueEntry(record.line, KnownHostsIssue.hashedUnmatched));
            endpoints.addAll(matched);
        }
      }
      for (final endpoint in endpoints) {
        ((found[endpoint] ??= {})[key.type] ??= {}).putIfAbsent(key.fingerprint, () => record.line);
      }
    }

    final trusted = KnownKeys(_trust.entries);
    final additions = <KnownHostsCandidate>[], alreadyTrusted = <KnownHostsCandidate>[];
    final conflicts = <KnownHostsConflict>[];
    for (final endpoint in found.keys.toList()..sort()) {
      for (final type in found[endpoint]!.keys.toList()..sort()) {
        final fingerprints = found[endpoint]![type]!;
        if (fingerprints.length > 1) {
          // Which of them is current cannot be told from the file, so none is taken.
          for (final MapEntry(key: fingerprint, value: line) in fingerprints.entries) {
            conflicts.add(KnownHostsConflict(line, endpoint, type, fingerprint, null));
          }
          continue;
        }
        final MapEntry(key: fingerprint, value: line) = fingerprints.entries.single;
        switch (trusted.check(endpoint, type, fingerprint)) {
          case KeyUnknown():
            additions.add(KnownHostsCandidate(line, endpoint, type, fingerprint));
          case KeyTrusted():
            alreadyTrusted.add(KnownHostsCandidate(line, endpoint, type, fingerprint));
          case KeyChanged(saved: final current):
            conflicts.add(KnownHostsConflict(line, endpoint, type, fingerprint, current));
        }
      }
    }
    issues.sort((a, b) => a.line.compareTo(b.line));
    return KnownHostsPreview(
      additions: additions,
      alreadyTrusted: alreadyTrusted,
      conflicts: conflicts,
      issues: issues,
    );
  }

  /// Saves the preview's additions. Judged again against what is saved now, so a key that was saved or changed since
  /// the preview is reported in the result instead of being overwritten.
  Future<TrustImportResult> commit(KnownHostsPreview preview) {
    final keys = <String, Map<String, String>>{};
    for (final c in preview.additions) {
      (keys[c.endpoint] ??= {})[c.type] = c.fingerprint;
    }
    return _trust.importKeys(keys);
  }
}

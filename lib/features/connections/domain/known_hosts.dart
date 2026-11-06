import 'dart:convert';

import 'known_keys.dart';

/// A larger file is refused rather than truncated.
const knownHostsMaxBytes = 2 * 1024 * 1024;

const _maxLine = 32 * 1024;
const _maxDetail = 48;

/// Key types the app can verify at connection time; others are reported instead of imported.
const knownHostsKeyTypes = {
  'ssh-ed25519',
  'ssh-rsa',
  'ecdsa-sha2-nistp256',
  'ecdsa-sha2-nistp384',
  'ecdsa-sha2-nistp521',
};

/// Why part of a known_hosts line was not imported. None of these is ever treated as trusted.
enum KnownHostsIssue { malformed, marker, wildcard, negation, keyType, badKey, hashedUnmatched }

class KnownHostsIssueEntry {
  const KnownHostsIssueEntry(this.line, this.kind, [this.detail = '']);

  final int line;
  final KnownHostsIssue kind;

  /// The marker, pattern or key type involved; part of a public file, never a secret.
  final String detail;
}

sealed class KnownHostsName {
  const KnownHostsName();
}

/// A host written out, as `host`, `[host]:port` or an unbracketed IPv6 address.
class PlainName extends KnownHostsName {
  const PlainName(this.address, this.port);

  final String address;
  final int port;

  String get endpoint => KnownKeys.endpoint(address, port);
}

/// A `|1|salt|hash` name: HMAC-SHA1 of the host, which can only be recognised, never read back.
class HashedName extends KnownHostsName {
  const HashedName(this.salt, this.hash);

  final List<int> salt, hash;
}

/// One line that names hosts and carries a key of a supported type; the key itself is not yet checked.
class KnownHostsRecord {
  const KnownHostsRecord(this.line, this.names, this.keyType, this.keyData);

  final int line;
  final List<KnownHostsName> names;
  final String keyType;

  /// The base64 text as written.
  final String keyData;
}

class KnownHostsFile {
  const KnownHostsFile(this.records, this.issues);

  final List<KnownHostsRecord> records;
  final List<KnownHostsIssueEntry> issues;
}

class KnownHostsCandidate {
  const KnownHostsCandidate(this.line, this.endpoint, this.type, this.fingerprint);

  final int line;
  final String endpoint, type, fingerprint;
}

/// A key that was not imported because it disagrees with another; [saved] is null when the file disagrees with
/// itself, so neither of its keys is taken.
class KnownHostsConflict extends KnownHostsCandidate {
  const KnownHostsConflict(super.line, super.endpoint, super.type, super.fingerprint, this.saved);

  final String? saved;
}

/// What importing a file would do, worked out before anything is saved.
class KnownHostsPreview {
  const KnownHostsPreview({
    this.additions = const [],
    this.alreadyTrusted = const [],
    this.conflicts = const [],
    this.issues = const [],
  });

  final List<KnownHostsCandidate> additions, alreadyTrusted;
  final List<KnownHostsConflict> conflicts;
  final List<KnownHostsIssueEntry> issues;
}

final _space = RegExp(r'[ \t]+');
final _hostName = RegExp(r'^[A-Za-z0-9._-]{1,255}$');
final _bareV6 = RegExp(r'^[0-9A-Fa-f:.]{2,45}$');
final _bracketed = RegExp(r'^\[([^\]]+)\]:([0-9]{1,5})$');

/// Reads the plain-text format of OpenSSH's known_hosts. Comments and blank lines are ignored; everything else is
/// either a record or an issue, so nothing is silently dropped.
KnownHostsFile parseKnownHosts(String text) {
  final records = <KnownHostsRecord>[];
  final issues = <KnownHostsIssueEntry>[];
  final lines = (text.startsWith('\uFEFF') ? text.substring(1) : text).split('\n');
  for (var i = 0; i < lines.length; i++) {
    final number = i + 1;
    void issue(KnownHostsIssue kind, [String detail = '']) => issues.add(
      KnownHostsIssueEntry(number, kind, detail.length > _maxDetail ? detail.substring(0, _maxDetail) : detail),
    );

    final raw = lines[i];
    if (raw.length > _maxLine) {
      issue(KnownHostsIssue.malformed);
      continue;
    }
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    final fields = line.split(_space);
    if (fields.first.startsWith('@')) {
      issue(KnownHostsIssue.marker, fields.first);
      continue;
    }
    if (fields.length < 3) {
      issue(KnownHostsIssue.malformed);
      continue;
    }
    final (hosts, type, data) = (fields[0], fields[1], fields[2]);
    if (!knownHostsKeyTypes.contains(type)) {
      issue(KnownHostsIssue.keyType, type);
      continue;
    }
    final names = <KnownHostsName>[];
    var malformed = false;
    if (hosts.startsWith('|')) {
      final hashed = _hashed(hosts);
      if (hashed == null) {
        issue(KnownHostsIssue.malformed);
        continue;
      }
      names.add(hashed);
    } else {
      final patterns = hosts.split(',');
      if (patterns.any((p) => p.startsWith('!'))) {
        issue(KnownHostsIssue.negation, hosts);
        continue;
      }
      for (final pattern in patterns) {
        if (pattern.contains('*') || pattern.contains('?')) {
          issue(KnownHostsIssue.wildcard, pattern);
        } else if (_plain(pattern) case final name?) {
          names.add(name);
        } else {
          malformed = true;
        }
      }
    }
    if (malformed) {
      issue(KnownHostsIssue.malformed);
    } else if (names.isNotEmpty) {
      records.add(KnownHostsRecord(number, names, type, data));
    }
  }
  return KnownHostsFile(records, issues);
}

HashedName? _hashed(String field) {
  final parts = field.split('|');
  if (parts.length != 4 || parts[1] != '1') return null;
  try {
    final (salt, hash) = (base64.decode(parts[2]), base64.decode(parts[3]));
    // HMAC-SHA1 with a salt of the same size, as ssh-keygen -H writes.
    return salt.length == 20 && hash.length == 20 ? HashedName(salt, hash) : null;
  } on FormatException {
    return null;
  }
}

bool _v6(String s) => s.split(':').length >= 3 && _bareV6.hasMatch(s);

PlainName? _plain(String pattern) {
  if (_bracketed.firstMatch(pattern) case final m?) {
    final port = int.parse(m[2]!);
    final host = m[1]!;
    if (port < 1 || port > 65535) return null;
    final valid = host.contains(':') ? _v6(host) : _hostName.hasMatch(host);
    return valid ? PlainName(host.toLowerCase(), port) : null;
  }
  if (pattern.contains(':')) return _v6(pattern) ? PlainName(pattern.toLowerCase(), 22) : null;
  return _hostName.hasMatch(pattern) ? PlainName(pattern.toLowerCase(), 22) : null;
}

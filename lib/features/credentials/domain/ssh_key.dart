enum KeySource { imported, generated }

/// Metadata of a private key kept in the secure store; the key itself is only behind [privateRef].
class SshKey {
  const SshKey({
    required this.id,
    required this.label,
    required this.algorithm,
    required this.fingerprint,
    required this.publicKey,
    required this.created,
    required this.source,
    this.encrypted = false,
  });

  final String id, label, algorithm, fingerprint;

  /// One `authorized_keys` line.
  final String publicKey;
  final DateTime created;
  final KeySource source;

  /// Stored as given, so it still needs its passphrase.
  final bool encrypted;

  String get privateRef => 'key/$id/private';
  String get passphraseRef => 'key/$id/passphrase';

  factory SshKey.fromJson(Map<String, dynamic> j) => SshKey(
        id: j['id'] as String,
        label: j['label'] as String? ?? '',
        algorithm: j['algorithm'] as String,
        fingerprint: j['fingerprint'] as String,
        publicKey: j['publicKey'] as String,
        created: DateTime.tryParse(j['created'] as String? ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0),
        source: KeySource.values.asNameMap()[j['source']] ?? KeySource.imported,
        encrypted: j['encrypted'] as bool? ?? false,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'algorithm': algorithm,
        'fingerprint': fingerprint,
        'publicKey': publicKey,
        'created': created.toUtc().toIso8601String(),
        'source': source.name,
        if (encrypted) 'encrypted': true,
      };
}

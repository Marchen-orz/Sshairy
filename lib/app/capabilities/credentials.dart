import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../foundation/result.dart';
import '../../features/capabilities/api.dart';
import '../../features/credentials/api.dart';

/// Public halves only: nothing here reads a private key or a passphrase (docs/SECURITY.md §6).
Map<String, Object?> keyDto(SshKey k) => {
  'id': k.id,
  'label': k.label,
  'algorithm': k.algorithm,
  'fingerprint': k.fingerprint,
  'publicKey': k.publicKey,
  'source': k.source.name,
  'encrypted': k.encrypted,
};

/// Importing reads files and passphrases, and deleting loses a secret, so both stay with the user's own hands.
List<Capability> keyCapabilities(Ref ref) => [
  FunctionCapability('key.list', Effect.query, (_, _) async => Ok([for (final k in ref.read(keysProvider)) keyDto(k)])),
  FunctionCapability(
    'key.generate',
    Effect.localChange,
    inputSchema: const {
      'type': 'object',
      'properties': {
        'label': {'type': 'string'},
      },
    },
    (a, _) async => Ok(keyDto(await ref.read(keysProvider.notifier).generate(a.optional<String>('label') ?? ''))),
  ),
];

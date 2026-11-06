sealed class KeyCheck {
  const KeyCheck();
}

class KeyTrusted extends KeyCheck {
  const KeyTrusted();
}

/// No saved key of this type; [others] lists saved keys of other types for the same endpoint.
class KeyUnknown extends KeyCheck {
  const KeyUnknown(this.others);
  final Map<String, String> others;
}

class KeyChanged extends KeyCheck {
  const KeyChanged(this.saved);
  final String saved;
}

/// Trusted host keys: endpoint (`host:port`) → key type → SHA256 fingerprint.
class KnownKeys {
  KnownKeys([Map<String, Map<String, String>>? entries]) : entries = entries ?? {};

  final Map<String, Map<String, String>> entries;

  KnownKeys copy() => KnownKeys({for (final e in entries.entries) e.key: {...e.value}});

  static String endpoint(String address, int port) =>
      address.contains(':') ? '[${address.toLowerCase()}]:$port' : '${address.toLowerCase()}:$port';

  KeyCheck check(String endpoint, String type, String fingerprint) {
    final saved = entries[endpoint] ?? const {};
    final matches = saved.entries.where((e) => keyType(e.key) == keyType(type));
    for (final match in matches) {
      if (match.value != fingerprint) return KeyChanged(match.value);
    }
    if (matches.isNotEmpty) return const KeyTrusted();
    return KeyUnknown(saved);
  }

  static String keyType(String type) => switch (type) {
    'rsa-sha2-256' || 'rsa-sha2-512' => 'ssh-rsa',
    _ => type,
  };

  void trust(String endpoint, String type, String fingerprint) {
    final keys = entries[endpoint] ??= {};
    keys.removeWhere((key, _) => keyType(key) == keyType(type));
    keys[keyType(type)] = fingerprint;
  }
}

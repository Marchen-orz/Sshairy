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

  static String endpoint(String address, int port) =>
      address.contains(':') ? '[${address.toLowerCase()}]:$port' : '${address.toLowerCase()}:$port';

  KeyCheck check(String endpoint, String type, String fingerprint) {
    final saved = entries[endpoint] ?? const {};
    final match = saved[type];
    if (match == fingerprint) return const KeyTrusted();
    if (match != null) return KeyChanged(match);
    return KeyUnknown(saved);
  }

  void trust(String endpoint, String type, String fingerprint) =>
      (entries[endpoint] ??= {})[type] = fingerprint;
}

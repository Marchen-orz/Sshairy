/// A local file or folder the user granted to one conversation (docs/AI.md §7.1). [root] never reaches the model.
class LocalGrant {
  const LocalGrant({
    required this.id,
    required this.root,
    required this.label,
    required this.directory,
    this.write = false,
  });

  final String id, root, label;
  final bool directory, write;

  Map<String, Object?> get description => {
    'grantId': id,
    'name': label,
    'kind': directory ? 'directory' : 'file',
    'write': write,
  };

  /// Local identity for approval bindings; not sent to the model.
  String get binding => '$id|$root|$directory|$write';
}

/// Splits a model-supplied path relative to a grant. Null refuses absolute, parent, drive or malformed paths.
List<String>? localRelativeParts(String path) {
  if (path.length > 4096 || path.startsWith('/') || path.contains('\\') || path.contains(':')) return null;
  if (RegExp(r'[\x00-\x1f\x7f]').hasMatch(path)) return null;
  final parts = path.split('/').where((part) => part.isNotEmpty && part != '.').toList();
  if (parts.any((part) => part == '..')) return null;
  return parts;
}

/// Credential and history locations stay refused even inside a granted folder.
bool localSensitivePath(List<String> parts) {
  const names = {
    '.ssh',
    '.gnupg',
    '.aws',
    '.azure',
    '.kube',
    '.docker',
    '.netrc',
    '.npmrc',
    '.pypirc',
    '.git-credentials',
    '.bash_history',
    '.zsh_history',
    '.python_history',
    '.mysql_history',
    '.psql_history',
  };
  final lower = [for (final part in parts) part.toLowerCase()];
  for (var i = 0; i < lower.length; i++) {
    final part = lower[i];
    if (names.contains(part) || part == '.env' || part.startsWith('.env.')) return true;
    if (RegExp(r'\.(?:pem|key|p12|pfx|kdbx)$').hasMatch(part)) return true;
    if (RegExp(r'^id_(?:rsa|dsa|ecdsa|ed25519)(?:\.|$)').hasMatch(part)) return true;
    if (part == '.config' && i + 1 < lower.length && const {'gcloud', 'gh', 'rclone'}.contains(lower[i + 1])) {
      return true;
    }
  }
  return false;
}

/// What a local upload always leaves out, whatever the model asks for.
const localSensitiveExcludes = [
  '.ssh',
  '.gnupg',
  '.aws',
  '.azure',
  '.kube',
  '.docker',
  '.netrc',
  '.npmrc',
  '.pypirc',
  '.git-credentials',
  '.env',
  '.env.*',
  '*.pem',
  '*.key',
  '*.p12',
  '*.pfx',
  '*.kdbx',
  'id_rsa*',
  'id_dsa*',
  'id_ecdsa*',
  'id_ed25519*',
  '.*_history',
];

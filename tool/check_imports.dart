// Enforces the dependency rules in CLAUDE.md. Usage: dart run tool/check_imports.dart
import 'dart:io';

/// Third-party packages and the only directories each may appear in.
const adapters = {
  // Credentials parses and generates keys with it; connections dials.
  'dartssh2': ['lib/features/connections/adapters/', 'lib/features/credentials/adapters/'],
  'pinenacl': ['lib/features/credentials/adapters/'],
  'crypto': [
    'lib/features/credentials/adapters/',
    'lib/features/connections/adapters/',
    'lib/features/hosts/adapters/finalshell_login.dart',
  ],
  // Read compatibility for FinalShell's legacy DES passwords only.
  'pointycastle': ['lib/features/hosts/adapters/finalshell_login.dart'],
  'xterm2': ['lib/features/terminal/adapters/'],
  'flutter_pty': ['lib/features/terminal/adapters/'],
  'flutter_svg': ['lib/features/hosts/adapters/import_source_icon.dart'],
  'flutter_secure_storage': ['lib/features/credentials/adapters/'],
  'desktop_drop': ['lib/features/files/adapters/'],
  'file_selector': [
    'lib/features/files/adapters/',
    'lib/features/hosts/adapters/',
    'lib/features/connections/adapters/',
    'lib/features/settings/adapters/',
  ],
};

final importLine = RegExp(r'''^\s*(?:import|export|part)\s+['"]([^'"]+)['"]''', multiLine: true);

List<String> checkImports(Directory lib) {
  final violations = <String>[];
  final dependencies = <String, Set<String>>{};
  final root = lib.absolute.path.replaceAll(r'\', '/');
  final files = lib.listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'));
  for (final file in files) {
    final path = 'lib/${file.absolute.path.replaceAll(r'\', '/').substring(root.length + 1)}';
    final segments = path.split('/');
    final feature = path.startsWith('lib/features/') ? segments[2] : null;
    if (feature != null) dependencies.putIfAbsent(feature, () => {});
    for (final match in importLine.allMatches(file.readAsStringSync())) {
      final target = match[1]!;
      void fail(String why) => violations.add('$path: $target ($why)');

      if (segments.contains('domain') &&
          (target.startsWith('package:') || target == 'dart:io' || target == 'dart:ui')) {
        fail('domain must not use packages, IO or Flutter');
      }
      if (target.startsWith('package:')) {
        final allowed = adapters[target.substring(8).split('/').first];
        if (allowed != null && !allowed.any(path.startsWith)) fail('only allowed in ${allowed.join(', ')}');
      }
      final Uri? resolved;
      if (target.startsWith('package:sshairy/')) {
        resolved = lib.absolute.uri.resolve(target.substring('package:sshairy/'.length));
      } else if (!target.contains(':')) {
        resolved = file.absolute.parent.uri.resolve(target);
      } else {
        resolved = null;
      }
      if (resolved == null) continue;
      final local = File.fromUri(resolved).absolute.path.replaceAll(r'\', '/');
      if (!local.startsWith('$root/')) continue;
      final relative = local.substring(root.length + 1);
      if (relative.startsWith('app/') && (feature != null || segments[1] == 'foundation' || segments[1] == 'design')) {
        fail('only the app composition layer may depend on app');
      }
      if ((path.startsWith('lib/foundation/') || path.startsWith('lib/design/')) && relative.startsWith('features/')) {
        fail('foundation and design must not depend on features');
      }
      if (!relative.startsWith('features/')) continue;
      final other = relative.substring('features/'.length).split('/');
      if (other.first == feature) continue;
      if (feature != null && feature != 'ai' && other.first == 'capabilities') {
        fail('business features must not depend on capabilities; register them in app');
      }
      if (other.length != 2 || other[1] != 'api.dart') fail('features may only import each other through api.dart');
      if (feature != null) dependencies[feature]!.add(other.first);
    }
  }
  final visited = <String>{}, active = <String>[];
  void visit(String feature) {
    if (active.contains(feature)) {
      violations.add('feature dependency cycle: ${[...active.skip(active.indexOf(feature)), feature].join(' -> ')}');
      return;
    }
    if (!visited.add(feature)) return;
    active.add(feature);
    for (final dependency in dependencies[feature] ?? const <String>{}) {
      visit(dependency);
    }
    active.removeLast();
  }

  for (final feature in dependencies.keys) {
    visit(feature);
  }
  return violations;
}

void main() {
  final violations = checkImports(Directory('lib'));
  violations.forEach(print);
  if (violations.isNotEmpty) exit(1);
  print('imports ok');
}

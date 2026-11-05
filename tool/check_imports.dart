// Enforces the dependency rules in CLAUDE.md. Usage: dart run tool/check_imports.dart
import 'dart:io';

/// Third-party packages and the only directory each may appear in.
const adapters = {
  'dartssh2': 'lib/features/connections/adapters/',
  'xterm2': 'lib/features/terminal/adapters/',
  'flutter_pty': 'lib/features/terminal/adapters/',
  'flutter_secure_storage': 'lib/features/credentials/adapters/',
};

final importLine = RegExp(r'''^\s*(?:import|export)\s+['"]([^'"]+)['"]''', multiLine: true);

void main() {
  final violations = <String>[];
  final files = Directory('lib')
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'));
  for (final file in files) {
    final path = file.path.replaceAll(r'\', '/');
    final segments = path.split('/');
    final feature = path.startsWith('lib/features/') ? segments[2] : null;
    for (final match in importLine.allMatches(file.readAsStringSync())) {
      final target = match[1]!;
      void fail(String why) => violations.add('$path: $target ($why)');

      if (segments.contains('domain') && (target.startsWith('package:') || target == 'dart:io')) {
        fail('domain must not use packages or IO');
      }
      if (target.startsWith('package:')) {
        final allowed = adapters[target.substring(8).split('/').first];
        if (allowed != null && !path.startsWith(allowed)) fail('only allowed in $allowed');
      }
      if (!target.contains(':')) {
        final resolved = file.parent.uri.resolve(target).path;
        final parts = resolved.split('/lib/features/');
        if (parts.length < 2) continue;
        final other = parts.last.split('/');
        final internal = other.length != 2 || other[1] != 'api.dart';
        if (other.first != feature && internal) fail('features may only import each other through api.dart');
      }
    }
  }
  violations.forEach(print);
  if (violations.isNotEmpty) exit(1);
  print('imports ok');
}

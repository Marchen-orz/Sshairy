import 'dart:convert';
import 'dart:io';

/// Includes build dependencies as well as runtime packages; never silently omits a license.
Future<void> main(List<String> args) async {
  if (args.length != 1) {
    stderr.writeln('Usage: dart run tool/write_notices.dart <output-file>');
    exitCode = 64;
    return;
  }
  final config = File('.dart_tool/package_config.json').absolute;
  final data = jsonDecode(await config.readAsString()) as Map<String, dynamic>;
  final packages = (data['packages'] as List).cast<Map<String, dynamic>>()
    ..sort((a, b) => (a['name'] as String).compareTo(b['name'] as String));
  final text = StringBuffer(
    'sshairy — third-party notices\n\n'
    'This inventory includes resolved runtime and build dependencies.\n'
    'These licenses apply to their respective components, not to sshairy as a whole.\n',
  );
  final missing = <String>[];
  for (final package in packages) {
    if (package['name'] == 'sshairy') continue;
    final root = Directory.fromUri(config.uri.resolve(package['rootUri'] as String));
    var licenses = await _licenses(root);
    // Flutter SDK packages share the SDK's root license.
    if (licenses.isEmpty &&
        [
          'flutter',
          'flutter_localizations',
          'flutter_test',
          'integration_test',
          'flutter_driver',
          'flutter_web_plugins',
          'fuchsia_remote_debug_protocol',
        ].contains(package['name'])) {
      licenses = await _licenses(root.parent.parent);
    }
    if (licenses.isEmpty) {
      missing.add(package['name'] as String);
      continue;
    }
    final pubspec = File.fromUri(root.uri.resolve('pubspec.yaml'));
    final version = pubspec.existsSync()
        ? RegExp(r'^version:\s*(.+)$', multiLine: true).firstMatch(await pubspec.readAsString())?.group(1) ?? 'SDK'
        : 'SDK';
    text.writeln('\n${'=' * 72}\n${package['name']} $version\n${'=' * 72}\n');
    for (final file in licenses) {
      text.writeln(await file.readAsString());
    }
  }
  // Bundled data rather than a Dart package: upstream Fig completion specs, license text kept verbatim.
  final completionLicense = File('assets/completions/LICENSE');
  if (completionLicense.existsSync()) {
    text.writeln('\n${'=' * 72}\nwithfig/autocomplete (bundled completion data)\n${'=' * 72}\n');
    text.writeln(
      'Upstream package.json declares ISC while its LICENSE file is the MIT text below; reproduced as published.\n',
    );
    text.writeln(await completionLicense.readAsString());
  } else {
    missing.add('assets/completions');
  }
  if (missing.isNotEmpty) {
    stderr.writeln('Missing license text: ${missing.join(', ')}');
    exitCode = 1;
    return;
  }
  final output = File(args.single);
  await output.parent.create(recursive: true);
  await output.writeAsString(text.toString(), flush: true);
  stdout.writeln('Wrote notices for ${packages.length - 1} packages.');
}

Future<List<File>> _licenses(Directory root) async {
  final files = <File>[];
  await for (final entry in root.list()) {
    if (entry is! File) continue;
    final name = entry.uri.pathSegments.last.toUpperCase();
    if (RegExp(r'^(LICENSE|LICENCE|COPYING|NOTICE)(\..+)?$').hasMatch(name)) files.add(entry);
  }
  files.sort((a, b) => a.path.compareTo(b.path));
  return files;
}

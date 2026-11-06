import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tool/check_imports.dart';

void main() {
  late Directory dir;
  late Directory lib;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('sshairy-imports-');
    lib = Directory('${dir.path}/lib')..createSync();
  });
  tearDown(() => dir.deleteSync(recursive: true));

  void source(String path, String text) {
    final file = File('${lib.path}/$path');
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(text);
  }

  test('app registrations may depend on capabilities and feature APIs', () {
    source(
      'app/capabilities/hosts.dart',
      "import '../../features/capabilities/api.dart';\nimport '../../features/hosts/api.dart';",
    );
    source('features/capabilities/api.dart', "export 'domain/capability.dart';");
    source('features/capabilities/domain/capability.dart', 'class Capability {}');
    source('features/hosts/api.dart', "export 'application/hosts.dart';");
    source('features/hosts/application/hosts.dart', 'class Hosts {}');
    expect(checkImports(lib), isEmpty);
  });

  test('a feature cannot depend on capabilities through relative or package imports', () {
    source('features/hosts/application/register.dart', "import '../../capabilities/api.dart';");
    source('features/settings/register.dart', "import 'package:sshairy/features/capabilities/api.dart';");
    final errors = checkImports(lib);
    expect(errors.length, 2);
    expect(errors.every((e) => e.contains('business features must not depend on capabilities')), isTrue);
  });

  test('a feature cannot reach capability registrations through app', () {
    source('features/hosts/api.dart', "export '../../app/capabilities/hosts.dart';");
    source('features/workspace/presentation/page.dart', "import 'package:sshairy/app/capabilities/workspace.dart';");
    final errors = checkImports(lib);
    expect(errors.length, 2);
    expect(errors.every((e) => e.contains('only the app composition layer may depend on app')), isTrue);
  });

  test('cross-feature internals and cycles remain rejected', () {
    source('features/hosts/api.dart', "import '../credentials/application/keys.dart';");
    source('features/credentials/application/keys.dart', "import '../../hosts/api.dart';");
    final errors = checkImports(lib);
    expect(errors.any((e) => e.contains('through api.dart')), isTrue);
    expect(errors.any((e) => e.contains('feature dependency cycle')), isTrue);
  });
}

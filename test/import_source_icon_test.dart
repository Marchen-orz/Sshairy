import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/design/theme.dart';
import 'package:sshairy/features/hosts/adapters/import_source_icon.dart';
import 'package:sshairy/features/hosts/domain/host_import.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('every bundled import source SVG compiles without external resources', () async {
    for (final format in ImportFormat.values) {
      final bytes = await SvgAssetLoader('assets/import_sources/${format.name}.svg').loadBytes(null);
      expect(bytes.lengthInBytes, greaterThan(0), reason: format.name);
    }
  });

  for (final brightness in Brightness.values) {
    testWidgets('import source marks render at tile size in ${brightness.name}', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(brightness),
          home: Scaffold(body: Row(children: [for (final format in ImportFormat.values) ImportSourceIcon(format)])),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(SvgPicture), findsNWidgets(ImportFormat.values.length));
      for (final element in find.byType(ImportSourceIcon).evaluate()) {
        expect(tester.getSize(find.byWidget(element.widget)), const Size(28, 28));
      }
      expect(tester.takeException(), isNull);
    });
  }
}

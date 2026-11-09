import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/design/theme.dart';
import 'package:sshairy/features/hosts/api.dart';
import 'package:sshairy/features/settings/adapters/background_images.dart';
import 'package:sshairy/features/settings/application/background_images.dart';
import 'package:sshairy/features/settings/domain/background.dart';
import 'package:sshairy/features/settings/presentation/background_image.dart';
import 'package:sshairy/features/settings/settings.dart';
import 'package:sshairy/features/workspace/presentation/workspace_page.dart';
import 'package:sshairy/foundation/data_dir.dart';
import 'package:sshairy/l10n/app_localizations.dart';

class _TestAssets extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async => key == 'AssetManifest.bin'
      ? const StandardMessageCodec().encodeMessage(<String, Object?>{})!
      : ByteData.sublistView(File(key).readAsBytesSync());
}

Future<Uint8List> _png() async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawColor(const Color(0xff000000), BlendMode.src);
  final picture = recorder.endRecording();
  final image = await picture.toImage(8, 8);
  final data = (await image.toByteData(format: ui.ImageByteFormat.png))!;
  return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
}

void main() {
  testWidgets('app background preview pixels', (tester) async {
    final dir = Directory.systemTemp.createTempSync('probe-');
    File('${dir.path}/hosts.json').writeAsStringSync(
      jsonEncode({
        'schemaVersion': 1,
        'hosts': [
          {'id': 'h1', 'label': 'one', 'address': 'example.com', 'port': 22, 'username': 'u', 'auth': 'password'},
        ],
      }),
    );
    final source = File('${dir.path}/source.png');
    await tester.runAsync(() async => source.writeAsBytes(await _png()));
    final store = BackgroundImageStore('${dir.path}/owned', pick: () async => source.path);
    final container = ProviderContainer(
      overrides: [dataDirProvider.overrideWithValue(dir.path), backgroundImageStoreProvider.overrideWithValue(store)],
    );
    final key = GlobalKey();
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: DefaultAssetBundle(
          bundle: _TestAssets(),
          child: MaterialApp(
            theme: buildTheme(Brightness.light),
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: RepaintBoundary(key: key, child: WorkspacePage(openPalette: (_) async {})),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    late BackgroundImages images;
    await tester.runAsync(() async {
      images = container.read(backgroundImagesProvider.notifier);
      await images.choose(BackgroundSlot.app);
    });
    await tester.pumpAndSettle();

    Future<int> pixel(double dx, double dy) async {
      final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      return (await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 1);
        final data = (await image.toByteData())!;
        final x = (dx * 1200).round(), y = (dy * 800).round();
        final offset = (y * 1200 + x) * 4;
        final value = (data.getUint8(offset) << 16) | (data.getUint8(offset + 1) << 8) | data.getUint8(offset + 2);
        image.dispose();
        return value;
      }))!;
    }

    // A point in the content area below the host cards, on blank app background.
    const dx = .7, dy = .9;
    debugPrint('setup  ${await pixel(dx, dy).then((v) => v.toRadixString(16))}');
    images.previewOpacity(BackgroundSlot.app, .9);
    await tester.pumpAndSettle();
    debugPrint('preview ${await pixel(dx, dy).then((v) => v.toRadixString(16))}');

    // Now the same through the settings slider drag.
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    final sliders = find.byType(Slider);
    debugPrint('sliders ${sliders.evaluate().length}');
    final appSlider = find.descendant(
      of: find.byType(BackgroundImageControls).first,
      matching: find.byType(Slider),
    );
    await tester.runAsync(() => images.saveOpacity(BackgroundSlot.app, .15));
    await tester.pumpAndSettle();
    debugPrint('reset  ${await pixel(dx, dy).then((v) => v.toRadixString(16))}');
    final gesture = await tester.startGesture(tester.getCenter(appSlider));
    await gesture.moveBy(const Offset(60, 0));
    await tester.pump();
    debugPrint('drag   ${await pixel(dx, dy).then((v) => v.toRadixString(16))}');
    await gesture.up();
    await tester.pumpAndSettle();
    debugPrint('up     ${await pixel(dx, dy).then((v) => v.toRadixString(16))}');
    container.dispose();
    await tester.runAsync(() async => Future<void>.delayed(const Duration(milliseconds: 50)));
  });
}

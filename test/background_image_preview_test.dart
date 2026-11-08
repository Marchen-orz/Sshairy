import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/design/theme.dart';
import 'package:sshairy/features/settings/adapters/background_images.dart';
import 'package:sshairy/features/settings/application/background_images.dart';
import 'package:sshairy/features/settings/domain/background.dart';
import 'package:sshairy/features/settings/presentation/background_image.dart';
import 'package:sshairy/features/settings/settings.dart';
import 'package:sshairy/foundation/data_dir.dart';
import 'package:sshairy/l10n/app_localizations.dart';

Future<Uint8List> _blackImage() async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawColor(Colors.black, BlendMode.src);
  final picture = recorder.endRecording();
  final image = await picture.toImage(8, 8);
  try {
    final data = (await image.toByteData(format: ui.ImageByteFormat.png))!;
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  } finally {
    image.dispose();
    picture.dispose();
  }
}

void main() {
  testWidgets('app background repaints while the opacity slider is held and saves on release', (tester) async {
    final dir = Directory.systemTemp.createTempSync('sshairy-background-preview-');
    final source = File('${dir.path}/source.png');
    await tester.runAsync(() async => source.writeAsBytes(await _blackImage()));
    final store = BackgroundImageStore('${dir.path}/owned', pick: () async => source.path);
    final container = ProviderContainer(
      overrides: [dataDirProvider.overrideWithValue(dir.path), backgroundImageStoreProvider.overrideWithValue(store)],
    );
    late BackgroundImages images;
    await tester.runAsync(() async {
      container.read(settingsProvider);
      images = container.read(backgroundImagesProvider.notifier);
      await images.choose(BackgroundSlot.app);
      final loaded = Completer<void>();
      final stream = FileImage(store.file(container.read(settingsProvider).get(SettingKeys.appBackgroundImage))!)
          .resolve(ImageConfiguration.empty);
      final listener = ImageStreamListener((image, _) {
        image.dispose();
        loaded.complete();
      }, onError: (Object error, StackTrace? stack) => loaded.completeError(error, stack));
      stream.addListener(listener);
      try {
        await loaded.future.timeout(const Duration(seconds: 5));
      } finally {
        stream.removeListener(listener);
      }
    });
    final boundaryKey = GlobalKey();
    Future<int> red() async {
      final boundary = boundaryKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      return (await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 1);
        try {
          return (await image.toByteData())!.getUint8(0);
        } finally {
          image.dispose();
        }
      }))!;
    }

    try {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: buildTheme(Brightness.light),
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: Column(
                children: [
                  SizedBox(
                    width: 320,
                    height: 180,
                    child: RepaintBoundary(
                      key: boundaryKey,
                      child: const BackgroundImageView(slot: BackgroundSlot.app, baseColor: Colors.white),
                    ),
                  ),
                  const SizedBox(width: 320, child: BackgroundImageControls(slot: BackgroundSlot.app)),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(await red(), closeTo(217, 2));
      final slider = find.byType(Slider);
      final gesture = await tester.startGesture(tester.getCenter(slider));
      await gesture.moveBy(const Offset(70, 0));
      await tester.pump();
      final preview = container.read(backgroundImagesProvider)[BackgroundSlot.app]!;
      expect(preview, greaterThan(.6));
      expect(container.read(settingsProvider).get(SettingKeys.appBackgroundOpacity), .15);
      expect(await red(), closeTo(255 * (1 - preview), 2), reason: 'the image must repaint before pointer up');
      await gesture.up();
      for (var i = 0; i < 100 && container.read(backgroundImagesProvider).containsKey(BackgroundSlot.app); i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump();
      }
      expect(container.read(backgroundImagesProvider), isEmpty);
      expect(container.read(settingsProvider).get(SettingKeys.appBackgroundOpacity), preview);
      expect(await red(), closeTo(255 * (1 - preview), 2));
      final restored = ProviderContainer(overrides: [dataDirProvider.overrideWithValue(dir.path)]);
      try {
        expect(restored.read(settingsProvider).get(SettingKeys.appBackgroundOpacity), preview);
      } finally {
        restored.dispose();
      }
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose();
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        dir.deleteSync(recursive: true);
      });
    }
  });
}

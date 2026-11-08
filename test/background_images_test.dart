import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/features/settings/adapters/background_images.dart';
import 'package:sshairy/features/settings/application/background_images.dart';
import 'package:sshairy/features/settings/domain/background.dart';
import 'package:sshairy/features/settings/presentation/background_image.dart';
import 'package:sshairy/features/settings/settings.dart';
import 'package:sshairy/foundation/data_dir.dart';
import 'package:sshairy/foundation/result.dart';

Future<Uint8List> _png(int width, int height) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawColor(const Color(0xff3688aa), BlendMode.src);
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  try {
    final data = (await image.toByteData(format: ui.ImageByteFormat.png))!;
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  } finally {
    image.dispose();
    picture.dispose();
  }
}

class _FailedSettings extends SettingsNotifier {
  @override
  Future<Result<void>> patch(Map<String, Object?> raw, {bool exposedOnly = false, int? expectedRevision}) async =>
      const Err(AppError('writeFailed'));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('PNG import owns a normalized copy and cleanup preserves sources and retained images', (tester) async {
    await tester.runAsync(() async {
      final dir = Directory.systemTemp.createTempSync('sshairy-background-');
      try {
        final source = File('${dir.path}/source.png');
        final bytes = await _png(32, 16);
        await source.writeAsBytes(bytes);
        final store = BackgroundImageStore('${dir.path}/owned');
        final first = await store.importFile(source.path, {});
        expect(first, isA<Ok<String>>());
        final firstId = (first as Ok<String>).value;
        expect(validBackgroundImageId(firstId), isTrue);
        expect(firstId, isNot(contains(source.path)));
        expect(store.file(firstId), isNotNull);
        expect(store.file('../source.png'), isNull);
        expect(await source.readAsBytes(), bytes);

        final second = await store.importFile(source.path, {firstId});
        expect(second, isA<Ok<String>>());
        final secondId = (second as Ok<String>).value;
        expect(secondId, isNot(firstId));
        final unrelated = File('${store.directory}/notes.txt')..writeAsStringSync('keep');
        await store.cleanup({secondId});
        expect(store.file(firstId), isNull);
        expect(store.file(secondId), isNotNull);
        expect(unrelated.existsSync(), isTrue);
        expect(await source.readAsBytes(), bytes);
        await store.delete('../source.png');
        expect(source.existsSync(), isTrue);
      } finally {
        dir.deleteSync(recursive: true);
      }
    });
  });

  testWidgets('large PNG is downsampled before storing within both decoded limits', (tester) async {
    await tester.runAsync(() async {
      final dir = Directory.systemTemp.createTempSync('sshairy-background-');
      try {
        final source = File('${dir.path}/large.png');
        await source.writeAsBytes(await _png(3000, 1500));
        final store = BackgroundImageStore('${dir.path}/owned');
        final result = await store.importFile(source.path, {});
        expect(result, isA<Ok<String>>());
        final stored = store.file((result as Ok<String>).value)!;
        final buffer = await ui.ImmutableBuffer.fromUint8List(await stored.readAsBytes());
        final descriptor = await ui.ImageDescriptor.encoded(buffer);
        try {
          expect(descriptor.width, lessThanOrEqualTo(BackgroundImageLimits.longestSide));
          expect(descriptor.height, lessThanOrEqualTo(BackgroundImageLimits.longestSide));
          expect(descriptor.width * descriptor.height, lessThanOrEqualTo(BackgroundImageLimits.decodedPixels));
          expect(descriptor.width / descriptor.height, closeTo(2, .01));
          expect(await stored.length(), lessThanOrEqualTo(BackgroundImageLimits.storedBytes));
        } finally {
          descriptor.dispose();
          buffer.dispose();
        }
      } finally {
        dir.deleteSync(recursive: true);
      }
    });
  });

  testWidgets('cancel and invalid input keep existing settings and image', (tester) async {
    await tester.runAsync(() async {
      final dir = Directory.systemTemp.createTempSync('sshairy-background-');
      final bad = File('${dir.path}/not-an-image.png')..writeAsStringSync('not a PNG');
      String? picked;
      final store = BackgroundImageStore('${dir.path}/owned', pick: () async => picked);
      final container = ProviderContainer(
        overrides: [dataDirProvider.overrideWithValue(dir.path), backgroundImageStoreProvider.overrideWithValue(store)],
      );
      try {
        final source = File('${dir.path}/source.png');
        await source.writeAsBytes(await _png(8, 8));
        picked = source.path;
        final images = container.read(backgroundImagesProvider.notifier);
        expect(await images.choose(BackgroundSlot.app), isA<Ok<void>>());
        final original = container.read(settingsProvider).get(SettingKeys.appBackgroundImage);
        picked = null;
        expect(await images.choose(BackgroundSlot.app), isNull);
        picked = bad.path;
        expect(await images.choose(BackgroundSlot.app), isA<Err<void>>());
        expect(container.read(settingsProvider).get(SettingKeys.appBackgroundImage), original);
        expect(store.file(original), isNotNull);
        expect(Directory(store.directory).listSync().whereType<File>(), hasLength(1));
      } finally {
        container.dispose();
        dir.deleteSync(recursive: true);
      }
    });
  });

  testWidgets('each slot resets independently and opacity preview writes only on save', (tester) async {
    await tester.runAsync(() async {
      final dir = Directory.systemTemp.createTempSync('sshairy-background-');
      final source = File('${dir.path}/source.png');
      await source.writeAsBytes(await _png(8, 8));
      final store = BackgroundImageStore('${dir.path}/owned', pick: () async => source.path);
      final container = ProviderContainer(
        overrides: [dataDirProvider.overrideWithValue(dir.path), backgroundImageStoreProvider.overrideWithValue(store)],
      );
      try {
        final images = container.read(backgroundImagesProvider.notifier);
        expect(await images.choose(BackgroundSlot.app), isA<Ok<void>>());
        expect(await images.choose(BackgroundSlot.terminal), isA<Ok<void>>());
        final before = container.read(settingsProvider);
        final appId = before.get(SettingKeys.appBackgroundImage);
        final terminalId = before.get(SettingKeys.terminalBackgroundImage);
        final config = File('${dir.path}/settings.json');
        final persistedBefore = await config.readAsString();
        images.previewOpacity(BackgroundSlot.app, .7);
        expect(container.read(backgroundImagesProvider)[BackgroundSlot.app], .7);
        expect(container.read(settingsProvider).get(SettingKeys.appBackgroundOpacity), BackgroundImageLimits.opacity);
        expect(await config.readAsString(), persistedBefore);
        expect(await images.saveOpacity(BackgroundSlot.app, .7), isA<Ok<void>>());
        expect(container.read(backgroundImagesProvider), isEmpty);
        expect(container.read(settingsProvider).get(SettingKeys.appBackgroundOpacity), .7);
        expect((jsonDecode(await config.readAsString()) as Map)['appBackgroundOpacity'], .7);
        expect(await images.saveOpacity(BackgroundSlot.terminal, .4), isA<Ok<void>>());
        expect(await images.reset(BackgroundSlot.app), isA<Ok<void>>());
        final reset = container.read(settingsProvider);
        expect(reset.get(SettingKeys.appBackgroundImage), isNull);
        expect(reset.get(SettingKeys.appBackgroundOpacity), BackgroundImageLimits.opacity);
        expect(reset.get(SettingKeys.terminalBackgroundImage), terminalId);
        expect(reset.get(SettingKeys.terminalBackgroundOpacity), .4);
        expect(store.file(appId), isNull);
        expect(store.file(terminalId), isNotNull);
        expect(source.existsSync(), isTrue);
      } finally {
        container.dispose();
        dir.deleteSync(recursive: true);
      }
    });
  });

  testWidgets('failed settings commit discards the newly imported managed copy', (tester) async {
    await tester.runAsync(() async {
      final dir = Directory.systemTemp.createTempSync('sshairy-background-');
      final source = File('${dir.path}/source.png');
      await source.writeAsBytes(await _png(8, 8));
      final store = BackgroundImageStore('${dir.path}/owned', pick: () async => source.path);
      final container = ProviderContainer(
        overrides: [
          dataDirProvider.overrideWithValue(dir.path),
          backgroundImageStoreProvider.overrideWithValue(store),
          settingsProvider.overrideWith(_FailedSettings.new),
        ],
      );
      try {
        expect(await container.read(backgroundImagesProvider.notifier).choose(BackgroundSlot.app), isA<Err<void>>());
        expect(container.read(settingsProvider).get(SettingKeys.appBackgroundImage), isNull);
        expect(Directory(store.directory).listSync(), isEmpty);
        expect(source.existsSync(), isTrue);
      } finally {
        container.dispose();
        dir.deleteSync(recursive: true);
      }
    });
  });

  testWidgets('missing image falls back to the opaque base without decoding', (tester) async {
    final dir = Directory.systemTemp.createTempSync('sshairy-background-');
    final container = ProviderContainer(overrides: [dataDirProvider.overrideWithValue(dir.path)]);
    try {
      await tester.runAsync(
        () => container
            .read(settingsProvider.notifier)
            .set(SettingKeys.appBackgroundImage, 'bg-1234-0123456789abcdef.png'),
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: SizedBox.expand(
              child: BackgroundImageView(slot: BackgroundSlot.app, baseColor: Color(0xff123456)),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(Image), findsNothing);
      final base = tester.widget<ColoredBox>(
        find.descendant(of: find.byType(BackgroundImageView), matching: find.byType(ColoredBox)),
      );
      expect(base.color, const Color(0xff123456));
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose();
      dir.deleteSync(recursive: true);
    }
  });
}

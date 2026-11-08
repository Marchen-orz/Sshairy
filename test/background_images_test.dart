import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/design/theme.dart';
import 'package:sshairy/features/settings/adapters/background_images.dart';
import 'package:sshairy/features/settings/application/background_images.dart';
import 'package:sshairy/features/settings/domain/background.dart';
import 'package:sshairy/features/settings/presentation/background_image.dart';
import 'package:sshairy/features/settings/settings.dart';
import 'package:sshairy/foundation/data_dir.dart';
import 'package:sshairy/foundation/result.dart';
import 'package:sshairy/l10n/app_localizations.dart';

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

var _failWrites = false;

/// Writes fail while [_failWrites] is set, as a full disk would.
class _FlakySettings extends SettingsNotifier {
  @override
  Future<Result<void>> patch(Map<String, Object?> raw, {bool exposedOnly = false, int? expectedRevision}) async {
    if (_failWrites) throw const FileSystemException('disk full');
    return super.patch(raw, exposedOnly: exposedOnly, expectedRevision: expectedRevision);
  }
}

/// Cannot delete files, as when another process holds them.
class _StubbornStore extends BackgroundImageStore {
  _StubbornStore(super.directory, {super.pick});

  @override
  Future<void> delete(String id) async => throw FileSystemException('locked', id);
}

class _Picker {
  _Picker(this.path);

  String? path;
  var calls = 0;

  Future<String?> call() async {
    calls++;
    return path;
  }
}

String _fakeId(int n) => 'bg-${n.toRadixString(16)}-0123456789abcdef.png';

Matcher _errCode(String code) => isA<Err<void>>().having((r) => r.error.code, 'code', code);

/// A data directory with one importable source image, a store that picks it, and the providers on top.
class _Env {
  _Env._(this.dir, this.source, this.picker, this.store, this.container);

  final Directory dir;
  final File source;
  final _Picker picker;
  final BackgroundImageStore store;
  final ProviderContainer container;

  static Future<_Env> create({bool flaky = false, bool stubborn = false}) async {
    _failWrites = false;
    final dir = Directory.systemTemp.createTempSync('sshairy-gallery-');
    final source = File('${dir.path}/source.png');
    await source.writeAsBytes(await _png(8, 8));
    final picker = _Picker(source.path);
    final owned = '${dir.path}/backgrounds';
    final store = stubborn ? _StubbornStore(owned, pick: picker.call) : BackgroundImageStore(owned, pick: picker.call);
    final container = ProviderContainer(
      overrides: [
        dataDirProvider.overrideWithValue(dir.path),
        backgroundImageStoreProvider.overrideWithValue(store),
        if (flaky) settingsProvider.overrideWith(_FlakySettings.new),
      ],
    );
    return _Env._(dir, source, picker, store, container);
  }

  BackgroundImages get images => container.read(backgroundImagesProvider.notifier);
  Settings get settings => container.read(settingsProvider);
  List<String> get gallery => container.read(backgroundGalleryProvider);
  String? selected(BackgroundSlot slot) => settings.get(imageSetting(slot));
  List<String> get saved => settings.get(SettingKeys.backgroundGallery);

  /// Rewrites the saved list and leaves the slots alone, as settings from before the gallery existed would be.
  Future<void> setSaved(List<String> ids) =>
      container.read(settingsProvider.notifier).set(SettingKeys.backgroundGallery, ids);

  Set<String> get files => {
    for (final file in Directory(store.directory).listSync().whereType<File>()) file.uri.pathSegments.last,
  };

  /// Imports the source image and selects it for [slot].
  Future<String> import(BackgroundSlot slot) async {
    expect(await images.choose(slot), isA<Ok<void>>());
    return selected(slot)!;
  }

  /// Puts files and a saved gallery in place as if earlier sessions had imported them.
  Future<void> seed(List<String> ids, {int bytes = 1, List<String>? listed}) async {
    Directory(store.directory).createSync(recursive: true);
    for (final id in ids) {
      File('${store.directory}/$id').writeAsBytesSync(Uint8List(bytes));
    }
    await container.read(settingsProvider.notifier).set(SettingKeys.backgroundGallery, listed ?? ids);
  }

  /// A new process reading the same data directory.
  ProviderContainer restart() => ProviderContainer(overrides: [dataDirProvider.overrideWithValue(dir.path)]);

  void dispose() {
    container.dispose();
    dir.deleteSync(recursive: true);
  }
}

void _galleryTest(String name, Future<void> Function(_Env env) body, {bool flaky = false, bool stubborn = false}) =>
    testWidgets(name, (tester) async {
      await tester.runAsync(() async {
        final env = await _Env.create(flaky: flaky, stubborn: stubborn);
        try {
          await body(env);
        } finally {
          env.dispose();
        }
      });
    });

/// `x` is the only saved image; the app slot shows `a` and the terminal slot `t`, which only the slots name.
Future<({String x, String a, String t})> _unlisted(_Env env) async {
  final x = await env.import(BackgroundSlot.app);
  final a = await env.import(BackgroundSlot.app);
  final t = await env.import(BackgroundSlot.terminal);
  await env.setSaved([x]);
  expect(env.gallery, [x, a, t]);
  return (x: x, a: a, t: t);
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

  testWidgets('each slot resets independently, keeps its saved image, and opacity previews write only on save', (
    tester,
  ) async {
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
        expect(store.file(appId), isNotNull);
        expect(store.file(terminalId), isNotNull);
        expect(container.read(backgroundGalleryProvider), [terminalId, appId]);
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

  test('gallery setting accepts only bounded, unique, valid identifiers', () {
    const gallery = SettingKeys.backgroundGallery;
    final full = [for (var i = 0; i < BackgroundImageLimits.galleryItems; i++) _fakeId(i)];
    expect(gallery.accepts(const <Object?>[]), isTrue);
    expect(gallery.accepts([_fakeId(1), _fakeId(2)]), isTrue);
    expect(gallery.accepts(full), isTrue);
    expect(gallery.accepts([...full, _fakeId(99)]), isFalse);
    expect(gallery.accepts([_fakeId(1), _fakeId(1)]), isFalse);
    expect(gallery.accepts(['../source.png']), isFalse);
    expect(gallery.accepts(['C:/Users/me/picture.png']), isFalse);
    expect(gallery.accepts([_fakeId(1), null]), isFalse);
    expect(gallery.accepts(null), isFalse);
    expect(gallery.accepts(_fakeId(1)), isFalse);
    expect(gallery.agentExposed, isFalse);
    expect(gallery.defaultValue, isEmpty);
    expect(gallery.schema['maxItems'], BackgroundImageLimits.galleryItems);

    final id = _fakeId(7);
    final settings = Settings.fromJson({
      'backgroundGallery': [id],
    });
    expect(settings.get(gallery), [id]);
    expect(Settings.fromJson(settings.toJson()).get(gallery), [id]);
    expect(
      Settings.fromJson({
        'backgroundGallery': ['../source.png'],
      }).get(gallery),
      isEmpty,
    );
    expect(
      Settings.fromJson({
        'backgroundGallery': [id, id],
      }).get(gallery),
      isEmpty,
    );
  });

  test('gallery setting is all or nothing in a patch and closed to the agent', () async {
    final dir = Directory.systemTemp.createTempSync('sshairy-background-');
    final container = ProviderContainer(overrides: [dataDirProvider.overrideWithValue(dir.path)]);
    try {
      final settings = container.read(settingsProvider.notifier);
      final id = _fakeId(3);
      expect(
        await settings.patch({
          'backgroundGallery': [id],
        }, exposedOnly: true),
        _errCode('unknownSetting'),
      );
      expect(
        await settings.patch({
          'backgroundGallery': [id, id],
        }),
        _errCode('invalidArgument'),
      );
      expect(
        await settings.patch({
          'backgroundGallery': [id],
          'appBackgroundImage': '../source.png',
        }),
        _errCode('invalidArgument'),
      );
      expect(container.read(settingsProvider).get(SettingKeys.backgroundGallery), isEmpty);
      expect(
        await settings.patch({
          'backgroundGallery': [id],
          'appBackgroundImage': id,
        }),
        isA<Ok<void>>(),
      );
      expect(container.read(settingsProvider).get(SettingKeys.backgroundGallery), [id]);
    } finally {
      container.dispose();
      dir.deleteSync(recursive: true);
    }
  });

  _galleryTest('imported images stay in the gallery across switching and restart', (env) async {
    final first = await env.import(BackgroundSlot.app);
    final second = await env.import(BackgroundSlot.terminal);
    final third = await env.import(BackgroundSlot.app);
    expect({first, second, third}, hasLength(3));
    expect(env.gallery, [third, second, first]);

    expect(await env.images.saveOpacity(BackgroundSlot.app, .5), isA<Ok<void>>());
    expect(await env.images.select(BackgroundSlot.app, first), isA<Ok<void>>());
    expect(await env.images.select(BackgroundSlot.terminal, first), isA<Ok<void>>());
    expect(env.selected(BackgroundSlot.app), first);
    expect(env.selected(BackgroundSlot.terminal), first);
    expect(env.settings.get(SettingKeys.appBackgroundOpacity), .5);
    expect(await env.images.select(BackgroundSlot.app, first), isA<Ok<void>>(), reason: 'already selected');
    expect(env.gallery, [third, second, first]);
    expect(env.files, {first, second, third});
    expect(env.source.existsSync(), isTrue);

    final restarted = env.restart();
    try {
      final settings = restarted.read(settingsProvider);
      expect(settings.get(SettingKeys.backgroundGallery), [third, second, first]);
      expect(settings.get(SettingKeys.appBackgroundImage), first);
      expect(settings.get(SettingKeys.terminalBackgroundImage), first);
      expect(settings.get(SettingKeys.appBackgroundOpacity), .5);
      expect(restarted.read(backgroundGalleryProvider), [third, second, first]);
      for (final id in [first, second, third]) {
        expect(env.store.file(id), isNotNull);
      }
    } finally {
      restarted.dispose();
    }
  });

  _galleryTest('selecting an unknown or unreadable image changes nothing', (env) async {
    final first = await env.import(BackgroundSlot.app);
    final second = await env.import(BackgroundSlot.terminal);
    File('${env.store.directory}/$second').deleteSync();
    expect(await env.images.select(BackgroundSlot.app, second), _errCode('backgroundImageUnreadable'));
    expect(await env.images.select(BackgroundSlot.app, _fakeId(5)), _errCode('invalidArgument'));
    expect(await env.images.select(BackgroundSlot.app, '../source.png'), _errCode('invalidArgument'));
    expect(env.selected(BackgroundSlot.app), first);
    expect(env.gallery, [second, first]);

    expect(await env.images.remove(second), isA<Ok<void>>(), reason: 'a dangling entry can still be removed');
    expect(env.gallery, [first]);
    expect(env.selected(BackgroundSlot.terminal), isNull);
  });

  _galleryTest('restore default clears the selection and opacity but keeps the saved image', (env) async {
    final appId = await env.import(BackgroundSlot.app);
    final terminalId = await env.import(BackgroundSlot.terminal);
    expect(await env.images.saveOpacity(BackgroundSlot.app, .7), isA<Ok<void>>());
    expect(await env.images.saveOpacity(BackgroundSlot.terminal, .4), isA<Ok<void>>());
    env.images.previewOpacity(BackgroundSlot.app, .9);

    expect(await env.images.reset(BackgroundSlot.app), isA<Ok<void>>());
    expect(env.selected(BackgroundSlot.app), isNull);
    expect(env.settings.get(SettingKeys.appBackgroundOpacity), BackgroundImageLimits.opacity);
    expect(env.container.read(backgroundImagesProvider), isEmpty);
    expect(env.selected(BackgroundSlot.terminal), terminalId);
    expect(env.settings.get(SettingKeys.terminalBackgroundOpacity), .4);
    expect(env.gallery, [terminalId, appId]);
    expect(env.files, {appId, terminalId});

    expect(await env.images.select(BackgroundSlot.app, appId), isA<Ok<void>>());
    expect(env.selected(BackgroundSlot.app), appId);
    expect(env.settings.get(SettingKeys.appBackgroundOpacity), BackgroundImageLimits.opacity);

    final restarted = env.restart();
    try {
      final settings = restarted.read(settingsProvider);
      expect(settings.get(SettingKeys.backgroundGallery), [terminalId, appId]);
      expect(settings.get(SettingKeys.appBackgroundImage), appId);
      expect(settings.get(SettingKeys.terminalBackgroundOpacity), .4);
    } finally {
      restarted.dispose();
    }
  });

  _galleryTest('removing an image deletes it and clears every slot that shows it', (env) async {
    final shared = await env.import(BackgroundSlot.app);
    expect(await env.images.select(BackgroundSlot.terminal, shared), isA<Ok<void>>());
    final other = await env.import(BackgroundSlot.app);
    expect(await env.images.saveOpacity(BackgroundSlot.terminal, .4), isA<Ok<void>>());

    expect(await env.images.remove(shared), isA<Ok<void>>());
    expect(env.gallery, [other]);
    expect(env.selected(BackgroundSlot.app), other);
    expect(env.selected(BackgroundSlot.terminal), isNull);
    expect(env.settings.get(SettingKeys.terminalBackgroundOpacity), .4, reason: 'opacity is not a selection');
    expect(env.files, {other});

    expect(await env.images.remove(other), isA<Ok<void>>());
    expect(env.gallery, isEmpty);
    expect(env.selected(BackgroundSlot.app), isNull);
    expect(env.files, isEmpty);
    expect(await env.images.remove(other), isA<Ok<void>>(), reason: 'removing twice is harmless');
    expect(await env.images.remove('../source.png'), _errCode('invalidArgument'));
    expect(env.source.existsSync(), isTrue);

    final restarted = env.restart();
    try {
      final settings = restarted.read(settingsProvider);
      expect(settings.get(SettingKeys.backgroundGallery), isEmpty);
      expect(settings.get(SettingKeys.appBackgroundImage), isNull);
      expect(settings.get(SettingKeys.terminalBackgroundImage), isNull);
    } finally {
      restarted.dispose();
    }
  });

  _galleryTest('failed commits leave gallery, selection and files unchanged', (env) async {
    final first = await env.import(BackgroundSlot.app);
    final second = await env.import(BackgroundSlot.terminal);
    void expectUnchanged() {
      expect(env.gallery, [second, first]);
      expect(env.selected(BackgroundSlot.app), first);
      expect(env.selected(BackgroundSlot.terminal), second);
      expect(env.files, {first, second});
    }

    _failWrites = true;
    expect(await env.images.remove(first), _errCode('backgroundImageSaveFailed'));
    expect(await env.images.select(BackgroundSlot.app, second), _errCode('backgroundImageSaveFailed'));
    expect(await env.images.reset(BackgroundSlot.terminal), _errCode('backgroundImageSaveFailed'));
    expect(await env.images.choose(BackgroundSlot.app), _errCode('backgroundImageSaveFailed'));
    expectUnchanged();

    _failWrites = false;
    expect(await env.images.remove(first), isA<Ok<void>>());
    expect(env.gallery, [second]);
    expect(env.selected(BackgroundSlot.app), isNull);
    expect(env.files, {second});
  }, flaky: true);

  _galleryTest('a failed file delete after a committed removal leaves an orphan the next import reclaims', (env) async {
    final first = await env.import(BackgroundSlot.app);
    expect(await env.images.remove(first), isA<Ok<void>>());
    expect(env.gallery, isEmpty);
    expect(env.selected(BackgroundSlot.app), isNull);
    expect(env.files, {first});

    final second = await env.import(BackgroundSlot.app);
    expect(env.files, {second});
    expect(env.gallery, [second]);
  }, stubborn: true);

  _galleryTest('a full gallery refuses imports without opening the picker or evicting', (env) async {
    final ids = [for (var i = 0; i < BackgroundImageLimits.galleryItems; i++) _fakeId(i)];
    await env.seed(ids);

    expect(await env.images.choose(BackgroundSlot.app), _errCode('backgroundGalleryFull'));
    expect(env.picker.calls, 0);
    expect(env.gallery, ids);
    expect(env.files, ids.toSet());
    expect(env.selected(BackgroundSlot.app), isNull);

    expect(await env.images.select(BackgroundSlot.terminal, ids[3]), isA<Ok<void>>());
    expect(await env.images.remove(ids.last), isA<Ok<void>>());
    final added = await env.import(BackgroundSlot.app);
    expect(env.picker.calls, 1);
    expect(env.gallery, [added, ...ids.take(ids.length - 1)]);
    expect(env.gallery, hasLength(BackgroundImageLimits.galleryItems));
    expect(env.files, {added, ...ids.take(ids.length - 1)});
  });

  _galleryTest('a full store refuses an import and keeps every saved image', (env) async {
    final big = _fakeId(1);
    await env.seed([big], bytes: BackgroundImageLimits.totalBytes);

    expect(await env.images.choose(BackgroundSlot.app), _errCode('backgroundGalleryFull'));
    expect(env.picker.calls, 1);
    expect(env.gallery, [big]);
    expect(env.files, {big});
    expect(env.selected(BackgroundSlot.app), isNull);
  });

  _galleryTest('unreferenced copies are reclaimed before the capacity check', (env) async {
    final orphan = _fakeId(2);
    await env.seed([orphan], bytes: BackgroundImageLimits.totalBytes, listed: const []);
    expect(env.gallery, isEmpty);

    final id = await env.import(BackgroundSlot.app);
    expect(env.files, {id});
    expect(env.gallery, [id]);
  });

  _galleryTest('a selection the gallery does not list is still shown, kept and then saved', (env) async {
    final legacy = await env.import(BackgroundSlot.app);
    // Settings written before the gallery existed name the image only through the slot.
    await env.container.read(settingsProvider.notifier).set(SettingKeys.backgroundGallery, const <String>[]);
    final stray = File('${env.store.directory}/${_fakeId(9)}')..writeAsBytesSync([1]);
    expect(env.gallery, [legacy]);

    final next = await env.import(BackgroundSlot.terminal);
    expect(env.settings.get(SettingKeys.backgroundGallery), [next, legacy]);
    expect(env.files, {legacy, next});
    expect(stray.existsSync(), isFalse);
    expect(env.selected(BackgroundSlot.app), legacy);
  });

  _galleryTest('restore default keeps an image that only the slot named', (env) async {
    final (:x, :a, :t) = await _unlisted(env);

    expect(await env.images.reset(BackgroundSlot.app), isA<Ok<void>>());
    expect(env.selected(BackgroundSlot.app), isNull);
    expect(env.selected(BackgroundSlot.terminal), t);
    expect(env.saved, [x, a, t]);
    expect(env.files, {x, a, t});

    expect(await env.images.reset(BackgroundSlot.terminal), isA<Ok<void>>());
    expect(env.saved, [x, a, t]);
    expect(env.files, {x, a, t});

    final restarted = env.restart();
    try {
      expect(restarted.read(backgroundGalleryProvider), [x, a, t]);
    } finally {
      restarted.dispose();
    }
    final added = await env.import(BackgroundSlot.app);
    expect(env.files, {x, a, t, added}, reason: 'cleanup keeps what the gallery lists');
  });

  _galleryTest('switching away from an image that only the slot named keeps it', (env) async {
    final (:x, :a, :t) = await _unlisted(env);

    expect(await env.images.select(BackgroundSlot.app, x), isA<Ok<void>>());
    expect(env.selected(BackgroundSlot.app), x);
    expect(env.selected(BackgroundSlot.terminal), t);
    expect(env.saved, [x, a, t]);
    expect(env.files, {x, a, t});

    expect(await env.images.select(BackgroundSlot.terminal, a), isA<Ok<void>>());
    expect(env.saved, [x, a, t]);
    expect(env.files, {x, a, t});

    final restarted = env.restart();
    try {
      final settings = restarted.read(settingsProvider);
      expect(restarted.read(backgroundGalleryProvider), [x, a, t]);
      expect(settings.get(SettingKeys.appBackgroundImage), x);
      expect(settings.get(SettingKeys.terminalBackgroundImage), a);
    } finally {
      restarted.dispose();
    }
  });

  _galleryTest('importing over an image that only the slot named keeps it', (env) async {
    final (:x, :a, :t) = await _unlisted(env);

    final added = await env.import(BackgroundSlot.app);
    expect(env.saved, [added, x, a, t]);
    expect(env.selected(BackgroundSlot.terminal), t);
    expect(env.files, {x, a, t, added});
  });

  _galleryTest('removing one image keeps every other, including those only a slot names', (env) async {
    final (:x, :a, :t) = await _unlisted(env);

    expect(await env.images.remove(a), isA<Ok<void>>());
    expect(env.selected(BackgroundSlot.app), isNull);
    expect(env.selected(BackgroundSlot.terminal), t);
    expect(env.saved, [x]);
    expect(env.gallery, [x, t]);
    expect(env.files, {x, t});

    expect(await env.images.remove(x), isA<Ok<void>>());
    expect(env.gallery, [t]);
    expect(env.files, {t});

    final restarted = env.restart();
    try {
      expect(restarted.read(backgroundGalleryProvider), [t]);
    } finally {
      restarted.dispose();
    }
  });

  _galleryTest('a full gallery plus an image only a slot names refuses what would orphan it', (env) async {
    final ids = [for (var i = 0; i < BackgroundImageLimits.galleryItems; i++) _fakeId(i)];
    await env.seed(ids);
    final unlisted = _fakeId(100);
    File('${env.store.directory}/$unlisted').writeAsBytesSync([1]);
    await env.container.read(settingsProvider.notifier).set(SettingKeys.appBackgroundImage, unlisted);
    expect(env.gallery, [...ids, unlisted]);

    void expectUnchanged() {
      expect(env.saved, ids);
      expect(env.selected(BackgroundSlot.app), unlisted);
      expect(env.files, {...ids, unlisted});
    }

    expect(await env.images.reset(BackgroundSlot.app), _errCode('backgroundGalleryFull'));
    expect(await env.images.select(BackgroundSlot.app, ids[0]), _errCode('backgroundGalleryFull'));
    expect(await env.images.choose(BackgroundSlot.app), _errCode('backgroundGalleryFull'));
    expect(env.picker.calls, 0);
    expectUnchanged();

    expect(await env.images.select(BackgroundSlot.terminal, ids[1]), isA<Ok<void>>(), reason: 'orphans nothing');
    expect(env.selected(BackgroundSlot.terminal), ids[1]);
    expectUnchanged();

    expect(await env.images.remove(ids.last), isA<Ok<void>>());
    expect(await env.images.reset(BackgroundSlot.app), isA<Ok<void>>(), reason: 'there is room now');
    expect(env.selected(BackgroundSlot.app), isNull);
    expect(env.saved, [...ids.take(ids.length - 1), unlisted]);
    expect(env.files, {...ids.take(ids.length - 1), unlisted});
  });

  _galleryTest('removing the image only a slot names clears a full gallery', (env) async {
    final ids = [for (var i = 0; i < BackgroundImageLimits.galleryItems; i++) _fakeId(i)];
    await env.seed(ids);
    final unlisted = _fakeId(100);
    File('${env.store.directory}/$unlisted').writeAsBytesSync([1]);
    await env.container.read(settingsProvider.notifier).set(SettingKeys.appBackgroundImage, unlisted);

    expect(await env.images.remove(unlisted), isA<Ok<void>>());
    expect(env.selected(BackgroundSlot.app), isNull);
    expect(env.saved, ids);
    expect(env.files, ids.toSet());
  });

  testWidgets('thumbnails switch only the tapped slot and removal clears the slots showing it', (tester) async {
    late _Env env;
    late String first, second;
    await tester.runAsync(() async {
      env = await _Env.create();
      first = await env.import(BackgroundSlot.app);
      second = await env.import(BackgroundSlot.terminal);
    });
    Finder tile(String id, BackgroundSlot slot) => find.byKey(ValueKey(id)).at(slot.index);
    Future<void> settle(bool Function() done) async {
      for (var i = 0; i < 300 && !done(); i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump();
      }
      expect(done(), isTrue);
      // Let the controls leave their busy state before the next tap.
      for (var i = 0; i < 3; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump();
      }
    }

    try {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: env.container,
          child: MaterialApp(
            theme: buildTheme(Brightness.light),
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const Scaffold(
              body: SizedBox(
                width: 400,
                child: Column(
                  children: [
                    BackgroundImageControls(slot: BackgroundSlot.app),
                    BackgroundImageControls(slot: BackgroundSlot.terminal),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byKey(ValueKey(first)), findsNWidgets(2));
      expect(find.byKey(ValueKey(second)), findsNWidgets(2));

      await tester.tap(tile(second, BackgroundSlot.app));
      await settle(() => env.selected(BackgroundSlot.app) == second);
      expect(env.selected(BackgroundSlot.terminal), second);

      await tester.tap(tile(first, BackgroundSlot.terminal));
      await settle(() => env.selected(BackgroundSlot.terminal) == first);
      expect(env.selected(BackgroundSlot.app), second);
      expect(env.files, {first, second});

      await tester.tap(find.descendant(of: tile(second, BackgroundSlot.app), matching: find.byType(IconButton)));
      await settle(() => env.gallery.length == 1);
      expect(env.selected(BackgroundSlot.app), isNull);
      expect(env.selected(BackgroundSlot.terminal), first);
      expect(env.files, {first});
      expect(find.byKey(ValueKey(second)), findsNothing);
      expect(find.byKey(ValueKey(first)), findsNWidgets(2));
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        env.dispose();
      });
    }
  });
}

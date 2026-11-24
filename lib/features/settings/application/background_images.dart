import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../foundation/data_dir.dart';
import '../../../foundation/result.dart';
import '../adapters/background_images.dart';
import '../domain/background.dart';
import '../settings.dart';

final backgroundImageStoreProvider = Provider<BackgroundImageStore>(
  (ref) => BackgroundImageStore('${ref.watch(dataDirProvider)}/backgrounds'),
);

final backgroundImagesProvider = NotifierProvider<BackgroundImages, Map<BackgroundSlot, double>>(BackgroundImages.new);

/// What the picker shows and what cleanup keeps: saved images plus anything a slot still selects.
final backgroundGalleryProvider = Provider<List<String>>((ref) {
  final saved = ref.watch(settingsProvider.select((s) => s.get(SettingKeys.backgroundGallery)));
  final app = ref.watch(settingsProvider.select((s) => s.get(SettingKeys.appBackgroundImage)));
  final terminal = ref.watch(settingsProvider.select((s) => s.get(SettingKeys.terminalBackgroundImage)));
  return backgroundGallery(saved, [app, terminal]);
});

BackgroundImageSetting imageSetting(BackgroundSlot slot) => switch (slot) {
  BackgroundSlot.app => SettingKeys.appBackgroundImage,
  BackgroundSlot.terminal => SettingKeys.terminalBackgroundImage,
};

DoubleSetting imageOpacitySetting(BackgroundSlot slot) => switch (slot) {
  BackgroundSlot.app => SettingKeys.appBackgroundOpacity,
  BackgroundSlot.terminal => SettingKeys.terminalBackgroundOpacity,
};

/// Owns gallery and selection changes; transient opacity previews never enter settings.json.
/// Saved images are only ever deleted by [remove] or when an import never commits.
class BackgroundImages extends Notifier<Map<BackgroundSlot, double>> {
  Future<void> _pending = Future.value();
  var _disposed = false;

  @override
  Map<BackgroundSlot, double> build() {
    ref.onDispose(() => _disposed = true);
    return const {};
  }

  Future<Result<void>?> _enqueue(Future<Result<void>?> Function() operation) {
    final next = _pending.then((_) => _disposed ? null : operation());
    _pending = next.then<void>((_) {}).catchError((Object _) {});
    return next;
  }

  Future<Result<void>> _commit(Map<String, Object?> values) async {
    try {
      return await ref.read(settingsProvider.notifier).patch(values);
    } on Object {
      return const Err(AppError('backgroundImageSaveFailed'));
    }
  }

  /// Commits slot selections. An image that only a slot names (settings from before the gallery, or an older snapshot)
  /// is written into the saved list first, so replacing the selection cannot orphan it; with no room for that the
  /// change is refused rather than evicting a saved image.
  Future<Result<void>> _changeSlots(
    Map<BackgroundSlot, String?> changes, [
    Map<String, Object?> more = const {},
  ]) async {
    final settings = ref.read(settingsProvider);
    final listed = ref.read(backgroundGalleryProvider);
    final after = backgroundGallery(settings.get(SettingKeys.backgroundGallery), [
      for (final slot in BackgroundSlot.values)
        changes.containsKey(slot) ? changes[slot] : settings.get(imageSetting(slot)),
    ]);
    final orphans = listed.any((id) => !after.contains(id));
    if (orphans && listed.length > BackgroundImageLimits.galleryItems) {
      return const Err(AppError('backgroundGalleryFull'));
    }
    return _commit({
      ...more,
      for (final MapEntry(:key, :value) in changes.entries) imageSetting(key).key: value,
      if (orphans) SettingKeys.backgroundGallery.key: listed,
    });
  }

  /// Imports a picked or dropped file into the gallery and selects it for [slot], or null when the picker was
  /// cancelled.
  Future<Result<void>?> choose(BackgroundSlot slot, {String? path}) => _enqueue(() async {
    if (ref.read(backgroundGalleryProvider).length >= BackgroundImageLimits.galleryItems) {
      return const Err(AppError('backgroundGalleryFull'));
    }
    final store = ref.read(backgroundImageStoreProvider);
    final picked = await store.choose(() => ref.read(backgroundGalleryProvider).toSet(), path: path);
    if (picked == null) return null;
    if (picked case Err(:final error)) return Err(error);
    final id = (picked as Ok<String>).value;
    if (_disposed) {
      await _discard(store, id);
      return null;
    }
    final result = await _commit({
      SettingKeys.backgroundGallery.key: [id, ...ref.read(backgroundGalleryProvider)],
      imageSetting(slot).key: id,
    });
    if (result case Err()) await _discard(store, id);
    return result;
  });

  /// Switches [slot] to a saved image; its opacity and the other slot stay as they are.
  Future<Result<void>?> select(BackgroundSlot slot, String id) => _enqueue(() async {
    if (!ref.read(backgroundGalleryProvider).contains(id)) return const Err(AppError('invalidArgument'));
    if (ref.read(settingsProvider).get(imageSetting(slot)) == id) return const Ok(null);
    if (ref.read(backgroundImageStoreProvider).file(id) == null) {
      return const Err(AppError('backgroundImageUnreadable'));
    }
    return _changeSlots({slot: id});
  });

  /// Clears the selection and restores the default opacity; the image stays in the gallery.
  Future<Result<void>?> reset(BackgroundSlot slot) => _enqueue(() async {
    final result = await _changeSlots({slot: null}, {imageOpacitySetting(slot).key: BackgroundImageLimits.opacity});
    if (result case Ok()) cancelPreview(slot);
    return result;
  });

  /// Deletes a saved image: one commit drops it from the gallery and from every slot showing it, then the file goes.
  /// A failed commit changes nothing; a failed delete leaves an unreferenced file the next import reclaims.
  Future<Result<void>?> remove(String id) => _enqueue(() async {
    if (!validBackgroundImageId(id)) return const Err(AppError('invalidArgument'));
    final settings = ref.read(settingsProvider);
    final saved = settings.get(SettingKeys.backgroundGallery);
    final selecting = [
      for (final slot in BackgroundSlot.values)
        if (settings.get(imageSetting(slot)) == id) slot,
    ];
    if (saved.contains(id) || selecting.isNotEmpty) {
      final result = await _commit({
        SettingKeys.backgroundGallery.key: [
          for (final other in saved)
            if (other != id) other,
        ],
        for (final slot in selecting) imageSetting(slot).key: null,
      });
      if (result case Err()) return result;
    }
    await _discard(ref.read(backgroundImageStoreProvider), id);
    return const Ok(null);
  });

  void previewOpacity(BackgroundSlot slot, double value) {
    if (!_disposed && value.isFinite) state = {...state, slot: value.clamp(0.0, 1.0)};
  }

  void cancelPreview(BackgroundSlot slot) {
    if (!_disposed && state.containsKey(slot)) state = {...state}..remove(slot);
  }

  Future<Result<void>?> saveOpacity(BackgroundSlot slot, double value) => _enqueue(() async {
    try {
      if (!imageOpacitySetting(slot).accepts(value)) return const Err(AppError('invalidArgument'));
      await ref.read(settingsProvider.notifier).set(imageOpacitySetting(slot), value);
      return const Ok(null);
    } on Object {
      return const Err(AppError('backgroundImageSaveFailed'));
    } finally {
      cancelPreview(slot);
    }
  });

  Future<void> _discard(BackgroundImageStore store, String id) async {
    try {
      await store.delete(id);
    } on Object {
      // A later import can reclaim this unreferenced copy.
    }
  }
}

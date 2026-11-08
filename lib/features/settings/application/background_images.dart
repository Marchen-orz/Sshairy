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

BackgroundImageSetting imageSetting(BackgroundSlot slot) => switch (slot) {
  BackgroundSlot.app => SettingKeys.appBackgroundImage,
  BackgroundSlot.terminal => SettingKeys.terminalBackgroundImage,
};

DoubleSetting imageOpacitySetting(BackgroundSlot slot) => switch (slot) {
  BackgroundSlot.app => SettingKeys.appBackgroundOpacity,
  BackgroundSlot.terminal => SettingKeys.terminalBackgroundOpacity,
};

/// Owns image changes; transient opacity previews never enter settings.json.
class BackgroundImages extends Notifier<Map<BackgroundSlot, double>> {
  Future<void> _pending = Future.value();
  var _disposed = false;

  @override
  Map<BackgroundSlot, double> build() {
    ref.onDispose(() => _disposed = true);
    return const {};
  }

  Set<String> _retained() {
    final settings = ref.read(settingsProvider);
    return {for (final slot in BackgroundSlot.values) ?settings.get(imageSetting(slot))};
  }

  Future<Result<void>?> _enqueue(Future<Result<void>?> Function() operation) {
    final next = _pending.then((_) => _disposed ? null : operation());
    _pending = next.then<void>((_) {}).catchError((Object _) {});
    return next;
  }

  Future<Result<void>?> choose(BackgroundSlot slot) => _enqueue(() async {
    final store = ref.read(backgroundImageStoreProvider);
    final picked = await store.choose(_retained());
    if (picked == null) return null;
    if (picked case Err(:final error)) return Err(error);
    final id = (picked as Ok<String>).value;
    if (_disposed) {
      await _discard(store, id);
      return null;
    }
    try {
      final result = await ref.read(settingsProvider.notifier).patch({imageSetting(slot).key: id});
      if (result case Err()) {
        await _discard(store, id);
        return result;
      }
    } on Object {
      await _discard(store, id);
      return const Err(AppError('backgroundImageSaveFailed'));
    }
    await _cleanup(store);
    return const Ok(null);
  });

  Future<Result<void>?> reset(BackgroundSlot slot) => _enqueue(() async {
    final store = ref.read(backgroundImageStoreProvider);
    try {
      final result = await ref.read(settingsProvider.notifier).patch({
        imageSetting(slot).key: null,
        imageOpacitySetting(slot).key: BackgroundImageLimits.opacity,
      });
      if (result case Err()) return result;
      state = {...state}..remove(slot);
    } on Object {
      return const Err(AppError('backgroundImageSaveFailed'));
    }
    await _cleanup(store);
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

  Future<void> _cleanup(BackgroundImageStore store) async {
    if (_disposed) return;
    try {
      await store.cleanup(_retained());
    } on Object {
      // Cleanup failure does not undo an already committed setting.
    }
  }

  Future<void> _discard(BackgroundImageStore store, String id) async {
    try {
      await store.delete(id);
    } on Object {
      // A later operation can reclaim this unreferenced copy.
    }
  }
}

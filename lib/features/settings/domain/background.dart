enum BackgroundSlot { app, terminal }

abstract final class BackgroundImageLimits {
  static const inputBytes = 16 * 1024 * 1024;
  static const sourcePixels = 40000000;
  static const decodedPixels = 2 * 1024 * 1024;
  static const longestSide = 2048;
  static const storedBytes = 8 * 1024 * 1024;
  static const totalBytes = 32 * 1024 * 1024;
  static const galleryItems = 24;
  static const opacity = .15;
}

const backgroundImageIdPattern = r'^bg-[0-9a-f]{1,16}-[0-9a-f]{16}\.png$';
final _imageId = RegExp(backgroundImageIdPattern);
bool validBackgroundImageId(Object? value) => value is String && _imageId.hasMatch(value);

/// The saved images in display order, then slot selections the saved list does not name: settings written before
/// the gallery existed, or restored from an older snapshot.
List<String> backgroundGallery(Iterable<String> saved, Iterable<String?> selected) {
  final ids = <String>{...saved};
  for (final id in selected) {
    if (id != null) ids.add(id);
  }
  return List.unmodifiable(ids);
}

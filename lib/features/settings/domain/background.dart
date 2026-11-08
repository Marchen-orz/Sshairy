enum BackgroundSlot { app, terminal }

abstract final class BackgroundImageLimits {
  static const inputBytes = 16 * 1024 * 1024;
  static const sourcePixels = 40000000;
  static const decodedPixels = 2 * 1024 * 1024;
  static const longestSide = 2048;
  static const storedBytes = 8 * 1024 * 1024;
  static const totalBytes = 32 * 1024 * 1024;
  static const opacity = .15;
}

final _imageId = RegExp(r'^bg-[0-9a-f]{1,16}-[0-9a-f]{16}\.png$');
bool validBackgroundImageId(Object? value) => value is String && _imageId.hasMatch(value);

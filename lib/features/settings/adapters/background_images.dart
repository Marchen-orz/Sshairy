import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart' as selector;

import '../../../foundation/result.dart';
import '../domain/background.dart';

class BackgroundImageStore {
  BackgroundImageStore(this.directory, {this.pick});

  final String directory;
  final Future<String?> Function()? pick;

  static Future<selector.XFile?> _chooseFile() => selector.openFile(
    acceptedTypeGroups: [
      const selector.XTypeGroup(
        label: 'PNG / JPEG',
        extensions: ['png', 'jpg', 'jpeg'],
        mimeTypes: ['image/png', 'image/jpeg'],
      ),
    ],
  );

  /// [retained] is read once a file is picked: the dialog can stay open while the gallery changes. A [path] that was
  /// dropped in is imported without asking.
  Future<Result<String>?> choose(Set<String> Function() retained, {String? path}) async {
    try {
      if (path != null) return await importFile(path, retained());
      if (pick != null) {
        final path = await pick!();
        return path == null ? null : await importFile(path, retained());
      }
      final file = await _chooseFile();
      if (file == null) return null;
      final bytes = await _readStream(file.openRead());
      return await _importRawBytes(bytes, retained());
    } on _ImageFailure catch (error) {
      return Err(AppError(error.code));
    } on Object {
      return const Err(AppError('backgroundImageUnreadable'));
    }
  }

  Future<Result<String>> importFile(String path, Set<String> retained) async {
    final Uint8List raw;
    try {
      raw = await _read(path);
    } on _ImageFailure catch (error) {
      return Err(AppError(error.code));
    } on FileSystemException {
      return const Err(AppError('backgroundImageUnreadable'));
    } on Object {
      return const Err(AppError('backgroundImageUnsupported'));
    }
    return _importRawBytes(raw, retained);
  }

  Future<Result<String>> _importRawBytes(Uint8List raw, Set<String> retained) async {
    final Uint8List bytes;
    try {
      bytes = await _normalize(raw);
    } on _ImageFailure catch (error) {
      return Err(AppError(error.code));
    } on Object {
      return const Err(AppError('backgroundImageUnsupported'));
    }
    String? id;
    try {
      await cleanup(retained);
      if (await _storedSize() + bytes.length > BackgroundImageLimits.totalBytes) {
        return const Err(AppError('backgroundGalleryFull'));
      }
      final random = Random.secure();
      final suffix = List.generate(8, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
      final name = 'bg-${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}-$suffix.png';
      final target = await File('$directory/$name').create(exclusive: true);
      id = name;
      await target.writeAsBytes(bytes, flush: true);
      return Ok(name);
    } on Object {
      if (id != null) {
        try {
          await delete(id);
        } on Object {
          // Unreferenced files are collected by the next successful operation.
        }
      }
      return const Err(AppError('backgroundImageSaveFailed'));
    }
  }

  File? file(String? id) {
    if (!validBackgroundImageId(id)) return null;
    final root = FileSystemEntity.typeSync(directory, followLinks: false);
    if (root != FileSystemEntityType.directory) return null;
    final path = '$directory/$id';
    return FileSystemEntity.typeSync(path, followLinks: false) == FileSystemEntityType.file ? File(path) : null;
  }

  Future<void> _root() async {
    final type = await FileSystemEntity.type(directory, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      await Directory(directory).create(recursive: true);
    } else if (type != FileSystemEntityType.directory) {
      throw const FileSystemException('Invalid background directory');
    }
  }

  Future<void> cleanup(Set<String> retained) async {
    await _root();
    await for (final entity in Directory(directory).list(followLinks: false)) {
      final name = entity.uri.pathSegments.last;
      if (!validBackgroundImageId(name) || retained.contains(name)) continue;
      if (await FileSystemEntity.type(entity.path, followLinks: false) == FileSystemEntityType.file) {
        await entity.delete();
      }
    }
  }

  Future<void> delete(String id) async {
    if (!validBackgroundImageId(id)) return;
    final target = file(id);
    if (target != null) await target.delete();
  }

  Future<int> _storedSize() async {
    var size = 0;
    await for (final entity in Directory(directory).list(followLinks: false)) {
      if (validBackgroundImageId(entity.uri.pathSegments.last) &&
          await FileSystemEntity.type(entity.path, followLinks: false) == FileSystemEntityType.file) {
        size += await File(entity.path).length();
      }
    }
    return size;
  }

  Future<Uint8List> _readStream(Stream<Uint8List> stream) async {
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in stream) {
      if (bytes.length + chunk.length > BackgroundImageLimits.inputBytes) {
        throw const _ImageFailure('backgroundImageTooLarge');
      }
      bytes.add(chunk);
    }
    return bytes.takeBytes();
  }

  Future<Uint8List> _read(String path) async {
    final input = await File(path).open();
    try {
      if (await input.length() > BackgroundImageLimits.inputBytes) throw const _ImageFailure('backgroundImageTooLarge');
      final bytes = BytesBuilder(copy: false);
      while (true) {
        final chunk = await input.read(min(65536, BackgroundImageLimits.inputBytes + 1 - bytes.length));
        if (chunk.isEmpty) break;
        bytes.add(chunk);
        if (bytes.length > BackgroundImageLimits.inputBytes) throw const _ImageFailure('backgroundImageTooLarge');
      }
      return bytes.takeBytes();
    } finally {
      await input.close();
    }
  }

  Future<Uint8List> _normalize(Uint8List bytes) async {
    final png =
        bytes.length >= 8 && [137, 80, 78, 71, 13, 10, 26, 10].asMap().entries.every((e) => bytes[e.key] == e.value);
    final jpeg = bytes.length >= 3 && bytes[0] == 255 && bytes[1] == 216 && bytes[2] == 255;
    if (!png && !jpeg) throw const _ImageFailure('backgroundImageUnsupported');
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    ui.Image? image;
    try {
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      final pixels = descriptor.width * descriptor.height;
      if (pixels > BackgroundImageLimits.sourcePixels) throw const _ImageFailure('backgroundImageTooLarge');
      final scale = min(
        1.0,
        min(
          BackgroundImageLimits.longestSide / max(descriptor.width, descriptor.height),
          sqrt(BackgroundImageLimits.decodedPixels / pixels),
        ),
      );
      codec = await descriptor.instantiateCodec(
        targetWidth: max(1, (descriptor.width * scale).floor()),
        targetHeight: max(1, (descriptor.height * scale).floor()),
      );
      if (codec.frameCount != 1) throw const _ImageFailure('backgroundImageUnsupported');
      image = (await codec.getNextFrame()).image;
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) throw const _ImageFailure('backgroundImageUnsupported');
      final result = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      if (result.length > BackgroundImageLimits.storedBytes) throw const _ImageFailure('backgroundImageTooLarge');
      return result;
    } finally {
      image?.dispose();
      codec?.dispose();
      descriptor?.dispose();
      buffer.dispose();
    }
  }
}

class _ImageFailure implements Exception {
  const _ImageFailure(this.code);
  final String code;
}

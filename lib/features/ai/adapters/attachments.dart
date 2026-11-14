import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart' as selector;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../foundation/ids.dart';
import '../domain/attachment.dart';

/// The system picker behind a local grant request; null when cancelled.
Future<String?> chooseLocalGrantPath({required bool directory}) async =>
    directory ? selector.getDirectoryPath() : (await selector.openFile())?.path;

final agentAttachmentPickerProvider = Provider<AgentAttachmentPicker>((_) => AgentAttachmentPicker());

class AttachmentImportFailure extends FormatException {
  const AttachmentImportFailure(super.message, this.fileName);
  final String fileName;
}

class AgentAttachmentPicker {
  AgentAttachmentPicker({Future<List<String>> Function()? pick, Future<List<String>> Function()? clipboard})
    : _pick = pick ?? _choose,
      _clipboard = clipboard ?? _clipboardFiles;
  final Future<List<String>> Function() _pick, _clipboard;

  static Future<List<String>> _clipboardFiles() async {
    if (!Platform.isWindows && !Platform.isMacOS && !Platform.isLinux) return const [];
    try {
      final paths = await const MethodChannel('sshairy/window').invokeListMethod<String>('clipboardFiles');
      return paths ?? const [];
    } on PlatformException catch (error) {
      throw FormatException(
        const {'attachmentTooMany', 'attachmentTooLarge'}.contains(error.code) ? error.code : 'attachmentUnreadable',
      );
    } on MissingPluginException {
      return const [];
    }
  }

  Future<List<String>> clipboardFiles() async {
    final paths = await _clipboard();
    _checkPaths(paths);
    return paths;
  }

  static void _checkPaths(List<String> paths) {
    if (paths.length > AgentAttachmentLimits.count) throw const FormatException('attachmentTooMany');
    if (paths.any((path) => path.length > 32767)) throw const FormatException('attachmentUnreadable');
  }

  static Future<List<String>> _choose() async => [for (final file in await selector.openFiles()) file.path];

  Future<List<AgentAttachment>> choose(List<AgentAttachment> current) async {
    try {
      return await importFiles(await _pick(), current);
    } on FormatException {
      rethrow;
    } on Object {
      throw const FormatException('attachmentUnreadable');
    }
  }

  /// Paths come only from explicit picker, file paste or drop events. Images and small text are read and the path is
  /// discarded; folders, large or non-text files become references whose path stays in memory until it becomes a
  /// conversation grant (docs/AI.md §7.1).
  Future<List<AgentAttachment>> importFiles(List<String> paths, List<AgentAttachment> current) async {
    try {
      _checkPaths(paths);
      if (paths.isEmpty) return current;
      if (paths.length + current.length > AgentAttachmentLimits.count) {
        throw const FormatException('attachmentTooMany');
      }
      final added = <AgentAttachment>[];
      var remaining = AgentAttachmentLimits.totalBytes - current.fold(0, (size, item) => size + item.bytes);
      for (final path in paths) {
        final name = path.replaceAll('\\', '/').split('/').where((part) => part.isNotEmpty).lastOrNull ?? '';
        final cleanName = name.replaceAll(RegExp(r'[\x00-\x1f\x7f-\x9f]'), '');
        final displayName = cleanName.substring(0, min(cleanName.length, 255));
        try {
          final type = await FileSystemEntity.type(path);
          if (_credentialName(name)) throw const FormatException('attachmentUnsupported');
          if (type == FileSystemEntityType.directory) {
            added.add(AgentAttachment.reference(id: newId(), name: name, directory: true, localPath: path));
            continue;
          }
          if (type != FileSystemEntityType.file) throw const FormatException('attachmentUnsupported');
          final size = await File(path).length();
          AgentAttachment reference() =>
              AgentAttachment.reference(id: newId(), name: name, directory: false, size: size, localPath: path);
          final head = await _read(path, min(size, 16), exact: false);
          final AgentAttachment attachment;
          if (_image(head)) {
            final bytes = await _read(path, AgentAttachmentLimits.inputImageBytes);
            attachment = AgentAttachment.image(id: newId(), name: name, base64: base64Encode(await _normalize(bytes)));
          } else if (_binaryName(name) || size > AgentAttachmentLimits.inlineTextBytes) {
            attachment = reference();
          } else {
            final bytes = await _read(path, AgentAttachmentLimits.inlineTextBytes);
            final String text;
            try {
              text = utf8.decode(bytes);
            } on FormatException {
              added.add(reference());
              continue;
            }
            attachment = AgentAttachment.text(id: newId(), name: name, text: text);
          }
          if (attachment.bytes > remaining) throw const FormatException('attachmentTotalTooLarge');
          remaining -= attachment.bytes;
          added.add(attachment);
        } on FormatException catch (error) {
          throw AttachmentImportFailure(
            error.message.startsWith('attachment') ? error.message : 'attachmentUnsupported',
            displayName,
          );
        } on Object {
          throw AttachmentImportFailure('attachmentUnreadable', displayName);
        }
      }
      return checkedAgentAttachments([...current, ...added]);
    } on FormatException {
      rethrow;
    } on Object {
      throw const FormatException('attachmentUnreadable');
    }
  }

  static bool _credentialName(String name) {
    final lower = name.toLowerCase();
    return lower == '.env' || lower.startsWith('.env.') || lower.startsWith('id_rsa') || lower.startsWith('id_ed25519');
  }

  /// Types sent as references rather than decoded as text.
  static bool _binaryName(String name) {
    final lower = name.toLowerCase();
    return const {
      'pdf',
      'doc',
      'docx',
      'xls',
      'xlsx',
      'ppt',
      'pptx',
      'odt',
      'ods',
      'odp',
      'zip',
      'rar',
      '7z',
      'gz',
      'tar',
      'mp3',
      'mp4',
      'wav',
      'ogg',
      'avi',
      'mov',
    }.contains(lower.split('.').last);
  }

  static bool _image(Uint8List bytes) =>
      (bytes.length >= 8 && [137, 80, 78, 71, 13, 10, 26, 10].asMap().entries.every((e) => bytes[e.key] == e.value)) ||
      (bytes.length >= 3 && bytes[0] == 255 && bytes[1] == 216 && bytes[2] == 255) ||
      (bytes.length >= 12 &&
          ascii.decode(bytes.sublist(0, 4), allowInvalid: true) == 'RIFF' &&
          ascii.decode(bytes.sublist(8, 12), allowInvalid: true) == 'WEBP');

  static Future<Uint8List> _read(String path, int limit, {bool exact = true}) async {
    final file = await File(path).open();
    try {
      if (!exact) return await file.read(limit);
      if (await file.length() > limit) throw const FormatException('attachmentTooLarge');
      final bytes = BytesBuilder(copy: false);
      while (bytes.length <= limit) {
        final chunk = await file.read(min(65536, limit + 1 - bytes.length));
        if (chunk.isEmpty) return bytes.takeBytes();
        bytes.add(chunk);
      }
      throw const FormatException('attachmentTooLarge');
    } finally {
      await file.close();
    }
  }

  static Future<Uint8List> _normalize(Uint8List bytes) async {
    if (!_image(bytes)) throw const FormatException('attachmentUnsupported');
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    ui.Image? image;
    try {
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      if (descriptor.width * descriptor.height > AgentAttachmentLimits.sourcePixels) {
        throw const FormatException('attachmentImageTooLarge');
      }
      final scale = min(1.0, AgentAttachmentLimits.longestSide / max(descriptor.width, descriptor.height));
      codec = await descriptor.instantiateCodec(
        targetWidth: max(1, (descriptor.width * scale).floor()),
        targetHeight: max(1, (descriptor.height * scale).floor()),
      );
      if (codec.frameCount != 1) throw const FormatException('attachmentUnsupported');
      image = (await codec.getNextFrame()).image;
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) throw const FormatException('attachmentUnsupported');
      final normalized = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      if (normalized.length > AgentAttachmentLimits.totalBytes) throw const FormatException('attachmentTooLarge');
      return normalized;
    } finally {
      image?.dispose();
      codec?.dispose();
      descriptor?.dispose();
      buffer.dispose();
    }
  }
}

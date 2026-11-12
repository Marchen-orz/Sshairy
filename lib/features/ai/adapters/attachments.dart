import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart' as selector;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../foundation/ids.dart';
import '../domain/attachment.dart';

final agentAttachmentPickerProvider = Provider<AgentAttachmentPicker>((_) => AgentAttachmentPicker());

class AgentAttachmentPicker {
  AgentAttachmentPicker({Future<List<String>> Function()? pick}) : _pick = pick ?? _choose;
  final Future<List<String>> Function() _pick;

  static Future<List<String>> _choose() async => [for (final file in await selector.openFiles()) file.path];

  /// Paths come only from the user-owned picker and are discarded once content has been read.
  Future<List<AgentAttachment>> choose(List<AgentAttachment> current) async {
    try {
      final paths = await _pick();
      if (paths.isEmpty) return current;
      if (paths.length + current.length > AgentAttachmentLimits.count) {
        throw const FormatException('attachmentTooLarge');
      }
      final added = <AgentAttachment>[];
      for (final path in paths) {
        final name = path.replaceAll('\\', '/').split('/').last;
        final extension = name.toLowerCase().split('.').last;
        final image = const {'png', 'jpg', 'jpeg', 'webp'}.contains(extension);
        if (!image && !_textName(name)) throw const FormatException('attachmentUnsupported');
        final bytes = await _read(
          path,
          image ? AgentAttachmentLimits.inputImageBytes : AgentAttachmentLimits.textBytes,
        );
        added.add(
          image
              ? AgentAttachment.image(id: newId(), name: name, base64: base64Encode(await _normalize(bytes)))
              : AgentAttachment.text(id: newId(), name: name, text: utf8.decode(bytes)),
        );
      }
      return checkedAgentAttachments([...current, ...added]);
    } on FormatException {
      rethrow;
    } on Object {
      throw const FormatException('attachmentUnreadable');
    }
  }

  static bool _textName(String name) {
    final lower = name.toLowerCase();
    if (lower == '.env' || lower.startsWith('.env.') || lower.startsWith('id_rsa') || lower.startsWith('id_ed25519')) {
      return false;
    }
    if (const {'dockerfile', 'makefile', 'readme', 'license', '.gitignore', '.gitattributes'}.contains(lower)) {
      return true;
    }
    return const {
      'txt',
      'md',
      'markdown',
      'rst',
      'log',
      'csv',
      'tsv',
      'json',
      'jsonc',
      'jsonl',
      'yaml',
      'yml',
      'toml',
      'xml',
      'ini',
      'cfg',
      'conf',
      'dart',
      'js',
      'mjs',
      'cjs',
      'jsx',
      'ts',
      'tsx',
      'py',
      'rb',
      'rs',
      'go',
      'java',
      'c',
      'h',
      'cpp',
      'hpp',
      'cs',
      'swift',
      'kt',
      'php',
      'pl',
      'sh',
      'bash',
      'zsh',
      'fish',
      'ps1',
      'bat',
      'cmd',
      'sql',
      'r',
      'lua',
      'html',
      'htm',
      'css',
      'scss',
      'vue',
      'svelte',
    }.contains(lower.split('.').last);
  }

  static Future<Uint8List> _read(String path, int limit) async {
    final file = await File(path).open();
    try {
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
    final png =
        bytes.length >= 8 && [137, 80, 78, 71, 13, 10, 26, 10].asMap().entries.every((e) => bytes[e.key] == e.value);
    final jpeg = bytes.length >= 3 && bytes[0] == 255 && bytes[1] == 216 && bytes[2] == 255;
    final webp =
        bytes.length >= 12 &&
        ascii.decode(bytes.sublist(0, 4), allowInvalid: true) == 'RIFF' &&
        ascii.decode(bytes.sublist(8, 12), allowInvalid: true) == 'WEBP';
    if (!png && !jpeg && !webp) throw const FormatException('attachmentUnsupported');
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    ui.Image? image;
    try {
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      if (descriptor.width * descriptor.height > AgentAttachmentLimits.sourcePixels) {
        throw const FormatException('attachmentTooLarge');
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
      if (normalized.length > AgentAttachmentLimits.imageBytes) throw const FormatException('attachmentTooLarge');
      return normalized;
    } finally {
      image?.dispose();
      codec?.dispose();
      descriptor?.dispose();
      buffer.dispose();
    }
  }
}

import 'dart:convert';

class AgentAttachmentLimits {
  static const count = 4;
  static const textBytes = 64 << 10;
  static const imageBytes = 256 << 10;
  static const totalBytes = 512 << 10;
  static const inputImageBytes = 8 << 20;
  static const sourcePixels = 16 * 1024 * 1024;
  static const longestSide = 1024;
}

/// Explicitly selected content. A local path is never part of this value.
class AgentAttachment {
  AgentAttachment._(this.id, this.name, this.mediaType, this.content, this.bytes);

  factory AgentAttachment.text({required String id, required String name, required String text}) {
    final size = utf8.encode(text).length;
    if (size > AgentAttachmentLimits.textBytes || !_safeText(text)) {
      throw const FormatException('attachmentUnsupported');
    }
    return AgentAttachment._(_id(id), _name(name), 'text/plain', text, size);
  }

  factory AgentAttachment.image({required String id, required String name, required String base64}) {
    if (base64.length > ((AgentAttachmentLimits.imageBytes + 2) ~/ 3) * 4) {
      throw const FormatException('attachmentTooLarge');
    }
    final data = base64Decode(base64);
    const png = [137, 80, 78, 71, 13, 10, 26, 10];
    if (data.length < 33 ||
        !png.asMap().entries.every((entry) => data[entry.key] == entry.value) ||
        data[8] != 0 ||
        data[9] != 0 ||
        data[10] != 0 ||
        data[11] != 13 ||
        ascii.decode(data.sublist(12, 16), allowInvalid: true) != 'IHDR') {
      throw const FormatException('attachmentUnsupported');
    }
    int dimension(int offset) =>
        (data[offset] << 24) | (data[offset + 1] << 16) | (data[offset + 2] << 8) | data[offset + 3];
    final width = dimension(16), height = dimension(20);
    if (width < 1 ||
        height < 1 ||
        width > AgentAttachmentLimits.longestSide ||
        height > AgentAttachmentLimits.longestSide ||
        data.length > AgentAttachmentLimits.imageBytes) {
      throw const FormatException('attachmentTooLarge');
    }
    return AgentAttachment._(_id(id), _name(name), 'image/png', base64Encode(data), data.length);
  }

  factory AgentAttachment.fromJson(Map<String, Object?> data) {
    if (data.keys.any((key) => !const {'id', 'name', 'mediaType', 'content'}.contains(key)) ||
        data['id'] is! String ||
        data['name'] is! String ||
        data['content'] is! String) {
      throw const FormatException('attachmentUnsupported');
    }
    return switch (data['mediaType']) {
      'text/plain' => AgentAttachment.text(
        id: data['id'] as String,
        name: data['name'] as String,
        text: data['content'] as String,
      ),
      'image/png' => AgentAttachment.image(
        id: data['id'] as String,
        name: data['name'] as String,
        base64: data['content'] as String,
      ),
      _ => throw const FormatException('attachmentUnsupported'),
    };
  }

  final String id, name, mediaType, content;
  final int bytes;
  bool get isImage => mediaType == 'image/png';
  int get storedBytes => utf8.encode(content).length + utf8.encode(name).length + 128;

  Map<String, Object?> toJson() => {'id': id, 'name': name, 'mediaType': mediaType, 'content': content};
  Map<String, Object?> get description => {'id': id, 'name': name, 'mediaType': mediaType, 'bytes': bytes};

  static String _id(String value) {
    if (!RegExp(r'^[A-Za-z0-9_.:\-]{1,128}$').hasMatch(value)) throw const FormatException('attachmentUnsupported');
    return value;
  }

  static String _name(String value) {
    if (value.isEmpty || value.length > 255 || RegExp(r'[\x00-\x1f\x7f-\x9f/\\]').hasMatch(value)) {
      throw const FormatException('attachmentUnsupported');
    }
    return value;
  }

  static bool _safeText(String text) =>
      !RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f]').hasMatch(text) &&
      !RegExp(
        r'-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----|\bBearer[ \t]+[A-Za-z0-9._~+/=\-]+',
        caseSensitive: false,
      ).hasMatch(text) &&
      !RegExp(
        r'''\b(?:[A-Za-z_][A-Za-z0-9_]*(?:KEY|TOKEN|SECRET|PASSWORD|PASSWD)|key|token|secret|password|passwd)\b["']?[ \t]*[:=][ \t]*["']?[^\s"',;}\]]+''',
        caseSensitive: false,
      ).hasMatch(text);
}

List<AgentAttachment> checkedAgentAttachments(Iterable<AgentAttachment> values) {
  final result = List<AgentAttachment>.unmodifiable(values);
  if (result.length > AgentAttachmentLimits.count ||
      result.fold(0, (size, value) => size + value.bytes) > AgentAttachmentLimits.totalBytes ||
      result.map((value) => value.id).toSet().length != result.length) {
    throw const FormatException('attachmentTooLarge');
  }
  return result;
}

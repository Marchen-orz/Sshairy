import 'dart:convert';

import '../domain/model.dart';

class SseEvent {
  const SseEvent(this.event, this.data);
  final String? event;
  final String data;
}

/// Incremental UTF-8 and line parsing; an incomplete final event is never dispatched.
Stream<SseEvent> decodeSse(Stream<List<int>> bytes, {int maxEventBytes = 256 * 1024}) async* {
  final decoder = _SseDecoder(maxEventBytes);
  try {
    await for (final text in bytes.transform(utf8.decoder)) {
      yield* Stream.fromIterable(decoder.add(text));
    }
    decoder.finish();
  } on FormatException {
    throw const ModelFailure('invalidModelStream');
  }
}

class _SseDecoder {
  _SseDecoder(this.limit);
  final int limit;
  var _line = StringBuffer();
  var _data = <String>[];
  String? _event;
  var _eventBytes = 0;
  var _skipLf = false;

  Iterable<SseEvent> add(String text) sync* {
    for (var i = 0; i < text.length; i++) {
      final char = text.codeUnitAt(i);
      if (_skipLf) {
        _skipLf = false;
        if (char == 10) continue;
      }
      // A UTF-16 surrogate pair contributes four UTF-8 bytes once, at its low surrogate.
      _eventBytes += char < 128
          ? 1
          : char < 2048
          ? 2
          : char >= 0xd800 && char <= 0xdbff
          ? 0
          : char >= 0xdc00 && char <= 0xdfff
          ? 4
          : 3;
      if (_eventBytes > limit) throw const ModelFailure('modelEventTooLarge');
      if (char == 10 || char == 13) {
        _skipLf = char == 13;
        final line = _line.toString();
        _line = StringBuffer();
        if (line.isEmpty) {
          if (_data.isNotEmpty) yield SseEvent(_event, _data.join('\n'));
          _data = [];
          _event = null;
          _eventBytes = 0;
          continue;
        }
        if (line.startsWith(':')) continue;
        final colon = line.indexOf(':');
        final field = colon < 0 ? line : line.substring(0, colon);
        var value = colon < 0 ? '' : line.substring(colon + 1);
        if (value.startsWith(' ')) value = value.substring(1);
        if (field == 'data') _data.add(value);
        if (field == 'event') _event = value;
      } else {
        _line.writeCharCode(char);
      }
    }
  }

  void finish() {
    if (_line.isNotEmpty || _data.isNotEmpty || _event != null) {
      throw const ModelFailure('incompleteModelStream');
    }
  }
}

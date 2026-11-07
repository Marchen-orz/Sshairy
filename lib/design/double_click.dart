import 'package:flutter/gestures.dart';

/// Tells a double click from two single ones by time. An `onDoubleTap` recognizer holds the gesture arena for the
/// whole timeout after every tap, which delays the buttons inside the same target by 300 ms.
class DoubleClick {
  DateTime? _first;

  /// True when this click follows another one closely enough to make a pair; the pair is then used up.
  bool get hit {
    final now = DateTime.now();
    final first = _first;
    if (first != null && now.difference(first) < kDoubleTapTimeout) {
      _first = null;
      return true;
    }
    _first = now;
    return false;
  }
}

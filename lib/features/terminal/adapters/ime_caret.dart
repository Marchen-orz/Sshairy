import 'dart:ffi';
import 'dart:io';
import 'dart:ui';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

/// The Windows embedder only moves the IME windows while a composition is active, and it destroys the system
/// caret when one ends. IMEs running through TSF (Baidu, for one) place the next candidate window before the
/// embedder sees the composition start, so it opened where the previous one was. Moving the input context's
/// composition and candidate forms, and the caret, whenever the terminal cursor moves fixes that.
/// Needs merged platform and UI threads (the Flutter default): carets and input contexts belong to a thread.
abstract final class ImeCaret {
  static final _user32 = Platform.isWindows ? DynamicLibrary.open('user32.dll') : null;
  static final _imm32 = Platform.isWindows ? DynamicLibrary.open('imm32.dll') : null;

  static final _getFocus = _user32?.lookupFunction<IntPtr Function(), int Function()>('GetFocus');
  static final _createCaret = _user32?.lookupFunction<Int32 Function(IntPtr, IntPtr, Int32, Int32),
      int Function(int, int, int, int)>('CreateCaret');
  static final _setCaretPos =
      _user32?.lookupFunction<Int32 Function(Int32, Int32), int Function(int, int)>('SetCaretPos');
  static final _getCaretPos =
      _user32?.lookupFunction<Int32 Function(Pointer<_Point>), int Function(Pointer<_Point>)>('GetCaretPos');

  static final _immGetContext = _imm32?.lookupFunction<IntPtr Function(IntPtr), int Function(int)>('ImmGetContext');
  static final _immReleaseContext =
      _imm32?.lookupFunction<Int32 Function(IntPtr, IntPtr), int Function(int, int)>('ImmReleaseContext');
  static final _immSetCompositionWindow = _imm32?.lookupFunction<Int32 Function(IntPtr, Pointer<_CompositionForm>),
      int Function(int, Pointer<_CompositionForm>)>('ImmSetCompositionWindow');
  static final _immSetCandidateWindow = _imm32?.lookupFunction<Int32 Function(IntPtr, Pointer<_CandidateForm>),
      int Function(int, Pointer<_CandidateForm>)>('ImmSetCandidateWindow');
  static final _immGetCompositionWindow = _imm32?.lookupFunction<Int32 Function(IntPtr, Pointer<_CompositionForm>),
      int Function(int, Pointer<_CompositionForm>)>('ImmGetCompositionWindow');
  static final _immGetCandidateWindow = _imm32?.lookupFunction<
      Int32 Function(IntPtr, Uint32, Pointer<_CandidateForm>),
      int Function(int, int, Pointer<_CandidateForm>)>('ImmGetCandidateWindow');

  static const _cfsPoint = 0x0002, _cfsExclude = 0x0080;

  /// [cursor] is in physical pixels of the view's client area. Uses the same forms as the embedder does.
  static void moveTo(Rect cursor) {
    final window = _getFocus?.call() ?? 0;
    if (window == 0) return;
    final left = cursor.left.toInt(), top = cursor.top.toInt();
    final right = cursor.right.toInt(), bottom = cursor.bottom.toInt();

    if (_setCaretPos!(left, bottom) == 0 && _createCaret!(window, 0, 1, 1) != 0) _setCaretPos!(left, bottom);

    final context = _immGetContext!(window);
    if (context == 0) return;
    using((arena) {
      final composition = arena<_CompositionForm>();
      composition.ref
        ..style = _cfsPoint
        ..x = left
        ..y = top;
      _immSetCompositionWindow!(context, composition);
      final candidate = arena<_CandidateForm>();
      candidate.ref
        ..index = 0
        ..style = _cfsExclude
        ..x = left
        ..y = bottom
        ..left = left
        ..top = top
        ..right = right
        ..bottom = bottom;
      _immSetCandidateWindow!(context, candidate);
    });
    _immReleaseContext!(window, context);
  }

  /// What an IME would read now: caret, composition point and candidate point, in physical pixels.
  @visibleForTesting
  static ({Offset caret, Offset composition, Offset candidate})? current() {
    final window = _getFocus?.call() ?? 0;
    if (window == 0) return null;
    final context = _immGetContext!(window);
    if (context == 0) return null;
    try {
      return using((arena) {
        final caret = arena<_Point>();
        final composition = arena<_CompositionForm>();
        final candidate = arena<_CandidateForm>();
        if (_getCaretPos!(caret) == 0 ||
            _immGetCompositionWindow!(context, composition) == 0 ||
            _immGetCandidateWindow!(context, 0, candidate) == 0) {
          return null;
        }
        return (
          caret: Offset(caret.ref.x.toDouble(), caret.ref.y.toDouble()),
          composition: Offset(composition.ref.x.toDouble(), composition.ref.y.toDouble()),
          candidate: Offset(candidate.ref.x.toDouble(), candidate.ref.y.toDouble()),
        );
      });
    } finally {
      _immReleaseContext!(window, context);
    }
  }
}

final class _Point extends Struct {
  @Int32()
  external int x;
  @Int32()
  external int y;
}

/// COMPOSITIONFORM
final class _CompositionForm extends Struct {
  @Uint32()
  external int style;
  @Int32()
  external int x;
  @Int32()
  external int y;
  @Int32()
  external int left;
  @Int32()
  external int top;
  @Int32()
  external int right;
  @Int32()
  external int bottom;
}

/// CANDIDATEFORM
final class _CandidateForm extends Struct {
  @Uint32()
  external int index;
  @Uint32()
  external int style;
  @Int32()
  external int x;
  @Int32()
  external int y;
  @Int32()
  external int left;
  @Int32()
  external int top;
  @Int32()
  external int right;
  @Int32()
  external int bottom;
}

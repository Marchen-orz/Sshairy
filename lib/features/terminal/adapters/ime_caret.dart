import 'dart:ffi';
import 'dart:io';

/// The Windows embedder destroys the system caret when a composition ends and only recreates it once the next
/// composition has started. IMEs that read the caret position (Baidu, for one) open the next candidate window
/// where the last one was. Keeping a caret at the terminal cursor between compositions fixes that.
/// Needs merged platform and UI threads (the Flutter default), since a caret belongs to the calling thread.
abstract final class ImeCaret {
  static final _user32 = Platform.isWindows ? DynamicLibrary.open('user32.dll') : null;
  static final _getFocus = _user32?.lookupFunction<IntPtr Function(), int Function()>('GetFocus');
  static final _createCaret = _user32?.lookupFunction<Int32 Function(IntPtr, IntPtr, Int32, Int32),
      int Function(int, int, int, int)>('CreateCaret');
  static final _setCaretPos =
      _user32?.lookupFunction<Int32 Function(Int32, Int32), int Function(int, int)>('SetCaretPos');

  /// [x] and [y] are physical pixels in the view's client area: the cursor's bottom-left, as the embedder uses.
  static void moveTo(int x, int y) {
    final setCaretPos = _setCaretPos;
    if (setCaretPos == null || setCaretPos(x, y) != 0) return;
    final window = _getFocus!();
    if (window == 0 || _createCaret!(window, 0, 1, 1) == 0) return;
    setCaretPos(x, y);
  }
}

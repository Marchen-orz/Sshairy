import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class DesktopWindowState {
  const DesktopWindowState({
    this.supported = false,
    this.maximized = false,
    this.active = true,
    this.maximizeHovered = false,
  });

  final bool supported, maximized, active, maximizeHovered;
}

/// Only the Windows runner extends its client area; other runners retain their native frame.
class DesktopWindow extends ValueNotifier<DesktopWindowState> {
  DesktopWindow({MethodChannel? channel, bool? windows})
    : _channel = channel ?? const MethodChannel('sshairy/window'),
      _windows = windows ?? (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows),
      super(const DesktopWindowState());

  static final instance = DesktopWindow();

  final MethodChannel _channel;
  final bool _windows;
  Future<void>? _initializing;

  Future<void> initialize() => _initializing ??= _initialize();

  Future<void> _initialize() async {
    if (!_windows) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'state') _update(call.arguments);
    });
    try {
      _update(await _channel.invokeMethod<Object?>('initialize'));
    } on MissingPluginException {
      // Widget tests and runners without this channel keep their existing window frame.
    }
  }

  void _update(Object? message) {
    if (message is! Map) return;
    value = DesktopWindowState(
      supported: true,
      maximized: message['maximized'] == true,
      active: message['active'] != false,
      maximizeHovered: message['maximizeHovered'] == true,
    );
  }

  Future<void> _invoke(String method, [Object? arguments]) async {
    if (value.supported) await _channel.invokeMethod<void>(method, arguments);
  }

  Future<void> minimize() => _invoke('minimize');
  Future<void> toggleMaximize() => _invoke('toggleMaximize');
  Future<void> beginDrag() => _invoke('drag');
  Future<void> showSystemMenu() => _invoke('systemMenu');

  /// Physical client coordinates let Windows identify the native maximize button for its Snap menu.
  Future<void> setMaximizeRect(Rect? bounds, double pixelRatio) => _invoke(
    'maximizeRect',
    bounds == null
        ? null
        : [bounds.left * pixelRatio, bounds.top * pixelRatio, bounds.right * pixelRatio, bounds.bottom * pixelRatio],
  );

  /// Uses the same cancelable application-exit request as Alt+F4 and the native close menu.
  Future<AppExitResponse> close() => ServicesBinding.instance.exitApplication(AppExitType.cancelable);

  @override
  void dispose() {
    _channel.setMethodCallHandler(null);
    super.dispose();
  }
}

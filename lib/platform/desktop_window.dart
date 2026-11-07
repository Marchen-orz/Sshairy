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
  ({String theme, bool dark})? _brandIcon;

  Future<void> initialize() => _initializing ??= _initialize();

  Future<void> _initialize() async {
    if (!_windows) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'state') _update(call.arguments);
      // Alt+F4, the taskbar and the system menu take the same confirmed path as the close button.
      if (call.method == 'closeRequested') await close();
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

  /// Quit hides the window before slow cleanup and shows it again only if cleanup needs a decision.
  Future<void> hide() => _invoke('hide');
  Future<void> show() => _invoke('show');

  /// Physical client coordinates let Windows identify the native maximize button for its Snap menu.
  Future<void> setMaximizeRect(Rect? bounds, double pixelRatio) => _invoke(
    'maximizeRect',
    bounds == null
        ? null
        : [bounds.left * pixelRatio, bounds.top * pixelRatio, bounds.right * pixelRatio, bounds.bottom * pixelRatio],
  );

  /// Switches the running window's title-bar and taskbar icon to the one for [theme] (the persisted accent name) and
  /// brightness. A repeat of the current icon is not sent again; a rejected icon is dropped and may be retried.
  Future<void> setBrandIcon(String theme, {required bool dark}) async {
    final icon = (theme: theme, dark: dark);
    if (!value.supported || icon == _brandIcon) return;
    _brandIcon = icon;
    try {
      await _channel.invokeMethod<void>('brandIcon', {'theme': theme, 'dark': dark});
    } on PlatformException {
      if (_brandIcon == icon) _brandIcon = null;
    }
  }

  /// Uses the same cancelable application-exit request as Alt+F4 and the native close menu.
  Future<AppExitResponse> close() => ServicesBinding.instance.exitApplication(AppExitType.cancelable);

  @override
  void dispose() {
    _channel.setMethodCallHandler(null);
    super.dispose();
  }
}

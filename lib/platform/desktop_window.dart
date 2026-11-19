import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class DesktopWindowState {
  const DesktopWindowState({
    this.supported = false,
    this.customChrome = true,
    this.maximized = false,
    this.active = true,
    this.maximizeHovered = false,
  });

  final bool supported, customChrome, maximized, active, maximizeHovered;
}

/// Native desktop operations; the runner reports whether Flutter draws the window buttons.
class DesktopWindow extends ValueNotifier<DesktopWindowState> {
  DesktopWindow({MethodChannel? channel, bool? windows, TargetPlatform? platform})
    : _channel = channel ?? const MethodChannel('sshairy/window'),
      _desktop =
          windows ??
          (!kIsWeb &&
              const {
                TargetPlatform.windows,
                TargetPlatform.macOS,
                TargetPlatform.linux,
              }.contains(platform ?? defaultTargetPlatform)),
      super(const DesktopWindowState());

  static final instance = DesktopWindow();

  final MethodChannel _channel;
  final bool _desktop;
  Future<void>? _initializing;
  ({String theme, bool dark})? _brandIcon;

  Future<void> initialize() => _initializing ??= _initialize();

  Future<void> _initialize() async {
    if (!_desktop) return;
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
      customChrome: message['customChrome'] != false,
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

  /// Quit hides the window before slow cleanup and shows it again only if cleanup needs a decision. Showing also
  /// restores a minimized window and raises it above others, so a dialog is never left waiting out of sight.
  Future<void> hide() => _invoke('hide');
  Future<void> show() => _invoke('show');

  /// Hands the foreground permission of a new Windows launch to the existing instance.
  Future<void> allowForeground(int ownerPid) => _invoke('allowForeground', ownerPid);

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

  var _relaunch = false;
  String? _installer;

  /// Closes through the same confirmed path and starts the app again once that close has drained.
  Future<void> restart() async {
    _relaunch = true;
    if (await close() == AppExitResponse.cancel) _relaunch = false;
  }

  /// Closes through the same confirmed path, then starts [installer]; false when the user cancels the close.
  Future<bool> installAndQuit(String path) async {
    if (!_desktop) return false;
    _installer = path;
    if (await close() == AppExitResponse.cancel) {
      _installer = null;
      return false;
    }
    return true;
  }

  /// Called by the close path after everything is saved and released, right before the process exits.
  Future<void> relaunchIfRequested() async {
    if (!_desktop) return;
    if (_relaunch) {
      _relaunch = false;
      try {
        await Process.start(Platform.resolvedExecutable, const [], mode: ProcessStartMode.detached);
      } on ProcessException {
        // The close still goes ahead; the user can start the app again by hand.
      }
    }
    final installer = _installer;
    _installer = null;
    if (installer != null) await _startInstaller(installer);
  }

  Future<void> _startInstaller(String path) async {
    try {
      if (Platform.isLinux) {
        // Downloads arrive without the executable bit; xdg-open would only show the archive.
        if (path.toLowerCase().endsWith('.appimage')) {
          await Process.run('chmod', ['+x', path]);
        }
        await Process.start('xdg-open', [path], mode: ProcessStartMode.detached);
      } else if (Platform.isMacOS) {
        await Process.start('open', [path], mode: ProcessStartMode.detached);
      } else {
        await Process.start(path, const [], mode: ProcessStartMode.detached);
      }
    } on ProcessException {
      // The file stays in Downloads so the user can start it by hand.
    }
  }

  @override
  void dispose() {
    _channel.setMethodCallHandler(null);
    super.dispose();
  }
}

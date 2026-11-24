import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/widgets.dart';

import '../design/interface_scale.dart';

/// Shortest-side breakpoint separating phones from tablets/iPads on mobile platforms (docs/MOBILE.md §2).
const double phoneShortestSideBreakpoint = 600.0;

bool get isDesktopPlatform =>
    !kIsWeb &&
    const {TargetPlatform.windows, TargetPlatform.macOS, TargetPlatform.linux}.contains(defaultTargetPlatform);

bool get isMobilePlatform =>
    !kIsWeb && const {TargetPlatform.android, TargetPlatform.iOS}.contains(defaultTargetPlatform);

bool get isAndroidPlatform => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

/// True on Android/iOS phones (shortestSide < 600dp regardless of orientation).
bool isPhoneWorkspace(BuildContext context) {
  if (!isMobilePlatform) return false;
  return InterfaceScale.viewportSizeOf(context).shortestSide < phoneShortestSideBreakpoint;
}

/// True on Android/iOS tablets (shortestSide >= 600dp).
bool isTabletWorkspace(BuildContext context) {
  if (!isMobilePlatform) return false;
  return InterfaceScale.viewportSizeOf(context).shortestSide >= phoneShortestSideBreakpoint;
}

/// True on Android/iOS devices (both phones and tablets); desktop platforms always keep the desktop workspace.
bool isCompactWorkspace(BuildContext context) => isMobilePlatform;

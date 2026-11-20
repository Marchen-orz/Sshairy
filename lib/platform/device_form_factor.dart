import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/widgets.dart';

/// Shortest-side breakpoint separating phones (portrait & landscape) from tablets/iPads (docs/MOBILE.md §2).
const double phoneShortestSideBreakpoint = 600.0;

bool get isDesktopPlatform =>
    !kIsWeb &&
    const {TargetPlatform.windows, TargetPlatform.macOS, TargetPlatform.linux}.contains(defaultTargetPlatform);

bool get isMobilePlatform =>
    !kIsWeb && const {TargetPlatform.android, TargetPlatform.iOS}.contains(defaultTargetPlatform);

/// True on Android/iOS phones (shortestSide < 600dp regardless of orientation); tablets keep the desktop layout.
bool isPhoneWorkspace(BuildContext context) {
  if (!isMobilePlatform) return false;
  return MediaQuery.sizeOf(context).shortestSide < phoneShortestSideBreakpoint;
}

/// Alias kept for existing workspace switch callers.
bool isCompactWorkspace(BuildContext context) => isPhoneWorkspace(context);

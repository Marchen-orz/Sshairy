import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/widgets.dart';

/// Compact breakpoint where the workspace switches from the desktop rail/tab bar to the mobile bottom-nav shell.
const double compactWorkspaceBreakpoint = 720.0;

bool get isDesktopPlatform =>
    !kIsWeb &&
    const {TargetPlatform.windows, TargetPlatform.macOS, TargetPlatform.linux}.contains(defaultTargetPlatform);

bool get isMobilePlatform =>
    !kIsWeb && const {TargetPlatform.android, TargetPlatform.iOS}.contains(defaultTargetPlatform);

/// True on Android/iOS (under the 720dp tablet breakpoint) or when desktop mobile-preview is toggled on.
bool isCompactWorkspace(BuildContext context, {bool previewMobile = false}) {
  if (previewMobile) return true;
  if (isMobilePlatform) return MediaQuery.sizeOf(context).width < compactWorkspaceBreakpoint;
  return false;
}

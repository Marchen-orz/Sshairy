import 'dart:io' show Platform;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/widgets.dart';

/// Only OS file-drop events supply paths; model text never reaches this entry.
class AgentAttachmentDropZone extends StatelessWidget {
  const AgentAttachmentDropZone({
    super.key,
    required this.enabled,
    required this.onHover,
    required this.onDrop,
    required this.child,
  });

  final bool enabled;
  final ValueChanged<bool> onHover;
  final ValueChanged<List<String>> onDrop;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!Platform.isWindows && !Platform.isMacOS && !Platform.isLinux) return child;
    return DropTarget(
      enable: enabled,
      onDragEntered: (_) => onHover(true),
      onDragExited: (_) => onHover(false),
      onDragDone: (event) {
        onHover(false);
        if (enabled) onDrop([for (final file in event.files) file.path]);
      },
      child: child,
    );
  }
}

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart' as selector;
import 'package:flutter/widgets.dart';

/// Files the user picks in the system dialog; empty when cancelled.
Future<List<String>> pickFiles() async => [for (final f in await selector.openFiles()) f.path];

/// A folder the user picks in the system dialog; null when cancelled.
Future<String?> pickDirectory() => selector.getDirectoryPath();

/// Takes files dragged in from the system's file manager; [onHover] tells when a drag is over it.
class OsDropZone extends StatelessWidget {
  const OsDropZone({super.key, required this.enabled, required this.onHover, required this.onDrop, required this.child});

  final bool enabled;
  final ValueChanged<bool> onHover;
  final ValueChanged<List<String>> onDrop;
  final Widget child;

  @override
  Widget build(BuildContext context) => DropTarget(
        enable: enabled,
        onDragEntered: (_) => onHover(true),
        onDragExited: (_) => onHover(false),
        onDragDone: (d) {
          onHover(false);
          onDrop([for (final f in d.files) f.path]);
        },
        child: child,
      );
}

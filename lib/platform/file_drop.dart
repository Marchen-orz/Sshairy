import 'dart:io' show Platform;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../design/drop_preview.dart';

/// Takes files dragged in from the system's file manager on desktop; elsewhere it is just [child]. The plugin offers
/// a drop to every target under the pointer, including those under a dialog or on a hidden page, so only the
/// innermost zone a hit test reaches at that point takes it (docs/UI.md §4).
class FileDropZone extends StatefulWidget {
  const FileDropZone({
    super.key,
    this.enabled = true,
    this.preview = false,
    this.onHover,
    required this.onDrop,
    required this.child,
  });

  final bool enabled;

  /// Marks the zone with a [DropPreview] while files are over it.
  final bool preview;
  final ValueChanged<bool>? onHover;

  /// Local paths, never empty, and where they were dropped in global coordinates.
  final void Function(List<String> paths, Offset position) onDrop;
  final Widget child;

  static final supported = Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  @override
  State<FileDropZone> createState() => _FileDropZoneState();
}

final _uri = RegExp(r'^[A-Za-z][A-Za-z0-9+.-]+://');

class _FileDropZoneState extends State<FileDropZone> {
  final _zone = GlobalKey();
  var _hover = false;

  bool _reaches(Offset position) {
    final zone = _zone.currentContext?.findRenderObject();
    if (zone is! _RenderZone || !zone.attached) return false;
    final result = HitTestResult();
    WidgetsBinding.instance.hitTestInView(result, position, View.of(context).viewId);
    for (final entry in result.path) {
      if (entry.target is _RenderZone) return identical(entry.target, zone);
    }
    return false;
  }

  void _setHover(bool value) {
    if (_hover == value || !mounted) return;
    setState(() => _hover = value);
    widget.onHover?.call(value);
  }

  @override
  Widget build(BuildContext context) {
    if (!FileDropZone.supported) return widget.child;
    return DropTarget(
      enable: widget.enabled,
      onDragEntered: (d) => _setHover(_reaches(d.globalPosition)),
      onDragUpdated: (d) => _setHover(_reaches(d.globalPosition)),
      onDragExited: (_) => _setHover(false),
      onDragDone: (d) {
        _setHover(false);
        // Linux passes non-file URIs (smb://, sftp://) through as they are; they are not paths this device can open.
        final paths = [
          for (final f in d.files)
            if (f.path.isNotEmpty && !_uri.hasMatch(f.path)) f.path,
        ];
        if (widget.enabled && paths.isNotEmpty && _reaches(d.globalPosition)) widget.onDrop(paths, d.globalPosition);
      },
      child: _Zone(
        key: _zone,
        child: widget.preview && _hover
            ? Stack(
                fit: StackFit.passthrough,
                children: [
                  widget.child,
                  const Positioned.fill(child: DropPreview()),
                ],
              )
            : widget.child,
      ),
    );
  }
}

/// Counts as hit anywhere inside its bounds, without hiding what lies behind from pointers.
class _Zone extends SingleChildRenderObjectWidget {
  const _Zone({super.key, super.child});

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderZone();
}

class _RenderZone extends RenderProxyBoxWithHitTestBehavior {
  _RenderZone() : super(behavior: HitTestBehavior.translucent);
}

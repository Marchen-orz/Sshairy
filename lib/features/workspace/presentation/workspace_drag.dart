part of 'workspace_page.dart';

class _TerminalDrag {
  _TerminalDrag(this.tab, this.layout, this.pane);

  final TabId tab;
  Layout layout;
  final PaneId? pane;
  final cancelled = ValueNotifier(false);

  Layout get incoming =>
      pane == null ? layout : Layout.single(pane!, layout.leaves.firstWhere((leaf) => leaf.pane == pane).session);
}

extension _WorkspaceDrag on _WorkspacePageState {
  bool _dragCurrent(_TerminalDrag drag) =>
      !drag.cancelled.value &&
      identical(_drag, drag) &&
      identical(ref.read(workspaceProvider).tabs.where((tab) => tab.id == drag.tab).firstOrNull?.layout, drag.layout);

  Widget _draggable(WorkspaceTab tab, PaneId? pane, String name, Widget child) {
    final current = _drag;
    // Flutter reads the latest end callback, including after a pane is reparented to another tab.
    final drag = current != null && current.pane == pane && (pane != null || current.tab == tab.id)
        ? current
        : _TerminalDrag(tab.id, tab.layout, pane);
    return Draggable<_TerminalDrag>(
      data: drag,
      maxSimultaneousDrags: current == null || identical(current, drag) ? 1 : 0,
      allowedButtonsFilter: (buttons) => buttons == 1,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      rootOverlay: true,
      feedback: ValueListenableBuilder<bool>(
        valueListenable: drag.cancelled,
        builder: (context, cancelled, _) => cancelled
            ? const SizedBox.shrink()
            : Transform.translate(
                offset: const Offset(Space.md, Space.md),
                child: Material(
                  color: Colors.transparent,
                  child: PopupSurface(
                    padding: const EdgeInsets.symmetric(horizontal: Space.md, vertical: Space.sm),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: WorkspaceSize.tabMax),
                      child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
                    ),
                  ),
                ),
              ),
      ),
      onDragStarted: () => _beginTerminalDrag(drag),
      onDraggableCanceled: (_, _) => _endTerminalDrag(drag),
      onDragCompleted: () => _endTerminalDrag(drag),
      child: child,
    );
  }

  void _beginTerminalDrag(_TerminalDrag drag) {
    _tabHover?.cancel();
    _dragOrigin = ref.read(workspaceProvider);
    drag.layout = _dragOrigin!.tabs.firstWhere((tab) => tab.id == drag.tab).layout;
    _dragCommitted = false;
    FocusManager.instance.addEarlyKeyEventHandler(_dragKeyHandler);
    _updateDrag(() => _drag = drag);
  }

  void _endTerminalDrag(_TerminalDrag drag) {
    if (!identical(_drag, drag)) return;
    FocusManager.instance.removeEarlyKeyEventHandler(_dragKeyHandler);
    _tabHover?.cancel();
    _hoverTab = null;
    if (!mounted) return;
    final before = _dragOrigin;
    if (!_dragCommitted && before != null) {
      final current = ref.read(workspaceProvider);
      if (before.active == null) {
        before.files ? _workspace.showFiles() : _workspace.showVault();
      } else if (current.tabs.any((tab) => tab.id == before.active)) {
        _workspace.activate(before.active!);
      }
    }
    _updateDrag(() {
      _drag = null;
      _dragOrigin = null;
    });
  }

  KeyEventResult _dragKey(KeyEvent event) {
    final drag = _drag;
    if (drag == null || event.logicalKey != LogicalKeyboardKey.escape) return KeyEventResult.ignored;
    if (event is KeyDownEvent) {
      drag.cancelled.value = true;
      _tabHover?.cancel();
      _updateDrag(() {});
    }
    return KeyEventResult.handled;
  }

  bool _dropFits(_TerminalDrag drag, WorkspaceTab target, Leaf leaf, PaneSide side) {
    final split = drag.tab == target.id && drag.pane == null;
    final layout = drag.tab == target.id && !split ? target.layout.remove(drag.pane!) : target.layout;
    final incoming = split ? Layout.single(const PaneId(''), const SessionId('')) : drag.incoming;
    final moved = layout?.insert(leaf.pane, side, incoming);
    final box = _layoutKeys[target.id]?.currentContext?.findRenderObject() as RenderBox?;
    if (moved == null || box == null || !box.hasSize) return false;
    final affected = {leaf.pane, ...incoming.leaves.map((leaf) => leaf.pane)};
    bool fits(PaneNode node, Size size) {
      if (node is Leaf) {
        return !affected.contains(node.pane) ||
            (size.width >= WorkspaceSize.paneMin && size.height >= WorkspaceSize.paneMin + WorkspaceSize.paneHeader);
      }
      final split = node as PaneSplit;
      final horizontal = split.axis == SplitAxis.horizontal;
      final available = (horizontal ? size.width : size.height) - WorkspaceSize.divider * (split.children.length - 1);
      for (var i = 0; i < split.children.length; i++) {
        final extent = available * split.ratios[i];
        if (!fits(split.children[i], horizontal ? Size(extent, size.height) : Size(size.width, extent))) return false;
      }
      return true;
    }

    return fits(moved.root, box.size);
  }

  void _hoverTerminalTab(TabId tab, _TerminalDrag drag) {
    if (!_dragCurrent(drag) || _hoverTab == tab) return;
    _tabHover?.cancel();
    _hoverTab = tab;
    if (ref.read(workspaceProvider).active == tab) return;
    _tabHover = Timer(const Duration(milliseconds: 450), () {
      if (mounted && _hoverTab == tab && _dragCurrent(drag)) _workspace.activate(tab);
    });
  }

  void _leaveTerminalTab(TabId tab) {
    if (_hoverTab != tab) return;
    _tabHover?.cancel();
    _hoverTab = null;
  }

  bool _canDropPane(_TerminalDrag drag, WorkspaceTab target, Leaf leaf, PaneSide side) =>
      _dragCurrent(drag) &&
      (drag.tab == target.id && drag.pane == null
          ? _workspace.canSplitPane(target.id, leaf.pane, expectedLayout: drag.layout)
          : _workspace.canMoveTerminal(
              sourceTabId: drag.tab,
              sourcePaneId: drag.pane,
              targetTabId: target.id,
              targetPaneId: leaf.pane,
              side: side,
              expectedSource: drag.layout,
              expectedTarget: target.layout,
            ));

  void _dropPane(_TerminalDrag drag, WorkspaceTab target, Leaf leaf, PaneSide side) {
    if (!_canDropPane(drag, target, leaf, side)) return;
    PaneId? focused;
    if (drag.tab == target.id && drag.pane == null) {
      focused = _workspace.splitPane(target.id, leaf.pane, side, expectedLayout: drag.layout);
      _dragCommitted = focused != null;
    } else {
      _dragCommitted = _workspace.moveTerminal(
        sourceTabId: drag.tab,
        sourcePaneId: drag.pane,
        targetTabId: target.id,
        targetPaneId: leaf.pane,
        side: side,
        expectedSource: drag.layout,
        expectedTarget: target.layout,
      );
      if (_dragCommitted) focused = drag.incoming.focused;
    }
    if (focused != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _paneFocus[focused]?.requestFocus();
      });
    }
  }

  void _dropOnTabStrip(_TerminalDrag drag, TabId? target, bool after) {
    if (!_dragCurrent(drag)) return;
    final tabs = ref.read(workspaceProvider).tabs;
    final targetIndex = target == null ? tabs.length : tabs.indexWhere((tab) => tab.id == target);
    if (targetIndex < 0) return;
    var index = targetIndex + (target != null && after ? 1 : 0);
    final sourceIndex = tabs.indexWhere((tab) => tab.id == drag.tab);
    if (drag.pane == null || drag.layout.leaves.length == 1) {
      if (sourceIndex < index) index--;
      _workspace.moveTab(sourceIndex, index.clamp(0, tabs.length - 1));
      _workspace.activate(drag.tab);
      _dragCommitted = true;
    } else {
      _dragCommitted = _workspace.detachPane(drag.tab, drag.pane!, index, expectedSource: drag.layout) != null;
    }
  }

  Widget _tabDropTarget(WorkspaceTab tab, Widget child) => _TabDropTarget(
    key: ValueKey('tab-drop-${tab.id.value}'),
    enabled: (drag) => _dragCurrent(drag),
    onHover: (drag) => _hoverTerminalTab(tab.id, drag),
    onLeave: () => _leaveTerminalTab(tab.id),
    onDrop: (drag, after) => _dropOnTabStrip(drag, tab.id, after),
    child: child,
  );
}

class _TabDropTarget extends StatefulWidget {
  const _TabDropTarget({
    super.key,
    required this.enabled,
    required this.onDrop,
    this.onHover,
    this.onLeave,
    required this.child,
  });

  final bool Function(_TerminalDrag) enabled;
  final void Function(_TerminalDrag, bool after) onDrop;
  final ValueChanged<_TerminalDrag>? onHover;
  final VoidCallback? onLeave;
  final Widget child;

  @override
  State<_TabDropTarget> createState() => _TabDropTargetState();
}

class _TabDropTargetState extends State<_TabDropTarget> {
  bool? _after;

  void _move(DragTargetDetails<_TerminalDrag> details) {
    if (!widget.enabled(details.data)) return;
    final box = context.findRenderObject()! as RenderBox;
    final after = box.globalToLocal(details.offset).dx > box.size.width / 2;
    if (_after != after) setState(() => _after = after);
    widget.onHover?.call(details.data);
    Scrollable.maybeOf(context)?.position.ensureVisible(
      box,
      alignment: after ? 1 : 0,
      duration: Motion.of(context, Motion.quick),
    );
  }

  @override
  Widget build(BuildContext context) => DragTarget<_TerminalDrag>(
    onWillAcceptWithDetails: (details) {
      if (!widget.enabled(details.data)) return false;
      _move(details);
      return true;
    },
    onMove: _move,
    onLeave: (_) {
      setState(() => _after = null);
      widget.onLeave?.call();
    },
    onAcceptWithDetails: (details) {
      if (widget.enabled(details.data)) widget.onDrop(details.data, _after ?? false);
      setState(() => _after = null);
    },
    builder: (context, candidates, _) => Stack(
      children: [
        widget.child,
        if (_after != null && candidates.whereType<_TerminalDrag>().any(widget.enabled))
          Positioned(
            top: Space.sm,
            bottom: Space.sm,
            left: _after! ? null : 0,
            right: _after! ? 0 : null,
            width: WorkspaceSize.divider * 2,
            child: IgnorePointer(child: ColoredBox(color: Theme.of(context).colorScheme.primary)),
          ),
      ],
    ),
  );
}

class _PaneDropTarget extends StatefulWidget {
  const _PaneDropTarget({
    super.key,
    required this.drag,
    required this.enabled,
    required this.fits,
    required this.onDrop,
    required this.child,
  });

  final _TerminalDrag? drag;
  final bool Function(_TerminalDrag, PaneSide) enabled;
  final bool Function(_TerminalDrag, PaneSide) fits;
  final void Function(_TerminalDrag, PaneSide) onDrop;
  final Widget child;

  @override
  State<_PaneDropTarget> createState() => _PaneDropTargetState();
}

class _PaneDropTargetState extends State<_PaneDropTarget> {
  PaneSide? _side;

  PaneSide? _destination(DragTargetDetails<_TerminalDrag> details) {
    final box = context.findRenderObject()! as RenderBox;
    final size = box.size, point = box.globalToLocal(details.offset);
    if (!(Offset.zero & size).contains(point)) return null;
    final x = point.dx / size.width, y = point.dy / size.height;
    final edges = {PaneSide.left: x, PaneSide.right: 1 - x, PaneSide.top: y, PaneSide.bottom: 1 - y};
    final side = edges.entries.reduce((a, b) => a.value <= b.value ? a : b);
    if (side.value > .25 || !widget.enabled(details.data, side.key) || !widget.fits(details.data, side.key)) {
      return null;
    }
    return side.key;
  }

  void _move(DragTargetDetails<_TerminalDrag> details) {
    final side = _destination(details);
    if (side != _side) setState(() => _side = side);
  }

  @override
  Widget build(BuildContext context) => DragTarget<_TerminalDrag>(
    onWillAcceptWithDetails: (details) {
      _move(details);
      return PaneSide.values.any((side) => widget.enabled(details.data, side));
    },
    onMove: _move,
    onLeave: (_) => setState(() => _side = null),
    onAcceptWithDetails: (details) {
      final side = _destination(details);
      if (side != null) widget.onDrop(details.data, side);
      setState(() => _side = null);
    },
    builder: (context, _, _) => Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        if (_side case final side? when widget.drag != null && widget.enabled(widget.drag!, side))
          Positioned.fill(
            child: FractionallySizedBox(
              widthFactor: side.axis == SplitAxis.horizontal ? .5 : 1,
              heightFactor: side.axis == SplitAxis.vertical ? .5 : 1,
              alignment: switch (side) {
                PaneSide.left => Alignment.centerLeft,
                PaneSide.right => Alignment.centerRight,
                PaneSide.top => Alignment.topCenter,
                PaneSide.bottom => Alignment.bottomCenter,
              },
              child: const DropPreview(key: ValueKey('pane-drop-preview')),
            ),
          ),
      ],
    ),
  );
}

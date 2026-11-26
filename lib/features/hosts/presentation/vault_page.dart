import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../design/brand.dart';
import '../../../design/dialog.dart';
import '../../../design/double_click.dart';
import '../../../design/menu.dart';
import '../../../design/popup.dart';
import '../../../design/scrolling.dart';
import '../../../design/side_drawer.dart';
import '../../../design/theme.dart';
import '../../../l10n/app_localizations.dart';
import '../../../foundation/ids.dart';
import '../../../platform/device_form_factor.dart';
import '../../settings/api.dart';
import '../application/hosts.dart';
import '../domain/host.dart';
import '../domain/host_library.dart';
import 'group_panel.dart';
import 'host_form.dart';
import 'identities_panel.dart';
import 'import_dialog.dart';
import 'keys_panel.dart';
import 'move_hosts_dialog.dart';

const _gridTile = 320.0, _gridRow = 64.0, _sectionHeader = 28.0;

/// A saved local terminal as the vault shows it; the terminal feature owns the data (docs/UI.md §3).
class VaultLocal {
  const VaultLocal({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.matches,
    required this.onOpen,
    required this.editor,
    required this.onDelete,
  });

  final String id, title, subtitle;
  final bool Function(String query) matches;
  final VoidCallback onOpen;
  final WidgetBuilder editor;
  final Future<void> Function() onDelete;
}

class VaultPage extends ConsumerStatefulWidget {
  const VaultPage({super.key, required this.active, required this.onConnect, this.locals = const [], this.localForm});

  final bool active;
  final void Function(Host host) onConnect;

  /// Shown below the hosts while no group is picked.
  final List<VaultLocal> locals;

  /// The form a new entry switches to for a local terminal.
  final WidgetBuilder? localForm;

  @override
  ConsumerState<VaultPage> createState() => _VaultPageState();
}

class _VaultPageState extends ConsumerState<VaultPage> {
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  final _groupScroll = ScrollController();

  /// The group being shown; empty for every host.
  var _group = '';
  final _selected = <HostId>{};
  HostId? _anchor;
  HostLibrary? _groupOrderBase, _groupOrderPreview;
  var _groupOrderSaving = false;
  var _hostsCollapsed = false, _localsCollapsed = false;

  /// The setting lands only after its write, so this keeps a second offer from opening meanwhile.
  var _offered = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _offerImport());
  }

  @override
  void didUpdateWidget(VaultPage old) {
    super.didUpdateWidget(old);
    if (widget.active && !old.active) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.active) _searchFocus.requestFocus();
        _offerImport();
      });
    }
  }

  /// Once, on an empty desktop vault (docs/HOST_IMPORT.md).
  void _offerImport() {
    if (!isDesktopPlatform) return;
    if (_offered || !mounted || !widget.active || ref.read(settingsProvider).get(SettingKeys.importOffered)) return;
    if (ref.read(hostsProvider).isNotEmpty) return;
    _offered = true;
    ref.read(settingsProvider.notifier).set(SettingKeys.importOffered, true);
    showImportDialog(context, welcome: true);
  }

  @override
  void dispose() {
    _search.dispose();
    _searchFocus.dispose();
    _groupScroll.dispose();
    super.dispose();
  }

  HostsNotifier get _hosts => ref.read(hostsProvider.notifier);

  void _edit([Host? host]) => showSideDrawer<void>(
    context,
    (_) => HostForm(host: host, group: _group, localForm: host == null ? widget.localForm : null),
  );

  List<(String, VoidCallback)> _localActions(VaultLocal local) {
    final l = AppLocalizations.of(context);
    return [(l.edit, () => showSideDrawer<void>(context, local.editor)), (l.delete, () => _deleteLocal(local))];
  }

  Future<void> _localMenu(VaultLocal local, Offset position) async {
    final l = AppLocalizations.of(context);
    final run = await showAppMenu<VoidCallback>(
      context: context,
      anchor: anchorAt(position),
      items: [
        for (final (label, action) in _localActions(local))
          AppMenuItem(value: action, label: label, destructive: label == l.delete),
      ],
    );
    run?.call();
  }

  Future<void> _deleteLocal(VaultLocal local) async {
    final l = AppLocalizations.of(context);
    final ok = await showAppDialog<bool>(
      context: context,
      builder: (context) => AppDialog(
        content: Text(l.deleteHost(local.title)),
        actions: [
          TextButton(autofocus: true, onPressed: () => Navigator.pop(context, false), child: Text(l.cancel)),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.pop(context, true),
            child: Text(l.delete),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await local.onDelete();
    } on Object {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.errSave)));
    }
  }

  Future<void> _delete(List<HostId> ids) async {
    final l = AppLocalizations.of(context);
    final hosts = _hosts;
    final targets = ids.toSet().toList();
    if (targets.isEmpty) return;
    final revision = hosts.revision;
    final title = hosts.byId(targets.first)?.title ?? '';

    final ok = await showAppDialog<bool>(
      context: context,
      builder: (context) => AppDialog(
        content: Text(targets.length == 1 ? l.deleteHost(title) : l.deleteHostsConfirm(targets.length)),
        actions: [
          TextButton(autofocus: true, onPressed: () => Navigator.pop(context, false), child: Text(l.cancel)),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.pop(context, true),
            child: Text(l.delete),
          ),
        ],
      ),
    );
    if (!(ok ?? false)) return;
    try {
      await hosts.deleteMany(targets, expectedRevision: revision);
    } on HostInUse catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.hostInUse(e.references.join(', ')))));
      }
    } on HostDeleteCleanupFailure {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.hostDeleteCleanupFailed)));
    } on Object {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.errSave)));
    }
  }

  Future<void> _reorderGroup(String id, String? beforeId, int revision) async {
    if (_groupOrderSaving) return;
    try {
      final base = _hosts.library;
      final preview = base.withGroupBefore(id, beforeId);
      if (identical(preview, base)) return;
      // Native reorder clears its gap immediately; keep the dropped order until the committed library takes over.
      setState(() {
        _groupOrderBase = base;
        _groupOrderPreview = preview;
        _groupOrderSaving = true;
      });
      await _hosts.reorderGroup(id, beforeId, expectedRevision: revision);
    } on Object {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(AppLocalizations.of(context).errSave)));
      }
    } finally {
      if (mounted && _groupOrderSaving) {
        setState(() {
          _groupOrderBase = null;
          _groupOrderPreview = null;
          _groupOrderSaving = false;
        });
      }
    }
  }

  Future<void> _groupMenu(String path, Offset p) async {
    final l = AppLocalizations.of(context);
    final library = ref.read(hostLibraryProvider);
    final group = library.groupById(library.groupIdFor(path));
    if (group == null) return;
    final run = await showAppMenu<VoidCallback>(
      context: context,
      anchor: anchorAt(p),
      items: [
        AppMenuItem(value: () => _editGroup(group), label: l.editGroup),
        AppMenuItem(value: () => _dissolve(group), label: l.dissolveGroup),
      ],
    );
    run?.call();
  }

  Future<void> _editGroup(HostGroup group) async {
    final shown = _group == ref.read(hostLibraryProvider).groupPath(group.id);
    await showSideDrawer<void>(context, (_) => GroupPanel(group: group));
    if (!mounted || !shown) return;
    // The view follows the group when its path changed.
    final library = ref.read(hostLibraryProvider);
    if (library.groupById(group.id) != null) setState(() => _group = library.groupPath(group.id));
  }

  /// Members move up a level; the group's own defaults are discarded, so a group that has some asks first.
  Future<void> _dissolve(HostGroup group) async {
    final l = AppLocalizations.of(context);
    final library = ref.read(hostLibraryProvider);
    final path = library.groupPath(group.id);
    final parent = group.parentId == null ? '' : library.groupPath(group.parentId);
    if (!group.defaults.isEmpty) {
      final ok = await showAppDialog<bool>(
        context: context,
        builder: (context) => AppDialog(
          content: Text(l.dissolveGroupConfirm(path)),
          actions: [
            TextButton(autofocus: true, onPressed: () => Navigator.pop(context, false), child: Text(l.cancel)),
            TextButton(
              style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
              onPressed: () => Navigator.pop(context, true),
              child: Text(l.dissolveGroup),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    try {
      await _hosts.deleteGroup(group.id);
      if (mounted) setState(() => _group = parent);
    } on Object {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.errSave)));
    }
  }

  void _select(HostId id, List<Host> visible, {bool toggle = false, bool range = false}) {
    final ids = visible.map((h) => h.id).toList();
    setState(() {
      if (range && _anchor != null && ids.contains(_anchor)) {
        final a = ids.indexOf(_anchor!), b = ids.indexOf(id);
        final span = ids.sublist(a < b ? a : b, (a < b ? b : a) + 1);
        if (!toggle) _selected.clear();
        _selected.addAll(span);
      } else {
        if (!toggle) {
          _selected.clear();
          _selected.add(id);
        } else if (!_selected.remove(id)) {
          _selected.add(id);
        }
        _anchor = id;
      }
    });
  }

  void _selectClick(Host host, List<Host> visible) {
    final keys = HardwareKeyboard.instance;
    _select(host.id, visible, toggle: keys.isControlPressed || keys.isMetaPressed, range: keys.isShiftPressed);
  }

  List<HostId> _targets(Host host) {
    if (!_selected.contains(host.id)) {
      setState(() {
        _selected.clear();
        _selected.add(host.id);
        _anchor = host.id;
      });
    }
    return _selected.toList();
  }

  Future<void> _moveHosts(List<HostId> ids) async {
    if (ids.isEmpty) return;
    await showAppDialog<void>(
      context: context,
      builder: (_) => MoveHostsDialog(hostIds: ids),
    );
  }

  List<(String, VoidCallback)> _hostActions(Host host) {
    final l = AppLocalizations.of(context);
    final targets = _targets(host);
    return [
      if (targets.length == 1) ...[
        (l.edit, () => _edit(host)),
        (l.duplicate, () => _hosts.duplicate(host, l.copyOf(host.title))),
        (host.pinned ? l.unpin : l.pin, () => _hosts.setPinned(host, !host.pinned)),
      ],
      (l.moveToGroup, () => _moveHosts(targets)),
      (l.delete, () => _delete(targets)),
    ];
  }

  Future<void> _hostMenu(Host host, Offset position) async {
    final actions = _hostActions(host);
    final run = await showAppMenu<VoidCallback>(
      context: context,
      anchor: anchorAt(position),
      items: [
        for (final (label, action) in actions)
          AppMenuItem(value: action, label: label, destructive: label == AppLocalizations.of(context).delete),
      ],
    );
    run?.call();
  }

  void _submit(List<Host> matches, List<VaultLocal> locals, Host? quick) {
    if (quick != null) {
      widget.onConnect(quick);
    } else if (matches.length == 1 && locals.isEmpty) {
      widget.onConnect(matches.single);
    } else if (matches.isEmpty && locals.length == 1) {
      locals.single.onOpen();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final query = _search.text.trim();
    final hosts = ref.watch(hostsProvider);
    final settings = ref.watch(settingsProvider);
    final view = settings.get(SettingKeys.hostView);
    final order = settings.get(SettingKeys.hostOrder);
    final library = ref.watch(hostLibraryProvider);
    final groups = library.groupPaths;
    if (_group.isNotEmpty && !groups.contains(_group)) _group = '';
    final matches = sortHosts(
      hosts.where((h) => inGroup(h, _group) && hostMatches(h, query)),
      recent: order == HostOrder.recent,
    );
    final locals = _group.isEmpty
        ? [
            for (final local in widget.locals)
              if (local.matches(query)) local,
          ]
        : <VaultLocal>[];
    final quick = query.isEmpty ? null : parseQuickConnect(_search.text);
    final visibleIds = {for (final host in matches) host.id};
    _selected.retainAll(visibleIds);
    if (!visibleIds.contains(_anchor)) _anchor = null;

    Widget localTile(VaultLocal local) => _VaultTile(
      key: ValueKey('local-${local.id}'),
      title: local.title,
      subtitle: local.subtitle,
      icon: Icons.terminal,
      list: view == HostView.list,
      selected: false,
      onSelect: () {},
      onToggle: () {},
      onSelectAll: () {},
      onClear: () {},
      onConnect: local.onOpen,
      onSecondaryTap: (position) => _localMenu(local, position),
      actions: () => _localActions(local),
    );

    Widget tile(Host h) {
      return _VaultTile(
        key: ValueKey(h.id),
        title: h.title,
        subtitle: h.target,
        detail: [if (h.group.isNotEmpty) h.group, ...h.tags.map((t) => '#$t')].join('  '),
        pinned: h.pinned,
        list: view == HostView.list,
        selected: _selected.contains(h.id),
        onSelect: () => _selectClick(h, matches),
        onToggle: () => _select(h.id, matches, toggle: true),
        onSelectAll: () => setState(() => _selected.addAll(visibleIds)),
        onClear: () => setState(() {
          _selected.clear();
          _anchor = null;
        }),
        onConnect: () => widget.onConnect(h),
        onSecondaryTap: (position) => _hostMenu(h, position),
        actions: () => _hostActions(h),
      );
    }

    return Padding(
      padding: const EdgeInsets.all(Space.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _search,
                  focusNode: _searchFocus,
                  autofocus: true,
                  decoration: InputDecoration(hintText: l.searchHint, prefixIcon: const Icon(Icons.search, size: 16)),
                  onChanged: (_) => setState(() {}),
                  onSubmitted: (_) => _submit(matches, locals, quick),
                ),
              ),
              const SizedBox(width: Space.sm),
              IconButton(
                tooltip: view == HostView.grid ? l.listView : l.gridView,
                onPressed: () => ref
                    .read(settingsProvider.notifier)
                    .set(SettingKeys.hostView, view == HostView.grid ? HostView.list : HostView.grid),
                icon: Icon(view == HostView.grid ? Icons.view_list_outlined : Icons.grid_view_outlined, size: 18),
              ),
              AppMenuButton<HostOrder>(
                tooltip: order == HostOrder.name ? l.sortName : l.sortRecent,
                icon: const Icon(Icons.sort, size: 18),
                onSelected: (v) => ref.read(settingsProvider.notifier).set(SettingKeys.hostOrder, v),
                items: () => [
                  AppMenuItem(value: HostOrder.name, label: l.sortName, checked: order == HostOrder.name),
                  AppMenuItem(value: HostOrder.recent, label: l.sortRecent, checked: order == HostOrder.recent),
                ],
              ),
              IconButton(
                tooltip: l.newGroup,
                onPressed: () => showSideDrawer<void>(context, (_) => GroupPanel(parent: _group)),
                icon: const Icon(Icons.create_new_folder_outlined, size: 18),
              ),
              IconButton(
                tooltip: l.importHosts,
                onPressed: () => showImportDialog(context),
                icon: const Icon(Icons.input_rounded, size: 18),
              ),
              AppMenuButton<VoidCallback>(
                tooltip: l.more,
                icon: const Icon(Icons.tune_outlined, size: 18),
                onSelected: (run) => run(),
                items: () => [
                  if (_selected.isNotEmpty) ...[
                    AppMenuItem(value: () => _moveHosts(_selected.toList()), label: l.moveToGroup),
                    AppMenuItem(value: () => _delete(_selected.toList()), label: l.delete, destructive: true),
                    const AppMenuDivider(),
                  ],
                  AppMenuItem(
                    value: () => showSideDrawer<void>(context, (_) => const DefaultsPanel()),
                    label: l.globalDefaults,
                  ),
                  AppMenuItem(
                    value: () => showSideDrawer<void>(context, (_) => const IdentitiesPanel()),
                    label: l.identities,
                  ),
                  AppMenuItem(value: () => showSideDrawer<void>(context, (_) => const KeysPanel()), label: l.keys),
                ],
              ),
              const SizedBox(width: Space.sm),
              FilledButton.icon(onPressed: _edit, icon: const Icon(Icons.add, size: 16), label: Text(l.newHost)),
            ],
          ),
          if (groups.isNotEmpty) ...[
            const SizedBox(height: Space.md),
            SizedBox(
              height: 32,
              child: _GroupOrderBar(
                library: identical(library, _groupOrderBase) ? _groupOrderPreview ?? library : library,
                revision: _hosts.revision,
                reorderEnabled: !_groupOrderSaving,
                controller: _groupScroll,
                selected: _group,
                onSelected: (group) => setState(() => _group = group),
                onMenu: _groupMenu,
                onReorder: _reorderGroup,
              ),
            ),
          ],
          const SizedBox(height: Space.md),
          if (quick != null) ...[
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: () => widget.onConnect(quick),
                icon: const Icon(Icons.bolt, size: 16),
                label: Text(l.connectTo(quick.target)),
              ),
            ),
            const SizedBox(height: Space.md),
          ],
          Expanded(
            child: matches.isEmpty && locals.isEmpty
                ? (query.isEmpty
                      ? BrandEmptyState(
                          active: widget.active,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(hosts.isEmpty ? l.noHosts : l.noHostsInGroup, style: theme.textTheme.titleMedium),
                              const SizedBox(height: Space.xs),
                              Text(
                                l.hostEmptyHint,
                                textAlign: TextAlign.center,
                                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                              ),
                            ],
                          ),
                        )
                      : quick != null
                      ? const SizedBox.shrink()
                      : Center(child: Text(l.noMatches)))
                : ScrollGutterLayout(
                    builder: (context, constraints) {
                      final list = view == HostView.list;
                      final contentWidth = constraints.maxWidth - ScrollGutterScope.gapOf(context);
                      // Fixed row extents give the hosts' height exactly; the watermark only fills space they leave.
                      final columns = list ? 1 : (contentWidth / (_gridTile + Space.sm)).ceil();
                      int rows(int count) => (count / columns).ceil();
                      final both = locals.isNotEmpty && matches.isNotEmpty;
                      final showSections = locals.isNotEmpty;
                      final hostsOpen = !showSections || !_hostsCollapsed;
                      final localsOpen = !_localsCollapsed;
                      final hostRows = hostsOpen ? rows(matches.length) : 0;
                      final localRows = localsOpen ? rows(locals.length) : 0;
                      final headers = (showSections && matches.isNotEmpty ? 1 : 0) + (locals.isNotEmpty ? 1 : 0);
                      final headerGaps =
                          (showSections && matches.isNotEmpty && hostsOpen ? 1 : 0) +
                          (locals.isNotEmpty && localsOpen ? 1 : 0);
                      final used =
                          (hostRows + localRows) * (list ? WorkspaceSize.listRow + Space.xs : _gridRow + Space.sm) +
                          headers * _sectionHeader +
                          headerGaps * Space.xs +
                          (both ? Space.md : 0);
                      Widget section(int count, Widget Function(int) item) => list
                          ? SliverList.separated(
                              itemCount: count,
                              separatorBuilder: (_, _) => const SizedBox(height: Space.xs),
                              itemBuilder: (context, i) => item(i),
                            )
                          : SliverGrid.builder(
                              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                                maxCrossAxisExtent: _gridTile,
                                mainAxisExtent: _gridRow,
                                crossAxisSpacing: Space.sm,
                                mainAxisSpacing: Space.sm,
                              ),
                              itemCount: count,
                              itemBuilder: (context, i) => item(i),
                            );
                      final spare =
                          constraints.maxHeight - used >= BrandWatermark.height + Space.xl + Space.lg &&
                          contentWidth >= BrandWatermark.width * 3;
                      return Stack(
                        fit: StackFit.expand,
                        children: [
                          if (spare)
                            Positioned(
                              right: Space.lg,
                              bottom: Space.lg,
                              child: BrandWatermark(active: widget.active),
                            ),
                          CustomScrollView(
                            slivers: [
                              if (showSections && matches.isNotEmpty)
                                SliverToBoxAdapter(
                                  child: _VaultSectionHeader(
                                    title: l.hosts,
                                    count: matches.length,
                                    collapsed: _hostsCollapsed,
                                    onToggle: () => setState(() => _hostsCollapsed = !_hostsCollapsed),
                                  ),
                                ),
                              if (showSections && matches.isNotEmpty && hostsOpen)
                                const SliverToBoxAdapter(child: SizedBox(height: Space.xs)),
                              if (matches.isNotEmpty && hostsOpen) section(matches.length, (i) => tile(matches[i])),
                              if (both) const SliverToBoxAdapter(child: SizedBox(height: Space.md)),
                              if (locals.isNotEmpty)
                                SliverToBoxAdapter(
                                  child: _VaultSectionHeader(
                                    title: l.localTerminals,
                                    count: locals.length,
                                    collapsed: _localsCollapsed,
                                    onToggle: () => setState(() => _localsCollapsed = !_localsCollapsed),
                                  ),
                                ),
                              if (locals.isNotEmpty && localsOpen)
                                const SliverToBoxAdapter(child: SizedBox(height: Space.xs)),
                              if (locals.isNotEmpty && localsOpen) section(locals.length, (i) => localTile(locals[i])),
                            ],
                          ),
                        ],
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _VaultSectionHeader extends StatelessWidget {
  const _VaultSectionHeader({
    required this.title,
    required this.count,
    required this.collapsed,
    required this.onToggle,
  });

  final String title;
  final int count;
  final bool collapsed;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return SizedBox(
      height: _sectionHeader,
      child: Align(
        alignment: Alignment.centerLeft,
        child: InkWell(
          borderRadius: BorderRadius.circular(Radii.control),
          onTap: onToggle,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.xs, vertical: Space.xs),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(collapsed ? Icons.chevron_right : Icons.expand_more, size: 16, color: muted),
                const SizedBox(width: Space.xs),
                Text(title, style: theme.textTheme.labelMedium?.copyWith(color: muted)),
                const SizedBox(width: Space.xs),
                Text('$count', style: theme.textTheme.labelSmall?.copyWith(color: muted.withValues(alpha: .7))),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _GroupOrderBar extends StatelessWidget {
  const _GroupOrderBar({
    required this.library,
    required this.revision,
    required this.reorderEnabled,
    required this.controller,
    required this.selected,
    required this.onSelected,
    required this.onMenu,
    required this.onReorder,
  });

  final HostLibrary library;
  final int revision;
  final bool reorderEnabled;
  final ScrollController controller;
  final String selected;
  final ValueChanged<String> onSelected;
  final void Function(String, Offset) onMenu;
  final Future<void> Function(String, String?, int) onReorder;

  Widget _chip(BuildContext context, String path) => Padding(
    padding: const EdgeInsets.only(right: Space.sm),
    child: GestureDetector(
      onSecondaryTapUp: path.isEmpty ? null : (d) => onMenu(path, d.globalPosition),
      child: ChoiceChip(
        key: ValueKey('group-chip-$path'),
        showCheckmark: false,
        visualDensity: VisualDensity.compact,
        label: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (path.isNotEmpty) ...[
              Icon(Icons.folder_outlined, size: 16, color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: Space.xs),
            ],
            Flexible(
              child: Tooltip(
                message: path.isEmpty ? AppLocalizations.of(context).allHosts : path,
                child: Text(
                  path.isEmpty ? AppLocalizations.of(context).allHosts : path,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            const SizedBox(width: Space.sm),
            Text(library.hosts.where((host) => inGroup(host, path)).length.toString()),
          ],
        ),
        selected: selected == path,
        onSelected: (_) => onSelected(path),
      ),
    ),
  );

  void _move(List<HostGroup> siblings, int from, int to) {
    final sequence = siblings.toList();
    final moved = sequence.removeAt(from);
    sequence.insert(to, moved);
    onReorder(moved.id, to + 1 < sequence.length ? sequence[to + 1].id : null, revision);
  }

  Widget _branch(BuildContext context, HostGroup group, double width) {
    final children = library.groupChildren(group.id);
    final chip = _chip(context, library.groupPath(group.id));
    if (children.isEmpty) {
      return ConstrainedBox(
        constraints: BoxConstraints(maxWidth: width),
        child: chip,
      );
    }
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: width),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: width / 2),
            child: chip,
          ),
          Flexible(
            child: LayoutBuilder(
              builder: (context, constraints) => _list(context, children, constraints.maxWidth, parent: group.id),
            ),
          ),
        ],
      ),
    );
  }

  Widget _list(BuildContext context, List<HostGroup> siblings, double width, {String? parent}) =>
      ReorderableListView.builder(
        // A changed library cancels an in-flight drag instead of applying its old indices to new groups.
        key: ValueKey(('group-order-list', parent, revision)),
        scrollController: parent == null ? controller : null,
        scrollDirection: Axis.horizontal,
        shrinkWrap: true,
        padding: EdgeInsets.zero,
        buildDefaultDragHandles: false,
        itemCount: siblings.length,
        onReorderItem: (from, to) {
          if (reorderEnabled) _move(siblings, from, to);
        },
        proxyDecorator: (child, _, _) => Material(type: MaterialType.transparency, child: child),
        itemBuilder: (context, index) => ReorderableDragStartListener(
          key: ValueKey(siblings[index].id),
          index: index,
          enabled: reorderEnabled,
          child: _branch(context, siblings[index], width),
        ),
      );

  @override
  Widget build(BuildContext context) => Row(
    children: [
      _chip(context, ''),
      Expanded(
        child: LayoutBuilder(
          builder: (context, constraints) => _list(context, library.groupChildren(null), constraints.maxWidth),
        ),
      ),
    ],
  );
}

class _VaultTile extends StatefulWidget {
  const _VaultTile({
    super.key,
    required this.title,
    required this.subtitle,
    this.detail = '',
    this.icon = Icons.dns_outlined,
    this.pinned = false,
    required this.list,
    required this.selected,
    required this.onSelect,
    required this.onToggle,
    required this.onSelectAll,
    required this.onClear,
    required this.onConnect,
    required this.onSecondaryTap,
    required this.actions,
  });

  final String title, subtitle;

  /// Group and tags in the list row.
  final String detail;
  final IconData icon;
  final bool pinned;

  /// A dense row with [detail], instead of a card.
  final bool list, selected;
  final VoidCallback onConnect, onSelect, onToggle, onSelectAll, onClear;
  final ValueChanged<Offset> onSecondaryTap;
  final List<(String, VoidCallback)> Function() actions;

  @override
  State<_VaultTile> createState() => _VaultTileState();
}

class _VaultTileState extends State<_VaultTile> {
  final _focus = FocusNode();
  var _clicks = DoubleClick();
  var _hovered = false, _focused = false;

  void _tap() {
    _focus.requestFocus();
    final keys = HardwareKeyboard.instance;
    final modified = keys.isControlPressed || keys.isMetaPressed || keys.isShiftPressed;
    if (modified) _clicks = DoubleClick();
    widget.onSelect();
    if (!modified && _clicks.hit) {
      widget.onConnect();
      _clicks = DoubleClick();
    }
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final name = Row(
      children: [
        Flexible(
          child: Tooltip(
            message: widget.title,
            child: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ),
        if (widget.pinned) ...[
          const SizedBox(width: Space.xs),
          Icon(Icons.push_pin, size: 12, color: theme.colorScheme.primary),
        ],
      ],
    );
    final target = Text(widget.subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: muted);
    final avatar = Container(
      width: widget.list ? 24 : 32,
      height: widget.list ? 24 : 32,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(Radii.control),
      ),
      child: Icon(widget.icon, size: widget.list ? 14 : 16, color: theme.colorScheme.primary),
    );
    // Stays in the tree when hidden: an open menu would otherwise lose its selection when focus moves.
    final actions = AnimatedOpacity(
      opacity: _hovered || _focused || widget.selected ? 1 : 0,
      duration: Motion.of(context, Motion.quick),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: l.connect,
            onPressed: widget.onConnect,
            icon: const Icon(Icons.play_arrow_outlined, size: 16),
          ),
          AppMenuButton<VoidCallback>(
            tooltip: l.more,
            icon: const Icon(Icons.more_horiz, size: 16),
            onSelected: (action) => action(),
            items: () => [
              for (final (label, run) in widget.actions())
                AppMenuItem(value: run, label: label, destructive: label == l.delete),
            ],
          ),
        ],
      ),
    );
    final content = widget.list
        ? Row(
            children: [
              avatar,
              const SizedBox(width: Space.md),
              Expanded(flex: 3, child: name),
              Expanded(flex: 3, child: target),
              Expanded(
                flex: 3,
                child: Text(widget.detail, maxLines: 1, overflow: TextOverflow.ellipsis, style: muted),
              ),
              actions,
            ],
          )
        : Row(
            children: [
              avatar,
              const SizedBox(width: Space.md),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [name, target],
                ),
              ),
              actions,
            ],
          );
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onFocusChange: (v) => setState(() => _focused = v),
        child: CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.enter): widget.onConnect,
            const SingleActivator(LogicalKeyboardKey.numpadEnter): widget.onConnect,
            const SingleActivator(LogicalKeyboardKey.space): widget.onToggle,
            const SingleActivator(LogicalKeyboardKey.keyA, control: true): widget.onSelectAll,
            const SingleActivator(LogicalKeyboardKey.keyA, meta: true): widget.onSelectAll,
            const SingleActivator(LogicalKeyboardKey.escape): widget.onClear,
          },
          child: Semantics(
            selected: widget.selected,
            child: TweenAnimationBuilder<Color?>(
              tween: ColorTween(end: widget.selected ? theme.colorScheme.primaryContainer : theme.colorScheme.surface),
              duration: Motion.of(context, Motion.quick),
              builder: (context, color, child) =>
                  Card(margin: EdgeInsets.zero, color: color, clipBehavior: Clip.antiAlias, child: child),
              child: InkWell(
                focusNode: _focus,
                onTap: _tap,
                onSecondaryTapUp: (details) {
                  _focus.requestFocus();
                  _clicks = DoubleClick();
                  widget.onSecondaryTap(details.globalPosition);
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Space.md),
                  child: widget.list ? SizedBox(height: WorkspaceSize.listRow, child: content) : content,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

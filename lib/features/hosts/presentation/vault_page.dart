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

const _gridTile = 320.0, _gridRow = 64.0;

class VaultPage extends ConsumerStatefulWidget {
  const VaultPage({super.key, required this.active, required this.onConnect});

  final bool active;
  final void Function(Host host) onConnect;

  @override
  ConsumerState<VaultPage> createState() => _VaultPageState();
}

class _VaultPageState extends ConsumerState<VaultPage> {
  final _search = TextEditingController();
  final _searchFocus = FocusNode();

  /// The group being shown; empty for every host.
  var _group = '';
  final _selected = <HostId>{};
  HostId? _anchor;

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

  /// Once, on an empty vault (docs/HOST_IMPORT.md).
  void _offerImport() {
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
    super.dispose();
  }

  HostsNotifier get _hosts => ref.read(hostsProvider.notifier);

  void _edit([Host? host]) => showSideDrawer<void>(context, (_) => HostForm(host: host, group: _group));

  Future<void> _delete(Host host) async {
    final l = AppLocalizations.of(context);
    final ok = await showAppDialog<bool>(
      context: context,
      builder: (context) => AppDialog(
        content: Text(l.deleteHost(host.title)),
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
      await _hosts.delete(host);
    } on HostInUse catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.hostInUse(e.references.join(', ')))));
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

  Future<void> _hostMenu(Host host, Offset position, List<(String, VoidCallback)> actions) async {
    _targets(host);
    final run = await showAppMenu<VoidCallback>(
      context: context,
      anchor: anchorAt(position),
      items: [for (final (label, action) in actions) AppMenuItem(value: action, label: label)],
    );
    run?.call();
  }

  void _submit(List<Host> matches, Host? quick) {
    if (quick != null) {
      widget.onConnect(quick);
    } else if (matches.length == 1) {
      widget.onConnect(matches.single);
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
    final groups = ref.watch(hostLibraryProvider).groupPaths;
    if (_group.isNotEmpty && !groups.contains(_group)) _group = '';
    final matches = sortHosts(
      hosts.where((h) => inGroup(h, _group) && hostMatches(h, query)),
      recent: order == HostOrder.recent,
    );
    final quick = query.isEmpty ? null : parseQuickConnect(_search.text);
    final visibleIds = {for (final host in matches) host.id};
    _selected.retainAll(visibleIds);
    if (!visibleIds.contains(_anchor)) _anchor = null;

    Widget tile(Host h) {
      final actions = <(String, VoidCallback)>[
        (l.edit, () => _edit(h)),
        (l.duplicate, () => _hosts.duplicate(h, l.copyOf(h.title))),
        (h.pinned ? l.unpin : l.pin, () => _hosts.setPinned(h, !h.pinned)),
        (l.moveToGroup, () => _moveHosts(_targets(h))),
        (l.delete, () => _delete(h)),
      ];
      return _HostTile(
        key: ValueKey(h.id),
        host: h,
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
        onMenu: () => _targets(h),
        onSecondaryTap: (position) => _hostMenu(h, position, actions),
        actions: actions,
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
                  onSubmitted: (_) => _submit(matches, quick),
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
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  for (final g in ['', ...groups])
                    Padding(
                      padding: const EdgeInsets.only(right: Space.sm),
                      child: GestureDetector(
                        onSecondaryTapUp: g.isEmpty ? null : (d) => _groupMenu(g, d.globalPosition),
                        child: ChoiceChip(
                          showCheckmark: false,
                          visualDensity: VisualDensity.compact,
                          label: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (g.isNotEmpty) ...[
                                Icon(Icons.folder_outlined, size: 16, color: theme.colorScheme.primary),
                                const SizedBox(width: Space.xs),
                              ],
                              Text(g.isEmpty ? l.allHosts : g),
                            ],
                          ),
                          selected: _group == g,
                          onSelected: (_) => setState(() => _group = g),
                        ),
                      ),
                    ),
                ],
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
            child: matches.isEmpty
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
                      final rows = list
                          ? matches.length
                          : (matches.length / (contentWidth / (_gridTile + Space.sm)).ceil()).ceil();
                      final used = list ? rows * (WorkspaceSize.listRow + Space.xs) : rows * (_gridRow + Space.sm);
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
                          list
                              ? ListView.separated(
                                  itemCount: matches.length,
                                  separatorBuilder: (_, _) => const SizedBox(height: Space.xs),
                                  itemBuilder: (context, i) => tile(matches[i]),
                                )
                              : GridView.builder(
                                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                                    maxCrossAxisExtent: _gridTile,
                                    mainAxisExtent: _gridRow,
                                    crossAxisSpacing: Space.sm,
                                    mainAxisSpacing: Space.sm,
                                  ),
                                  itemCount: matches.length,
                                  itemBuilder: (context, i) => tile(matches[i]),
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

class _HostTile extends StatefulWidget {
  const _HostTile({
    super.key,
    required this.host,
    required this.list,
    required this.selected,
    required this.onSelect,
    required this.onToggle,
    required this.onSelectAll,
    required this.onClear,
    required this.onConnect,
    required this.onMenu,
    required this.onSecondaryTap,
    required this.actions,
  });

  final Host host;

  /// A dense row with group and tags, instead of a card.
  final bool list, selected;
  final VoidCallback onConnect, onSelect, onToggle, onSelectAll, onClear, onMenu;
  final ValueChanged<Offset> onSecondaryTap;
  final List<(String, VoidCallback)> actions;

  @override
  State<_HostTile> createState() => _HostTileState();
}

class _HostTileState extends State<_HostTile> {
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
    final host = widget.host;
    final name = Row(
      children: [
        Flexible(
          child: Tooltip(
            message: host.title,
            child: Text(host.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ),
        if (host.pinned) ...[
          const SizedBox(width: Space.xs),
          Icon(Icons.push_pin, size: 12, color: theme.colorScheme.primary),
        ],
      ],
    );
    final target = Text(host.target, maxLines: 1, overflow: TextOverflow.ellipsis, style: muted);
    final avatar = Container(
      width: widget.list ? 24 : 32,
      height: widget.list ? 24 : 32,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(Radii.control),
      ),
      child: Icon(Icons.dns_outlined, size: widget.list ? 14 : 16, color: theme.colorScheme.primary),
    );
    // Stays in the tree when hidden: an open menu would otherwise lose its selection when focus moves.
    final actions = Opacity(
      opacity: _hovered || _focused || widget.selected ? 1 : 0,
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
            items: () {
              widget.onMenu();
              return [for (final (label, run) in widget.actions) AppMenuItem(value: run, label: label)];
            },
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
                child: Text(
                  [if (host.group.isNotEmpty) host.group, ...host.tags.map((t) => '#$t')].join('  '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: muted,
                ),
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
            child: Card(
              margin: EdgeInsets.zero,
              color: widget.selected ? theme.colorScheme.primaryContainer : null,
              clipBehavior: Clip.antiAlias,
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

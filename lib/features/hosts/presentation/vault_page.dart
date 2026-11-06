import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../design/side_drawer.dart';
import '../../../design/text_prompt.dart';
import '../../../design/theme.dart';
import '../../../l10n/app_localizations.dart';
import '../../settings/api.dart';
import '../application/hosts.dart';
import '../domain/host.dart';
import 'host_form.dart';
import 'keys_panel.dart';

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

  @override
  void didUpdateWidget(VaultPage old) {
    super.didUpdateWidget(old);
    if (widget.active && !old.active) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.active) _searchFocus.requestFocus();
      });
    }
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
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
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
    if (ok ?? false) await _hosts.delete(host);
  }

  Future<void> _groupMenu(String group, Offset p) async {
    final l = AppLocalizations.of(context);
    final run = await showMenu<VoidCallback>(
      context: context,
      position: RelativeRect.fromLTRB(p.dx, p.dy, p.dx, p.dy),
      items: [
        PopupMenuItem(
          height: 36,
          value: () async {
            final to = await showDialog<String>(
              context: context,
              builder: (_) => TextPromptDialog(title: l.renameGroup, initial: group),
            );
            if (to == null || normalizeGroup(to).isEmpty) return;
            await _hosts.renameGroup(group, to);
            if (mounted && _group == group) setState(() => _group = normalizeGroup(to));
          },
          child: Text(l.renameGroup),
        ),
        PopupMenuItem(
          height: 36,
          value: () async {
            await _hosts.renameGroup(group, '');
            if (mounted) setState(() => _group = '');
          },
          child: Text(l.dissolveGroup),
        ),
      ],
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
    final groups = allGroups(hosts);
    if (_group.isNotEmpty && !groups.contains(_group)) _group = '';
    final matches = sortHosts(
      hosts.where((h) => inGroup(h, _group) && hostMatches(h, query)),
      recent: order == HostOrder.recent,
    );
    final quick = query.isEmpty ? null : parseQuickConnect(_search.text);

    Widget tile(Host h) => _HostTile(
          key: ValueKey(h.id),
          host: h,
          list: view == HostView.list,
          onConnect: () => widget.onConnect(h),
          actions: [
            (l.edit, () => _edit(h)),
            (l.duplicate, () => _hosts.duplicate(h, l.copyOf(h.title))),
            (h.pinned ? l.unpin : l.pin, () => _hosts.setPinned(h, !h.pinned)),
            (l.delete, () => _delete(h)),
          ],
        );

    return Padding(
      padding: const EdgeInsets.all(Space.xl),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(
            child: TextField(
              controller: _search,
              focusNode: _searchFocus,
              autofocus: true,
              decoration: InputDecoration(hintText: l.searchHint, prefixIcon: const Icon(Icons.search, size: 20)),
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
            icon: Icon(view == HostView.grid ? Icons.view_list_outlined : Icons.grid_view_outlined, size: 20),
          ),
          PopupMenuButton<HostOrder>(
            tooltip: order == HostOrder.name ? l.sortName : l.sortRecent,
            icon: const Icon(Icons.sort, size: 20),
            initialValue: order,
            onSelected: (v) => ref.read(settingsProvider.notifier).set(SettingKeys.hostOrder, v),
            itemBuilder: (_) => [
              CheckedPopupMenuItem(value: HostOrder.name, checked: order == HostOrder.name, child: Text(l.sortName)),
              CheckedPopupMenuItem(value: HostOrder.recent, checked: order == HostOrder.recent, child: Text(l.sortRecent)),
            ],
          ),
          IconButton(
            tooltip: l.keys,
            onPressed: () => showSideDrawer<void>(context, (_) => const KeysPanel()),
            icon: const Icon(Icons.key_outlined, size: 20),
          ),
          const SizedBox(width: Space.sm),
          FilledButton.icon(onPressed: _edit, icon: const Icon(Icons.add, size: 20), label: Text(l.newHost)),
        ]),
        if (groups.isNotEmpty) ...[
          const SizedBox(height: Space.lg),
          SizedBox(
            height: 32,
            child: ListView(scrollDirection: Axis.horizontal, children: [
              for (final g in ['', ...groups])
                Padding(
                  padding: const EdgeInsets.only(right: Space.sm),
                  child: GestureDetector(
                    onSecondaryTapUp: g.isEmpty ? null : (d) => _groupMenu(g, d.globalPosition),
                    child: ChoiceChip(
                      showCheckmark: false,
                      visualDensity: VisualDensity.compact,
                      label: Text(g.isEmpty ? l.allHosts : g),
                      avatar: g.isEmpty ? null : Icon(Icons.folder_outlined, size: 16, color: theme.colorScheme.primary),
                      selected: _group == g,
                      onSelected: (_) => setState(() => _group = g),
                    ),
                  ),
                ),
            ]),
          ),
        ],
        const SizedBox(height: Space.lg),
        if (quick != null) ...[
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: () => widget.onConnect(quick),
              icon: const Icon(Icons.bolt, size: 20),
              label: Text(l.connectTo(quick.target)),
            ),
          ),
          const SizedBox(height: Space.lg),
        ],
        Expanded(
          child: matches.isEmpty
              ? (query.isEmpty || quick != null ? const SizedBox.shrink() : Center(child: Text(l.noMatches)))
              : view == HostView.list
                  ? ListView.separated(
                      itemCount: matches.length,
                      separatorBuilder: (_, _) => const SizedBox(height: Space.xs),
                      itemBuilder: (context, i) => tile(matches[i]),
                    )
                  : GridView.builder(
                      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                        maxCrossAxisExtent: 320,
                        mainAxisExtent: 76,
                        crossAxisSpacing: Space.md,
                        mainAxisSpacing: Space.md,
                      ),
                      itemCount: matches.length,
                      itemBuilder: (context, i) => tile(matches[i]),
                    ),
        ),
      ]),
    );
  }
}

class _HostTile extends StatefulWidget {
  const _HostTile({super.key, required this.host, required this.list, required this.onConnect, required this.actions});

  final Host host;

  /// A dense row with group and tags, instead of a card.
  final bool list;
  final VoidCallback onConnect;
  final List<(String, VoidCallback)> actions;

  @override
  State<_HostTile> createState() => _HostTileState();
}

class _HostTileState extends State<_HostTile> {
  final _focus = FocusNode();
  var _hovered = false, _focused = false;

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
    final name = Row(children: [
      Flexible(child: Tooltip(message: host.title, child: Text(host.title, maxLines: 1, overflow: TextOverflow.ellipsis))),
      if (host.pinned) ...[
        const SizedBox(width: Space.xs),
        Icon(Icons.push_pin, size: 12, color: theme.colorScheme.primary),
      ],
    ]);
    final target = Text(host.target, maxLines: 1, overflow: TextOverflow.ellipsis, style: muted);
    final avatar = Container(
      width: widget.list ? 32 : 40,
      height: widget.list ? 32 : 40,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(Radii.control),
      ),
      child: Icon(Icons.dns_outlined, size: widget.list ? 18 : 20, color: theme.colorScheme.primary),
    );
    // Stays in the tree when hidden: an open menu would otherwise lose its selection when focus moves.
    final actions = Opacity(
      opacity: _hovered || _focused ? 1 : 0,
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        IconButton(tooltip: l.connect, onPressed: widget.onConnect, icon: const Icon(Icons.play_arrow_outlined, size: 20)),
        PopupMenuButton<VoidCallback>(
          tooltip: l.more,
          icon: const Icon(Icons.more_horiz, size: 20),
          onSelected: (action) => action(),
          itemBuilder: (_) => [for (final (label, run) in widget.actions) PopupMenuItem(value: run, child: Text(label))],
        ),
      ]),
    );
    final content = widget.list
        ? Row(children: [
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
          ])
        : Row(children: [
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
          ]);
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
          },
          child: Card(
            margin: EdgeInsets.zero,
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              focusNode: _focus,
              onTap: _focus.requestFocus,
              onDoubleTap: widget.onConnect,
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: Space.md, vertical: widget.list ? Space.xs : 0),
                child: content,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

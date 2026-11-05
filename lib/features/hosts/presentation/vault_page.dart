import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../design/side_drawer.dart';
import '../../../design/theme.dart';
import '../../../l10n/app_localizations.dart';
import '../application/hosts.dart';
import '../domain/host.dart';
import 'host_form.dart';

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

  void _edit([Host? host]) => showSideDrawer<void>(context, (_) => HostForm(host: host));

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
    if (ok ?? false) await ref.read(hostsProvider.notifier).delete(host);
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
    final query = _search.text.trim().toLowerCase();
    final hosts = ref.watch(hostsProvider);
    final matches = [
      for (final h in hosts)
        if ('${h.title} ${h.target}'.toLowerCase().contains(query)) h,
    ];
    final quick = query.isEmpty ? null : parseQuickConnect(_search.text);
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
          const SizedBox(width: Space.md),
          FilledButton.icon(onPressed: _edit, icon: const Icon(Icons.add, size: 20), label: Text(l.newHost)),
        ]),
        const SizedBox(height: Space.xl),
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
              : GridView.builder(
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 320,
                    mainAxisExtent: 76,
                    crossAxisSpacing: Space.md,
                    mainAxisSpacing: Space.md,
                  ),
                  itemCount: matches.length,
                  itemBuilder: (context, i) {
                    final h = matches[i];
                    return _HostCard(
                      key: ValueKey(h.id),
                      host: h,
                      onConnect: () => widget.onConnect(h),
                      onEdit: () => _edit(h),
                      onDelete: () => _delete(h),
                    );
                  },
                ),
        ),
      ]),
    );
  }
}

class _HostCard extends StatefulWidget {
  const _HostCard({super.key, required this.host, required this.onConnect, required this.onEdit, required this.onDelete});

  final Host host;
  final VoidCallback onConnect, onEdit, onDelete;

  @override
  State<_HostCard> createState() => _HostCardState();
}

class _HostCardState extends State<_HostCard> {
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
    final host = widget.host;
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
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              focusNode: _focus,
              onTap: _focus.requestFocus,
              onDoubleTap: widget.onConnect,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: Space.md),
                child: Row(children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerLow,
                      borderRadius: BorderRadius.circular(Radii.control),
                    ),
                    child: Icon(Icons.dns_outlined, size: 20, color: theme.colorScheme.primary),
                  ),
                  const SizedBox(width: Space.md),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(host.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                        Text(
                          host.target,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                  // Stays in the tree when hidden: an open menu would otherwise lose its selection when focus moves.
                  Opacity(
                    opacity: _hovered || _focused ? 1 : 0,
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      IconButton(
                        tooltip: l.connect,
                        onPressed: widget.onConnect,
                        icon: const Icon(Icons.play_arrow_outlined, size: 20),
                      ),
                      PopupMenuButton<VoidCallback>(
                        tooltip: l.more,
                        icon: const Icon(Icons.more_horiz, size: 20),
                        onSelected: (action) => action(),
                        itemBuilder: (_) => [
                          PopupMenuItem(value: widget.onEdit, child: Text(l.edit)),
                          PopupMenuItem(value: widget.onDelete, child: Text(l.delete)),
                        ],
                      ),
                    ]),
                  ),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

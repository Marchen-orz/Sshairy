import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../design/theme.dart';
import '../../../foundation/ids.dart';
import '../../../l10n/app_localizations.dart';
import '../application/hosts.dart';
import '../domain/host.dart';

/// Connection status is supplied by the workspace; the host library owns only saved configuration.
class HostTree extends ConsumerStatefulWidget {
  const HostTree({super.key, required this.onConnect, this.activeHost, this.status});

  final void Function(Host host) onConnect;
  final HostId? activeHost;
  final Widget Function(Host host)? status;

  @override
  ConsumerState<HostTree> createState() => _HostTreeState();
}

class _HostTreeState extends ConsumerState<HostTree> {
  final _collapsed = <String>{};
  var _query = '';

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final hosts = sortHosts(ref.watch(hostsProvider).where((h) => hostMatches(h, _query)));
    // Empty groups show while browsing; a search shows only the groups its matches sit in.
    final ordered = ref.watch(hostLibraryProvider).groupPaths;
    final matched = allGroups(hosts).toSet();
    final groups = _query.trim().isEmpty
        ? ordered
        : [
            for (final path in ordered)
              if (matched.contains(path)) path,
          ];
    final scheme = Theme.of(context).colorScheme;

    List<Widget> rows(String group, int depth) => [
      for (final child in groups.where(
        (g) => (g.contains('/') ? g.substring(0, g.lastIndexOf('/')) : '') == group,
      )) ...[
        Padding(
          padding: EdgeInsets.only(left: Space.sm + depth.clamp(0, 8) * Space.md),
          child: SizedBox(
            height: WorkspaceSize.treeRow,
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: () =>
                    setState(() => _collapsed.contains(child) ? _collapsed.remove(child) : _collapsed.add(child)),
                child: Row(
                  children: [
                    Icon(
                      _collapsed.contains(child) && _query.isEmpty ? Icons.chevron_right : Icons.expand_more,
                      size: 16,
                    ),
                    const SizedBox(width: Space.xs),
                    Icon(Icons.folder_outlined, size: 16, color: scheme.onSurfaceVariant),
                    const SizedBox(width: Space.sm),
                    Expanded(child: Text(child.split('/').last, maxLines: 1, overflow: TextOverflow.ellipsis)),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (!_collapsed.contains(child) || _query.isNotEmpty) ...rows(child, depth + 1),
      ],
      for (final host in hosts.where((h) => h.group == group))
        Padding(
          padding: EdgeInsets.only(left: Space.sm + depth.clamp(0, 8) * Space.md, right: Space.sm),
          child: Tooltip(
            message: host.target,
            child: Material(
              color: widget.activeHost == host.id ? scheme.primary.withValues(alpha: .12) : Colors.transparent,
              borderRadius: BorderRadius.circular(Radii.control),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                key: ValueKey(host.id),
                onTap: () => widget.onConnect(host),
                child: SizedBox(
                  height: WorkspaceSize.treeRow,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: Space.sm),
                    child: Row(
                      children: [
                        Icon(Icons.dns_outlined, size: 16, color: scheme.onSurfaceVariant),
                        const SizedBox(width: Space.sm),
                        Expanded(child: Text(host.title, maxLines: 1, overflow: TextOverflow.ellipsis)),
                        if (widget.status case final status?) ...[
                          const SizedBox(width: Space.xs),
                          SizedBox.square(dimension: 16, child: Center(child: status(host))),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
    ];

    return ColoredBox(
      color: scheme.surfaceContainerLow,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(Space.sm),
            child: TextField(
              decoration: InputDecoration(hintText: l.searchHint, prefixIcon: const Icon(Icons.search, size: 16)),
              onChanged: (value) => setState(() => _query = value),
            ),
          ),
          Expanded(
            child: hosts.isEmpty ? Center(child: Text(l.noMatches)) : ListView(children: rows('', 0)),
          ),
        ],
      ),
    );
  }
}

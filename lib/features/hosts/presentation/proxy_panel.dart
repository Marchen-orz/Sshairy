import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../design/controls.dart';
import '../../../design/side_drawer.dart';
import '../../../design/theme.dart';
import '../../../foundation/ids.dart';
import '../../../foundation/json_file.dart';
import '../../../l10n/app_localizations.dart';
import '../application/hosts.dart';
import '../domain/host.dart';
import '../domain/host_library.dart';
import 'form_parts.dart';
import 'proxy_editor.dart';

typedef _Target = ({Host? host, HostGroup? group});

String _title(AppLocalizations l, HostLibrary library, _Target target) =>
    target.host?.title ?? (target.group == null ? l.globalDefaults : library.groupPath(target.group!.id));

ConnectionOverrides _own(HostLibrary library, _Target target) => target.host == null
    ? (target.group?.defaults ?? library.defaults)
    : target.host!.overrides ?? explicitConnection(target.host!);

ResolvedConnection _effective(HostLibrary library, _Target target) => library.resolveConnection(
  target.host?.groupId ?? target.group?.id,
  target.host == null ? null : _own(library, target),
);

String _source(AppLocalizations l, HostLibrary library, _Target target, String source) => switch (source) {
  '' => l.inheritBuiltIn,
  'host' => l.proxyConfiguredHere,
  'global' => target.host == null && target.group == null ? l.proxyConfiguredHere : l.inheritedFrom(l.globalDefaults),
  _ when source == 'group:${target.group?.id}' => l.proxyConfiguredHere,
  _ => l.inheritedFrom(library.groupPath(source.substring('group:'.length))),
};

Host? _outerHost(HostLibrary library, Host host) {
  final seen = <HostId>{};
  var current = host;
  while (current.jumpHostId != null) {
    final id = current.jumpHostId!;
    if (!seen.add(current.id) || seen.length >= 8) return null;
    final next = library.hostById(id);
    if (next == null) return null;
    current = next;
  }
  return current;
}

String _endpoint(AppLocalizations l, Proxy? proxy) {
  if (proxy == null) return l.directConnection;
  final protocol = proxy.kind == ProxyKind.socks5 ? 'SOCKS5' : 'HTTP CONNECT';
  final address = proxy.address.contains(':') ? '[${proxy.address}]' : proxy.address;
  return '$protocol · $address:${proxy.port}${proxy.username.isEmpty ? '' : ' · ${proxy.username}'}';
}

/// The proxy layer of the existing host library, including inherited settings and the actual outer hop.
class ProxyPanel extends ConsumerStatefulWidget {
  const ProxyPanel({super.key});

  @override
  ConsumerState<ProxyPanel> createState() => _ProxyPanelState();
}

class _ProxyPanelState extends ConsumerState<ProxyPanel> {
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _edit(_Target target) => showSideDrawer<void>(context, (_) => _ProxyForm(target: target));

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final library = ref.watch(hostLibraryProvider);
    final groups = library.groups.toList()..sort((a, b) => library.groupPath(a.id).compareTo(library.groupPath(b.id)));
    final targets = <_Target>[
      (host: null, group: null),
      for (final group in groups) (host: null, group: group),
      for (final host in sortHosts(library.hosts)) (host: host, group: null),
    ];
    final query = _search.text.trim().toLowerCase();
    final rows = targets.where((target) {
      final outer = target.host == null ? null : _outerHost(library, target.host!);
      final owner = outer == null ? target : (host: outer, group: null);
      return '${_title(l, library, target)} ${target.host?.group ?? ''} '
              '${outer?.title ?? ''} ${_endpoint(l, _effective(library, owner).proxy)}'
          .toLowerCase()
          .contains(query);
    }).toList();
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _search,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(hintText: l.proxySearch, prefixIcon: const Icon(Icons.search, size: 16)),
        ),
        const SizedBox(height: Space.sm),
        Expanded(
          child: rows.isEmpty
              ? Center(child: Text(l.noMatches, style: muted))
              : ListView.builder(
                  itemCount: rows.length,
                  itemBuilder: (context, index) {
                    final target = rows[index];
                    final host = target.host;
                    final outer = host == null ? null : _outerHost(library, host);
                    final owner = outer == null ? target : (host: outer, group: null);
                    final effective = _effective(library, owner);
                    final invalid = host != null && outer == null;
                    final via = outer != null && outer.id != host?.id;
                    return Padding(
                      key: ValueKey(target.host?.id.value ?? 'group:${target.group?.id ?? 'global'}'),
                      padding: const EdgeInsets.symmetric(vertical: Space.sm),
                      child: Row(
                        children: [
                          Icon(
                            host != null
                                ? Icons.dns_outlined
                                : target.group != null
                                ? Icons.folder_outlined
                                : Icons.public_outlined,
                            size: 18,
                            color: theme.colorScheme.primary,
                          ),
                          const SizedBox(width: Space.sm),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(_title(l, library, target), maxLines: 1, overflow: TextOverflow.ellipsis),
                                Text(
                                  invalid ? l.errRouteInvalid : _endpoint(l, effective.proxy),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: muted,
                                ),
                                if (via) Text('${l.proxyVia} · ${outer.title}', style: muted),
                                if (!invalid)
                                  Text(_source(l, library, owner, effective.sources['proxy']!), style: muted),
                              ],
                            ),
                          ),
                          if (via)
                            IconButton(
                              tooltip: l.proxyEditHop,
                              onPressed: () => _edit((host: outer, group: null)),
                              icon: const Icon(Icons.route_outlined, size: 16),
                            ),
                          IconButton(
                            tooltip: l.edit,
                            onPressed: () => _edit(target),
                            icon: const Icon(Icons.edit_outlined, size: 16),
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _ProxyForm extends ConsumerStatefulWidget {
  const _ProxyForm({required this.target});

  final _Target target;

  @override
  ConsumerState<_ProxyForm> createState() => _ProxyFormState();
}

class _ProxyFormState extends ConsumerState<_ProxyForm> {
  final _form = GlobalKey<FormState>();
  final _proxy = GlobalKey<ProxyEditorState>();
  late final int _revision;
  late final _library = ref.read(hostLibraryProvider);
  late final _initial = _own(_library, widget.target).proxy;
  late final _inherited = widget.target.host != null
      ? _library.resolveConnection(widget.target.host!.groupId, null)
      : widget.target.group != null
      ? _library.resolveConnection(widget.target.group!.parentId, null)
      : HostLibrary().resolveConnection(null, null);
  late var _inherit = _initial.mode == OverrideMode.inherit;
  var _saving = false, _savedWithCleanupError = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _revision = ref.read(hostsProvider.notifier).revision;
  }

  OverrideValue<Proxy>? _currentProxy(HostLibrary library) {
    if (widget.target.host case final host?) {
      final current = library.hostById(host.id);
      return current == null ? null : (current.overrides ?? explicitConnection(current)).proxy;
    }
    if (widget.target.group case final group?) return library.groupById(group.id)?.defaults.proxy;
    return library.defaults.proxy;
  }

  Future<void> _save() async {
    if (_saving || _savedWithCleanupError || !_form.currentState!.validate()) return;
    final value = _inherit ? null : _proxy.currentState!.value;
    final override = _inherit
        ? const OverrideValue<Proxy>.inherit()
        : value == null
        ? const OverrideValue<Proxy>.disabled()
        : OverrideValue<Proxy>.value(value);
    final hosts = ref.read(hostsProvider.notifier);
    final l = AppLocalizations.of(context);
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      if (widget.target.host case final host?) {
        await hosts.setHostProxy(host.id, override, expectedRevision: _revision);
      } else if (widget.target.group case final group?) {
        await hosts.setGroupProxy(group.id, override, expectedRevision: _revision);
      } else {
        await hosts.setDefaultProxy(override, expectedRevision: _revision);
      }
      if (mounted) Navigator.pop(context);
    } on Object catch (error) {
      if (!mounted) return;
      final current = _currentProxy(hosts.library);
      final committed =
          error is! JsonFileError &&
          hosts.revision > _revision &&
          current?.mode == override.mode &&
          current?.value?.key == override.value?.key;
      setState(() {
        _savedWithCleanupError = committed;
        _error = committed
            ? l.proxyCleanupFailed
            : error is JsonFileError && error.kind == JsonFileFailure.conflict
            ? l.proxyChanged
            : saveError(l, error, invalid: l.proxyInvalid);
      });
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final muted = Theme.of(context).textTheme.bodySmall
        ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant);
    return Form(
      key: _form,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: ListView(
              children: [
                Text(_title(l, _library, widget.target), style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: Space.md),
                AppToggleRow(
                  title: l.proxyInherit,
                  subtitle: _source(l, _library, widget.target, _inherited.sources['proxy']!),
                  value: _inherit,
                  onChanged: _saving || _savedWithCleanupError ? null : (value) => setState(() => _inherit = value),
                ),
                const SizedBox(height: Space.sm),
                ProxyEditor(
                  key: _proxy,
                  initial: _initial.mode == OverrideMode.inherit ? _inherited.proxy : _initial.value,
                  enabled: !_inherit && !_saving && !_savedWithCleanupError,
                ),
                const SizedBox(height: Space.lg),
                Text(l.proxyNextConnection, style: muted),
              ],
            ),
          ),
          FormFooter(onSave: _save, saving: _saving || _savedWithCleanupError, error: _error),
        ],
      ),
    );
  }
}

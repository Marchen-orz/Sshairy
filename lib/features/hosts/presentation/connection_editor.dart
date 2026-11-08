import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../design/controls.dart';
import '../../../design/select.dart';
import '../../../design/side_drawer.dart';
import '../../../foundation/ids.dart';
import '../../../l10n/app_localizations.dart';
import '../application/hosts.dart';
import '../domain/host.dart';
import '../domain/host_library.dart';
import 'form_parts.dart';
import 'identities_panel.dart';
import 'login_editor.dart';
import 'proxy_editor.dart';

/// A control with the switch between its own value and the one it inherits.
class _Inheritable extends StatelessWidget {
  const _Inheritable({
    required this.linked,
    required this.source,
    required this.onChanged,
    required this.child,
    this.canLink = true,
  });

  final bool linked, canLink;
  final String source;
  final ValueChanged<bool> onChanged;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: child),
        IconButton(
          tooltip: linked ? l.inheritedFrom(source) : l.useInherited(source),
          onPressed: canLink ? () => onChanged(!linked) : null,
          icon: Icon(
            linked ? Icons.link : Icons.link_off,
            size: 16,
            color: linked ? scheme.primary : scheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

/// Port, login, route and legacy algorithms of one layer: a host, a group or the global defaults. Every field is
/// either linked to what the layers above give it, or has its own value.
class ConnectionEditor extends ConsumerStatefulWidget {
  const ConnectionEditor({
    super.key,
    required this.initial,
    required this.inherited,
    this.self,
    this.fresh = false,
    this.loginOptional = false,
  });

  final ConnectionOverrides initial;

  /// What the layers above provide; follows the host's group while it is being edited.
  final ResolvedConnection inherited;

  /// The host being edited, which cannot be its own jump host.
  final HostId? self;

  /// A new host types its port itself where no default gives one, so a plain form stays plain.
  final bool fresh;

  /// A group or the defaults may leave the login unset; a host needs one from somewhere.
  final bool loginOptional;

  @override
  ConsumerState<ConnectionEditor> createState() => ConnectionEditorState();
}

class ConnectionEditorState extends ConsumerState<ConnectionEditor> {
  final _login = GlobalKey<LoginEditorState>();
  final _proxy = GlobalKey<ProxyEditorState>();
  final _route = ExpansibleController();

  ResolvedConnection get _inherited => widget.inherited;
  bool get _canLinkLogin => widget.loginOptional || _inherited.authentication != null;

  bool _startsLinked(OverrideMode mode, String field) =>
      mode == OverrideMode.inherit && !(widget.fresh && field == 'port' && _inherited.sources[field] == '');

  late bool _portLinked = _startsLinked(widget.initial.port.mode, 'port');
  late final _portField = TextEditingController(text: '${widget.initial.port.value ?? _inherited.port}');

  late bool _loginLinked = _startsLinked(widget.initial.authentication.mode, 'authentication') && _canLinkLogin;
  late String? _identityId = widget.initial.authentication.value?.identityId;
  late Login? _loginSeed = _loginOf(widget.initial.authentication.value);

  late bool _jumpLinked = _startsLinked(widget.initial.jump.mode, 'jump');
  late HostId? _jump = widget.initial.jump.value;

  late bool _proxyLinked = _startsLinked(widget.initial.proxy.mode, 'proxy');
  late Proxy? _proxySeed = widget.initial.proxy.value;

  late bool _legacyLinked = _startsLinked(widget.initial.legacy.mode, 'legacy');
  late bool _legacy = widget.initial.legacy.value ?? _inherited.legacy;

  Login? _loginOf(Authentication? selected) => selected == null ? null : ref.read(hostLibraryProvider).login(selected);

  @override
  void dispose() {
    _route.dispose();
    _portField.dispose();
    super.dispose();
  }

  /// The overrides the fields describe; the caller validates the form first.
  ConnectionOverrides get value {
    final jump = _jumpLinked ? _inherited.jump : _jump;
    return ConnectionOverrides(
      port: _portLinked ? const OverrideValue.inherit() : OverrideValue.value(int.parse(_portField.text)),
      authentication: _loginLinked
          ? const OverrideValue.inherit()
          : OverrideValue.value(switch (_identityId) {
              final id? => Authentication.identity(id),
              _ => () {
                final login = _login.currentState!.value;
                return Authentication.inline(login.username, login.policy);
              }(),
            }),
      jump: _jumpLinked
          ? const OverrideValue.inherit()
          : _jump == null
          ? const OverrideValue.disabled()
          : OverrideValue.value(_jump!),
      // Only the first hop of a route uses a proxy, so a host reached through a jump host keeps none of its own.
      proxy: _proxyLinked
          ? const OverrideValue.inherit()
          : switch (jump == null ? _proxy.currentState?.value : null) {
              final proxy? => OverrideValue.value(proxy),
              _ => const OverrideValue.disabled(),
            },
      legacy: _legacyLinked ? const OverrideValue.inherit() : OverrideValue.value(_legacy),
    );
  }

  /// A section that is folded away cannot show what is wrong inside it, so a failed save opens it.
  void _revealRoute() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (mounted && !_route.isExpanded) _route.expand();
  });

  void _unlinkPort() => _portField.text = '${_inherited.port}';

  void _unlinkLogin() {
    _identityId = _inherited.authentication?.identityId;
    _loginSeed = _loginOf(_inherited.authentication);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final library = ref.watch(hostLibraryProvider);
    final hosts = ref.watch(hostsProvider);

    String sourceName(String field) {
      final source = _inherited.sources[field] ?? '';
      if (source == 'global') return l.globalDefaults;
      if (source.startsWith('group:')) return library.groupPath(source.substring(6));
      return l.inheritBuiltIn;
    }

    final inheritedLogin = _loginOf(_inherited.authentication);
    final inheritedIdentity = _inherited.authentication?.identityId;
    final identities = library.identities;
    final identityId = _loginLinked ? inheritedIdentity : _identityId;

    Widget identityPicker() => Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: AppSelect<String?>(
            value: identityId,
            label: l.identity,
            options: [
              AppOption(null, l.customLogin),
              for (final identity in identities) AppOption(identity.id, '${identity.label} · ${identity.username}'),
            ],
            onChanged: _loginLinked
                ? null
                : (id) => setState(() {
                    if (id == null && _identityId != null) {
                      _loginSeed = _loginOf(Authentication.identity(_identityId!));
                    }
                    _identityId = id;
                  }),
          ),
        ),
        IconButton(
          tooltip: l.identities,
          onPressed: _loginLinked ? null : () => showSideDrawer<void>(context, (_) => const IdentitiesPanel()),
          icon: const Icon(Icons.badge_outlined, size: 18),
        ),
      ],
    );

    final effectiveJump = _jumpLinked ? _inherited.jump : _jump;
    final route = ExpansionTile(
      controller: _route,
      title: Text(l.route),
      tilePadding: EdgeInsets.zero,
      maintainState: true,
      initiallyExpanded: !_jumpLinked || !_proxyLinked || !_legacyLinked,
      children: [
        _Inheritable(
          linked: _jumpLinked,
          source: sourceName('jump'),
          onChanged: (linked) => setState(() {
            _jumpLinked = linked;
            if (!linked) _jump = _inherited.jump;
          }),
          child: AppSelect<HostId?>(
            value: effectiveJump,
            label: l.jumpHost,
            options: [
              AppOption(null, l.directConnection),
              if (effectiveJump != null && (effectiveJump == widget.self || hosts.every((h) => h.id != effectiveJump)))
                AppOption(effectiveJump, l.errRouteMissing),
              for (final h in hosts.where((h) => h.id != widget.self)) AppOption(h.id, h.title),
            ],
            onChanged: _jumpLinked ? null : (v) => setState(() => _jump = v),
          ),
        ),
        if (effectiveJump == null) ...[
          formGap,
          _Inheritable(
            linked: _proxyLinked,
            source: sourceName('proxy'),
            onChanged: (linked) => setState(() {
              _proxyLinked = linked;
              if (!linked) _proxySeed = _inherited.proxy;
            }),
            child: _proxyLinked
                ? ProxyEditor(
                    key: ValueKey('proxy-${_inherited.proxy?.key}'),
                    initial: _inherited.proxy,
                    enabled: false,
                  )
                : ProxyEditor(key: _proxy, initial: _proxySeed, onInvalid: _revealRoute),
          ),
        ],
        formGap,
        _Inheritable(
          linked: _legacyLinked,
          source: sourceName('legacy'),
          onChanged: (linked) => setState(() {
            _legacyLinked = linked;
            if (!linked) _legacy = _inherited.legacy;
          }),
          child: AppToggleRow(
            title: l.legacyAlgorithms,
            subtitle: l.legacyAlgorithmsHint,
            value: _legacyLinked ? _inherited.legacy : _legacy,
            onChanged: _legacyLinked ? null : (v) => setState(() => _legacy = v),
          ),
        ),
      ],
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Inheritable(
          linked: _portLinked,
          source: sourceName('port'),
          onChanged: (linked) => setState(() {
            _portLinked = linked;
            if (!linked) _unlinkPort();
          }),
          child: _portLinked
              ? TextFormField(
                  key: ValueKey('port-${_inherited.port}'),
                  initialValue: '${_inherited.port}',
                  enabled: false,
                  decoration: InputDecoration(labelText: l.port),
                )
              : TextFormField(
                  controller: _portField,
                  validator: (v) => portField(l, v),
                  decoration: InputDecoration(labelText: l.port),
                ),
        ),
        formGap,
        _Inheritable(
          linked: _loginLinked,
          canLink: _canLinkLogin,
          source: sourceName('authentication'),
          onChanged: (linked) => setState(() {
            _loginLinked = linked;
            if (!linked) _unlinkLogin();
          }),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              identityPicker(),
              if (identityId == null) ...[
                formGap,
                _loginLinked
                    ? LoginEditor(
                        key: ValueKey('login-${inheritedLogin?.username}-${inheritedLogin?.policy.toJson()}'),
                        initial: inheritedLogin,
                        enabled: false,
                      )
                    : LoginEditor(key: _login, initial: _loginSeed),
              ],
            ],
          ),
        ),
        formGap,
        route,
      ],
    );
  }
}

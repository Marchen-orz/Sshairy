import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../design/side_drawer.dart';
import '../../../design/theme.dart';
import '../../../l10n/app_localizations.dart';
import '../../connections/api.dart';
import '../../hosts/api.dart';
import '../../settings/api.dart';
import '../../terminal/api.dart';

class WorkspacePage extends ConsumerStatefulWidget {
  const WorkspacePage({super.key});

  @override
  ConsumerState<WorkspacePage> createState() => _WorkspacePageState();
}

class _WorkspacePageState extends ConsumerState<WorkspacePage> {
  final _sessions = <TerminalSession>[];

  /// null is the host vault.
  TerminalSession? _active;
  var _settingsOpen = false;

  void _open(Host host) {
    final session = TerminalSession(host, ref.read(connectorProvider));
    setState(() {
      _sessions.add(session);
      _active = session;
    });
  }

  void _close(TerminalSession session) {
    final i = _sessions.indexOf(session);
    setState(() {
      _sessions.removeAt(i);
      if (_active == session) _active = _sessions.isEmpty ? null : _sessions[i.clamp(0, _sessions.length - 1)];
    });
    session.close();
  }

  Future<void> _openSettings() async {
    if (_settingsOpen) return;
    _settingsOpen = true;
    await showSideDrawer<void>(context, (_) => const SettingsPanel());
    _settingsOpen = false;
  }

  late final _bindings = <SingleActivator, VoidCallback>{
    const SingleActivator(LogicalKeyboardKey.keyN, control: true, shift: true): () => setState(() => _active = null),
    const SingleActivator(LogicalKeyboardKey.keyW, control: true, shift: true): () {
      if (_active case final session?) _close(session);
    },
    const SingleActivator(LogicalKeyboardKey.comma, control: true): _openSettings,
  };

  KeyEventResult _onKey(FocusNode _, KeyEvent event) {
    for (final e in _bindings.entries) {
      if (e.key.accepts(event, HardwareKeyboard.instance)) {
        e.value();
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  @override
  void dispose() {
    for (final s in _sessions) {
      s.close();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final fontSize = ref.watch(settingsProvider.select((s) => s.fontSize));
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: Focus(
        onKeyEvent: _onKey,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Container(
            height: 40,
            padding: const EdgeInsets.symmetric(horizontal: Space.xs),
            color: scheme.surfaceContainerLow,
            child: Row(children: [
              _Tab(
                selected: _active == null,
                onTap: () => setState(() => _active = null),
                leading: const Icon(Icons.dns_outlined, size: 16),
                title: l.hosts,
              ),
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(children: [
                    for (final s in _sessions)
                      ListenableBuilder(
                        key: ValueKey(s),
                        listenable: s,
                        builder: (context, _) => _Tab(
                          selected: _active == s,
                          onTap: () => setState(() => _active = s),
                          leading: _StatusIcon(s.status),
                          title: s.host.title,
                          onClose: () => _close(s),
                        ),
                      ),
                    IconButton(
                      tooltip: l.newConnection,
                      onPressed: () => setState(() => _active = null),
                      icon: const Icon(Icons.add, size: 18),
                    ),
                  ]),
                ),
              ),
              IconButton(
                tooltip: l.settings,
                onPressed: _openSettings,
                icon: const Icon(Icons.settings_outlined, size: 18),
              ),
            ]),
          ),
          const Divider(),
          Expanded(
            // Not IndexedStack: its wrappers are unkeyed, so closing a middle tab would rebuild the panes after it.
            child: Stack(fit: StackFit.expand, children: [
              Visibility.maintain(
                key: const ValueKey('vault'),
                visible: _active == null,
                child: ExcludeFocus(
                  excluding: _active != null,
                  child: VaultPage(active: _active == null, onConnect: _open),
                ),
              ),
              for (final s in _sessions)
                Visibility.maintain(
                  key: ValueKey(s),
                  visible: _active == s,
                  child: IgnorePointer(
                    ignoring: _active != s,
                    child: ExcludeFocus(
                      excluding: _active != s,
                      child: ColoredBox(
                        color: scheme.surfaceContainerLowest,
                        child: TerminalPane(s, fontSize: fontSize, active: _active == s, onKeyEvent: _onKey),
                      ),
                    ),
                  ),
                ),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _StatusIcon extends StatelessWidget {
  const _StatusIcon(this.status);

  final SessionStatus status;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return switch (status) {
      SessionStatus.connecting => const SizedBox.square(dimension: 12, child: CircularProgressIndicator(strokeWidth: 2)),
      SessionStatus.connected => Icon(Icons.circle, size: 8, color: scheme.primary),
      SessionStatus.failed || SessionStatus.disconnected => Icon(Icons.link_off, size: 14, color: scheme.error),
    };
  }
}

class _Tab extends StatelessWidget {
  const _Tab({required this.selected, required this.onTap, required this.leading, required this.title, this.onClose});

  final bool selected;
  final VoidCallback onTap;
  final Widget leading;
  final String title;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(right: Space.xs),
      child: Material(
        color: selected ? scheme.surface : Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.control),
          side: selected ? BorderSide(color: scheme.outlineVariant) : BorderSide.none,
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 96, maxWidth: 220),
            child: SizedBox(
              height: 30,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: Space.sm),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  SizedBox.square(dimension: 16, child: Center(child: leading)),
                  const SizedBox(width: Space.sm),
                  Flexible(child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis)),
                  if (onClose != null) ...[
                    const SizedBox(width: Space.xs),
                    IconButton(
                      tooltip: AppLocalizations.of(context).close,
                      onPressed: onClose,
                      constraints: const BoxConstraints.tightFor(width: 22, height: 22),
                      style: IconButton.styleFrom(minimumSize: const Size(22, 22), padding: EdgeInsets.zero),
                      icon: const Icon(Icons.close, size: 14),
                    ),
                  ],
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

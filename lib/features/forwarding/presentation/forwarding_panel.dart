import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../design/controls.dart';
import '../../../design/dialog.dart';
import '../../../design/select.dart';
import '../../../design/side_drawer.dart';
import '../../../design/theme.dart';
import '../../../foundation/ids.dart';
import '../../../l10n/app_localizations.dart';
import '../../connections/api.dart';
import '../../hosts/api.dart';
import '../application/forwarding.dart';
import '../domain/forward.dart';

/// Rule list for `showSideDrawer`: start, stop, edit and delete.
class ForwardingPanel extends ConsumerWidget {
  const ForwardingPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final items = ref.watch(forwardsProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: Text(l.portForwarding, style: Theme.of(context).textTheme.titleMedium)),
            IconButton(
              onPressed: () => showSideDrawer<void>(context, (_) => const _ForwardEditor()),
              icon: const Icon(Icons.add),
            ),
            IconButton(tooltip: l.closePane, onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close)),
          ],
        ),
        const SizedBox(height: Space.md),
        Expanded(
          child: items.isEmpty
              ? Center(child: Text(l.none))
              : ListView.builder(
                  itemCount: items.length,
                  itemBuilder: (context, index) => Padding(
                    padding: const EdgeInsets.only(bottom: Space.sm),
                    child: _RuleCard(items[index]),
                  ),
                ),
        ),
      ],
    );
  }
}

String forwardErrorText(AppLocalizations l, String code, String detail) => switch (code) {
  ForwardErrors.addressInUse => l.fwErrInUse,
  ForwardErrors.permissionDenied => l.fwErrPermission,
  ForwardErrors.addressUnavailable => l.fwErrAddress,
  ForwardErrors.refused => l.fwErrRefused,
  ForwardErrors.hostMissing => l.fwErrHost,
  ForwardErrors.connectionLost => l.fwErrLost,
  ForwardErrors.stopFailed => l.fwErrStop,
  ForwardErrors.targetFailed => l.fwErrTarget,
  ForwardErrors.timeout => l.fwErrTimeout,
  ForwardErrors.handshake => l.fwErrSocks,
  ForwardErrors.limit => l.fwErrLimit,
  ForwardErrors.busy => l.fwBusy,
  _ => connectErrorText(l, ConnectError(ConnectFailure.values.asNameMap()[code] ?? ConnectFailure.network, detail)),
};

class _RuleCard extends ConsumerWidget {
  const _RuleCard(this.forward);
  final ForwardState forward;

  void _tell(BuildContext context, String text) =>
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(text)));

  Future<void> _toggle(BuildContext context, WidgetRef ref) async {
    final l = AppLocalizations.of(context);
    final forwards = ref.read(forwardsProvider.notifier);
    try {
      if (forward.active) {
        await forwards.stop(forward.rule.id);
      } else {
        await forwards.start(forward.rule.id);
      }
    } on ForwardError catch (e) {
      if (context.mounted) _tell(context, forwardErrorText(l, e.code, e.detail));
    }
  }

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    final l = AppLocalizations.of(context);
    final yes = await showAppDialog<bool>(
      context: context,
      builder: (context) => AppDialog(
        content: Text(l.deleteOne(forward.rule.title)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(l.cancel)),
          TextButton(onPressed: () => Navigator.pop(context, true), child: Text(l.delete)),
        ],
      ),
    );
    if (yes != true || !context.mounted) return;
    try {
      await ref.read(forwardsProvider.notifier).delete(forward.rule.id);
    } on Object catch (e) {
      if (context.mounted) _tell(context, e is ForwardError ? forwardErrorText(l, e.code, e.detail) : l.fwSaveFailed);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final rule = forward.rule;
    final host = ref.watch(hostsProvider.select((hosts) => hosts.where((h) => h.id == rule.hostId).firstOrNull));
    final listen = addressPort(rule.listenAddress, forward.port ?? rule.listenPort);
    final route = rule.kind == ForwardKind.dynamic ? listen : '$listen → ${rule.destination}';
    final failed = forward.error != null;
    final stopping = forward.phase == ForwardPhase.stopping;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                _PhaseMark(forward.phase),
                const SizedBox(width: Space.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(switch (rule.kind) {
                            ForwardKind.local => 'L',
                            ForwardKind.remote => 'R',
                            ForwardKind.dynamic => 'D',
                          }, style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                          const SizedBox(width: Space.sm),
                          Flexible(
                            child: Text(
                              rule.label.isEmpty ? listen : rule.label,
                              style: theme.textTheme.titleSmall,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (rule.exposed) ...[
                            const SizedBox(width: Space.sm),
                            Text(l.fwExposed, style: theme.textTheme.bodySmall?.copyWith(color: scheme.error)),
                          ],
                        ],
                      ),
                      Text(
                        host == null ? route : '${host.title} · $route',
                        style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                if (forward.connections > 0) ...[
                  const Icon(Icons.swap_horiz, size: 14),
                  const SizedBox(width: Space.xs),
                  Text('${forward.connections}', style: theme.textTheme.bodySmall),
                ],
                IconButton(
                  tooltip: forward.active ? l.stop : l.fwStart,
                  onPressed: stopping ? null : () => _toggle(context, ref),
                  icon: Icon(forward.active ? Icons.stop : Icons.play_arrow, size: 16),
                ),
                IconButton(
                  tooltip: l.edit,
                  onPressed: forward.active ? null : () => showSideDrawer<void>(context, (_) => _ForwardEditor(rule)),
                  icon: const Icon(Icons.edit_outlined, size: 16),
                ),
                IconButton(
                  tooltip: l.delete,
                  onPressed: forward.active ? null : () => _delete(context, ref),
                  icon: const Icon(Icons.delete_outline, size: 16),
                ),
              ],
            ),
            if (failed)
              Padding(
                padding: const EdgeInsets.only(top: Space.sm),
                child: Text(
                  forwardErrorText(l, forward.error!, forward.detail),
                  style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Spinner while moving between states, a dot otherwise: filled when running, red when something is wrong.
class _PhaseMark extends StatelessWidget {
  const _PhaseMark(this.phase);
  final ForwardPhase phase;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: 16,
      height: 16,
      child: switch (phase) {
        ForwardPhase.starting ||
        ForwardPhase.reconnecting ||
        ForwardPhase.stopping => const CircularProgressIndicator(strokeWidth: 2),
        ForwardPhase.running => Icon(Icons.circle, size: 12, color: scheme.primary),
        ForwardPhase.failed || ForwardPhase.stopFailed => Icon(Icons.circle, size: 12, color: scheme.error),
        ForwardPhase.stopped => Icon(Icons.circle_outlined, size: 12, color: scheme.outline),
      },
    );
  }
}

class _ForwardEditor extends ConsumerStatefulWidget {
  const _ForwardEditor([this.rule]);
  final ForwardRule? rule;

  @override
  ConsumerState<_ForwardEditor> createState() => _ForwardEditorState();
}

class _ForwardEditorState extends ConsumerState<_ForwardEditor> {
  late final _label = TextEditingController(text: widget.rule?.label);
  late final _listenAddress = TextEditingController(text: widget.rule?.listenAddress)..addListener(_changed);
  late final _listenPort = TextEditingController(text: widget.rule?.listenPort.toString());
  late final _destinationAddress = TextEditingController(text: widget.rule?.destinationAddress);
  late final _destinationPort = TextEditingController(
    text: widget.rule == null || widget.rule!.destinationPort == 0 ? '' : widget.rule!.destinationPort.toString(),
  );
  late HostId? _host = widget.rule?.hostId ?? ref.read(hostsProvider).firstOrNull?.id;
  late ForwardKind _kind = widget.rule?.kind ?? ForwardKind.local;
  late bool _autoStart = widget.rule?.autoStart ?? false;
  late bool _autoReconnect = widget.rule?.autoReconnect ?? false;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _label.dispose();
    _listenAddress.dispose();
    _listenPort.dispose();
    _destinationAddress.dispose();
    _destinationPort.dispose();
    super.dispose();
  }

  void _changed() => setState(() {});

  String _addressOr(TextEditingController c, String fallback) => c.text.trim().isEmpty ? fallback : c.text.trim();

  /// Null when the fields do not make a valid rule.
  ForwardRule? _build() {
    final host = _host;
    final listenPort = int.tryParse(_listenPort.text.trim());
    if (host == null || listenPort == null) return null;
    final rule = ForwardRule(
      id: widget.rule?.id ?? ForwardId(newId()),
      hostId: host,
      label: _label.text.trim(),
      kind: _kind,
      listenAddress: _addressOr(_listenAddress, '127.0.0.1'),
      listenPort: listenPort,
      destinationAddress: _addressOr(_destinationAddress, '127.0.0.1'),
      destinationPort: _kind == ForwardKind.dynamic ? 0 : int.tryParse(_destinationPort.text.trim()) ?? 0,
      autoStart: _autoStart,
      autoReconnect: _autoReconnect,
    );
    try {
      rule.validate();
    } on ArgumentError {
      return null;
    }
    return rule;
  }

  Future<void> _save() async {
    if (_saving) return;
    final l = AppLocalizations.of(context);
    final rule = _build();
    if (rule == null) return setState(() => _error = l.fwInvalid);
    final forwards = ref.read(forwardsProvider.notifier);
    if (forwards.needsExposureConfirmation(rule)) {
      final allowed = await showAppDialog<bool>(
        context: context,
        builder: (context) => AppDialog(
          content: Text(l.fwExposeConfirm(rule.endpoint)),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: Text(l.cancel)),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(l.fwExposeAllow)),
          ],
        ),
      );
      if (allowed != true || !mounted) return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await forwards.save(rule, exposureConfirmed: true);
      if (mounted) Navigator.pop(context);
    } on Object catch (e) {
      if (mounted) {
        setState(
          () => _error = switch (e) {
            ForwardError(code: ForwardErrors.busy) => l.fwBusy,
            ArgumentError() => l.fwInvalid,
            _ => l.fwSaveFailed,
          },
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final hosts = ref.watch(hostsProvider);
    final exposed = !isLoopback(_addressOr(_listenAddress, '127.0.0.1'));
    final remote = _kind == ForwardKind.remote;
    Widget row(Widget address, Widget port) => Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: address),
        const SizedBox(width: Space.md),
        SizedBox(width: 110, child: port),
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: _label,
                  decoration: InputDecoration(labelText: l.label),
                ),
                const SizedBox(height: Space.lg),
                if (hosts.isEmpty)
                  Text(l.fwNoHosts)
                else
                  AppSelect<HostId?>(
                    value: hosts.any((h) => h.id == _host) ? _host : null,
                    label: l.fwHost,
                    options: [for (final h in hosts) AppOption(h.id, h.title)],
                    onChanged: (v) => setState(() => _host = v),
                  ),
                const SizedBox(height: Space.lg),
                Align(
                  alignment: Alignment.centerLeft,
                  child: AppSegmented<ForwardKind>(
                    segments: {
                      ForwardKind.local: l.fwLocal,
                      ForwardKind.remote: l.fwRemote,
                      ForwardKind.dynamic: l.fwDynamic,
                    },
                    selected: _kind,
                    onChanged: (v) => setState(() => _kind = v),
                  ),
                ),
                const SizedBox(height: Space.lg),
                row(
                  TextField(
                    controller: _listenAddress,
                    decoration: InputDecoration(
                      labelText: l.fwListen,
                      hintText: '127.0.0.1',
                      prefixIcon: Icon(remote ? Icons.dns_outlined : Icons.computer_outlined, size: 16),
                      helperText: exposed ? l.fwExposed : null,
                      helperStyle: TextStyle(color: scheme.error),
                    ),
                  ),
                  TextField(
                    controller: _listenPort,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(labelText: l.port),
                  ),
                ),
                if (_kind != ForwardKind.dynamic) ...[
                  const SizedBox(height: Space.lg),
                  row(
                    TextField(
                      controller: _destinationAddress,
                      decoration: InputDecoration(
                        labelText: l.fwDestination,
                        hintText: '127.0.0.1',
                        prefixIcon: Icon(remote ? Icons.computer_outlined : Icons.dns_outlined, size: 16),
                      ),
                    ),
                    TextField(
                      controller: _destinationPort,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(labelText: l.port),
                    ),
                  ),
                ],
                const SizedBox(height: Space.sm),
                AppToggleRow(title: l.fwAutoStart, value: _autoStart, onChanged: (v) => setState(() => _autoStart = v)),
                AppToggleRow(
                  title: l.autoReconnect,
                  value: _autoReconnect,
                  onChanged: (v) => setState(() => _autoReconnect = v),
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: Space.sm),
                    child: Text(_error!, style: TextStyle(color: scheme.error)),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: Space.lg),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(onPressed: _saving ? null : () => Navigator.pop(context), child: Text(l.cancel)),
            const SizedBox(width: Space.sm),
            FilledButton(onPressed: _saving || hosts.isEmpty ? null : _save, child: Text(l.save)),
          ],
        ),
      ],
    );
  }
}

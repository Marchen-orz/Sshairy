import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/controls.dart';
import '../../design/dialog.dart';
import '../../design/form_field.dart';
import '../../design/select.dart';
import '../../design/theme.dart';
import '../../features/hosts/api.dart';
import '../../features/settings/api.dart';
import '../../foundation/ids.dart';
import '../../l10n/app_localizations.dart';
import 'adapters/client_icon.dart';
import 'controller.dart';
import 'storage.dart';

class McpSettings extends ConsumerStatefulWidget {
  const McpSettings({super.key});

  @override
  ConsumerState<McpSettings> createState() => _McpSettingsState();
}

class _McpSettingsState extends ConsumerState<McpSettings> {
  final _pending = <McpClient>{};
  String? _error;
  String? _portDraft;

  // Controls stay as they are while a change runs, so quick settings never flash a disabled state.
  Future<void> _change(FutureOr<void> Function() action) async {
    if (_error != null) setState(() => _error = null);
    try {
      await action();
    } on Object {
      if (mounted) setState(() => _error = AppLocalizations.of(context).mcpChangeFailed);
    }
  }

  Future<void> _scope() => showAppDialog<void>(
    context: context,
    builder: (context) => Consumer(
      builder: (context, ref, _) {
        final l = AppLocalizations.of(context);
        final controller = ref.watch(mcpControllerProvider);
        final hosts = ref.watch(settingsProvider).get(SettingKeys.mcpHosts);
        final digests = ref.watch(mcpRouteDigestsProvider);
        final write = ref.read(settingsProvider.notifier);
        return ListenableBuilder(
          listenable: controller,
          builder: (context, _) {
            final routes = controller.routes();
            final saved = ref.watch(hostsProvider).where((host) => !host.transient).toList();
            final selectable = saved.where((host) => digests.containsKey(host.id)).toList();
            return AppDialog(
              title: Text(l.mcpModeAuto),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    AppToggleRow(
                      title: l.selectAll,
                      checkbox: true,
                      value:
                          selectable.isNotEmpty && selectable.every((host) => hosts[host.id.value] == digests[host.id]),
                      onChanged: selectable.isEmpty && hosts.isEmpty
                          ? null
                          : (value) => _change(
                              () => write.set(SettingKeys.mcpHosts, {
                                if (value)
                                  for (final host in selectable) host.id.value: digests[host.id]!,
                              }),
                            ),
                    ),
                    const Divider(height: Space.sm),
                    for (final host in saved)
                      AppToggleRow(
                        title: hosts.containsKey(host.id.value) && !controller.inAutomaticScope(host.id, routes)
                            ? l.mcpScopeChanged(host.title)
                            : host.title,
                        checkbox: true,
                        value: hosts.containsKey(host.id.value),
                        onChanged: !hosts.containsKey(host.id.value) && !digests.containsKey(host.id)
                            ? null
                            : (value) => _change(() {
                                final next = {...hosts};
                                if (value) {
                                  next[host.id.value] = digests[host.id]!;
                                } else {
                                  next.remove(host.id.value);
                                }
                                return write.set(SettingKeys.mcpHosts, next);
                              }),
                      ),
                  ],
                ),
              ),
              actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(l.close))],
            );
          },
        );
      },
    ),
  );

  Future<void> _audit(McpController controller) async {
    final operations = mcpAuditOperations(await controller.audit.recent());
    if (!mounted) return;
    final names = {for (final host in ref.read(hostsProvider)) host.id.value: host.title};
    await showAppDialog<void>(
      context: context,
      builder: (context) {
        final l = AppLocalizations.of(context);
        return AppDialog(
          title: Text(l.mcpAudit),
          width: 600,
          content: operations.isEmpty
              ? Text(l.mcpAuditEmpty)
              : SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [for (final record in operations) _auditRow(context, l, record, names)],
                  ),
                ),
          actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(l.close))],
        );
      },
    );
  }

  Widget _auditRow(BuildContext context, AppLocalizations l, Map<String, Object?> record, Map<String, String> names) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final outcome = '${record['outcome']}';
    final finished = record['stage'] == 'finished' || record['stage'] == 'withheld';
    final (icon, color, status) = switch (outcome) {
      _ when !finished => (Icons.schedule_rounded, scheme.onSurfaceVariant, l.mcpAuditRunning),
      'completed' => (Icons.check_circle_outline_rounded, scheme.primary, l.mcpAuditCompleted),
      'cancelled' => (Icons.remove_circle_outline_rounded, scheme.onSurfaceVariant, l.mcpAuditCancelled),
      'hostDenied' => (Icons.block_rounded, scheme.error, l.mcpAuditHostDenied),
      'reviewDenied' => (Icons.block_rounded, scheme.error, l.mcpAuditReviewDenied),
      'reviewUnavailable' => (Icons.error_outline_rounded, scheme.error, l.mcpAuditReviewUnavailable),
      'outsideScope' => (Icons.block_rounded, scheme.error, l.mcpAuditOutsideScope),
      'scopeChanged' => (Icons.error_outline_rounded, scheme.error, l.mcpAuditScopeChanged),
      'notExposed' => (Icons.block_rounded, scheme.error, l.mcpAuditNotExposed),
      'invalidArgument' => (Icons.error_outline_rounded, scheme.error, l.mcpAuditInvalid),
      _ => (Icons.error_outline_rounded, scheme.error, l.mcpAuditFailed(outcome)),
    };
    final tool = switch (record['tool']) {
      'host_list' => l.aiAgentToolHosts,
      'diagnostics_collect' => switch (record['template']) {
        'systemSummary' => l.aiAgentDiagnosticSystem,
        'storageCapacity' => l.aiAgentDiagnosticStorage,
        'processSummary' => l.aiAgentDiagnosticProcesses,
        'listeningPorts' => l.aiAgentDiagnosticPorts,
        'serviceStates' => l.aiAgentDiagnosticServices,
        _ => l.aiAgentDiagnostics,
      },
      _ => l.mcpAuditNotExposed,
    };
    final client = McpClient.values.asNameMap()[record['client']]?.label ?? '${record['client']}';
    final host = record['host'] is String ? names[record['host']] ?? '${record['host']}' : null;
    final mode = switch (record['mode']) {
      'model' => l.mcpModeModel,
      'automatic' => l.mcpModeAuto,
      _ => l.mcpModeHost,
    };
    final time = DateTime.tryParse('${record['time']}')?.toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    final now = DateTime.now();
    final stamp = time == null
        ? ''
        : time.year == now.year && time.month == now.month && time.day == now.day
        ? '${two(time.hour)}:${two(time.minute)}:${two(time.second)}'
        : '${two(time.month)}-${two(time.day)} ${two(time.hour)}:${two(time.minute)}';
    final muted = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Space.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(icon, size: 16, color: color),
          ),
          const SizedBox(width: Space.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(host == null ? tool : '$tool · $host'),
                Text([client, mode, status].join(' · '), style: muted),
              ],
            ),
          ),
          const SizedBox(width: Space.md),
          Text(stamp, style: muted?.copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final settings = ref.watch(settingsProvider);
    final write = ref.read(settingsProvider.notifier);
    final controller = ref.watch(mcpControllerProvider);
    final enabled = settings.get(SettingKeys.mcpEnabled);
    final mode = settings.get(SettingKeys.mcpMode);
    final hosts = settings.get(SettingKeys.mcpHosts);
    final scoped = mode == McpApprovalMode.automatic
        ? ref.watch(hostsProvider).where((host) => !host.transient && hosts.containsKey(host.id.value)).toList()
        : const <Host>[];
    final port = settings.get(SettingKeys.mcpPort);
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final fieldHeight = AppFormField.height(context);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppToggleRow(
            title: 'MCP',
            // The address keeps its line whether or not the listener is up, so toggling never shifts the layout.
            subtitle: controller.failed ? l.mcpStartFailed : controller.url,
            value: enabled,
            onChanged: (value) => _change(() => write.set(SettingKeys.mcpEnabled, value)),
          ),
          const SizedBox(height: Space.md),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.xs),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Flexible(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 160),
                        child: AppFormField(
                          label: l.port,
                          child: TextFormField(
                            key: ValueKey(port),
                            initialValue: '$port',
                            keyboardType: TextInputType.number,
                            inputFormatters: [
                              FilteringTextInputFormatter.digitsOnly,
                              LengthLimitingTextInputFormatter(5),
                            ],
                            decoration: AppFormField.decoration(context),
                            onChanged: (text) => setState(() => _portDraft = text),
                            onFieldSubmitted: (text) => _savePort(write, text),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: Space.sm),
                    SizedBox(
                      height: fieldHeight,
                      child: TextButton(
                        onPressed: _portDraft == null || _portDraft == '$port'
                            ? null
                            : () => _savePort(write, _portDraft!),
                        child: Text(l.mcpPortSave),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: Space.md),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final options = {
                      McpApprovalMode.model: l.mcpModeModel,
                      McpApprovalMode.host: l.mcpModeHost,
                      McpApprovalMode.automatic: l.mcpModeAuto,
                    };
                    void select(McpApprovalMode value) => _change(() => write.set(SettingKeys.mcpMode, value));
                    final routes = scoped.isEmpty ? const <HostId, String>{} : controller.routes();
                    final changed = scoped.any((host) => !controller.inAutomaticScope(host.id, routes));
                    return Wrap(
                      spacing: Space.sm,
                      runSpacing: Space.sm,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        if (constraints.maxWidth < WorkspaceSize.toolPanel)
                          AppSelect<McpApprovalMode>(
                            value: mode,
                            options: [for (final entry in options.entries) AppOption(entry.key, entry.value)],
                            onChanged: select,
                          )
                        else
                          AppSegmented<McpApprovalMode>(
                            segments: options,
                            tooltips: {
                              McpApprovalMode.model: l.mcpModeModelHint,
                              McpApprovalMode.host: l.mcpModeHostHint,
                              McpApprovalMode.automatic: l.mcpModeAutoHint,
                            },
                            selected: mode,
                            onChanged: select,
                          ),
                        if (mode == McpApprovalMode.automatic)
                          TextButton.icon(
                            onPressed: _scope,
                            style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: Space.sm)),
                            icon: Icon(
                              changed ? Icons.error_outline_rounded : Icons.dns_outlined,
                              size: 16,
                              color: changed ? theme.colorScheme.error : null,
                            ),
                            label: Text(l.mcpScopeHosts(scoped.length)),
                          ),
                      ],
                    );
                  },
                ),
                const SizedBox(height: Space.lg),
                Wrap(
                  spacing: Space.sm,
                  runSpacing: Space.sm,
                  children: [for (final client in McpClient.values) _client(controller, client, l)],
                ),
              ],
            ),
          ),
          const SizedBox(height: Space.sm),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => _change(() => _audit(controller)),
              style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: Space.xs)),
              icon: const Icon(Icons.history_rounded, size: 16),
              label: Text(l.mcpAudit),
            ),
          ),
          if (_error != null) Text(_error!, style: muted?.copyWith(color: theme.colorScheme.error)),
        ],
      ),
    );
  }

  void _savePort(SettingsNotifier write, String text) => _change(() async {
    await write.set(SettingKeys.mcpPort, int.parse(text));
    _portDraft = null;
  });

  Widget _client(McpController controller, McpClient client, AppLocalizations l) {
    final state = controller.clients.status(client);
    final on = controller.paired(client);
    final blocked = state == SkillStatus.conflict || state == SkillStatus.unavailable;
    final problem = switch (state) {
      SkillStatus.conflict => l.mcpClientConflict,
      SkillStatus.unavailable => l.mcpClientUnavailable,
      SkillStatus.absent when on => l.mcpClientUnavailable,
      _ when controller.clientUpdateFailed(client) => l.mcpChangeFailed,
      _ => null,
    };
    return AppIconToggle(
      icon: McpClientIcon(client),
      tooltip: problem == null ? client.label : '${client.label}\n$problem',
      alert: problem != null,
      value: on,
      onChanged: !on && (blocked || !controller.running)
          ? null
          : (value) {
              if (!_pending.add(client)) return;
              _change(() => value ? controller.connect(client) : controller.disconnect(client))
                  .whenComplete(() => _pending.remove(client));
            },
    );
  }
}

class McpHostPrompts extends ConsumerStatefulWidget {
  const McpHostPrompts({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<McpHostPrompts> createState() => _McpHostPromptsState();
}

class _McpHostPromptsState extends ConsumerState<McpHostPrompts> {
  McpHostApproval? _shown;

  Future<void> _show(McpController controller, McpHostApproval approval) async {
    if (!mounted || !identical(controller.approval, approval)) {
      _shown = null;
      if (mounted) setState(() {});
      return;
    }
    BuildContext? routeContext;
    final dialog = showAppDialog<bool>(
      context: context,
      builder: (context) {
        routeContext = context;
        if (!mounted || !identical(controller.approval, approval)) {
          final route = ModalRoute.of(context);
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (route != null && route.isActive) route.navigator?.removeRoute(route, false);
          });
          return const SizedBox.shrink();
        }
        final l = AppLocalizations.of(context);
        final saved = ref.read(hostsProvider).where((host) => host.id == approval.host.id).firstOrNull;
        final target = saved == null
            ? approval.host.id.value
            : saved.label.isEmpty
            ? saved.target
            : '${saved.label} (${saved.target})';
        return AppDialog(
          title: Text(l.aiAgentHostAccessTitle),
          content: SingleChildScrollView(child: Text(l.mcpHostPrompt(approval.client.label, target))),
          actions: [
            TextButton(autofocus: true, onPressed: () => Navigator.pop(context, false), child: Text(l.cancel)),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(l.aiAgentHostAccessAllow)),
          ],
        );
      },
    );
    void changed() {
      if (identical(controller.approval, approval)) return;
      final dialogContext = routeContext;
      if (dialogContext == null || !dialogContext.mounted) return;
      final route = ModalRoute.of(dialogContext);
      if (route != null && route.isActive) route.navigator?.removeRoute(route, false);
    }

    controller.addListener(changed);
    try {
      controller.decide(approval, await dialog ?? false);
    } finally {
      controller.removeListener(changed);
      if (mounted) setState(() => _shown = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(mcpControllerProvider);
    return ListenableBuilder(
      listenable: controller,
      child: widget.child,
      builder: (context, child) {
        for (final client in controller.takeConnectedClients()) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted || !controller.paired(client)) return;
            final l = AppLocalizations.of(context);
            ScaffoldMessenger.maybeOf(context)
                ?.showSnackBar(SnackBar(content: Text(l.mcpClientConnected(client.label))));
          });
        }
        final approval = controller.approval;
        if (_shown == null && approval != null) {
          _shown = approval;
          WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_show(controller, approval)));
        }
        return child!;
      },
    );
  }
}

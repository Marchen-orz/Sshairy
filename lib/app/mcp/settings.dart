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
import 'controller.dart';
import 'storage.dart';

class McpSettings extends ConsumerStatefulWidget {
  const McpSettings({super.key});

  @override
  ConsumerState<McpSettings> createState() => _McpSettingsState();
}

class _McpSettingsState extends ConsumerState<McpSettings> {
  bool _busy = false;
  String? _error;
  String? _portDraft;

  Future<void> _change(FutureOr<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } on Object {
      if (mounted) _error = AppLocalizations.of(context).mcpChangeFailed;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _audit(McpController controller) async {
    final rows = await controller.audit.recent();
    if (!mounted) return;
    await showAppDialog<void>(
      context: context,
      builder: (context) {
        final l = AppLocalizations.of(context);
        return AppDialog(
          title: Text(l.mcpAudit),
          width: 700,
          content: SingleChildScrollView(child: SelectableText(rows.isEmpty ? l.mcpAuditEmpty : rows.join('\n\n'))),
          actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(l.close))],
        );
      },
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
    final digests = mode == McpApprovalMode.automatic ? ref.watch(mcpRouteDigestsProvider) : const <HostId, String>{};
    final routes = mode == McpApprovalMode.automatic ? controller.routes() : const <HostId, String>{};
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
            subtitle: controller.failed
                ? l.mcpStartFailed
                : controller.running
                ? controller.url
                : null,
            value: enabled,
            onChanged: _busy ? null : (value) => _change(() => write.set(SettingKeys.mcpEnabled, value)),
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
                            enabled: !_busy,
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
                        onPressed: _busy || _portDraft == null || _portDraft == '$port'
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
                    return Align(
                      alignment: Alignment.centerLeft,
                      child: constraints.maxWidth < WorkspaceSize.toolPanel
                          ? AppSelect<McpApprovalMode>(
                              value: mode,
                              options: [for (final entry in options.entries) AppOption(entry.key, entry.value)],
                              onChanged: _busy ? null : select,
                            )
                          : AppSegmented<McpApprovalMode>(
                              segments: options,
                              selected: mode,
                              onChanged: _busy ? null : select,
                            ),
                    );
                  },
                ),
              ],
            ),
          ),
          if (mode == McpApprovalMode.automatic) ...[
            const SizedBox(height: Space.sm),
            for (final host in ref.watch(hostsProvider).where((host) => !host.transient))
              AppToggleRow(
                title: hosts.containsKey(host.id.value) && !controller.inAutomaticScope(host.id, routes)
                    ? l.mcpScopeChanged(host.title)
                    : host.title,
                checkbox: true,
                value: hosts.containsKey(host.id.value),
                onChanged: _busy || (!hosts.containsKey(host.id.value) && !digests.containsKey(host.id))
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
          const SizedBox(height: Space.lg),
          for (final client in McpClient.values) _client(controller, client, l),
          const SizedBox(height: Space.sm),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _busy ? null : () => _change(() => _audit(controller)),
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
    return AppToggleRow(
      title: client.label,
      subtitle: switch (state) {
        SkillStatus.conflict => l.mcpClientConflict,
        SkillStatus.unavailable => l.mcpClientUnavailable,
        SkillStatus.absent when on => l.mcpClientUnavailable,
        _ when controller.clientUpdateFailed(client) => l.mcpChangeFailed,
        _ => null,
      },
      value: on,
      onChanged: _busy || (!on && (blocked || !controller.running))
          ? null
          : (value) => _change(() => value ? controller.connect(client) : controller.disconnect(client)),
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

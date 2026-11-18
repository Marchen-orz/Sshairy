import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/controls.dart';
import '../../design/dialog.dart';
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
  McpClient _client = McpClient.claude;
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

  Future<void> _copy(McpController controller) async {
    final token = (await controller.pair(_client)).reveal();
    final url = controller.url;
    final variable = 'SSHAIRY_MCP_${_client.name.toUpperCase()}_TOKEN';
    final config = switch (_client) {
      McpClient.claude => const JsonEncoder.withIndent('  ').convert({
        'mcpServers': {
          'sshairy': {
            'type': 'http',
            'url': url,
            'headers': {'Authorization': 'Bearer \${$variable}'},
          },
        },
      }),
      McpClient.codex => '[mcp_servers.sshairy]\nurl = "$url"\nbearer_token_env_var = "$variable"',
      McpClient.zcode => const JsonEncoder.withIndent('  ').convert({
        'features': {'mcp': true},
        'mcp': {
          'servers': {
            'sshairy': {
              'type': 'http',
              'url': url,
              'timeoutMs': 60000,
              'headers': {'Authorization': 'Bearer <TOKEN>'},
            },
          },
        },
      }),
      McpClient.deepseek =>
        '- insert:\n'
            '    - id: mcp-sshairy\n'
            '      name: "@deepseek-ai/dsh-mcp-client"\n'
            '      config:\n'
            '        serverName: sshairy\n'
            '        transport: streamable-http\n'
            '        url: $url\n'
            '        headers:\n'
            '          Authorization: "Bearer \${credential:$variable}"\n'
            '        expandTemplates: true',
    };
    if (!mounted) return;
    await showAppDialog<void>(
      context: context,
      builder: (context) {
        final l = AppLocalizations.of(context);
        return AppDialog(
          title: Text(_client.label),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_client == McpClient.zcode ? l.mcpHeaderSetup : l.mcpTokenSetup(variable)),
                const SizedBox(height: Space.sm),
                SelectableText(config),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Clipboard.setData(ClipboardData(text: config)),
              child: Text(l.mcpCopyConfig),
            ),
            TextButton(
              onPressed: () => Clipboard.setData(ClipboardData(text: token)),
              child: Text(l.mcpCopyToken),
            ),
            FilledButton(onPressed: () => Navigator.pop(context), child: Text(l.close)),
          ],
        );
      },
    );
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
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _row(
            'MCP',
            AppSwitch(
              value: enabled,
              onChanged: _busy ? null : (value) => _change(() => write.set(SettingKeys.mcpEnabled, value)),
              semanticLabel: 'MCP',
            ),
          ),
          if (controller.failed) Text(l.mcpStartFailed),
          if (controller.running) SelectableText(controller.url),
          const SizedBox(height: Space.sm),
          Row(
            children: [
              SizedBox(
                width: 130,
                child: TextFormField(
                  key: ValueKey(port),
                  initialValue: '$port',
                  enabled: !_busy,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(5)],
                  decoration: InputDecoration(labelText: l.port),
                  onChanged: (text) => setState(() => _portDraft = text),
                  onFieldSubmitted: (text) => _savePort(write, text),
                ),
              ),
              const SizedBox(width: Space.sm),
              TextButton(
                onPressed: _busy || _portDraft == null || _portDraft == '$port'
                    ? null
                    : () => _savePort(write, _portDraft!),
                child: Text(l.mcpPortSave),
              ),
            ],
          ),
          const SizedBox(height: Space.sm),
          AppSelect<McpApprovalMode>(
            value: mode,
            options: [
              AppOption(McpApprovalMode.model, l.mcpModeModel),
              AppOption(McpApprovalMode.host, l.mcpModeHost),
              AppOption(McpApprovalMode.automatic, l.mcpModeAuto),
            ],
            onChanged: _busy ? null : (value) => _change(() => write.set(SettingKeys.mcpMode, value)),
          ),
          if (mode == McpApprovalMode.automatic)
            for (final host in ref.watch(hostsProvider).where((host) => !host.transient))
              _row(
                hosts.containsKey(host.id.value) && !controller.inAutomaticScope(host.id, routes)
                    ? l.mcpScopeChanged(host.title)
                    : host.title,
                AppCheckbox(
                  value: hosts.containsKey(host.id.value),
                  semanticLabel: host.title,
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
              ),
          const SizedBox(height: Space.sm),
          AppSelect<McpClient>(
            value: _client,
            options: [for (final client in McpClient.values) AppOption(client, client.label)],
            onChanged: _busy ? null : (client) => setState(() => _client = client),
          ),
          Wrap(
            spacing: Space.sm,
            children: [
              TextButton(
                onPressed: !_busy && controller.running ? () => _change(() => _copy(controller)) : null,
                child: Text(l.mcpConnection),
              ),
              if (!controller.running || controller.paired(_client))
                TextButton(
                  onPressed: _busy ? null : () => _change(() => controller.revoke(_client)),
                  child: Text(l.mcpRevoke),
                ),
              TextButton(onPressed: _busy ? null : () => _change(() => _audit(controller)), child: Text(l.mcpAudit)),
            ],
          ),
          const Divider(),
          for (final client in McpClient.values) _row('${client.label} Skill', _skill(controller, client, l)),
          if (_error != null) Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
        ],
      ),
    );
  }

  void _savePort(SettingsNotifier write, String text) => _change(() async {
    await write.set(SettingKeys.mcpPort, int.parse(text));
    _portDraft = null;
  });

  Widget _skill(McpController controller, McpClient client, AppLocalizations l) {
    final state = controller.skills.status(client);
    if (state == SkillStatus.conflict) return Text(l.mcpSkillConflict);
    if (state == SkillStatus.unavailable) return Text(l.mcpChangeFailed);
    return AppSwitch(
      value: state == SkillStatus.installed,
      semanticLabel: '${client.label} Skill',
      onChanged: _busy ? null : (value) => _change(() => controller.skills.setInstalled(client, value)),
    );
  }

  Widget _row(String label, Widget action) => Padding(
    padding: const EdgeInsets.symmetric(vertical: Space.xs),
    child: Row(
      children: [
        Expanded(child: Text(label)),
        action,
      ],
    ),
  );
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

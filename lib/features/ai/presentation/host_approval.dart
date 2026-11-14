import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../design/dialog.dart';
import '../../../l10n/app_localizations.dart';
import '../adapters/attachments.dart';
import '../application/configuration.dart';
import '../application/providers.dart';
import '../application/runtime.dart';

/// Lives with the workspace so a background Agent cannot lose its host confirmation or local access request when the
/// sidebar closes.
class AgentHostApprovalPrompts extends ConsumerStatefulWidget {
  const AgentHostApprovalPrompts({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<AgentHostApprovalPrompts> createState() => _AgentHostApprovalPromptsState();
}

class _AgentHostApprovalPromptsState extends ConsumerState<AgentHostApprovalPrompts> {
  AgentRuntime? _runtime;
  AgentHostApproval? _shown;
  AgentLocalAccessRequest? _localShown;
  DialogRoute<bool>? _route;
  NavigatorState? _navigator;

  void _dismiss() {
    final route = _route, navigator = _navigator;
    if (route != null && route.isActive && navigator != null && navigator.mounted) {
      navigator.removeRoute(route, false);
    }
  }

  Future<void> _show(AgentRuntime runtime, AgentHostApproval approval) async {
    if (!mounted || !identical(_runtime, runtime) || !identical(runtime.hostApproval, approval)) {
      if (identical(runtime.hostApproval, approval)) runtime.decideHost(approval, false);
      _shown = null;
      if (mounted) setState(() {});
      return;
    }
    final navigator = Navigator.of(context);
    final route = DialogRoute<bool>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: Theme.of(context).brightness == Brightness.dark ? .5 : .28),
      builder: (context) {
        final l = AppLocalizations.of(context);
        return AppDialog(
          key: const ValueKey('ai-host-approval'),
          title: Text(l.aiAgentHostAccessTitle),
          content: SingleChildScrollView(child: Text(l.aiAgentHostAccessPrompt(approval.target))),
          actions: [
            TextButton(
              key: const ValueKey('ai-host-deny'),
              autofocus: true,
              onPressed: () => Navigator.pop(context, false),
              child: Text(l.cancel),
            ),
            FilledButton(
              key: const ValueKey('ai-host-allow'),
              onPressed: () => Navigator.pop(context, true),
              child: Text(l.aiAgentHostAccessAllow),
            ),
          ],
        );
      },
    );
    _navigator = navigator;
    _route = route;
    void changed() {
      if (!identical(runtime.hostApproval, approval) && route.isActive && navigator.mounted) {
        navigator.removeRoute(route, false);
      }
    }

    runtime.addListener(changed);
    try {
      final allowed = await navigator.push(route) ?? false;
      if (identical(runtime.hostApproval, approval)) {
        runtime.decideHost(approval, allowed && identical(_runtime, runtime));
      }
    } finally {
      runtime.removeListener(changed);
      _shown = null;
      _route = null;
      _navigator = null;
      if (mounted) setState(() {});
    }
  }

  /// The user picks the actual folder or file; the dialog only explains the request and its read/write scope.
  Future<void> _showLocal(AgentRuntime runtime, AgentLocalAccessRequest request) async {
    if (!mounted || !identical(_runtime, runtime) || !identical(runtime.localAccessRequest, request)) {
      if (identical(runtime.localAccessRequest, request)) runtime.decideLocalAccess(request, null);
      _localShown = null;
      if (mounted) setState(() {});
      return;
    }
    final navigator = Navigator.of(context);
    final route = DialogRoute<bool>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: Theme.of(context).brightness == Brightness.dark ? .5 : .28),
      builder: (context) {
        final l = AppLocalizations.of(context);
        return AppDialog(
          key: const ValueKey('ai-local-access'),
          title: Text(l.aiAgentLocalAccessTitle),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  request.write
                      ? l.aiAgentLocalAccessWrite
                      : request.directory
                      ? l.aiAgentLocalAccessFolder
                      : l.aiAgentLocalAccessFile,
                ),
                if (request.purpose.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(request.purpose, style: Theme.of(context).textTheme.bodySmall),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              key: const ValueKey('ai-local-deny'),
              autofocus: true,
              onPressed: () => Navigator.pop(context, false),
              child: Text(l.cancel),
            ),
            FilledButton(
              key: const ValueKey('ai-local-choose'),
              onPressed: () => Navigator.pop(context, true),
              child: Text(request.directory ? l.aiAgentLocalAccessChooseFolder : l.aiAgentLocalAccessChooseFile),
            ),
          ],
        );
      },
    );
    _navigator = navigator;
    _route = route;
    void changed() {
      if (!identical(runtime.localAccessRequest, request) && route.isActive && navigator.mounted) {
        navigator.removeRoute(route, false);
      }
    }

    runtime.addListener(changed);
    try {
      final choose = await navigator.push(route) ?? false;
      String? path;
      if (choose && identical(runtime.localAccessRequest, request) && identical(_runtime, runtime)) {
        path = await chooseLocalGrantPath(directory: request.directory);
      }
      if (identical(runtime.localAccessRequest, request)) {
        runtime.decideLocalAccess(request, identical(_runtime, runtime) ? path : null);
      }
    } on Object {
      if (identical(runtime.localAccessRequest, request)) runtime.decideLocalAccess(request, null);
    } finally {
      runtime.removeListener(changed);
      _localShown = null;
      _route = null;
      _navigator = null;
      if (mounted) setState(() {});
    }
  }

  @override
  void dispose() {
    _runtime = null;
    _dismiss();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final runtime = ref.watch(aiConfigurationProvider).enabled ? ref.watch(agentRuntimeProvider) : null;
    if (!identical(_runtime, runtime)) {
      _runtime = runtime;
      WidgetsBinding.instance.addPostFrameCallback((_) => _dismiss());
    }
    if (runtime == null) return widget.child;
    return ListenableBuilder(
      listenable: runtime,
      child: widget.child,
      builder: (context, child) {
        final approval = runtime.hostApproval;
        if (_shown == null && approval != null) {
          _shown = approval;
          WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_show(runtime, approval)));
        }
        final local = runtime.localAccessRequest;
        if (_localShown == null && local != null) {
          _localShown = local;
          WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_showLocal(runtime, local)));
        }
        return child!;
      },
    );
  }
}

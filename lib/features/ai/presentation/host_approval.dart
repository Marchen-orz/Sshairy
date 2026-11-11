import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../design/dialog.dart';
import '../../../l10n/app_localizations.dart';
import '../application/configuration.dart';
import '../application/providers.dart';
import '../application/runtime.dart';

/// Lives with the workspace so a background Agent cannot lose its host confirmation when the sidebar closes.
class AgentHostApprovalPrompts extends ConsumerStatefulWidget {
  const AgentHostApprovalPrompts({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<AgentHostApprovalPrompts> createState() => _AgentHostApprovalPromptsState();
}

class _AgentHostApprovalPromptsState extends ConsumerState<AgentHostApprovalPrompts> {
  AgentRuntime? _runtime;
  AgentHostApproval? _shown;
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
        return child!;
      },
    );
  }
}

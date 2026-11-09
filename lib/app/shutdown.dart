import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/dialog.dart';
import '../features/connections/api.dart';
import '../features/credentials/api.dart';
import '../features/files/api.dart';
import '../features/forwarding/api.dart';
import '../features/hosts/api.dart';
import '../features/settings/api.dart';
import '../features/snippets/api.dart';
import '../features/terminal/api.dart';
import '../features/workspace/api.dart';
import '../foundation/diagnostics.dart';
import '../l10n/app_localizations.dart';
import '../platform/desktop_window.dart';

enum _ExitFailureChoice { back, retry, quit }

/// Every close request shares this decision and drain sequence, including the custom titlebar and Alt+F4.
class ShutdownGuard extends ConsumerStatefulWidget {
  const ShutdownGuard({super.key, required this.child, this.window});
  final Widget child;
  final DesktopWindow? window;

  @override
  ConsumerState<ShutdownGuard> createState() => _ShutdownGuardState();
}

class _ShutdownGuardState extends ConsumerState<ShutdownGuard> {
  late final _listener = AppLifecycleListener(onExitRequested: _onExit);
  var _asking = false;
  var _draining = false;

  DesktopWindow get _window => widget.window ?? DesktopWindow.instance;

  @override
  void initState() {
    super.initState();
    _listener;
  }

  @override
  void dispose() {
    _listener.dispose();
    super.dispose();
  }

  Future<AppExitResponse> _onExit() async {
    if (_asking) return AppExitResponse.cancel;
    _asking = true;
    final transfers = ref.read(transfersProvider.notifier);
    final edits = ref.read(editsProvider.notifier);
    final forwards = ref.read(forwardsProvider.notifier);
    try {
      final running = transfers.activeCount;
      final unsaved = edits.unsavedCount;
      final tunnels = ref.read(forwardsProvider).where((f) => f.active).length;
      final sessions = ref
          .read(terminalSessionsProvider)
          .values
          .where((s) => s.status == SessionStatus.connected || s.status == SessionStatus.connecting)
          .length;
      // Work that would be lost always asks; otherwise the confirmQuit setting decides.
      final ask = running > 0 || unsaved > 0 || tunnels > 0 || ref.read(settingsProvider).get(SettingKeys.confirmQuit);
      if (ask && !await _confirm(running, unsaved, tunnels, sessions)) {
        return AppExitResponse.cancel;
      }
      while (mounted) {
        setState(() => _draining = true);
        // Cleanup and engine teardown happen after the window is gone, never on a frozen frame.
        await _window.hide();
        try {
          await Future.wait([transfers.shutdown(), edits.shutdown(), forwards.shutdown()])
              .timeout(const Duration(seconds: 8));
          await Future.wait([
            ref.read(hostsProvider.notifier).saved,
            ref.read(keysProvider.notifier).saved,
            ref.read(hostTrustProvider).saved,
            ref.read(settingsProvider.notifier).saved,
            ref.read(snippetsProvider.notifier).saved,
            ref.read(workspaceProvider.notifier).saved,
          ]).timeout(const Duration(seconds: 5));
          await ref.read(terminalSessionsProvider.notifier).shutdown().timeout(const Duration(seconds: 5));
          ref.read(connectionManagerProvider).closeAll();
          await _closeDiagnostics();
          return AppExitResponse.exit;
        } on Object {
          ref
              .read(diagnosticLogProvider)
              .record(DiagnosticArea.application, DiagnosticAction.shutdown, DiagnosticOutcome.failed);
          if (!mounted) return AppExitResponse.cancel;
          setState(() => _draining = false);
          await _window.show();
          if (!mounted) return AppExitResponse.cancel;
          switch (await _failure()) {
            case _ExitFailureChoice.retry:
              continue;
            case _ExitFailureChoice.quit:
              // Only an explicit choice can abandon pending saves or an unconfirmed remote listener.
              await _window.hide();
              ref.read(terminalSessionsProvider.notifier).closeAll();
              ref.read(connectionManagerProvider).closeAll();
              return AppExitResponse.exit;
            case _ExitFailureChoice.back:
              transfers.resumeAfterShutdown();
              edits.resumeAfterShutdown();
              forwards.resumeAfterShutdown();
              return AppExitResponse.cancel;
          }
        }
      }
      return AppExitResponse.cancel;
    } finally {
      _asking = false;
      if (mounted) setState(() => _draining = false);
    }
  }

  Future<void> _closeDiagnostics() async {
    final log = ref.read(diagnosticLogProvider);
    log.record(DiagnosticArea.application, DiagnosticAction.shutdown, DiagnosticOutcome.succeeded);
    // A diagnostic IO failure must not turn a successful business drain into a failed save.
    try {
      await log.close().timeout(const Duration(seconds: 1));
    } on Object {
      return;
    }
  }

  Future<bool> _confirm(int running, int unsaved, int tunnels, int sessions) async {
    if (!mounted) return false;
    final l = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final lines = [
      if (sessions > 0) l.sessionsOpen(sessions),
      if (running > 0) l.transfersRunning(running),
      if (unsaved > 0) l.editsUnsaved(unsaved),
      if (tunnels > 0) l.forwardsRunning(tunnels),
      if (running > 0 || unsaved > 0) l.quitNote,
    ];
    return await showAppDialog<bool>(
          context: context,
          builder: (context) => AppDialog(
            title: Text(l.quitTitle),
            content: lines.isEmpty ? null : Text(lines.join('\n')),
            actions: [
              TextButton(autofocus: true, onPressed: () => Navigator.pop(context, false), child: Text(l.cancel)),
              TextButton(
                style: TextButton.styleFrom(foregroundColor: scheme.error),
                onPressed: () => Navigator.pop(context, true),
                child: Text(l.quit),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<_ExitFailureChoice> _failure() async {
    final l = AppLocalizations.of(context);
    return await showAppDialog<_ExitFailureChoice>(
          context: context,
          barrierDismissible: false,
          builder: (context) => AppDialog(
            content: Text(l.quitFailed),
            actions: [
              TextButton(
                autofocus: true,
                onPressed: () => Navigator.pop(context, _ExitFailureChoice.back),
                child: Text(l.returnToApp),
              ),
              TextButton(onPressed: () => Navigator.pop(context, _ExitFailureChoice.retry), child: Text(l.retryAction)),
              TextButton(
                style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
                onPressed: () => Navigator.pop(context, _ExitFailureChoice.quit),
                child: Text(l.quitAnyway),
              ),
            ],
          ),
        ) ??
        _ExitFailureChoice.back;
  }

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      widget.child,
      if (_draining) ...[
        ModalBarrier(dismissible: false, color: Theme.of(context).colorScheme.scrim.withValues(alpha: 0.2)),
        const Center(child: CircularProgressIndicator()),
      ],
    ],
  );
}

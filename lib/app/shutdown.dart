import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/files/api.dart';
import '../features/snippets/api.dart';
import '../features/workspace/api.dart';
import '../l10n/app_localizations.dart';

/// Asks before the window closes on running transfers or edits not uploaded, then lets each feature finish writing.
class ShutdownGuard extends ConsumerStatefulWidget {
  const ShutdownGuard({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<ShutdownGuard> createState() => _ShutdownGuardState();
}

class _ShutdownGuardState extends ConsumerState<ShutdownGuard> {
  late final _listener = AppLifecycleListener(onExitRequested: _onExit);
  var _asking = false;

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
    final transfers = ref.read(transfersProvider.notifier);
    final edits = ref.read(editsProvider.notifier);
    final running = transfers.activeCount, unsaved = edits.unsavedCount;
    if (running > 0 || unsaved > 0) {
      _asking = true;
      final quit = await _confirm(running, unsaved);
      _asking = false;
      if (!quit) return AppExitResponse.cancel;
    }
    await ref.read(snippetsProvider.notifier).saved;
    await transfers.shutdown();
    await Future.wait([edits.saved, ref.read(workspaceProvider.notifier).saved])
        .timeout(const Duration(seconds: 2), onTimeout: () => const []);
    return AppExitResponse.exit;
  }

  Future<bool> _confirm(int running, int unsaved) async {
    if (!mounted) return true;
    final l = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          [if (running > 0) l.transfersRunning(running), if (unsaved > 0) l.editsUnsaved(unsaved)].join('\n'),
        ),
        content: Text(l.quitNote),
        actions: [
          TextButton(autofocus: true, onPressed: () => Navigator.pop(context, false), child: Text(l.cancel)),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: scheme.error),
            onPressed: () => Navigator.pop(context, true),
            child: Text(l.quit),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

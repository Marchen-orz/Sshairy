import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../design/dialog.dart';
import '../../../design/theme.dart';
import '../../../foundation/result.dart';
import '../../../l10n/app_localizations.dart';
import '../../settings/api.dart';
import '../adapters/known_hosts_file.dart';
import '../application/host_trust.dart';
import '../application/providers.dart';
import '../domain/known_hosts.dart';
import 'known_hosts_dialog.dart';

/// Trust records under Data & security. Removing one means the next connection asks again; only the user
/// manages these, never the agent (docs/SECURITY.md).
final trustSettingsSection = SettingsSection((l) => l.dataSecurity, (_) => const _TrustedKeys());

class _TrustedKeys extends ConsumerStatefulWidget {
  const _TrustedKeys();

  @override
  ConsumerState<_TrustedKeys> createState() => _TrustedKeysState();
}

class _TrustedKeysState extends ConsumerState<_TrustedKeys> {
  Future<void> _import() async {
    final l = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.maybeOf(context);
    final importer = ref.read(knownHostsImportProvider);
    final picked = await pickKnownHosts();
    if (picked == null || !mounted) return;
    switch (picked) {
      case Err(:final error):
        final text = error.code == 'knownHostsTooLarge'
            ? l.knownHostsTooLarge(knownHostsMaxBytes ~/ (1024 * 1024))
            : l.knownHostsUnreadable;
        messenger?.showSnackBar(SnackBar(content: Text(text)));
      case Ok(:final value):
        final preview = await importer.preview(value);
        if (!mounted) return;
        final result = await showAppDialog<TrustImportResult>(
          context: context,
          barrierDismissible: false,
          builder: (_) => KnownHostsImportDialog(preview: preview, commit: () => importer.commit(preview)),
        );
        if (result == null || !mounted) return;
        setState(() {});
        messenger?.showSnackBar(SnackBar(content: Text(l.knownHostsImported(result.added))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final trust = ref.read(hostTrustProvider);
    final keys = [
      for (final MapEntry(key: endpoint, value: types) in trust.entries.entries)
        for (final MapEntry(key: type, value: fingerprint) in types.entries) (endpoint, type, fingerprint),
    ]..sort((a, b) => a.$1.compareTo(b.$1));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: Text(l.trustedKeys)),
            IconButton(
              tooltip: l.importKnownHosts,
              onPressed: _import,
              icon: const Icon(Icons.file_upload_outlined, size: 16),
            ),
          ],
        ),
        const SizedBox(height: Space.sm),
        if (keys.isEmpty) Text(l.none, style: muted),
        for (final (endpoint, type, fingerprint) in keys)
          Padding(
            padding: const EdgeInsets.only(bottom: Space.sm),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(endpoint, maxLines: 1, overflow: TextOverflow.ellipsis),
                      Tooltip(
                        message: fingerprint,
                        child: Text(
                          '$type  $fingerprint',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: mono(context, muted),
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: l.remove,
                  onPressed: () async {
                    await trust.forget(endpoint, type);
                    if (mounted) setState(() {});
                  },
                  icon: const Icon(Icons.delete_outline, size: 16),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

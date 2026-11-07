import 'package:flutter/material.dart';

import '../../../design/dialog.dart';
import '../../../design/theme.dart';
import '../../../l10n/app_localizations.dart';
import '../application/host_trust.dart';
import '../domain/known_hosts.dart';

/// What importing a known_hosts file would do. Nothing is saved until the user presses Import; conflicts and
/// unsupported lines are listed and left out.
class KnownHostsImportDialog extends StatefulWidget {
  const KnownHostsImportDialog({super.key, required this.preview, required this.commit});

  final KnownHostsPreview preview;
  final Future<TrustImportResult> Function() commit;

  @override
  State<KnownHostsImportDialog> createState() => _KnownHostsImportDialogState();
}

class _KnownHostsImportDialogState extends State<KnownHostsImportDialog> {
  static const _shownLines = 8;
  static const _shownConflicts = 200;
  static const _shownAdditions = 500;

  var _busy = false, _failed = false;

  Future<void> _commit() async {
    setState(() {
      _busy = true;
      _failed = false;
    });
    try {
      final result = await widget.commit();
      if (mounted) Navigator.pop(context, result);
    } on Object {
      if (mounted) {
        setState(() {
          _busy = false;
          _failed = true;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final p = widget.preview;
    final muted = Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    final monoStyle = mono(context, muted);

    Widget summary(IconData icon, Color color, int count, String label) => Padding(
      padding: const EdgeInsets.only(bottom: Space.xs),
      child: Row(
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: Space.sm),
          SizedBox(
            width: 48,
            child: Text('$count', style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
          Expanded(child: Text(label)),
        ],
      ),
    );

    Widget item(IconData icon, Color color, List<Widget> lines) => Padding(
      padding: const EdgeInsets.symmetric(vertical: Space.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(icon, size: 16, color: color),
          ),
          const SizedBox(width: Space.sm),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: lines),
          ),
        ],
      ),
    );

    Widget fingerprint(String label, String value) => Tooltip(
      message: value,
      child: Text(
        label.isEmpty ? value : '$label  $value',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: monoStyle,
      ),
    );

    final rows = <Widget Function()>[
      for (final c in p.conflicts.take(_shownConflicts))
        () => item(Icons.warning_amber_rounded, scheme.error, [
          Text('${c.endpoint} · ${c.type}', maxLines: 1, overflow: TextOverflow.ellipsis),
          if (c.saved case final saved?)
            fingerprint(l.knownHostsSavedKey, saved)
          else
            Text(l.knownHostsFileConflict, style: muted),
          fingerprint(l.knownHostsFileKey, c.fingerprint),
        ]),
      for (final kind in KnownHostsIssue.values)
        if (p.issues.where((i) => i.kind == kind).toList() case final group when group.isNotEmpty)
          () {
            final details = {
              for (final i in group)
                if (i.detail.isNotEmpty) i.detail,
            }.take(4);
            final lines = group.take(_shownLines).map((i) => '#${i.line}');
            return item(Icons.block, scheme.tertiary, [
              Text(_reason(l, kind)),
              Text(
                [...details, ...lines, if (group.length > _shownLines) '…'].join('  '),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: monoStyle,
              ),
            ]);
          },
      for (final a in p.additions.take(_shownAdditions))
        () => item(Icons.add_circle_outline, scheme.primary, [
          Text('${a.endpoint} · ${a.type}', maxLines: 1, overflow: TextOverflow.ellipsis),
          fingerprint('', a.fingerprint),
        ]),
    ];

    return AppDialog(
      width: 608,
      title: Text(l.importKnownHosts),
      content: SizedBox(
        height: 120 + (rows.length * 52.0).clamp(0.0, 300.0).toDouble(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            summary(Icons.add_circle_outline, scheme.primary, p.additions.length, l.knownHostsNew),
            if (p.alreadyTrusted.isNotEmpty)
              summary(
                Icons.check_circle_outline,
                scheme.onSurfaceVariant,
                p.alreadyTrusted.length,
                l.knownHostsTrusted,
              ),
            if (p.conflicts.isNotEmpty)
              summary(Icons.warning_amber_rounded, scheme.error, p.conflicts.length, l.knownHostsConflict),
            if (p.issues.isNotEmpty) summary(Icons.block, scheme.tertiary, p.issues.length, l.knownHostsSkipped),
            const SizedBox(height: Space.sm),
            const Divider(),
            Expanded(
              child: ListView.builder(itemCount: rows.length, itemBuilder: (_, i) => rows[i]()),
            ),
            if (_failed)
              Padding(
                padding: const EdgeInsets.only(top: Space.sm),
                child: Text(l.knownHostsSaveFailed, style: TextStyle(color: scheme.error)),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.pop(context), child: Text(l.cancel)),
        FilledButton(
          onPressed: p.additions.isEmpty || _busy ? null : _commit,
          child: Text('${l.importAction} ${p.additions.length}'),
        ),
      ],
    );
  }

  static String _reason(AppLocalizations l, KnownHostsIssue kind) => switch (kind) {
    KnownHostsIssue.malformed => l.knownHostsMalformed,
    KnownHostsIssue.marker => l.knownHostsMarker,
    KnownHostsIssue.wildcard => l.knownHostsWildcard,
    KnownHostsIssue.negation => l.knownHostsNegation,
    KnownHostsIssue.keyType => l.knownHostsKeyType,
    KnownHostsIssue.badKey => l.knownHostsBadKey,
    KnownHostsIssue.hashedUnmatched => l.knownHostsHashed,
  };
}

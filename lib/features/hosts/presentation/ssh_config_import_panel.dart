import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../design/controls.dart';
import '../../../design/theme.dart';
import '../../../foundation/json_file.dart';
import '../../../l10n/app_localizations.dart';
import '../application/ssh_config_import.dart';
import '../domain/import_plan.dart';
import '../domain/ssh_config.dart';

class SshConfigImportPanel extends ConsumerStatefulWidget {
  const SshConfigImportPanel({super.key});

  @override
  ConsumerState<SshConfigImportPanel> createState() => _SshConfigImportPanelState();
}

class _SshConfigImportPanelState extends ConsumerState<SshConfigImportPanel> {
  SshConfigPreview? _preview;
  final _selected = <String>{};
  var _busy = false;
  String? _error;

  Future<void> _pick() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final preview = await ref.read(sshConfigImportProvider).pick();
      if (!mounted || preview == null) return;
      setState(() {
        _preview = preview;
        _selected
          ..clear()
          ..addAll(preview.plan.drafts.where((d) => d.selectable).map((d) => d.source.alias));
      });
    } on Exception {
      if (mounted) setState(() => _error = AppLocalizations.of(context).sshConfigFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _commit() async {
    final preview = _preview;
    if (_busy || preview == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final count = await ref.read(sshConfigImportProvider).commit(preview, {..._selected});
      if (!mounted) return;
      final messenger = ScaffoldMessenger.maybeOf(context);
      final message = AppLocalizations.of(context).sshConfigImported(count);
      Navigator.pop(context);
      messenger?.showSnackBar(SnackBar(content: Text(message)));
    } on JsonFileError catch (error) {
      if (mounted) {
        setState(
          () => _error = error.kind == JsonFileFailure.conflict
              ? AppLocalizations.of(context).sshConfigChanged
              : AppLocalizations.of(context).sshConfigFailed,
        );
      }
    } on Exception {
      if (mounted) setState(() => _error = AppLocalizations.of(context).sshConfigFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final preview = _preview;
    final drafts = preview?.plan.drafts ?? const <SshImportDraft>[];
    final selectable = drafts.where((d) => d.selectable).toList();
    final count = preview?.plan.additions(_selected).length ?? 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: Text(l.sshConfigImport, style: theme.textTheme.titleMedium)),
            IconButton(
              tooltip: l.closePane,
              onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.close, size: 16),
            ),
          ],
        ),
        const SizedBox(height: Space.md),
        OutlinedButton.icon(
          onPressed: _busy ? null : _pick,
          icon: const Icon(Icons.file_open_outlined, size: 16),
          label: Text(preview?.name ?? l.sshConfigPick, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
        if (_busy) const LinearProgressIndicator(),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: Space.md),
            child: Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
          ),
        if (selectable.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: Space.sm),
            child: AppToggleRow(
              checkbox: true,
              title: l.selectAll,
              value: selectable.every((d) => _selected.contains(d.source.alias)),
              onChanged: _busy
                  ? null
                  : (checked) => setState(() {
                      _selected.clear();
                      if (checked) _selected.addAll(selectable.map((d) => d.source.alias));
                    }),
            ),
          ),
        const SizedBox(height: Space.sm),
        Expanded(
          child: ListView(
            children: [
              for (final draft in drafts)
                _DraftRow(
                  draft: draft,
                  selected: _selected.contains(draft.source.alias),
                  onChanged: _busy || !draft.selectable
                      ? null
                      : (value) => setState(() {
                          if (value) {
                            _selected.add(draft.source.alias);
                          } else {
                            _selected.remove(draft.source.alias);
                          }
                        }),
                ),
              for (final issue in preview?.plan.issues ?? const <SshConfigIssue>[])
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: Space.sm),
                  child: Text(
                    '${issue.file}:${issue.line} · ${issue.option.isEmpty ? '' : '${issue.option} · '}${_issueText(l, issue.kind)}',
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ),
              if (preview != null && drafts.isEmpty && preview.plan.issues.isEmpty)
                Padding(padding: const EdgeInsets.all(Space.lg), child: Text(l.none)),
            ],
          ),
        ),
        const SizedBox(height: Space.md),
        FilledButton(onPressed: _busy || count == 0 ? null : _commit, child: Text('${l.importAction} ($count)')),
      ],
    );
  }
}

class _DraftRow extends StatelessWidget {
  const _DraftRow({required this.draft, required this.selected, required this.onChanged});
  final SshImportDraft draft;
  final bool selected;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final source = draft.source;
    final status = draft.existing != null
        ? l.sshConfigExisting
        : draft.issues.isNotEmpty
        ? l.sshConfigBlocked
        : null;
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final details = DefaultTextStyle.merge(
      style: muted,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${source.username}@${source.address}:${source.port}', maxLines: 2, overflow: TextOverflow.ellipsis),
          if (source.jumps.isNotEmpty)
            Text('↳ ${source.jumps.join(' → ')}', maxLines: 2, overflow: TextOverflow.ellipsis),
          if (source.keyPath != null)
            Text('${l.keyPath}: ${source.keyPath}', maxLines: 2, overflow: TextOverflow.ellipsis),
          if (status != null)
            Text(
              status,
              style: TextStyle(
                color: draft.issues.isEmpty ? theme.colorScheme.onSurfaceVariant : theme.colorScheme.error,
              ),
            ),
          for (final issue in draft.issues)
            Text(
              '${issue.file}:${issue.line} · ${_issueText(l, issue.kind)}',
              style: TextStyle(color: theme.colorScheme.error),
            ),
        ],
      ),
    );
    // A checkbox row with several detail lines, which AppToggleRow's single subtitle cannot hold.
    return MergeSemantics(
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.control),
        onTap: onChanged == null ? null : () => onChanged!(!selected),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: Space.xs),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: AppCheckbox(value: selected, onChanged: onChanged),
              ),
              const SizedBox(width: Space.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(source.alias, maxLines: 1, overflow: TextOverflow.ellipsis),
                    details,
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _issueText(AppLocalizations l, SshConfigIssueKind issue) => switch (issue) {
  SshConfigIssueKind.malformed => l.sshConfigMalformed,
  SshConfigIssueKind.unsupported => l.sshConfigUnsupported,
  SshConfigIssueKind.match => l.sshConfigMatch,
  SshConfigIssueKind.pattern => l.sshConfigPattern,
  SshConfigIssueKind.includeOutside => l.sshConfigIncludeOutside,
  SshConfigIssueKind.includeLimit => l.sshConfigIncludeLimit,
  SshConfigIssueKind.includeMissing => l.sshConfigIncludeMissing,
  SshConfigIssueKind.includeCycle => l.sshConfigIncludeCycle,
  SshConfigIssueKind.incomplete => l.sshConfigIncomplete,
  SshConfigIssueKind.proxyCommand => l.sshConfigProxyCommand,
  SshConfigIssueKind.invalid => l.sshConfigInvalid,
  SshConfigIssueKind.jump => l.sshConfigJump,
  SshConfigIssueKind.jumpCycle => l.sshConfigJumpCycle,
  SshConfigIssueKind.ambiguous => l.sshConfigAmbiguous,
  SshConfigIssueKind.identity => l.sshConfigIdentity,
  SshConfigIssueKind.extraIdentity => l.sshConfigExtraIdentity,
  SshConfigIssueKind.hostLimit => l.sshConfigHostLimit,
};

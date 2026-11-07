import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../design/controls.dart';
import '../../../design/dialog.dart';
import '../../../design/select.dart';
import '../../../design/theme.dart';
import '../../../foundation/json_file.dart';
import '../../../l10n/app_localizations.dart';
import '../application/host_import.dart';
import '../application/hosts.dart';
import '../domain/import_plan.dart';
import '../domain/ssh_config.dart';

/// Choose a source, then pick hosts and a group (docs/HOST_IMPORT.md); [welcome] is the first-run offer.
Future<void> showImportDialog(BuildContext context, {bool welcome = false}) => showAppDialog<void>(
  context: context,
  builder: (_) => ImportDialog(welcome: welcome),
);

const _names = {
  ImportFormat.openssh: 'OpenSSH',
  ImportFormat.putty: 'PuTTY',
  ImportFormat.mobaxterm: 'MobaXterm',
  ImportFormat.securecrt: 'SecureCRT',
  ImportFormat.xshell: 'Xshell',
  ImportFormat.finalshell: 'FinalShell',
  ImportFormat.tabby: 'Tabby',
  ImportFormat.csv: 'CSV',
};

class ImportDialog extends ConsumerStatefulWidget {
  const ImportDialog({super.key, this.welcome = false});

  final bool welcome;

  @override
  ConsumerState<ImportDialog> createState() => _ImportDialogState();
}

class _ImportDialogState extends ConsumerState<ImportDialog> {
  Map<ImportFormat, int> _found = const {};
  ImportPreview? _preview;
  final _selected = <String>{};
  var _busy = false;
  String? _error;

  HostImport get _import => ref.read(hostImportProvider);

  @override
  void initState() {
    super.initState();
    _import.detect().then((found) {
      if (mounted) setState(() => _found = found);
    });
  }

  Future<void> _open(Future<ImportPreview?> Function() read) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final preview = await read();
      if (mounted && preview != null) _show(preview, all: true);
    } on Exception {
      if (mounted) setState(() => _error = AppLocalizations.of(context).importFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _show(ImportPreview preview, {bool all = false}) {
    final selectable = {
      for (final d in preview.plan.drafts)
        if (d.selectable) d.key,
    };
    setState(() {
      _preview = preview;
      if (all) {
        _selected
          ..clear()
          ..addAll(selectable);
      } else {
        _selected.retainAll(selectable);
      }
    });
  }

  Future<void> _commit() async {
    final preview = _preview;
    if (_busy || preview == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final count = await _import.commit(preview, {..._selected});
      if (!mounted) return;
      final messenger = ScaffoldMessenger.maybeOf(context);
      final message = AppLocalizations.of(context).sshConfigImported(count);
      Navigator.pop(context);
      messenger?.showSnackBar(SnackBar(content: Text(message)));
    } on JsonFileError catch (error) {
      if (mounted) {
        final l = AppLocalizations.of(context);
        setState(() => _error = error.kind == JsonFileFailure.conflict ? l.importChanged : l.importFailed);
      }
    } on Exception {
      if (mounted) setState(() => _error = AppLocalizations.of(context).importFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final preview = _preview;
    final count = preview?.plan.additions(_selected).length ?? 0;
    final dismiss = TextButton(
      onPressed: () => Navigator.pop(context),
      child: Text(widget.welcome ? l.skip : l.cancel),
    );
    return AppDialog(
      width: 560,
      icon: const Icon(Icons.input_rounded),
      title: Text(l.importHosts),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (preview == null) _sources(l) else ..._planned(l, theme, preview),
          if (_busy)
            const Padding(
              padding: EdgeInsets.only(top: Space.sm),
              child: LinearProgressIndicator(),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: Space.sm),
              child: Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
            ),
        ],
      ),
      actions: [
        dismiss,
        if (preview != null)
          FilledButton(onPressed: _busy || count == 0 ? null : _commit, child: Text('${l.importAction} ($count)')),
      ],
    );
  }

  Widget _sources(AppLocalizations l) {
    final sources = _import.sources;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OutlinedButton.icon(
          onPressed: _busy ? null : () => _open(_import.fromFile),
          icon: const Icon(Icons.file_open_outlined, size: 16),
          label: Text(l.importFromFile),
        ),
        const SizedBox(height: Space.md),
        for (var i = 0; i < sources.length; i += 3) ...[
          if (i > 0) const SizedBox(height: Space.sm),
          Row(
            children: [
              for (var j = i; j < i + 3; j++) ...[
                if (j > i) const SizedBox(width: Space.sm),
                Expanded(
                  child: j < sources.length
                      ? _SourceTile(
                          name: _names[sources[j]]!,
                          found: _found[sources[j]] ?? 0,
                          onTap: _busy ? null : () => _open(() => _import.fromSoftware(sources[j])),
                        )
                      : const SizedBox.shrink(),
                ),
              ],
            ],
          ),
        ],
      ],
    );
  }

  List<Widget> _planned(AppLocalizations l, ThemeData theme, ImportPreview preview) {
    final drafts = preview.plan.drafts;
    final selectable = drafts.where((d) => d.selectable).toList();
    final groups = ref.watch(hostLibraryProvider).groupPaths;
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return [
      Row(
        children: [
          IconButton(
            tooltip: l.back,
            onPressed: _busy
                ? null
                : () => setState(() {
                    _preview = null;
                    _error = null;
                  }),
            icon: const Icon(Icons.arrow_back, size: 16),
          ),
          const SizedBox(width: Space.xs),
          Expanded(
            child: Text(
              preview.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurface),
            ),
          ),
          const SizedBox(width: Space.sm),
          AppSelect<String>(
            width: 200,
            value: preview.group,
            options: [
              AppOption('', l.importNoGroup, icon: Icons.folder_off_outlined),
              for (final g in groups) AppOption(g, g, icon: Icons.folder_outlined),
            ],
            onChanged: _busy ? null : (g) => _show(_import.regroup(preview, g)),
          ),
        ],
      ),
      if (selectable.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: Space.sm),
          child: AppToggleRow(
            checkbox: true,
            title: l.selectAll,
            value: selectable.every((d) => _selected.contains(d.key)),
            onChanged: _busy
                ? null
                : (checked) => setState(() {
                    _selected.clear();
                    if (checked) _selected.addAll(selectable.map((d) => d.key));
                  }),
          ),
        ),
      const SizedBox(height: Space.xs),
      Flexible(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final draft in drafts)
              _DraftRow(
                draft: draft,
                selected: _selected.contains(draft.key),
                onChanged: _busy || !draft.selectable
                    ? null
                    : (value) => setState(() => value ? _selected.add(draft.key) : _selected.remove(draft.key)),
              ),
            for (final issue in preview.plan.issues)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: Space.xs, horizontal: Space.xs),
                child: Text(_issueLine(l, issue), style: muted),
              ),
            if (drafts.isEmpty && preview.plan.issues.isEmpty)
              Padding(
                padding: const EdgeInsets.all(Space.lg),
                child: Center(child: Text(l.none)),
              ),
          ],
        ),
      ),
    ];
  }
}

class _SourceTile extends StatelessWidget {
  const _SourceTile({required this.name, required this.found, required this.onTap});

  final String name;
  final int found;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(Radii.card),
      side: BorderSide(color: scheme.outlineVariant),
    );
    return Material(
      type: MaterialType.transparency,
      shape: shape,
      child: InkWell(
        customBorder: shape,
        onTap: onTap,
        child: SizedBox(
          height: 52,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.md),
            child: Row(
              children: [
                Container(
                  width: 28,
                  height: 28,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: scheme.primary.withValues(alpha: .14),
                    borderRadius: BorderRadius.circular(Radii.control),
                  ),
                  child: ExcludeSemantics(
                    child: Text(
                      name.substring(0, 2),
                      style: text.labelMedium?.copyWith(color: scheme.primary, fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
                const SizedBox(width: Space.sm),
                Expanded(
                  child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: text.bodyMedium),
                ),
                if (found > 0) Text('$found', style: text.bodySmall?.copyWith(color: scheme.primary)),
              ],
            ),
          ),
        ),
      ),
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
            Text(_issueLine(l, issue), style: TextStyle(color: theme.colorScheme.error)),
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
                    Row(
                      children: [
                        Flexible(child: Text(source.alias, maxLines: 1, overflow: TextOverflow.ellipsis)),
                        if (source.group.isNotEmpty) ...[
                          const SizedBox(width: Space.sm),
                          Icon(Icons.folder_outlined, size: 12, color: theme.colorScheme.onSurfaceVariant),
                          const SizedBox(width: 2),
                          Flexible(
                            child: Text(source.group, maxLines: 1, overflow: TextOverflow.ellipsis, style: muted),
                          ),
                        ],
                      ],
                    ),
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

String _issueLine(AppLocalizations l, SshConfigIssue issue) {
  final at = issue.line > 0 ? '${issue.file}:${issue.line}' : issue.file;
  final option = issue.option.isEmpty ? '' : '${issue.option} · ';
  return '$at · $option${_issueText(l, issue.kind)}';
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
  SshConfigIssueKind.notSsh => l.importNotSsh,
  SshConfigIssueKind.noAddress => l.importNoAddress,
  SshConfigIssueKind.unreadable => l.importUnreadable,
  SshConfigIssueKind.ppk => l.importPpk,
};

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../design/brand.dart';
import '../../../design/controls.dart';
import '../../../design/dialog.dart';
import '../../../design/menu.dart';
import '../../../design/theme.dart';
import '../../../foundation/cancellation.dart';
import '../../../foundation/file_system.dart';
import '../../../l10n/app_localizations.dart';
import '../../connections/api.dart';
import '../application/edits.dart';
import '../application/file_systems.dart' show localFiles;
import '../application/transfers.dart';
import '../domain/transfer.dart';
import 'file_text.dart';

/// Asks through dialogs in [context], the window's; registered once so queued work can ask from any page.
class DialogTransferUi implements TransferUi {
  DialogTransferUi(this.context);
  final BuildContext context;

  @override
  ConnectPrompts get prompts => DialogPrompts(context);

  @override
  Future<ConflictAnswer?> conflict(Transfer transfer, Conflict conflict, CancellationToken cancel) async {
    if (!context.mounted) return null;
    final navigator = Navigator.of(context);
    final route = DialogRoute<ConflictAnswer>(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black.withValues(alpha: Theme.of(context).brightness == Brightness.dark ? .5 : .28),
      builder: (_) => _ConflictDialog(transfer, conflict),
    );
    // Only this dialog closes; a password prompt opened above it meanwhile stays.
    cancel.whenCancelled.then((_) {
      if (route.isActive) navigator.removeRoute(route);
    }).ignore();
    return navigator.push(route);
  }
}

class _ConflictDialog extends StatefulWidget {
  const _ConflictDialog(this.transfer, this.conflict);
  final Transfer transfer;
  final Conflict conflict;

  @override
  State<_ConflictDialog> createState() => _ConflictDialogState();
}

class _ConflictDialogState extends State<_ConflictDialog> {
  var _all = false;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final c = widget.conflict;
    final name = c.existing.name;
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    Widget side(String label, String where, FileEntry e) => Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: theme.textTheme.labelMedium),
          Text(where, style: muted, maxLines: 1, overflow: TextOverflow.ellipsis),
          Text([formatSize(e.size), formatTime(e.modified)].where((s) => s.isNotEmpty).join(' · '), style: muted),
        ],
      ),
    );
    String label(ConflictChoice choice) => switch (choice) {
      ConflictChoice.replace => l.replace,
      ConflictChoice.merge => l.merge,
      ConflictChoice.keepBoth => l.keepBoth,
      ConflictChoice.skip => l.skip,
      ConflictChoice.cancel => l.cancel,
    };
    final t = widget.transfer;
    return AppDialog(
      width: 508,
      title: Text(switch (c.kind) {
        ConflictKind.file => l.conflictFile(name),
        ConflictKind.directory => l.conflictDir(name),
        ConflictKind.fileOnDir => l.conflictType(name),
      }),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SelectableText(c.path, style: mono(context, theme.textTheme.bodySmall)),
            const SizedBox(height: Space.md),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                side(l.existingItem, t.target.local ? l.thisComputer : t.target.label, c.existing),
                const SizedBox(width: Space.lg),
                side(l.incomingItem, t.source.local ? l.thisComputer : t.source.label, c.incoming),
              ],
            ),
            const SizedBox(height: Space.sm),
            AppToggleRow(checkbox: true, value: _all, onChanged: (v) => setState(() => _all = v), title: l.applyToAll),
          ],
        ),
      ),
      actions: [
        for (final choice in c.choices)
          choice == c.choices.first
              ? FilledButton(
                  autofocus: true,
                  onPressed: () => Navigator.pop(context, ConflictAnswer(choice, all: _all)),
                  child: Text(label(choice)),
                )
              : TextButton(
                  onPressed: () =>
                      Navigator.pop(context, ConflictAnswer(choice, all: _all && choice != ConflictChoice.cancel)),
                  child: Text(label(choice)),
                ),
      ],
    );
  }
}

/// Edits first (they hold the user's unsaved work), then transfers, newest first.
class TransfersPanel extends ConsumerWidget {
  const TransfersPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final transfers = ref.watch(transfersProvider).reversed.toList();
    final edits = ref.watch(editsProvider);
    final manager = ref.read(transfersProvider.notifier);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton.icon(
              onPressed: transfers.any((t) => !t.state.active) ? manager.clearFinished : null,
              icon: const Icon(Icons.clear_all, size: 16),
              label: Text(l.clearFinished),
            ),
          ],
        ),
        const SizedBox(height: Space.sm),
        if (transfers.isEmpty && edits.isEmpty) BrandHint(pose: BrandPose.sftpTransfer, label: l.none, size: 88),
        Flexible(
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final e in edits) _EditRow(e),
              if (edits.isNotEmpty && transfers.isNotEmpty) const Divider(height: Space.xl),
              for (final t in transfers) _TransferRow(t),
            ],
          ),
        ),
      ],
    );
  }
}

class _TransferRow extends ConsumerWidget {
  const _TransferRow(this.t);
  final Transfer t;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    final manager = ref.read(transfersProvider.notifier);
    String place(FileEnd end) => end.local ? l.thisComputer : end.label;
    final name = TransferManager.styleOf(t.source.host).name(t.source.path);
    final total = t.total;
    final fraction = total == null || total == 0 ? null : (t.bytes / total).clamp(0.0, 1.0);
    final status = switch (t.state) {
      TransferState.queued => l.tsQueued,
      TransferState.waiting => l.tsWaiting,
      TransferState.pausing => l.tsPausing,
      TransferState.paused => l.tsPaused,
      TransferState.running => switch (t.phase) {
        TransferPhase.scanning => l.tsScanning,
        TransferPhase.verifying => l.tsVerifying,
        TransferPhase.publishing => l.tsPublishing,
        _ =>
          [formatSize(t.bytes), if (total != null) formatSize(total)].join(' / ') +
              (t.speed > 0 ? '  ${formatSize(t.speed.round())}/s' : ''),
      },
      TransferState.completed => l.tsCompleted,
      TransferState.cancelled => l.tsCancelled,
      TransferState.interrupted => l.tsInterrupted,
      TransferState.failed =>
        t.error == 'connect'
            ? l.errConnect(t.detail)
            : t.error == 'leftoverPart'
            ? l.leftoverPart(t.detail)
            : fileErrorCode(l, t.error ?? ''),
    };
    final extra = [
      if ((t.totalFiles ?? 0) > 1) l.filesCount(t.files, t.totalFiles!),
      if (t.skipped > 0) l.skippedCount(t.skipped),
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.md),
      child: Row(
        children: [
          Icon(
            t.upload ? Icons.upload : (t.download ? Icons.download : Icons.swap_horiz),
            size: 16,
            color: t.state == TransferState.failed ? scheme.error : scheme.primary,
          ),
          const SizedBox(width: Space.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Tooltip(
                  message: '${t.source.path}\n→ ${t.target.path}',
                  child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
                Text(
                  '${place(t.source)} → ${place(t.target)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: muted,
                ),
                if (t.state == TransferState.running || t.state == TransferState.paused)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: Space.xs),
                    child: LinearProgressIndicator(
                      value: t.phase == TransferPhase.scanning ? null : fraction,
                      minHeight: 3,
                    ),
                  ),
                Text(
                  [status, if (extra.isNotEmpty) extra].join(' · '),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: t.state == TransferState.failed ? muted?.copyWith(color: scheme.error) : muted,
                ),
              ],
            ),
          ),
          if (t.state == TransferState.running && t.phase == TransferPhase.copying && !t.directory)
            IconButton(
              tooltip: l.pause,
              onPressed: () => manager.pause(t.id),
              icon: const Icon(Icons.pause_outlined, size: 16),
            ),
          if (t.state == TransferState.paused ||
              (t.state == TransferState.interrupted && t.checkpoint?.settled == true))
            IconButton(
              tooltip: l.resume,
              onPressed: () => manager.resume(t.id),
              icon: const Icon(Icons.play_arrow, size: 16),
            ),
          if (t.state.active && t.state != TransferState.paused)
            IconButton(
              tooltip: l.cancel,
              onPressed: () => manager.cancel(t.id),
              icon: const Icon(Icons.close, size: 16),
            )
          else ...[
            if (t.state.canRetry)
              IconButton(
                tooltip: l.retry,
                onPressed: () => manager.retry(t.id),
                icon: const Icon(Icons.refresh, size: 16),
              ),
            IconButton(
              tooltip: l.remove,
              onPressed: () => manager.remove(t.id),
              icon: const Icon(Icons.delete_outline, size: 16),
            ),
          ],
        ],
      ),
    );
  }
}

class _EditRow extends ConsumerWidget {
  const _EditRow(this.e);
  final ExternalEdit e;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    final edits = ref.read(editsProvider.notifier);

    Future<void> finish() async {
      if (e.unsaved) {
        final ok = await showAppDialog<bool>(
          context: context,
          builder: (context) => AppDialog(
            content: Text(l.discardEdit(e.name)),
            actions: [
              TextButton(autofocus: true, onPressed: () => Navigator.pop(context, false), child: Text(l.cancel)),
              TextButton(
                style: TextButton.styleFrom(foregroundColor: scheme.error),
                onPressed: () => Navigator.pop(context, true),
                child: Text(l.discard),
              ),
            ],
          ),
        );
        if (!(ok ?? false)) return;
      }
      await edits.finish(e.id);
    }

    final status = switch (e.state) {
      EditState.clean => l.esClean,
      EditState.modified => l.esModified,
      EditState.uploading => l.esUploading,
      EditState.conflict => l.editConflict,
      EditState.failed =>
        e.error == 'cleanupFailed'
            ? l.editCleanupFailed(localFiles.style.parent(e.localPath))
            : fileErrorCode(l, e.error ?? ''),
    };
    final warn = e.state == EditState.conflict || e.state == EditState.failed;
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.edit_note, size: 18, color: warn ? scheme.error : scheme.primary),
              const SizedBox(width: Space.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Tooltip(
                      message: e.remotePath,
                      child: Text(e.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                    ),
                    Text(
                      '${e.hostLabel} · $status',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: warn ? muted?.copyWith(color: scheme.error) : muted,
                    ),
                  ],
                ),
              ),
              if (e.state == EditState.modified || e.state == EditState.failed)
                IconButton(
                  tooltip: l.upload,
                  onPressed: () => edits.upload(e.id),
                  icon: const Icon(Icons.upload, size: 16),
                ),
              IconButton(
                tooltip: l.open,
                onPressed: () => edits.reopen(e.id),
                icon: const Icon(Icons.open_in_new, size: 16),
              ),
              AppMenuButton<VoidCallback>(
                tooltip: l.more,
                icon: const Icon(Icons.more_horiz, size: 16),
                onSelected: (run) => run(),
                items: () => [
                  AppMenuItem(
                    checked: e.autoUpload,
                    value: () => edits.setAutoUpload(e.id, !e.autoUpload),
                    label: l.autoUpload,
                  ),
                  AppMenuItem(value: () => edits.redownload(e.id), label: l.redownload),
                  AppMenuItem(value: finish, label: l.finishEdit),
                ],
              ),
            ],
          ),
          if (e.state == EditState.conflict)
            Padding(
              padding: const EdgeInsets.only(left: 32),
              child: Wrap(
                spacing: Space.sm,
                children: [
                  TextButton(
                    style: TextButton.styleFrom(foregroundColor: scheme.error),
                    onPressed: () => edits.upload(e.id, force: true),
                    child: Text(l.overwrite),
                  ),
                  TextButton(onPressed: () => edits.upload(e.id, asCopy: true), child: Text(l.uploadAsCopy)),
                  TextButton(onPressed: () => edits.redownload(e.id), child: Text(l.redownload)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

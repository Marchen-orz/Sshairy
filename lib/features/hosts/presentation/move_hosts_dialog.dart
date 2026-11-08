import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../design/dialog.dart';
import '../../../design/select.dart';
import '../../../design/theme.dart';
import '../../../foundation/ids.dart';
import '../../../l10n/app_localizations.dart';
import '../application/hosts.dart';
import 'form_parts.dart';

class MoveHostsDialog extends ConsumerStatefulWidget {
  const MoveHostsDialog({super.key, required this.hostIds});

  final List<HostId> hostIds;

  @override
  ConsumerState<MoveHostsDialog> createState() => _MoveHostsDialogState();
}

class _MoveHostsDialogState extends ConsumerState<MoveHostsDialog> {
  late final int _revision;
  var _group = '';
  var _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final hosts = ref.read(hostsProvider.notifier);
    _revision = hosts.revision;
    final groups = {for (final id in widget.hostIds) hosts.byId(id)?.groupId};
    if (groups.length == 1) _group = groups.single ?? '';
  }

  Future<void> _move() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref
          .read(hostsProvider.notifier)
          .moveToGroup(widget.hostIds, _group.isEmpty ? null : _group, expectedRevision: _revision);
      if (mounted) Navigator.pop(context);
    } on Object catch (error) {
      if (mounted) setState(() => _error = saveError(AppLocalizations.of(context), error));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final library = ref.watch(hostLibraryProvider);
    return AppDialog(
      width: 380,
      title: Text(l.moveHostsTitle(widget.hostIds.length)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppSelect<String>(
            value: _group,
            label: l.group,
            searchable: library.groups.length > 8,
            searchHint: l.searchHint,
            options: [
              AppOption('', l.importNoGroup),
              for (final path in library.groupPaths)
                AppOption(library.groupIdFor(path)!, path, icon: Icons.folder_outlined),
            ],
            onChanged: _saving ? null : (value) => setState(() => _group = value),
          ),
          if (_error != null) ...[
            const SizedBox(height: Space.sm),
            Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
        ],
      ),
      actions: [
        TextButton(onPressed: _saving ? null : () => Navigator.pop(context), child: Text(l.cancel)),
        FilledButton(onPressed: _saving ? null : _move, child: Text(l.moveToGroup)),
      ],
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../design/controls.dart';
import '../../../design/dialog.dart';
import '../../../design/double_click.dart';
import '../../../design/theme.dart';
import '../../../l10n/app_localizations.dart';
import '../adapters/desktop.dart';
import '../application/open_with.dart';
import '../domain/open_with.dart';

/// The program picked in [OpenWithDialog], and whether it becomes the program for the file's type.
class OpenWithChoice {
  const OpenWithChoice(this.app, {required this.remember});

  final OpenWithApp app;
  final bool remember;
}

Future<OpenWithChoice?> showOpenWithDialog(BuildContext context, String fileName) => showAppDialog<OpenWithChoice>(
  context: context,
  builder: (_) => OpenWithDialog(fileName: fileName),
);

/// The programs the computer offers for a file, the system's own first. Choosing one is the choice of a default
/// unless the box is cleared.
class OpenWithDialog extends ConsumerStatefulWidget {
  const OpenWithDialog({super.key, required this.fileName, this.pick = pickProgram});

  final String fileName;

  /// Asks for a program in the system's file dialog; null when cancelled.
  final Future<String?> Function() pick;

  @override
  ConsumerState<OpenWithDialog> createState() => _OpenWithDialogState();
}

class _OpenWithDialogState extends ConsumerState<OpenWithDialog> {
  late final OpenWithApp _current;
  late final List<OpenWithApp> _extra;
  late OpenWithApp _selected;
  List<OpenWithApp>? _found;
  final _clicks = <String, DoubleClick>{};
  var _remember = true, _rejected = false;

  @override
  void initState() {
    super.initState();
    final chosen = ref.read(editorAppsProvider).forFile(widget.fileName);
    _current = chosen ?? const OpenWithApp.system();
    _selected = _current;
    // A default that the system's list does not name (a program picked by hand) still has to show.
    _extra = [?chosen];
    _load();
  }

  Future<void> _load() async {
    List<OpenWithApp> found;
    try {
      found = await ref.read(editorLauncherProvider).apps(widget.fileName);
    } on Object {
      found = const [];
    }
    if (mounted) setState(() => _found = found);
  }

  Future<void> _choose() async {
    final path = await widget.pick();
    if (path == null || !mounted) return;
    final app = await ref.read(editorLauncherProvider).program(path);
    if (!mounted) return;
    setState(() {
      _rejected = app == null;
      if (app == null) return;
      if (!_extra.contains(app)) _extra.add(app);
      _selected = app;
    });
  }

  void _done() => Navigator.pop(context, OpenWithChoice(_selected, remember: _remember));

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    final rows = {const OpenWithApp.system(), ...?_found, ..._extra}.toList();
    Widget row(OpenWithApp app) {
      final selected = app == _selected;
      final body = Padding(
        padding: const EdgeInsets.symmetric(horizontal: Space.md, vertical: Space.sm),
        child: Row(
          children: [
            Icon(app.isSystem ? Icons.desktop_windows_outlined : Icons.apps, size: 16, color: scheme.onSurfaceVariant),
            const SizedBox(width: Space.sm),
            Expanded(
              child: Text(
                app.isSystem ? l.systemDefaultApp : app.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurface),
              ),
            ),
            if (app == _current) Text(l.defaultApp, style: muted),
          ],
        ),
      );
      return Material(
        color: selected ? scheme.primary.withValues(alpha: 0.14) : Colors.transparent,
        borderRadius: BorderRadius.circular(Radii.control),
        child: InkWell(
          borderRadius: BorderRadius.circular(Radii.control),
          onTap: () {
            setState(() => _selected = app);
            if (_clicks.putIfAbsent(app.id, DoubleClick.new).hit) _done();
          },
          // The path tells apart two programs of one name.
          child: app.executable == null ? body : Tooltip(message: app.executable!, child: body),
        ),
      );
    }

    return AppDialog(
      width: 420,
      title: Text(l.openWith),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Flexible(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 280),
              child: ListView(shrinkWrap: true, children: [for (final app in rows) row(app)]),
            ),
          ),
          if (_found == null)
            const Padding(
              padding: EdgeInsets.all(Space.md),
              child: Center(child: SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _choose,
              icon: const Icon(Icons.folder_open_outlined, size: 16),
              label: Text(l.chooseProgram),
            ),
          ),
          if (_rejected) Text(l.errLaunchFailed, style: muted?.copyWith(color: scheme.error)),
          AppToggleRow(
            checkbox: true,
            value: _remember,
            onChanged: (v) => setState(() => _remember = v),
            title: l.alwaysOpenWith(fileTypeLabel(fileTypeKey(widget.fileName))),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(l.cancel)),
        FilledButton(autofocus: true, onPressed: _done, child: Text(l.open)),
      ],
    );
  }
}

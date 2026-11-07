import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../design/dialog.dart';
import '../../../design/popup.dart';
import '../../../design/theme.dart';
import '../../../l10n/app_localizations.dart';
import '../../../foundation/result.dart';
import '../application/palette.dart';
import '../domain/capability.dart';

/// docs/UI.md §5: at most 640×480, a little above centre; Esc returns focus to where it was.
Future<void> showCommandPalette(BuildContext context) =>
    showAppDialog<void>(context: context, builder: (_) => _CommandPalette(context));

class _CommandPalette extends ConsumerStatefulWidget {
  const _CommandPalette(this.origin);

  final BuildContext origin;

  @override
  ConsumerState<_CommandPalette> createState() => _CommandPaletteState();
}

class _CommandPaletteState extends ConsumerState<_CommandPalette> {
  final _query = TextEditingController();
  final _scroll = ScrollController();
  var _selected = 0;

  static const _rowHeight = 36.0;

  @override
  void dispose() {
    _query.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _dispatch(String id, [Map<String, Object?> args = const {}]) async {
    final result = await ref.read(capabilityDispatcherProvider).dispatch(id, args, RequestContext(Origin.palette));
    // The palette has closed by now; report on the screen it was opened from.
    if (result case Err(:final error) when widget.origin.mounted) {
      ScaffoldMessenger.maybeOf(widget.origin)?.showSnackBar(SnackBar(content: Text('$error')));
    }
  }

  List<PaletteEntry> _entries(AppLocalizations l) {
    final query = _query.text.trim().toLowerCase();
    final c = PaletteContext(widget.origin, ref, l, _dispatch);
    final all = [for (final source in ref.watch(paletteSourcesProvider)) ...source(c)];
    final matches = query.isEmpty ? all : all.where((e) => e.matches(query)).toList();
    matches.sort((a, b) => a.section.index.compareTo(b.section.index));
    return matches;
  }

  void _move(int delta, int count) {
    if (count == 0) return;
    setState(() => _selected = (_selected + delta) % count);
    final top = _selected * _rowHeight;
    if (top < _scroll.offset) {
      _scroll.jumpTo(top);
    } else if (top + _rowHeight > _scroll.offset + _scroll.position.viewportDimension) {
      _scroll.jumpTo(top + _rowHeight - _scroll.position.viewportDimension);
    }
  }

  Future<void> _run(PaletteEntry entry) async {
    Navigator.pop(context);
    await entry.run();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final entries = _entries(l);
    if (_selected >= entries.length) _selected = 0;
    return Align(
      alignment: const Alignment(0, -0.5),
      child: Padding(
        padding: const EdgeInsets.all(Space.xl),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640, maxHeight: 480),
          child: PopupSurface(
            radius: Radii.panel,
            child: CallbackShortcuts(
              bindings: {
                const SingleActivator(LogicalKeyboardKey.arrowDown): () => _move(1, entries.length),
                const SingleActivator(LogicalKeyboardKey.arrowUp): () => _move(-1, entries.length),
              },
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.all(Space.sm),
                    child: TextField(
                      controller: _query,
                      autofocus: true,
                      decoration: InputDecoration(
                        hintText: l.paletteHint,
                        prefixIcon: const Icon(Icons.search, size: 18),
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        filled: false,
                      ),
                      onChanged: (_) => setState(() => _selected = 0),
                      onSubmitted: (_) {
                        if (entries.isNotEmpty) _run(entries[_selected]);
                      },
                    ),
                  ),
                  const Divider(),
                  Flexible(
                    child: entries.isEmpty
                        ? Padding(
                            padding: const EdgeInsets.all(Space.lg),
                            child: Text(l.noMatches, style: TextStyle(color: theme.colorScheme.onSurfaceVariant)),
                          )
                        : ListView.builder(
                            controller: _scroll,
                            shrinkWrap: true,
                            padding: const EdgeInsets.symmetric(vertical: Space.xs),
                            itemExtent: _rowHeight,
                            itemCount: entries.length,
                            itemBuilder: (context, i) =>
                                _Row(entry: entries[i], selected: i == _selected, onTap: () => _run(entries[i])),
                          ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.entry, required this.selected, required this.onTap});

  final PaletteEntry entry;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Space.xs),
      child: Material(
        color: selected ? theme.colorScheme.primary.withValues(alpha: 0.12) : Colors.transparent,
        borderRadius: BorderRadius.circular(Radii.control),
        child: InkWell(
          borderRadius: BorderRadius.circular(Radii.control),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.md),
            child: Row(
              children: [
                Icon(
                  entry.icon,
                  size: 16,
                  color: selected ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: Space.md),
                Flexible(child: Text(entry.title, maxLines: 1, overflow: TextOverflow.ellipsis)),
                if (entry.subtitle.isNotEmpty) ...[
                  const SizedBox(width: Space.sm),
                  Expanded(
                    child: Text(entry.subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: muted),
                  ),
                ] else
                  const Spacer(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

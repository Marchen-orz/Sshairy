import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'popup.dart';
import 'theme.dart';

class AppOption<T> {
  const AppOption(this.value, this.label, {this.icon, this.style});

  final T value;
  final String label;
  final IconData? icon;

  /// How the label is drawn in the list, such as a font previewed in itself.
  final TextStyle? style;
}

/// A field-like button that opens a list of [options] under itself; replaces Material's dropdowns.
class AppSelect<T> extends StatefulWidget {
  const AppSelect({
    super.key,
    required this.value,
    required this.options,
    required this.onChanged,
    this.label,
    this.hint,
    this.errorText,
    this.width,
    this.searchable = false,
    this.searchHint,
  });

  final T value;
  final List<AppOption<T>> options;

  /// Null disables the field.
  final ValueChanged<T>? onChanged;

  /// Shown above the field, as form labels are.
  final String? label;
  final String? hint, errorText, searchHint;

  /// Null fills the available width.
  final double? width;

  /// Adds a filter box above the list, for long lists such as fonts.
  final bool searchable;

  @override
  State<AppSelect<T>> createState() => _AppSelectState<T>();
}

class _AppSelectState<T> extends State<AppSelect<T>> {
  final _field = GlobalKey();
  var _hovered = false, _focused = false, _open = false;

  Future<void> _show() async {
    final onChanged = widget.onChanged;
    if (onChanged == null || _open) return;
    final context = _field.currentContext!;
    final anchor = anchorOf(context);
    setState(() => _open = true);
    final picked = await showAnchoredPopup<AppOption<T>>(
      context: context,
      anchor: anchor,
      width: anchor.width < 180 ? 180 : anchor.width,
      maxHeight: 360,
      builder: (_) => _OptionList<T>(
        options: widget.options,
        selected: widget.value,
        searchable: widget.searchable,
        searchHint: widget.searchHint,
      ),
    );
    if (!mounted) return;
    setState(() => _open = false);
    if (picked != null && picked.value != widget.value) onChanged(picked.value);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final enabled = widget.onChanged != null;
    final current = widget.options.where((o) => o.value == widget.value).firstOrNull;
    final error = widget.errorText;
    final borderColor = error != null
        ? scheme.error
        : _focused || _open
        ? scheme.primary
        : _hovered
        ? scheme.outline
        : scheme.outlineVariant;
    final field = Semantics(
      button: true,
      enabled: enabled,
      label: widget.label,
      value: current?.label,
      child: FocusableActionDetector(
        enabled: enabled,
        mouseCursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onShowHoverHighlight: (v) => setState(() => _hovered = v),
        onFocusChange: (v) => setState(() => _focused = v),
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.arrowDown): ActivateIntent(),
        },
        actions: {ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) => _show())},
        child: GestureDetector(
          onTap: _show,
          child: AnimatedContainer(
            key: _field,
            duration: Motion.quick,
            width: widget.width,
            height: WorkspaceSize.control,
            padding: const EdgeInsets.only(left: 10, right: 6),
            decoration: BoxDecoration(
              color: enabled ? scheme.surface : scheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(Radii.control),
              border: Border.all(color: borderColor, width: _focused || _open ? 1.5 : 1),
            ),
            child: Row(
              children: [
                if (current?.icon != null) ...[
                  Icon(current!.icon, size: 16, color: scheme.onSurfaceVariant),
                  const SizedBox(width: Space.sm),
                ],
                Expanded(
                  child: Text(
                    current?.label ?? widget.hint ?? '',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: current == null || !enabled ? scheme.onSurfaceVariant : scheme.onSurface,
                    ),
                  ),
                ),
                AnimatedRotation(
                  turns: _open ? .5 : 0,
                  duration: Motion.normal,
                  child: Icon(Icons.keyboard_arrow_down_rounded, size: 18, color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (widget.label == null && error == null) return field;
    final muted = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.label != null) ...[Text(widget.label!, style: muted), const SizedBox(height: Space.xs)],
        field,
        if (error != null) ...[
          const SizedBox(height: Space.xs),
          Text(error, style: muted?.copyWith(color: scheme.error)),
        ],
      ],
    );
  }
}

class _OptionList<T> extends StatefulWidget {
  const _OptionList({required this.options, required this.selected, required this.searchable, this.searchHint});

  final List<AppOption<T>> options;
  final T selected;
  final bool searchable;
  final String? searchHint;

  @override
  State<_OptionList<T>> createState() => _OptionListState<T>();
}

class _OptionListState<T> extends State<_OptionList<T>> {
  var _query = '';
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    // Long lists open scrolled to the current value.
    final index = widget.options.indexWhere((o) => o.value == widget.selected);
    if (index > 6) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.jumpTo((index * 32.0 - 96).clamp(0, _scroll.position.maxScrollExtent).toDouble());
        }
      });
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final q = _query.trim().toLowerCase();
    final shown = q.isEmpty ? widget.options : widget.options.where((o) => o.label.toLowerCase().contains(q)).toList();
    return PopupSurface(
      padding: const EdgeInsets.symmetric(vertical: Space.xs),
      child: PopupKeys(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.searchable)
              Padding(
                padding: const EdgeInsets.fromLTRB(Space.xs, 0, Space.xs, Space.xs),
                child: TextField(
                  autofocus: true,
                  decoration: InputDecoration(
                    hintText: widget.searchHint,
                    prefixIcon: const Icon(Icons.search, size: 16),
                  ),
                  onChanged: (v) => setState(() => _query = v),
                  onSubmitted: (_) {
                    if (shown.isNotEmpty) Navigator.pop(context, shown.first);
                  },
                ),
              ),
            Flexible(
              child: ListView.builder(
                controller: _scroll,
                shrinkWrap: true,
                itemExtent: 32,
                itemCount: shown.length,
                itemBuilder: (context, i) {
                  final o = shown[i];
                  final selected = o.value == widget.selected;
                  return PopupRow(
                    autofocus: !widget.searchable && selected,
                    selected: selected,
                    onTap: () => Navigator.pop(context, o),
                    child: Row(
                      children: [
                        if (o.icon != null) ...[
                          Icon(o.icon, size: 16, color: scheme.onSurfaceVariant),
                          const SizedBox(width: Space.sm),
                        ],
                        Expanded(
                          child: Text(o.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: o.style),
                        ),
                        if (selected) Icon(Icons.check, size: 15, color: scheme.primary),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

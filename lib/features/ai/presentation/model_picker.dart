import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../design/form_field.dart';
import '../../../design/popup.dart';
import '../../../design/theme.dart';
import '../../../foundation/cancellation.dart';
import '../../../foundation/secret.dart';
import '../../../l10n/app_localizations.dart';
import '../application/model_catalog.dart';
import '../domain/model.dart';
import '../domain/model_catalog.dart';

/// Settings and the composer use the same explicit, searchable provider directory.
class AiModelPicker extends ConsumerStatefulWidget {
  const AiModelPicker({
    super.key,
    required this.value,
    required this.onChanged,
    required this.protocol,
    required this.endpoint,
    this.credentialIdentity,
    this.draftKey,
    this.compact = false,
    this.label,
    this.footer,
  });

  final String value, endpoint;
  final ValueChanged<String>? onChanged;
  final ModelProtocol protocol;
  final String? credentialIdentity, label;
  final Secret? draftKey;
  final bool compact;

  /// Shown under the model list, for settings that belong to the chosen model.
  final WidgetBuilder? footer;

  @override
  ConsumerState<AiModelPicker> createState() => _AiModelPickerState();
}

class _AiModelPickerState extends ConsumerState<AiModelPicker> {
  final _anchor = GlobalKey();
  CancellationToken? _cancel;

  @override
  void didUpdateWidget(AiModelPicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.protocol != widget.protocol ||
        oldWidget.endpoint != widget.endpoint ||
        oldWidget.credentialIdentity != widget.credentialIdentity ||
        oldWidget.draftKey?.reveal() != widget.draftKey?.reveal() ||
        widget.onChanged == null) {
      _cancel?.cancel();
    }
  }

  @override
  void dispose() {
    _cancel?.cancel();
    super.dispose();
  }

  Future<void> _show() async {
    if (widget.onChanged == null || _cancel != null) return;
    final cancel = CancellationToken();
    _cancel = cancel;
    final value = widget.value, protocol = widget.protocol, endpoint = widget.endpoint;
    final credentialIdentity = widget.credentialIdentity, draftKey = widget.draftKey, footer = widget.footer;
    final catalog = ref.read(aiModelCatalogProvider);
    final anchor = anchorOf(_anchor.currentContext!);
    final selected = await showAnchoredPopup<String>(
      context: context,
      anchor: anchor,
      width: max(anchor.width, WorkspaceSize.toolPanelMin),
      maxHeight: WorkspaceSize.toolPanel,
      builder: (_) => _Models(
        catalog: catalog,
        value: value,
        protocol: protocol,
        endpoint: endpoint,
        credentialIdentity: credentialIdentity,
        draftKey: draftKey,
        cancel: cancel,
        footer: footer,
      ),
    );
    if (mounted && !cancel.isCancelled && selected != null) {
      widget.onChanged?.call(selected);
    }
    cancel.cancel();
    if (identical(_cancel, cancel)) _cancel = null;
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final enabled = widget.onChanged != null && widget.endpoint.trim().isNotEmpty;
    final label = widget.value.isEmpty ? l.aiConfigModel : widget.value;
    final content = Row(
      children: [
        const Icon(Icons.auto_awesome_outlined, size: 14),
        const SizedBox(width: Space.xs),
        Expanded(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis)),
        const SizedBox(width: Space.xs),
        const Icon(Icons.keyboard_arrow_down_rounded, size: 16),
      ],
    );
    final button = widget.compact
        ? TextButton(
            key: _anchor,
            style: TextButton.styleFrom(
              minimumSize: const Size(0, WorkspaceSize.tabHeight),
              padding: const EdgeInsets.symmetric(horizontal: Space.xs),
              visualDensity: VisualDensity.standard,
              alignment: Alignment.centerLeft,
              foregroundColor: Theme.of(context).colorScheme.onSurfaceVariant,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            onPressed: enabled ? _show : null,
            child: content,
          )
        : OutlinedButton(
            key: _anchor,
            style:
                OutlinedButton.styleFrom(
                  minimumSize: Size(0, AppFormField.height(context)),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: Space.xs),
                  alignment: Alignment.centerLeft,
                  textStyle: Theme.of(context).textTheme.bodyMedium,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.control)),
                  visualDensity: VisualDensity.standard,
                ).copyWith(
                  foregroundColor: WidgetStateProperty.resolveWith(
                    (states) => states.contains(WidgetState.disabled)
                        ? BrandPalette.of(context).textMuted
                        : Theme.of(context).colorScheme.onSurface,
                  ),
                  backgroundColor: WidgetStateProperty.resolveWith(
                    (states) => AppFormField.fill(context, enabled: !states.contains(WidgetState.disabled)),
                  ),
                  side: WidgetStateProperty.resolveWith(
                    (states) => AppFormField.border(
                      context,
                      enabled: !states.contains(WidgetState.disabled),
                      focused: states.contains(WidgetState.focused),
                      hovered: states.contains(WidgetState.hovered),
                    ),
                  ),
                ),
            onPressed: enabled ? _show : null,
            child: content,
          );
    if (!widget.compact) {
      final field = Tooltip(message: label, child: button);
      return widget.label == null ? field : AppFormField(label: widget.label!, child: field);
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.label != null) ...[
          Text(widget.label!, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: Space.xs),
        ],
        Tooltip(message: label, child: button),
      ],
    );
  }
}

class _Models extends StatefulWidget {
  const _Models({
    required this.catalog,
    required this.value,
    required this.protocol,
    required this.endpoint,
    required this.cancel,
    this.credentialIdentity,
    this.draftKey,
    this.footer,
  });

  final WidgetBuilder? footer;
  final ModelCatalog catalog;
  final String value, endpoint;
  final ModelProtocol protocol;
  final CancellationToken cancel;
  final String? credentialIdentity;
  final Secret? draftKey;

  @override
  State<_Models> createState() => _ModelsState();
}

class _ModelsState extends State<_Models> {
  final _search = TextEditingController();
  CancellationToken? _request;
  var _models = <String>[];
  var _loading = true;
  ModelFailure? _failure;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    unawaited(
      widget.cancel.whenCancelled.then((_) {
        _request?.cancel();
        if (mounted) setState(() => _models = []);
      }),
    );
    unawaited(_load());
  }

  @override
  void dispose() {
    _generation++;
    _request?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (widget.cancel.isCancelled) return;
    final generation = ++_generation;
    _request?.cancel();
    final cancel = CancellationToken();
    _request = cancel;
    setState(() {
      _loading = true;
      _failure = null;
    });
    try {
      final models = await widget.catalog.list(
        protocol: widget.protocol,
        endpoint: widget.endpoint,
        credentialIdentity: widget.credentialIdentity,
        draftKey: widget.draftKey,
        cancel: cancel,
      );
      if (!mounted || generation != _generation || widget.cancel.isCancelled) {
        return;
      }
      setState(() => _models = models);
    } on Object catch (error) {
      if (!mounted || generation != _generation || widget.cancel.isCancelled) {
        return;
      }
      setState(() => _failure = error is ModelFailure ? error : const ModelFailure('modelCatalogFailed'));
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  String _reason(AppLocalizations l, ModelFailure failure) => switch (failure.code) {
    'modelCatalogHttp' when failure.statusCode != null => l.aiModelsLoadHttp('${failure.statusCode}'),
    'modelCatalogTimedOut' => l.aiModelsLoadTimedOut,
    _ => l.aiModelsLoadFailed,
  };

  bool _valid(String value) =>
      value.isNotEmpty && value.length <= 256 && !RegExp(r'[\x00-\x20\x7f-\x9f]').hasMatch(value);

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final query = _search.text.trim();
    final matches = _models.where((model) => model.toLowerCase().contains(query.toLowerCase())).toList();
    if (widget.value.isNotEmpty &&
        !matches.contains(widget.value) &&
        widget.value.toLowerCase().contains(query.toLowerCase())) {
      matches.insert(0, widget.value);
    }
    final custom = _valid(query) && !matches.contains(query);
    final available = !widget.cancel.isCancelled;
    return PopupSurface(
      padding: const EdgeInsets.all(Space.sm),
      child: PopupKeys(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const ValueKey('ai-model-search'),
                    controller: _search,
                    autofocus: true,
                    enabled: available,
                    maxLength: 256,
                    decoration: InputDecoration(
                      hintText: l.aiModelSearch,
                      prefixIcon: const Icon(Icons.search_rounded, size: 18),
                      counterText: '',
                      isDense: true,
                    ),
                    onChanged: (_) => setState(() {}),
                    onSubmitted: (_) {
                      if (available && _valid(query) && _search.value.composing.isCollapsed) {
                        Navigator.pop(context, query);
                      }
                    },
                  ),
                ),
                IconButton(
                  tooltip: l.aiModelsRefresh,
                  onPressed: available && !_loading ? _load : null,
                  icon: const Icon(Icons.refresh_rounded, size: 17),
                ),
              ],
            ),
            const SizedBox(height: Space.sm),
            if (_loading) const LinearProgressIndicator(),
            if (_failure case final failure?)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: Space.sm),
                child: Text(_reason(l, failure), style: Theme.of(context).textTheme.bodySmall),
              ),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: matches.length + (custom ? 1 : 0),
                itemBuilder: (context, index) {
                  final model = index < matches.length ? matches[index] : query;
                  return PopupRow(
                    key: ValueKey('ai-model-option-$model'),
                    selected: model == widget.value,
                    onTap: available ? () => Navigator.pop(context, model) : null,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: Space.sm),
                      child: Text(
                        index < matches.length ? model : l.aiModelCustom(model),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  );
                },
              ),
            ),
            if (!_loading && matches.isEmpty && !custom)
              Padding(padding: const EdgeInsets.all(Space.sm), child: Text(l.aiModelsEmpty)),
            if (widget.footer case final footer?) ...[const SizedBox(height: Space.xs), footer(context)],
          ],
        ),
      ),
    );
  }
}

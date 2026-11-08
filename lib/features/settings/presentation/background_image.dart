import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../design/theme.dart';
import '../../../foundation/result.dart';
import '../../../l10n/app_localizations.dart';
import '../application/background_images.dart';
import '../domain/background.dart';
import '../settings.dart';

/// Only this layer fades; controls and terminal glyphs are painted above it.
class BackgroundImageView extends ConsumerWidget {
  const BackgroundImageView({super.key, required this.slot, this.baseColor, this.opacity, this.active = true});

  final BackgroundSlot slot;
  final Color? baseColor;
  final double? opacity;
  final bool active;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final preview = ref.watch(backgroundImagesProvider);
    final alpha = opacity ?? preview[slot] ?? settings.get<double>(imageOpacitySetting(slot));
    final file = active && alpha > 0
        ? ref.watch(backgroundImageStoreProvider).file(settings.get(imageSetting(slot)))
        : null;
    return IgnorePointer(
      child: ExcludeSemantics(
        child: ColoredBox(
          color: baseColor ?? Theme.of(context).colorScheme.surface,
          child: file == null
              ? const SizedBox.expand()
              : Image.file(
                  file,
                  fit: BoxFit.cover,
                  width: double.infinity,
                  height: double.infinity,
                  // Changing a static opacity animation does not invalidate RenderImage's paint.
                  color: Colors.white.withValues(alpha: alpha),
                  colorBlendMode: BlendMode.modulate,
                  gaplessPlayback: false,
                  errorBuilder: (_, _, _) => const SizedBox.expand(),
                ),
        ),
      ),
    );
  }
}

class BackgroundImageControls extends ConsumerStatefulWidget {
  const BackgroundImageControls({super.key, required this.slot});

  final BackgroundSlot slot;

  @override
  ConsumerState<BackgroundImageControls> createState() => _BackgroundImageControlsState();
}

class _BackgroundImageControlsState extends ConsumerState<BackgroundImageControls> {
  var _busy = false;
  String? _error;

  Future<void> _run(Future<Result<void>?> Function() operation) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final result = await operation();
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (result case Err(:final error)) _error = error.code;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final controller = ref.read(backgroundImagesProvider.notifier);
    final slot = widget.slot;
    final selected = ref.watch(settingsProvider.select((s) => s.get(imageSetting(slot)) != null));
    final error = switch (_error) {
      null => null,
      'backgroundImageTooLarge' => l.backgroundImageTooLarge,
      'backgroundImageUnsupported' => l.backgroundImageUnsupported,
      'backgroundImageUnreadable' => l.backgroundImageUnreadable,
      'backgroundGalleryFull' => l.backgroundGalleryFull,
      _ => l.errSave,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _busy ? null : () => _run(() => controller.choose(slot)),
                icon: const Icon(Icons.image_outlined, size: 16),
                label: Text(l.backgroundChooseImage),
              ),
            ),
            const SizedBox(width: Space.sm),
            IconButton(
              tooltip: l.backgroundRestoreDefault,
              onPressed: _busy || !selected ? null : () => _run(() => controller.reset(slot)),
              icon: const Icon(Icons.restore, size: 18),
            ),
          ],
        ),
        _Gallery(
          slot: slot,
          enabled: !_busy,
          onSelect: (id) => _run(() => controller.select(slot, id)),
          onRemove: (id) => _run(() => controller.remove(id)),
        ),
        _OpacityRow(slot: slot, enabled: !_busy, onSave: (value) => _run(() => controller.saveOpacity(slot, value))),
        if (error != null) Text(error, style: TextStyle(color: Theme.of(context).colorScheme.error)),
      ],
    );
  }
}

/// Watches the live preview on its own, so a held slider does not rebuild the rest of the controls.
class _OpacityRow extends ConsumerWidget {
  const _OpacityRow({required this.slot, required this.enabled, required this.onSave});

  final BackgroundSlot slot;
  final bool enabled;
  final ValueChanged<double> onSave;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final controller = ref.read(backgroundImagesProvider.notifier);
    final preview = ref.watch(backgroundImagesProvider.select((previews) => previews[slot]));
    final saved = ref.watch(settingsProvider.select((s) => s.get<double>(imageOpacitySetting(slot))));
    final value = preview ?? saved;
    return Row(
      children: [
        Expanded(
          child: Slider(
            value: value,
            min: 0,
            max: 1,
            divisions: 100,
            label: '${(value * 100).round()}%',
            semanticFormatterCallback: (v) => '${l.backgroundOpacity} ${(v * 100).round()}%',
            onChanged: enabled ? (v) => controller.previewOpacity(slot, v) : null,
            onChangeEnd: onSave,
          ),
        ),
        SizedBox(
          width: Space.xl + Space.sm,
          child: Text('${(value * 100).round()}%', textAlign: TextAlign.end),
        ),
      ],
    );
  }
}

/// The saved images both slots share; selection is shown per slot, removal is global.
class _Gallery extends ConsumerWidget {
  const _Gallery({required this.slot, required this.enabled, required this.onSelect, required this.onRemove});

  final BackgroundSlot slot;
  final bool enabled;
  final ValueChanged<String> onSelect;
  final ValueChanged<String> onRemove;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final ids = ref.watch(backgroundGalleryProvider);
    if (ids.isEmpty) return const SizedBox.shrink();
    final selected = ref.watch(settingsProvider.select((s) => s.get(imageSetting(slot))));
    final store = ref.watch(backgroundImageStoreProvider);
    return Padding(
      padding: const EdgeInsets.only(top: Space.sm),
      child: Wrap(
        spacing: Space.sm,
        runSpacing: Space.sm,
        children: [
          for (var i = 0; i < ids.length; i++)
            _Thumbnail(
              key: ValueKey(ids[i]),
              file: store.file(ids[i]),
              label: l.backgroundImageItem(i + 1),
              selected: ids[i] == selected,
              enabled: enabled,
              onSelect: () => onSelect(ids[i]),
              onRemove: () => onRemove(ids[i]),
            ),
        ],
      ),
    );
  }
}

class _Thumbnail extends StatelessWidget {
  const _Thumbnail({
    super.key,
    required this.file,
    required this.label,
    required this.selected,
    required this.enabled,
    required this.onSelect,
    required this.onRemove,
  });

  static const width = 64.0, height = 40.0, badge = 14.0, remove = 20.0;

  final File? file;
  final String label;
  final bool selected;
  final bool enabled;
  final VoidCallback onSelect;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final radius = BorderRadius.circular(Radii.control);
    const missing = Icon(Icons.broken_image_outlined, size: 18);
    return SizedBox(
      width: width,
      height: height,
      child: Stack(
        children: [
          Positioned.fill(
            child: ClipRRect(
              borderRadius: radius,
              child: ColoredBox(
                color: scheme.surfaceContainerHighest,
                child: file == null
                    ? const Center(child: missing)
                    : Image.file(
                        file!,
                        fit: BoxFit.cover,
                        cacheWidth: (width * MediaQuery.devicePixelRatioOf(context)).ceil(),
                        errorBuilder: (_, _, _) => const Center(child: missing),
                      ),
              ),
            ),
          ),
          Positioned.fill(
            child: Semantics(
              button: true,
              selected: selected,
              enabled: enabled,
              label: label,
              child: Material(
                type: MaterialType.transparency,
                child: InkWell(borderRadius: radius, onTap: enabled && !selected ? onSelect : null),
              ),
            ),
          ),
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: radius,
                  border: Border.all(color: selected ? scheme.primary : scheme.outlineVariant, width: selected ? 2 : 1),
                ),
              ),
            ),
          ),
          if (selected)
            Positioned(
              right: Space.xs,
              bottom: Space.xs,
              child: IgnorePointer(
                child: SizedBox.square(
                  dimension: badge,
                  child: DecoratedBox(
                    decoration: BoxDecoration(color: scheme.primary, shape: BoxShape.circle),
                    child: Icon(Icons.check_rounded, size: 10, color: scheme.onPrimary),
                  ),
                ),
              ),
            ),
          Positioned(
            top: 2,
            right: 2,
            child: IconButton(
              tooltip: '${l.remove} · $label',
              onPressed: enabled ? onRemove : null,
              style: IconButton.styleFrom(
                fixedSize: const Size.square(remove),
                minimumSize: const Size.square(remove),
                padding: EdgeInsets.zero,
                iconSize: 12,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                backgroundColor: scheme.surface.withValues(alpha: .85),
                foregroundColor: scheme.onSurface,
              ),
              icon: const Icon(Icons.close_rounded),
            ),
          ),
        ],
      ),
    );
  }
}

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
                  opacity: AlwaysStoppedAnimation(alpha),
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
    final settings = ref.watch(settingsProvider);
    final preview = ref.watch(backgroundImagesProvider);
    final controller = ref.read(backgroundImagesProvider.notifier);
    final slot = widget.slot;
    final value = preview[slot] ?? settings.get<double>(imageOpacitySetting(slot));
    final selected = settings.get(imageSetting(slot)) != null;
    final error = switch (_error) {
      null => null,
      'backgroundImageTooLarge' => l.backgroundImageTooLarge,
      'backgroundImageUnsupported' => l.backgroundImageUnsupported,
      'backgroundImageUnreadable' => l.backgroundImageUnreadable,
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
        Row(
          children: [
            Expanded(
              child: Slider(
                value: value,
                min: 0,
                max: 1,
                divisions: 100,
                label: '${(value * 100).round()}%',
                semanticFormatterCallback: (v) => '${l.backgroundOpacity} ${(v * 100).round()}%',
                onChanged: _busy ? null : (v) => controller.previewOpacity(slot, v),
                onChangeEnd: (v) => _run(() => controller.saveOpacity(slot, v)),
              ),
            ),
            SizedBox(
              width: Space.xl + Space.sm,
              child: Text('${(value * 100).round()}%', textAlign: TextAlign.end),
            ),
          ],
        ),
        if (error != null) Text(error, style: TextStyle(color: Theme.of(context).colorScheme.error)),
      ],
    );
  }
}

import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// Bounds unused decoded images; live image listeners remain owned by their widgets.
class ImageCacheBudget extends StatefulWidget {
  const ImageCacheBudget({super.key, required this.child, this.cache});

  final Widget child;
  final ImageCache? cache;

  static const maxBytes = 16 * 1024 * 1024;
  static const maxImages = 128;

  @override
  State<ImageCacheBudget> createState() => _ImageCacheBudgetState();
}

class _ImageCacheBudgetState extends State<ImageCacheBudget> with WidgetsBindingObserver {
  late final ImageCache _cache;
  late final int _previousBytes, _previousImages;

  @override
  void initState() {
    super.initState();
    _cache = widget.cache ?? PaintingBinding.instance.imageCache;
    _previousBytes = _cache.maximumSizeBytes;
    _previousImages = _cache.maximumSize;
    _cache.maximumSizeBytes = math.min(_previousBytes, ImageCacheBudget.maxBytes);
    _cache.maximumSize = math.min(_previousImages, ImageCacheBudget.maxImages);
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.hidden || state == AppLifecycleState.paused) _cache.clear();
  }

  @override
  void didHaveMemoryPressure() => _cache.clear();

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cache.maximumSizeBytes = _previousBytes;
    _cache.maximumSize = _previousImages;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

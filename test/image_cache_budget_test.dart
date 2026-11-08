import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/app/image_cache_budget.dart';

class _Cache extends ImageCache {
  int clears = 0, liveClears = 0;
  @override
  void clear() {
    clears++;
    super.clear();
  }

  @override
  void clearLiveImages() {
    liveClears++;
    super.clearLiveImages();
  }
}

void main() {
  testWidgets('unused image cache is bounded and hidden/pressure cleanup preserves active images', (tester) async {
    final cache = _Cache();
    final previousBytes = cache.maximumSizeBytes, previousCount = cache.maximumSize;
    await tester.pumpWidget(ImageCacheBudget(cache: cache, child: const SizedBox()));
    expect(cache.maximumSizeBytes, ImageCacheBudget.maxBytes);
    expect(cache.maximumSize, ImageCacheBudget.maxImages);

    // Keep an image listener alive while lifecycle cleanup discards the unused LRU.
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawColor(const ui.Color(0xff123456), ui.BlendMode.src);
    final picture = recorder.endRecording();
    final image = picture.toImageSync(8, 8);
    picture.dispose();
    final source = Completer<ImageInfo>();
    final completer = cache.putIfAbsent('active', () => OneFrameImageStreamCompleter(source.future))!;
    final listener = ImageStreamListener((_, _) {});
    completer.addListener(listener);
    source.complete(ImageInfo(image: image));
    await tester.pump();
    expect(cache.liveImageCount, 1);
    expect(cache.currentSizeBytes, greaterThan(0));

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pump();
    expect(cache.clears, greaterThan(0));
    expect(cache.currentSizeBytes, 0);
    expect(cache.liveImageCount, 1);
    expect(cache.liveClears, 0);
    final clears = cache.clears;
    tester.binding.handleMemoryPressure();
    await tester.pump();
    expect(cache.clears, greaterThan(clears));
    expect(cache.liveImageCount, 1);
    expect(cache.liveClears, 0);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    completer.removeListener(listener);
    await tester.pumpWidget(const SizedBox());
    expect(cache.maximumSizeBytes, previousBytes);
    expect(cache.maximumSize, previousCount);
  });

  testWidgets('an embedding app smaller image budget is retained', (tester) async {
    final cache = _Cache()
      ..maximumSizeBytes = 1024
      ..maximumSize = 4;
    await tester.pumpWidget(ImageCacheBudget(cache: cache, child: const SizedBox()));
    expect(cache.maximumSizeBytes, 1024);
    expect(cache.maximumSize, 4);
    await tester.pumpWidget(const SizedBox());
  });
}

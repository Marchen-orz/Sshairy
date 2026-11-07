import 'package:flutter/material.dart';

import 'theme.dart';

/// Only selected, right-sized artwork is bundled; the original source pack is not a runtime asset.
abstract final class BrandAssets {
  static String mark(Accent theme) => 'assets/brand/${theme.name}/mark.png';
  static String mascot(Accent theme) => 'assets/brand/${theme.name}/mascot.png';
  static String logo(Accent theme, Brightness mode) => 'assets/brand/${theme.name}/logo-${mode.name}.png';
  static String breeze(Accent theme, Brightness mode) => 'assets/brand/${theme.name}/breeze-${mode.name}.png';
}

class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.size = 28});

  final double size;

  @override
  Widget build(BuildContext context) => Image.asset(
    BrandAssets.mark(BrandPalette.of(context).theme),
    width: size,
    height: size,
    cacheWidth: (size * MediaQuery.devicePixelRatioOf(context)).ceil(),
    fit: BoxFit.contain,
    semanticLabel: 'Sshairy',
  );
}

class BrandLogo extends StatelessWidget {
  const BrandLogo({super.key, this.width = 208});

  final double width;

  @override
  Widget build(BuildContext context) {
    final palette = BrandPalette.of(context);
    return Image.asset(
      BrandAssets.logo(palette.theme, palette.brightness),
      width: width,
      cacheWidth: (width * MediaQuery.devicePixelRatioOf(context)).ceil(),
      fit: BoxFit.contain,
      semanticLabel: 'Sshairy',
    );
  }
}

/// A quiet illustration for an empty content area; excludes non-interactive art from accessibility.
class BrandEmptyState extends StatelessWidget {
  const BrandEmptyState({super.key, this.child});

  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final palette = BrandPalette.of(context);
    final scale = MediaQuery.devicePixelRatioOf(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(Space.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ExcludeSemantics(
              child: SizedBox(
                width: 236,
                height: 170,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Positioned(
                      right: 0,
                      bottom: 0,
                      child: Opacity(
                        opacity: palette.brightness == Brightness.light ? .26 : .16,
                        child: Image.asset(
                          BrandAssets.breeze(palette.theme, palette.brightness),
                          width: 124,
                          cacheWidth: (124 * scale).ceil(),
                        ),
                      ),
                    ),
                    Image.asset(BrandAssets.mascot(palette.theme), width: 176, cacheWidth: (176 * scale).ceil()),
                  ],
                ),
              ),
            ),
            if (child != null) ...[const SizedBox(height: Space.md), child!],
          ],
        ),
      ),
    );
  }
}

# sshairy logo generation

- Model requested: `gpt-image-2`, high quality, via the installed `imagegen` skill and `imagegen-config-fallback` configuration route.
- Full prompt: `sshairy-logo-prompt.txt`.
- Requested: 1024×1024, two variants. The configured service returned one 1254×1254 RGB image: `sshairy-logo-1.png`. This is preserved unchanged.
- Selected mark: ice-cyan airy spirit with a dark `>_` terminal face.
- Historical transparent master: `legacy-icon-source.png`, normalized to 1024×1024 after removing the connected near-white exterior. This is raster artwork, not an SVG.
- Historical light/dark and small-size preview: `legacy-preview.png`.

These images were superseded on 2026-11-07 by the author's six-theme brand pack and are kept only as generation history. They are not application assets. The old exporter was removed so it cannot overwrite the current platform icons. Current imports use `python -I tool/import_brand.py <repository>`; see `docs/BRAND.md`.

No application data, credentials, host configurations or third-party brand assets were included in the generation prompt. macOS icon exports have not been verified in a running macOS application.

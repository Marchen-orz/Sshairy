# sshairy logo generation

- Model requested: `gpt-image-2`, high quality, via the installed `imagegen` skill and `imagegen-config-fallback` configuration route.
- Full prompt: `sshairy-logo-prompt.txt`.
- Requested: 1024×1024, two variants. The configured service returned one 1254×1254 RGB image: `sshairy-logo-1.png`. This is preserved unchanged.
- Selected mark: ice-cyan airy spirit with a dark `>_` terminal face.
- Transparent master: `../../assets/brand/icon-source.png`, normalized to 1024×1024 after removing the connected near-white exterior. This is raster artwork, not an SVG.
- Application PNG, Windows ICO and macOS icons share that master. Light/dark and small-size preview: `../../assets/brand/preview.png`.

Reproduce the exports from the generated image:

```sh
python -I tool/render_icon.py <repository> --source <repository>/output/imagegen/sshairy-logo-1.png --remove-white-background
```

Re-export from the prepared transparent master:

```sh
python -I tool/render_icon.py <repository>
```

No application data, credentials, host configurations or third-party brand assets were included in the generation prompt. macOS icon exports have not been verified in a running macOS application.

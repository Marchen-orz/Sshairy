"""Export desktop icons and a size preview from the selected GPT-generated PNG.

Development tool only: Python and Pillow. No network requests.
Usage: python -I tool/render_icon.py <repository> [--source <png>]
"""
import argparse
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont


def flat_pixels(image):
    get_pixels = getattr(image, "get_flattened_data", image.getdata)
    return get_pixels()


def remove_background(image):
    """Remove only the connected near-white exterior; preserve enclosed white details."""
    rgb = image.convert("RGB")
    mask = Image.new("L", image.size)
    mask.putdata([255 if min(pixel) >= 235 else 0 for pixel in flat_pixels(rgb)])
    for corner in ((0, 0), (image.width - 1, 0), (0, image.height - 1), (image.width - 1, image.height - 1)):
        ImageDraw.floodfill(mask, corner, 128)
    mask = mask.point(lambda value: 0 if value == 128 else 255)
    interior = mask.filter(ImageFilter.MinFilter(3))
    pixels = []
    for color, keep, solid in zip(flat_pixels(rgb), flat_pixels(mask), flat_pixels(interior)):
        if not keep:
            pixels.append((0, 0, 0, 0))
        elif solid or color[0] < 35:
            pixels.append((*color, 255))
        else:
            # The cyan outline has a low red channel. Unmatte its one-pixel white fringe so the transparent
            # icon does not acquire a pale halo on the dark application surface.
            alpha = min(1.0, (255 - color[0]) / 245)
            foreground = tuple(max(0, min(255, round((v - 255 * (1 - alpha)) / alpha))) for v in color)
            pixels.append((*foreground, round(255 * alpha)))
    result = Image.new("RGBA", image.size)
    result.putdata(pixels)
    return result


parser = argparse.ArgumentParser()
parser.add_argument("repository", type=Path)
parser.add_argument("--source", type=Path)
parser.add_argument("--remove-white-background", action="store_true")
args = parser.parse_args()
root = args.repository.resolve()
brand = root / "assets/brand"
source = args.source or brand / "icon-source.png"
image = Image.open(source).convert("RGBA")
if image.width != image.height:
    raise ValueError("The icon source must be square")
if args.remove_white_background:
    image = remove_background(image)
    bounds = image.getbbox()
    if bounds is None:
        raise ValueError("The source contains no visible symbol")
    symbol = image.crop(bounds)
    symbol.thumbnail((850, 850), Image.Resampling.LANCZOS)
    image = Image.new("RGBA", (1024, 1024))
    image.alpha_composite(symbol, ((1024 - symbol.width) // 2, (1024 - symbol.height) // 2))
    image.save(brand / "icon-source.png")
image.save(brand / "icon.png")
image.save(root / "windows/runner/resources/app_icon.ico", sizes=[(s, s) for s in (16, 24, 32, 48, 64, 128, 256)])
# Existing platform assets share the same source even when the runner is not tested here.
mac = root / "macos/Runner/Assets.xcassets/AppIcon.appiconset"
if mac.exists():
    for size in (16, 32, 64, 128, 256, 512, 1024):
        image.resize((size, size), Image.Resampling.LANCZOS).save(mac / f"app_icon_{size}.png")
preview = Image.new("RGB", (960, 460), "#F4F8FA")
draw = ImageDraw.Draw(preview)
draw.rectangle((480, 0, 960, 460), fill="#10191E")
try:
    font = ImageFont.truetype("C:/Windows/Fonts/segoeui.ttf", 14)
except OSError:
    font = ImageFont.load_default()
for offset, text in ((0, "#162E39"), (480, "#DFF4F5")):
    large = image.resize((256, 256), Image.Resampling.LANCZOS)
    preview.paste(large, (offset + 112, 24), large)
    x = offset + 32
    for size in (16, 24, 32, 48, 64, 128):
        small = image.resize((size, size), Image.Resampling.LANCZOS)
        preview.paste(small, (x, 312 + (128 - size) // 2), small)
        draw.text((x, 445), str(size), fill=text, font=font, anchor="ld")
        x += size + 12
preview.save(brand / "preview.png")
print("Exported icon.png, Windows ICO, macOS icons and preview.png")

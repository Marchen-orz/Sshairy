"""Render the original SVG with a locally installed Edge and export desktop icons.

Development tools only: Python, Pillow and Playwright. No network requests.
Usage: python -I tool/render_icon.py <repository> [--browser <executable>]
"""
import argparse
import io
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont
from playwright.sync_api import sync_playwright

parser = argparse.ArgumentParser()
parser.add_argument("repository", type=Path)
parser.add_argument("--browser", default="C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe")
args = parser.parse_args()
root = args.repository.resolve()
brand = root / "assets/brand"
svg = (brand / "icon.svg").read_text(encoding="utf-8")
with sync_playwright() as playwright:
    browser = playwright.chromium.launch(executable_path=args.browser, headless=True)
    page = browser.new_page(viewport={"width": 512, "height": 512}, device_scale_factor=1)
    page.set_content('<html><body style="margin:0;background:transparent">' + svg + "</body></html>")
    image = Image.open(io.BytesIO(page.locator("svg").screenshot(omit_background=True))).convert("RGBA")
    browser.close()
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

"""Export the README spreads from spreads.html into media/ and media/zh/ (2400 px wide, transparent corners).

python -I -X utf8 tool/readme/render_spreads.py [name ...]
Needs Playwright for Python and an installed Microsoft Edge. See SOURCES.md.
"""

import sys
from pathlib import Path

from PIL import Image
from playwright.sync_api import sync_playwright

REPO = Path(__file__).resolve().parents[2]
PAGE = (REPO / 'tool/readme/spreads.html').as_uri()
NAMES = ['cover', 'workspace', 'features', 'airy', 'themes', 'performance', 'footprint']


def main():
    names = sys.argv[1:] or NAMES
    assert set(names) <= set(NAMES), names
    with sync_playwright() as p:
        browser = p.chromium.launch(channel='msedge')
        page = browser.new_page(viewport={'width': 1200, 'height': 900}, device_scale_factor=2)
        problems = []
        page.on('console', lambda message: problems.append(message.text) if message.type == 'error' else None)
        page.on('pageerror', lambda error: problems.append(str(error)))
        page.on('requestfailed', lambda request: problems.append(request.url))
        for lang, folder in (('en', REPO / 'media'), ('zh', REPO / 'media/zh')):
            folder.mkdir(parents=True, exist_ok=True)
            page.goto(f'{PAGE}?lang={lang}')
            page.wait_for_load_state('networkidle')
            page.evaluate('document.fonts.ready')
            assert page.evaluate('[...document.images].every((image) => image.complete && image.naturalWidth > 0)')
            # Text that leaves its spread would be silently clipped by the rounded frame.
            clipped = page.evaluate('''[...document.querySelectorAll('.sp :is(h1,h2,h3,p,b,span,em)')].filter((el) => {
                if (el.closest('.sa,.sa-part')) return false;
                const box = el.getBoundingClientRect(), frame = el.closest('.sp').getBoundingClientRect();
                return box.width && (box.left < frame.left || box.right > frame.right || box.top < frame.top || box.bottom > frame.bottom);
            }).map((el) => el.textContent.slice(0, 40))''')
            assert not clipped, (lang, clipped)
            for name in names:
                target = folder / f'{name}.png'
                page.locator(f'#{name}').screenshot(path=str(target), omit_background=True)
                image = Image.open(target)
                assert image.width == 2400, (name, image.size)
                image.save(target, optimize=True)
                print(f'{lang}/{name}.png {image.width}x{image.height} {target.stat().st_size // 1024} KiB')
        assert not problems, problems
        browser.close()


if __name__ == '__main__':
    main()

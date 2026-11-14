"""Render film.html to site/media/sshairy-<lang>.mp4 (1920x1080, 30 fps) with bgm.mp3 and a poster frame.

python -I -X utf8 tool/motion/render.py [en|zh ...] [--seconds N]
Needs Playwright for Python, an installed Microsoft Edge and ffmpeg on PATH.
"""

import subprocess
import sys
from pathlib import Path

from playwright.sync_api import sync_playwright

HERE = Path(__file__).resolve().parent
OUT = HERE.parents[1] / 'site/media'
FPS = 30


def render(page, lang, limit):
    page.goto(f'{(HERE / "film.html").as_uri()}?render&lang={lang}')
    page.wait_for_load_state('load')
    page.evaluate('document.fonts.ready')
    assert page.evaluate('[...document.images].every((image) => image.complete && image.naturalWidth > 0)')
    film = page.evaluate('({end: FILM.end, audioAt: FILM.audioAt})')
    end = min(limit or film['end'], film['end'])
    target = OUT / f'sshairy-{lang}.mp4'
    encoder = subprocess.Popen(
        ['ffmpeg', '-v', 'error', '-y', '-f', 'image2pipe', '-framerate', str(FPS), '-c:v', 'mjpeg', '-i', '-',
         '-ss', str(film['audioAt']), '-i', str(HERE / 'bgm.mp3'), '-map', '0:v', '-map', '1:a', '-t', f'{end:.3f}',
         '-af', f'afade=t=in:d=0.6,afade=t=out:st={end - 2.4:.3f}:d=2.4',
         '-c:v', 'libx264', '-preset', 'slow', '-crf', '21', '-pix_fmt', 'yuv420p', '-movflags', '+faststart',
         '-c:a', 'aac', '-b:a', '160k', str(target)],
        stdin=subprocess.PIPE)
    frames = round(end * FPS)
    for index in range(frames):
        page.evaluate('(time) => window.seek(time)', index / FPS)
        encoder.stdin.write(page.screenshot(type='jpeg', quality=95))
        if index % 300 == 0:
            print(f'{lang} {index}/{frames}', flush=True)
    encoder.stdin.close()
    assert encoder.wait() == 0
    page.evaluate('window.seek(7.6)')
    page.screenshot(path=str(OUT / f'poster-{lang}.jpg'), type='jpeg', quality=88)
    print(f'{target.name} {target.stat().st_size / 1048576:.1f} MiB, {frames} frames')


def main():
    args = sys.argv[1:]
    limit = float(args.pop(args.index('--seconds') + 1)) if '--seconds' in args else None
    langs = [arg for arg in args if arg != '--seconds'] or ['en', 'zh']
    assert set(langs) <= {'en', 'zh'}, langs
    OUT.mkdir(parents=True, exist_ok=True)
    with sync_playwright() as p:
        browser = p.chromium.launch(channel='msedge')
        page = browser.new_page(viewport={'width': 1920, 'height': 1080})
        problems = []
        page.on('console', lambda message: problems.append(message.text) if message.type == 'error' else None)
        page.on('pageerror', lambda error: problems.append(str(error)))
        for lang in langs:
            render(page, lang, limit)
        assert not problems, problems
        browser.close()


if __name__ == '__main__':
    main()

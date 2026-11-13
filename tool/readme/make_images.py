"""Draws the README art from the Sshairy brand asset pack.

  python -I -X utf8 make_images.py [brand_pack_dir] [output_dir]

Uses the official palette tokens, the traced wordmark and the transparent mascot.
The six-theme board is assembled from real application screenshots in <output_dir>/tiles.
Every picture has a light and a dark variant; the Chinese variants live in output_dir/zh.
"""

import json
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

REPO = Path(__file__).resolve().parents[2]
PACK = Path(sys.argv[1]) if len(sys.argv) > 1 else REPO / 'Sshairy-Brand-Asset-Pack'
OUT = Path(sys.argv[2]) if len(sys.argv) > 2 else REPO / 'media'
BRAND = PACK / '01-IceBlue-Mint'
FONTS = Path('C:/Windows/Fonts')

PALETTE = json.loads((BRAND / 'palette' / 'palette.json').read_text(encoding='utf-8'))['tokens']
DARK = json.loads((BRAND / 'dark' / 'theme-dark.json').read_text(encoding='utf-8'))['tokens']

INK = PALETTE['ink']
PRIMARY = PALETTE['primary']       # #2E6EF7, official primary
SKY = PALETTE['sky']
MINT = PALETTE['accent']
SURFACE = PALETTE['surface']
WHITE = PALETTE['white']

THEMES = [
    ('01-IceBlue-Mint', 'blue', 'Ice Blue / Mint', '冰蓝薄荷绿'),
    ('02-MintGreen', 'green', 'Mint Green', '薄荷绿'),
    ('03-Violet', 'violet', 'Violet', '紫罗兰'),
    ('04-SunsetOrange', 'orange', 'Sunset Orange', '落日橙'),
    ('05-DeepSeaBlue', 'deepSea', 'Deep Sea Blue', '深海蓝'),
    ('06-SakuraPink', 'pink', 'Sakura Pink', '樱花粉'),
]
SLUGS = {slug: (folder, en, zh, json.loads((PACK / folder / 'palette' / 'palette.json').read_text(encoding='utf-8'))['tokens'])
         for folder, slug, en, zh in THEMES}

START = [('sshairy', 0.62, True), ('Netcatty', 2.60, False), ('FinalShell', 7.55, False)]
MEMORY = [('sshairy', 131.3, True), ('FinalShell', 333.9, False), ('Netcatty', 446.8, False)]
DOWNLOAD = [('sshairy', 27.2, True), ('WindTerm', 31.2, False), ('MobaXterm', 42.2, False),
            ('Xshell', 49.9, False), ('electerm', 114.6, False), ('Netcatty', 126.9, False),
            ('Wave Terminal', 156.2, False), ('Tabby', 161.9, False), ('Termius', 327.9, False)]
INSIDE = [('Shell completion specs', 52.7, False), ('Flutter engine', 20.3, False),
          ('App code (AOT)', 14.7, True), ('Brand artwork', 5.6, False),
          ('Runner and plugins', 1.5, False), ('Notices and readme', 1.5, False),
          ('ICU data', 0.8, False)]

TEXT = {
    'en': dict(
        kicker='A LIGHTWEIGHT SSH / SFTP CLIENT FOR THE DESKTOP',
        tagline='An SSH client that gets out of your way.',
        sub='Native Dart + Flutter. No Chromium, no WebView. Airy, the built-in agent, asks before it acts.',
        badges=['Windows', 'Flutter', 'Dart', 'SSH / SFTP', 'AI agent'],
        tiles=[('0.62 s', 'to first window', 'warm start, median of 5 runs'),
               ('131 MB', 'idle memory', 'one process, no sessions'),
               ('27 MB', 'download', 'portable Windows ZIP'),
               ('0', 'browser engines', 'no Chromium, no WebView')],
        chart_titles=dict(start='Startup', memory='Idle memory', download='Windows download size',
                          inside='What is in the app folder'),
        chart_subs=dict(start='Seconds to the first visible window · lower is better',
                        memory='Unique set size, MiB · lower is better',
                        download='MiB · lower is better',
                        inside='MiB, unpacked'),
        footnotes=dict(start='Windows 11 · Ryzen 7 8845HS · 2026-11-13 · tool/readme/measure_startup.py',
                       memory='15 s after launch, whole process tree · 2026-11-13',
                       download='Latest public Windows release files, read 2026-11-13',
                       inside='1,453 shell completion specs make up the largest part'),
        arch=('Why it stays light', 'An Electron SSH client', 'sshairy',
              ['Chromium renderer', 'Node.js main process', 'GPU process', 'Network process', 'Utility process'],
              '5 processes · 447 MB idle', ['Dart AOT app', 'Flutter engine'], '1 process · 131 MB idle'),
        board=('Six color themes', 'Each with its own light and dark palette, logo and artwork'),
        hero_badge='0.1.0 · early preview',
    ),
    'zh': dict(
        kicker='轻量 SSH / SFTP 桌面客户端',
        tagline='一个不碍事的 SSH 客户端。',
        sub='原生 Dart + Flutter,不含 Chromium 或 WebView。内置助手 Airy,动手前先征得同意。',
        badges=['Windows', 'Flutter', 'Dart', 'SSH / SFTP', 'AI 助手'],
        tiles=[('0.62 秒', '到首屏', '预热启动,5 次取中位数'),
               ('131 MB', '空闲内存', '单进程,未开会话'),
               ('27 MB', '下载体积', 'Windows 便携 ZIP'),
               ('0', '浏览器内核', '不含 Chromium / WebView')],
        chart_titles=dict(start='启动速度', memory='空闲内存', download='Windows 下载体积',
                          inside='安装目录构成'),
        chart_subs=dict(start='到第一个可见窗口的秒数 · 越短越好',
                        memory='独占内存,MiB · 越低越好',
                        download='MiB · 越小越好',
                        inside='MiB,解压后'),
        footnotes=dict(start='Windows 11 · Ryzen 7 8845HS · 2026-11-13 · tool/readme/measure_startup.py',
                       memory='启动 15 秒后,整个进程树 · 2026-11-13',
                       download='2026-11-13 读取的各项目公开发布文件',
                       inside='占比最大的是 1,453 个 Shell 补全规格'),
        arch=('为什么它轻', '典型 Electron SSH 客户端', 'sshairy',
              ['Chromium 渲染进程', 'Node.js 主进程', 'GPU 进程', '网络进程', '工具进程'],
              '5 个进程 · 空闲 447 MB', ['Dart AOT 应用', 'Flutter 引擎'], '1 个进程 · 空闲 131 MB'),
        board=('六套主题', '每套都有独立的浅色与深色配色、Logo 与素材'),
        hero_badge='0.1.0 · 早期预览',
    ),
}


def font(size, weight='regular', zh=False, mono=False):
    if mono:
        name = 'consola.ttf' if weight != 'bold' else 'consolab.ttf'
    elif zh:
        name = 'msyhbd.ttc' if weight in ('bold', 'semibold') else 'msyh.ttc'
    else:
        name = {'regular': 'segoeui.ttf', 'bold': 'segoeuib.ttf', 'semibold': 'seguisb.ttf'}[weight]
    return ImageFont.truetype(str(FONTS / name), size)


def fit(draw, text, size, width, weight, zh, minimum=16):
    while size > minimum and draw.textlength(text, font=font(size, weight, zh)) > width:
        size -= 2
    return size


def wrap(draw, text, size, width, weight, zh):
    if ' ' in text:
        words, joiner = text.split(' '), ' '
    else:
        words, joiner = list(text), ''
    lines, line = [], ''
    for word in words:
        candidate = f'{line}{joiner}{word}' if line else word
        if draw.textlength(candidate, font=font(size, weight, zh)) <= width:
            line = candidate
        else:
            lines.append(line)
            line = word
    return lines + [line]


def asset(path, height=None, width=None):
    image = Image.open(path).convert('RGBA')
    bbox = image.getchannel('A').getbbox()
    if bbox:
        image = image.crop(bbox)
    if height:
        return image.resize((round(image.width * height / image.height), height), Image.Resampling.LANCZOS)
    return image.resize((width, round(image.height * width / image.width)), Image.Resampling.LANCZOS)


def theme(mode):
    if mode == 'light':
        return dict(bg=SURFACE, panel=WHITE, border='#CDD7E4', ink=INK, muted='#60738C',
                    soft='#8A9CB4', accent=PRIMARY, wash='#E3EEFF', bar='#DDE8F5', grid='#E7EDF5',
                    mark=SKY, logo=f'{BRAND}/logos/wordmark.png')
    return dict(bg=DARK['background'], panel=DARK['surface'], border=DARK['border-subtle'],
                ink=DARK['text'], muted=DARK['text-secondary'], soft=DARK['text-muted'],
                accent=DARK['primary'], wash=DARK['sidebar'], bar='#30445C', grid='#25384D',
                mark=DARK['primary'], logo=f'{BRAND}/dark/logos/wordmark.png')


def badge(draw, x, y, label, t, zh):
    f = font(22, 'semibold', zh)
    w = round(draw.textlength(label, font=f)) + 36
    draw.rounded_rectangle((x, y, x + w, y + 42), radius=21, fill=t['panel'], outline=t['border'], width=1)
    draw.text((x + w / 2, y + 21), label, font=f, fill=t['muted'], anchor='mm')
    return w + 12


def hero(t, mode, lang, text):
    W, H = 2400, 900
    image = Image.new('RGB', (W, H), t['bg'])
    draw = ImageDraw.Draw(image)
    draw.ellipse((-420, 60, 1500, 1980), fill=t['wash'])
    cloud = asset(f'{BRAND}/decorations/cloud.png', width=260)
    image.paste(cloud, (1460, 250), cloud)

    wordmark = asset(t['logo'], width=460)
    image.paste(wordmark, (140, 96), wordmark)
    draw.text((140, 252), text['kicker'], font=font(24, 'semibold', lang == 'zh'), fill=t['accent'])

    size = fit(draw, text['tagline'], 62, 1050, 'bold', lang == 'zh')
    draw.text((140, 330), text['tagline'], font=font(size, 'bold', lang == 'zh'), fill=t['ink'])
    y = 440
    for line in wrap(draw, text['sub'], 30, 1000, 'regular', lang == 'zh'):
        draw.text((142, y), line, font=font(30, 'regular', lang == 'zh'), fill=t['muted'])
        y += 46

    x = 140
    for label in text['badges']:
        x += badge(draw, x, y + 28, label, t, lang == 'zh')

    version = text['hero_badge']
    vf = font(24, 'semibold', lang == 'zh')
    vw = round(draw.textlength(version, font=vf)) + 40
    draw.rounded_rectangle((140, 740, 140 + vw, 794), radius=27, fill=t['accent'])
    draw.text((140 + vw / 2, 767), version, font=vf, fill=WHITE if mode == 'light' else DARK['background'], anchor='mm')

    mascot = asset(f'{BRAND}/poses/default.png', height=620)
    image.paste(mascot, (W - mascot.width - 40, (H - mascot.height) // 2 + 60), mascot)
    return image


def tiles(t, lang, text):
    W, H = 2400, 420
    image = Image.new('RGB', (W, H), t['bg'])
    draw = ImageDraw.Draw(image)
    for i, (number, label, caption) in enumerate(text['tiles']):
        x = 40 + i * 580
        draw.rounded_rectangle((x, 30, x + 560, 390), radius=28, fill=t['panel'], outline=t['border'], width=1)
        draw.rectangle((x + 44, 78, x + 50, 148), fill=t['accent'])
        draw.text((x + 70, 66), number, font=font(84, 'bold'), fill=t['ink'])
        draw.text((x + 44, 202), label, font=font(32, 'semibold', lang == 'zh'), fill=t['accent'])
        draw.text((x + 44, 262), caption, font=font(24, 'regular', lang == 'zh'), fill=t['muted'])
    return image


def step_for(maximum):
    raw = maximum / 4
    magnitude = 10 ** max(0, len(str(int(raw))) - 1)
    for step in (magnitude / 2, magnitude, magnitude * 2, magnitude * 5, magnitude * 10):
        if maximum / step <= 6:
            return max(step, 1)
    return maximum / 4


def chart(t, folder, name, mode, lang, text, rows, unit, decimals=1):
    row, top = 104, 230
    bottom = top + row * len(rows) + 56
    W, H = 2400, bottom + 104
    image = Image.new('RGB', (W, H), t['bg'])
    draw = ImageDraw.Draw(image)
    draw.text((140, 56), text['chart_titles'][name], font=font(52, 'bold', lang == 'zh'), fill=t['ink'])
    draw.text((140, 134), text['chart_subs'][name], font=font(27, 'regular', lang == 'zh'), fill=t['muted'])

    step = step_for(max(v for _, v, _ in rows))
    tick_max = step * (int(max(v for _, v, _ in rows) / step) + 1)
    left, right = 600, 2060
    scale = (right - left) / tick_max
    for tick in range(0, int(tick_max) + 1, int(step)):
        x = left + tick * scale
        draw.line((x, top - 48, x, bottom - 30), fill=t['grid'], width=1)
        draw.text((x, bottom - 6), f'{tick:g}', font=font(21, 'regular', lang == 'zh'),
                  fill=t['soft'], anchor='mt')
    for i, (label, value, emphasize) in enumerate(rows):
        y = top + i * row + 36
        end = left + value * scale
        draw.rounded_rectangle((left, y - 11, end, y + 11), radius=11,
                               fill=t['accent'] if emphasize else t['bar'])
        draw.rectangle((left, y - 11, left + 12, y + 11), fill=t['accent'] if emphasize else t['bar'])
        draw.text((left - 36, y), label, font=font(29, 'bold' if emphasize else 'regular', lang == 'zh'),
                  fill=t['ink'] if emphasize else t['muted'], anchor='rm')
        value_text = f'{value:.{decimals}f} {unit}' if unit else f'{value:.{decimals}f}'
        draw.text((end + 20, y), value_text, font=font(29, 'bold' if emphasize else 'regular', lang == 'zh'),
                  fill=t['ink'] if emphasize else t['muted'], anchor='lm')
    draw.text((140, H - 62), text['footnotes'][name], font=font(21, 'regular', lang == 'zh'), fill=t['soft'])
    image.save(folder / f'{name}-{mode}.png', optimize=True)


def architecture(t, folder, mode, lang, text):
    W, H = 2400, 900
    image = Image.new('RGB', (W, H), t['bg'])
    draw = ImageDraw.Draw(image)
    title, left_title, right_title, boxes, left_note, own, right_note = text['arch']
    draw.text((140, 58), title, font=font(52, 'bold', lang == 'zh'), fill=t['ink'])
    draw.rounded_rectangle((120, 200, 1160, 800), radius=28, fill=t['panel'], outline=t['border'], width=1)
    draw.text((172, 244), left_title, font=font(29, 'semibold', lang == 'zh'), fill=t['muted'])
    for i, box in enumerate(boxes):
        y = 320 + i * 76
        draw.rounded_rectangle((172, y, 1108, y + 56), radius=12, fill=t['bar'])
        draw.text((198, y + 28), box, font=font(24, 'regular', lang == 'zh'), fill=t['ink'], anchor='lm')
    draw.text((172, 738), left_note, font=font(23, 'regular', lang == 'zh'), fill=t['soft'])
    draw.rounded_rectangle((1240, 200, 2280, 800), radius=28, fill=t['wash'], outline=t['accent'], width=2)
    draw.text((1292, 244), right_title, font=font(29, 'semibold', lang == 'zh'), fill=t['muted'])
    for i, box in enumerate(own):
        y = 370 + i * 92
        draw.rounded_rectangle((1292, y, 2228, y + 68), radius=14, fill=t['panel'], outline=t['border'], width=1)
        draw.text((1320, y + 34), box, font=font(27, 'semibold', lang == 'zh'), fill=t['ink'], anchor='lm')
    draw.text((1292, 738), right_note, font=font(23, 'regular', lang == 'zh'), fill=t['soft'])
    image.save(folder / f'architecture-{mode}.png', optimize=True)


def board(t, folder, mode, lang, text):
    W, H = 2400, 1230
    image = Image.new('RGB', (W, H), t['bg'])
    draw = ImageDraw.Draw(image)
    draw.text((140, 52), text['board'][0], font=font(52, 'bold', lang == 'zh'), fill=t['ink'])
    draw.text((140, 130), text['board'][1], font=font(27, 'regular', lang == 'zh'), fill=t['muted'])
    tile_w, tile_h, gap = 700, 460, 30
    for i, (folder_name, slug, en, zh) in enumerate(THEMES):
        col, row = i % 3, i // 3
        x = 140 + col * (tile_w + gap)
        y = 200 + row * (tile_h + gap)
        colors = json.loads((PACK / folder_name / 'palette' / 'palette.json').read_text(encoding='utf-8'))['tokens']
        draw.rounded_rectangle((x, y, x + tile_w, y + tile_h), radius=22,
                               fill=t['panel'], outline=t['border'], width=1)
        shot = OUT / 'tiles' / f'theme-{slug}.png'
        if shot.exists():
            frame = Image.open(shot).convert('RGB')
            frame.thumbnail((tile_w - 28, 360), Image.Resampling.LANCZOS)
            bx = x + (tile_w - frame.width) // 2
            by = y + 14
            image.paste(frame, (bx, by))
            draw.rectangle((bx, by, bx + frame.width, by + frame.height), outline=t['border'], width=1)
        draw.rounded_rectangle((x + 22, y + 386, x + 64, y + 428), radius=10, fill=colors['primary'])
        draw.text((x + 80, y + 390), zh if lang == 'zh' else en,
                  font=font(27, 'bold', lang == 'zh'), fill=t['ink'])
        draw.text((x + 80, y + 424), colors['primary'].upper(), font=font(19, 'regular', mono=True), fill=t['soft'])
    image.save(folder / f'themes-{mode}.png', optimize=True)


def main():
    for lang, folder in (('en', OUT), ('zh', OUT / 'zh')):
        folder.mkdir(parents=True, exist_ok=True)
        text = TEXT[lang]
        for mode in ('light', 'dark'):
            t = theme(mode)
            hero(t, mode, lang, text).save(folder / f'hero-{mode}.png', optimize=True)
            tiles(t, lang, text).save(folder / f'stats-{mode}.png', optimize=True)
            chart(t, folder, 'start', mode, lang, text, START, 's', decimals=2)
            chart(t, folder, 'memory', mode, lang, text, MEMORY, 'MB')
            chart(t, folder, 'download', mode, lang, text, DOWNLOAD, 'MB')
            chart(t, folder, 'inside', mode, lang, text, INSIDE, 'MB')
            architecture(t, folder, mode, lang, text)
            if mode == 'light':
                board(t, folder, mode, lang, text)
            else:
                # The board is artwork over a dark README surface; render it directly instead of reusing a light one.
                board(t, folder, mode, lang, text)


if __name__ == '__main__':
    main()

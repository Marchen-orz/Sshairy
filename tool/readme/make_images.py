"""Export the light README spreads from brand assets and real demo screenshots.

python -I -X utf8 tool/readme/make_images.py [brand_pack_dir] [output_dir]
See SOURCES.md for the illustration prompt, measurements and screenshot provenance.
"""

import json
import math
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

REPO = Path(__file__).resolve().parents[2]
PACK = Path(sys.argv[1]) if len(sys.argv) > 1 else REPO / 'Sshairy-Brand-Asset-Pack'
OUT = Path(sys.argv[2]) if len(sys.argv) > 2 else REPO / 'media'
BRAND = PACK / '01-IceBlue-Mint'
FONTS = Path('C:/Windows/Fonts')
PALETTE = json.loads((BRAND / 'palette/palette.json').read_text(encoding='utf-8'))['tokens']
INK, BLUE, MINT, SURFACE = (PALETTE[k] for k in ('ink', 'primary', 'accent', 'surface'))
MUTED, LINE, NEUTRAL = '#60738C', '#DCE6F1', '#B6C5D6'
W = 2400
THEMES = [
    ('01-IceBlue-Mint', 'blue', 'Ice Blue / Mint', '冰蓝薄荷'),
    ('02-MintGreen', 'green', 'Mint Green', '薄荷绿'),
    ('03-Violet', 'violet', 'Violet', '紫罗兰'),
    ('04-SunsetOrange', 'orange', 'Sunset Orange', '落日橙'),
    ('05-DeepSeaBlue', 'deepSea', 'Deep Sea Blue', '深海蓝'),
    ('06-SakuraPink', 'pink', 'Sakura Pink', '樱花粉'),
]
BENCHMARKS = json.loads((REPO / 'tool/readme/benchmarks.json').read_text(encoding='utf-8'))['clients']
START = [(row['name'], row['startup_seconds']) for row in BENCHMARKS]
MEMORY = [(row['name'], row['idle_mib']) for row in BENCHMARKS]
DOWNLOAD = [
    ('Sshairy', 27.2), ('WindTerm', 31.2), ('MobaXterm', 42.2), ('Xshell', 45.4), ('electerm', 114.6),
    ('Netcatty', 126.9), ('Wave Terminal', 156.2), ('Tabby', 161.9), ('Termius', 327.9),
]
# Rounded MiB; the tiny files are grouped so the displayed parts total 97.4.
CONTENTS = [52.7, 20.3, 14.7, 5.6, 4.1]
TEXT = {
    'en': dict(
        hero=['Lightweight SSH.', 'Powered by AI.'],
        sub='A modern, native SSH workspace.',
        metrics=[('0.62 s', 'to open'), ('131 MiB', 'idle memory'),
                 ('27 MiB', 'portable ZIP'), ('Native', 'no browser engine')],
        hosts='Your host library.', host_note='Groups / Tags / Pins / Search',
        default='Ice Blue / Mint · the default theme',
        airy='Meet Airy.', airy_sub=['An assistant, right beside your terminal.'],
        airy_points=[('39 tools', 'Hosts, files, commands and more.'),
                     ('4 permission modes', 'Confirm before acting, by default.'),
                     ('Your model', 'Anthropic or an OpenAI-compatible API.')],
        themes='Six ways to feel at home.', themes_note='Light palettes shown',
        perf='Less waiting. More working.',
        perf_sub='A quick start. A lighter desktop.',
        start='Startup', memory='Idle memory',
        start_unit='seconds', mem_unit='MiB',
        footprint='Travel light.',
        foot_sub='A small download. A native app. Plenty of tools.',
        download='Windows download', download_unit='MiB',
        unpacked='unpacked', content_title='Inside the app folder',
        contents=['Shell completions', 'Flutter engine', 'App code · AOT', 'Brand artwork', 'Other files'],
        specs='1,453 shell completion specs',
        native=['Dart AOT', 'Flutter', 'Desktop OS'],
        native_note='One app process. No Chromium or WebView.',
    ),
    'zh': dict(
        hero=['轻量 SSH。', '由 AI 驱动。'],
        sub='现代、清爽的原生 SSH 工作区。',
        metrics=[('0.62 秒', '启动'), ('131 MiB', '空闲内存'),
                 ('27 MiB', '便携 ZIP'), ('原生', '无需浏览器内核')],
        hosts='主机，一目了然。', host_note='分组 / 标签 / 置顶 / 搜索',
        default='冰蓝薄荷 · 默认主题',
        airy='认识 Airy。', airy_sub=['终端旁边，多一个帮手。'],
        airy_points=[('39 个工具', '主机、文件、命令，都能帮上忙。'),
                     ('4 档权限', '默认在操作前，由你确认。'),
                     ('自选模型', '支持 Anthropic 与 OpenAI 兼容接口。')],
        themes='六种配色，换个心情。', themes_note='浅色主题展示',
        perf='打开就用。',
        perf_sub='启动更快，桌面更轻。',
        start='启动', memory='空闲内存',
        start_unit='秒', mem_unit='MiB',
        footprint='轻装上阵。',
        foot_sub='小巧的下载体积，完整的原生工具。',
        download='Windows 下载体积', download_unit='MiB',
        unpacked='解压后', content_title='包里装了什么',
        contents=['Shell 补全规格', 'Flutter 引擎', 'AOT 应用代码', '品牌素材', '其余文件'],
        specs='内置 1,453 个 Shell 补全规格',
        native=['Dart AOT', 'Flutter', 'Desktop OS'],
        native_note='单个应用进程，无 Chromium 或 WebView。',
    ),
}


def font(size, weight='regular', zh=False, mono=False):
    if mono:
        name = 'consolab.ttf' if weight == 'bold' else 'consola.ttf'
    elif zh:
        name = 'msyhbd.ttc' if weight in ('bold', 'semibold') else 'msyh.ttc'
    else:
        name = {'regular': 'segoeui.ttf', 'semibold': 'seguisb.ttf', 'bold': 'segoeuib.ttf'}[weight]
    return ImageFont.truetype(str(FONTS / name), size)


def canvas(height, color='white'):
    return Image.new('RGB', (W, height), color)


def text(image, xy, value, size=34, weight='regular', zh=False, fill=INK, anchor=None):
    draw = ImageDraw.Draw(image)
    f = font(size, weight, zh)
    bounds = draw.textbbox(xy, value, font=f, anchor=anchor)
    assert bounds[0] >= 0 and bounds[2] <= image.width, (value, bounds)
    assert bounds[1] >= 0 and bounds[3] <= image.height, (value, bounds)
    draw.text(xy, value, font=f, fill=fill, anchor=anchor)


def asset(path, width):
    image = Image.open(path).convert('RGBA')
    bounds = image.getchannel('A').getbbox()
    assert bounds, path
    image = image.crop(bounds)
    return image.resize((width, round(width * image.height / image.width)), Image.Resampling.LANCZOS)


def paste_asset(image, path, xy, width):
    part = asset(path, width)
    image.paste(part, xy, part)


def frame(image, shot, xy, width, radius=20):
    shot = shot.convert('RGB')
    height = round(width * shot.height / shot.width)
    shot = shot.resize((width, height), Image.Resampling.LANCZOS)
    x, y = xy
    assert x >= 0 and y >= 0 and x + width <= W and y + height <= image.height
    shadow = Image.new('RGBA', image.size)
    ImageDraw.Draw(shadow).rounded_rectangle((x, y + 18, x + width, y + height + 18), radius,
                                             fill=(31, 58, 95, 27))
    image.paste(Image.alpha_composite(image.convert('RGBA'), shadow.filter(ImageFilter.GaussianBlur(28))))
    mask = Image.new('L', shot.size)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, width - 1, height - 1), radius, fill=255)
    image.paste(shot, xy, mask)
    ImageDraw.Draw(image).rounded_rectangle((x, y, x + width - 1, y + height - 1), radius,
                                            outline=LINE, width=2)


def cover(lang):
    t, zh = TEXT[lang], lang == 'zh'
    image = Image.open(OUT / 'source/airflow.png').convert('RGB').resize((W, 1350), Image.Resampling.LANCZOS)
    # Fade the illustration into the white metric strip, leaving the brand artwork intact.
    fade = Image.new('L', (1, 1350))
    fade.putdata([round(255 * min(1, max(0, (y - 940) / 160))) for y in range(1350)])
    image.paste('white', (0, 0, W, 1350), fade.resize((W, 1350)))
    paste_asset(image, BRAND / 'logos/wordmark.png', (112, 90), 560)
    for i, line in enumerate(t['hero']):
        text(image, (112, 320 + i * 138), line, 108, 'bold', zh)
    text(image, (118, 650), t['sub'], 36, zh=zh, fill=MUTED)
    text(image, (118, 735), 'Windows · macOS · Linux', 34, fill=MUTED)
    paste_asset(image, BRAND / 'poses/default.png', (1510, 330), 640)
    draw = ImageDraw.Draw(image)
    draw.line((112, 1070, 2288, 1070), fill=LINE, width=2)
    for i, (number, label) in enumerate(t['metrics']):
        x = 112 + i * 560
        text(image, (x, 1110), number, 74, 'semibold', zh)
        text(image, (x + 2, 1216), label, 32, zh=zh, fill=MUTED)
    return image


def workspace(lang):
    t, zh = TEXT[lang], lang == 'zh'
    image = canvas(1160, SURFACE)
    draw = ImageDraw.Draw(image)
    draw.ellipse((1430, -670, 3020, 960), fill=PALETTE['mist'])
    text(image, (112, 90), t['hosts'], 84, 'bold', zh)
    text(image, (2288, 132), t['host_note'], 34, zh=zh, fill=MUTED, anchor='rt')
    shot = Image.open(OUT / f'hosts-{lang}-light.png').crop((0, 0, 2560, 800))
    frame(image, shot, (112, 320), 2176)
    text(image, (112, 1050), t['default'], 32, zh=zh, fill=MUTED)
    return image


def airy(lang):
    t, zh = TEXT[lang], lang == 'zh'
    image = canvas(1440, PALETTE['mist'])
    draw = ImageDraw.Draw(image)
    draw.ellipse((-740, 490, 1280, 2500), fill='white')
    text(image, (112, 90), t['airy'], 112, 'bold', zh)
    text(image, (116, 260), t['airy_sub'][0], 38, zh=zh, fill=MUTED)
    paste_asset(image, BRAND / 'poses/thinking-ai.png', (170, 400), 390)
    for i, (title, sub) in enumerate(t['airy_points']):
        y = 805 + i * 178
        text(image, (112, y), title, 54, 'semibold', zh)
        text(image, (114, y + 80), sub, 33, zh=zh, fill=MUTED)
    shot = Image.open(OUT / f'approval-{lang}-light.png').crop((1838, 90, 2560, 1176))
    frame(image, shot, (1390, 80), 830)
    return image


def themes(lang):
    t, zh = TEXT[lang], lang == 'zh'
    image = canvas(1540)
    text(image, (112, 70), t['themes'], 82, 'bold', zh)
    text(image, (2288, 112), t['themes_note'], 32, zh=zh, fill=MUTED, anchor='rt')
    for i, (folder, slug, en, chinese) in enumerate(THEMES):
        col, row = i % 3, i // 3
        x, y = 112 + col * 742, 270 + row * 600
        tokens = json.loads((PACK / folder / 'palette/palette.json').read_text(encoding='utf-8'))['tokens']
        draw = ImageDraw.Draw(image)
        draw.rounded_rectangle((x, y, x + 692, y + 552), 28, fill=tokens['surface'])
        text(image, (x + 32, y + 26), chinese if zh else en, 38, 'semibold', zh)
        # This close crop is from the real theme screenshot, not a drawn UI mockup.
        shot = Image.open(OUT / f'tiles/theme-{slug}.png').convert('RGB').crop((105, 220, 1320, 595))
        frame(image, shot, (x + 30, y + 118), 632, radius=12)
        paste_asset(image, PACK / folder / 'poses/default.png', (x + 35, y + 338), 210)
        for j, key in enumerate(('primary', 'sky', 'accent', 'mist')):
            cx, cy = x + 336 + j * 74, y + 424
            ImageDraw.Draw(image).ellipse((cx, cy, cx + 48, cy + 48), fill=tokens[key])
        text(image, (x + 338, y + 495), tokens['primary'].upper(), 26, fill=MUTED)
    return image


def bars(image, rows, x, y, width, maximum, ticks, unit, digits, step=140, label_width=245):
    draw = ImageDraw.Draw(image)
    left, plot_width = x + label_width, width - label_width - 170
    bottom = y + (len(rows) - 1) * step + 50
    for tick in ticks:
        px = left + plot_width * tick / maximum
        draw.line((px, y - 45, px, bottom), fill=LINE, width=2)
        text(image, (px, bottom + 25), f'{tick:g}', 27, fill=MUTED, anchor='mt')
    for i, (name, value) in enumerate(rows):
        cy = y + i * step
        text(image, (left - 28, cy), name, 34, 'semibold' if name == 'Sshairy' else 'regular', anchor='rm')
        end = left + plot_width * value / maximum
        draw.rounded_rectangle((left, cy - 11, end, cy + 11), 8,
                               fill=BLUE if name == 'Sshairy' else NEUTRAL)
        draw.rectangle((left, cy - 11, left + 7, cy + 11), fill=BLUE if name == 'Sshairy' else NEUTRAL)
        label = f'{value:.{digits}f}{unit}'
        text(image, (end + 20, cy), label, 34, 'semibold' if name == 'Sshairy' else 'regular', anchor='lm')


def performance(lang):
    t, zh = TEXT[lang], lang == 'zh'
    height = 750 + (len(START) - 1) * 104
    image = canvas(height, SURFACE)
    text(image, (112, 74), t['perf'], 86, 'bold', zh)
    text(image, (116, 204), t['perf_sub'], 35, zh=zh, fill=MUTED)
    ImageDraw.Draw(image).line((1200, 350, 1200, height - 80), fill=LINE, width=2)
    for x, title, subtitle in ((112, t['start'], t['start_unit']), (1300, t['memory'], t['mem_unit'])):
        text(image, (x, 350), title, 48, 'semibold', zh)
        text(image, (x, 425), subtitle, 29, zh=zh, fill=MUTED)
    start_limit = math.ceil(max(value for _, value in START) / 2) * 2
    memory_step = 500 if max(value for _, value in MEMORY) > 800 else 200
    memory_limit = math.ceil(max(value for _, value in MEMORY) / memory_step) * memory_step
    bars(image, START, 112, 570, 990, start_limit, range(0, start_limit + 1, 2), ' s', 2,
         step=104, label_width=260)
    bars(image, MEMORY, 1300, 570, 988, memory_limit, range(0, memory_limit + 1, memory_step), '', 1,
         step=104, label_width=260)
    return image


def footprint(lang):
    t, zh = TEXT[lang], lang == 'zh'
    height = max(1410, 708 + (len(DOWNLOAD) - 1) * 107)
    image = canvas(height)
    text(image, (112, 60), t['footprint'], 94, 'bold', zh)
    text(image, (116, 204), t['foot_sub'], 35, zh=zh, fill=MUTED)
    ImageDraw.Draw(image).line((1260, 360, 1260, height - 70), fill=LINE, width=2)
    text(image, (112, 340), t['download'], 48, 'semibold', zh)
    text(image, (116, 418), t['download_unit'], 29, zh=zh, fill=MUTED)
    bars(image, DOWNLOAD, 112, 558, 1068, 350, [0, 100, 200, 300], '', 1, step=107,
         label_width=250)
    text(image, (1380, 340), '97.4', 120, 'semibold')
    text(image, (1715, 421), f'MiB {t["unpacked"]}', 34, zh=zh, fill=MUTED)
    text(image, (1384, 520), t['content_title'], 40, 'semibold', zh)
    # Highlight the largest component against the remaining folder; details stay directly labelled.
    boundary = round(1384 + 880 * CONTENTS[0] / sum(CONTENTS))
    draw = ImageDraw.Draw(image)
    draw.rectangle((1384, 615, boundary - 3, 651), fill=BLUE)
    draw.rectangle((boundary + 3, 615, 2264, 651), fill=NEUTRAL)
    text(image, (1384, 665), f'{t["contents"][0]} · 54%', 25, zh=zh, fill=MUTED)
    text(image, (2264, 665), '其余 · 46%' if zh else 'Rest · 46%', 25, zh=zh, fill=MUTED, anchor='rt')
    for i, (label, value) in enumerate(zip(t['contents'], CONTENTS)):
        y = 718 + i * 78
        text(image, (1384, y), label, 32, 'semibold' if i == 0 else 'regular', zh)
        text(image, (2264, y), f'{value:.1f} MiB', 31, anchor='rt', fill=MUTED)
    text(image, (1384, 1130), t['specs'], 32, 'semibold', zh)
    for i, label in enumerate(t['native']):
        x = 1384 + i * 310
        ImageDraw.Draw(image).rounded_rectangle((x, 1225, x + 260, 1283), 12, fill=SURFACE)
        text(image, (x + 130, 1254), label, 29, anchor='mm')
        if i < 2:
            text(image, (x + 283, 1254), '›', 34, anchor='mm', fill=MUTED)
    text(image, (1384, 1325), t['native_note'], 29, zh=zh, fill=MUTED)
    return image


def main():
    assert round(sum(CONTENTS), 1) == 97.4
    for rows in (START, MEMORY, DOWNLOAD):
        assert len({name for name, _ in rows}) == len(rows)
        assert all(value > 0 for _, value in rows)
    for lang, folder in (('en', OUT), ('zh', OUT / 'zh')):
        folder.mkdir(parents=True, exist_ok=True)
        for name, render in (('cover', cover), ('workspace', workspace), ('airy', airy),
                             ('themes', themes), ('performance', performance), ('footprint', footprint)):
            image = render(lang)
            assert image.width == W and image.mode == 'RGB'
            image.save(folder / f'{name}.png', optimize=True)
            print(f'{lang}/{name}.png {image.width}x{image.height}')


if __name__ == '__main__':
    main()

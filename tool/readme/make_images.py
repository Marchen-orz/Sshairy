"""Draws the README pictures: hero, stat tiles, comparison charts and the architecture sketch.

  python -I -X utf8 make_images.py [brand_pack_dir] [output_dir]

Writes light and dark versions for English (output_dir) and Chinese (output_dir/zh).
The figures in the charts are the ones recorded in the README; the brand pack is only read.
"""

import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

REPO = Path(__file__).resolve().parents[2]
BRAND = Path(sys.argv[1]) if len(sys.argv) > 1 else REPO / 'Sshairy-Brand-Asset-Pack' / '01-IceBlue-Mint'
OUT = Path(sys.argv[2]) if len(sys.argv) > 2 else REPO / 'media'

FONTS = Path('C:/Windows/Fonts')
LIGHT = dict(bg='#F1F7FF', panel='#FFFFFF', border='#CDD7E4', ink='#1F3A5F', muted='#60738C',
             soft='#8A9CB4', accent='#2C71E8', wash='#E3EEFF', bar='#C9D4E3')
DARK = dict(bg='#121418', panel='#1C1F25', border='#2E323A', ink='#ECEEF2', muted='#A6ABB5',
            soft='#7C828E', accent='#3987E5', wash='#1B2433', bar='#3A414D')

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
        tagline='Lightweight SSH. Powered by AI.',
        sub='Native. Instant. Quiet on memory. And an agent that asks before it acts.',
        chips=['No Electron', 'No WebView', 'Dart AOT', 'Built-in agent'],
        tiles=[('0.62 s', 'to first window', 'warm start, empty profile'),
               ('131 MB', 'idle memory', 'whole process tree'),
               ('27 MB', 'download', 'Windows x64 ZIP'),
               ('1', 'process', 'native Dart AOT')],
        start=('Time to first window', 'Warm start, empty profile, median of 5 runs',
               'Measured on Windows 11 / Ryzen 7 8845HS, 2026-11-13, with tool/readme/measure_startup.py.'),
        memory=('Memory after launch', 'Unique set size of the whole process tree, no sessions open',
                'Measured on Windows 11 / Ryzen 7 8845HS, 2026-11-13, 15 s after the window appeared.'),
        download=('Windows download size', 'Installer or portable archive of the latest stable release, MiB',
                  'sshairy: own ZIP. Others: public release files read on 2026-11-13.'),
        inside=("What's inside the app folder", '97 MB unpacked, 27 MB compressed, MiB',
                '1,453 shell completion spec files are the largest part: content, not overhead.'),
        arch=('One process, no browser', 'Typical Electron SSH client', 'sshairy',
              ['Chromium renderer', 'Node.js main', 'GPU process', 'Network process', 'Utility process'],
              '5 processes - 447 MB measured (Netcatty 1.1.90)',
              ['Dart AOT app', 'Flutter engine'],
              '1 process - 131 MB measured (sshairy 0.1.0)'),
    ),
    'zh': dict(
        tagline='轻量 SSH,由 AI 驱动。',
        sub='原生运行,秒开,内存安静;AI 动手之前先问你。',
        chips=['不用 Electron', '不用 WebView', 'Dart AOT', '内置 Agent'],
        tiles=[('0.62 秒', '到首屏', '预热启动,空配置'),
               ('131 MB', '空闲内存', '整个进程树'),
               ('27 MB', '下载体积', 'Windows x64 ZIP'),
               ('1', '个进程', '原生 Dart AOT')],
        start=('到首屏时间', '预热启动、空配置,5 次取中位数',
               '2026-11-13 在 Windows 11 / Ryzen 7 8845HS 上实测,方法见 tool/readme/measure_startup.py。'),
        memory=('启动后内存', '整个进程树的独占内存,未开任何会话',
                '2026-11-13 在 Windows 11 / Ryzen 7 8845HS 上实测,窗口出现 15 秒后取值。'),
        download=('Windows 下载体积', '最新稳定版的安装包或便携包,MiB',
                  'sshairy 为自身 ZIP;其余为 2026-11-13 读取的公开发布文件。'),
        inside=('安装目录里有什么', '解压 97 MB,压缩后 27 MB,MiB',
                '最大一块是 1,453 个 Shell 补全规格:内容,不是开销。'),
        arch=('一个进程,不用浏览器', '典型 Electron SSH 客户端', 'sshairy',
              ['Chromium 渲染进程', 'Node.js 主进程', 'GPU 进程', '网络进程', '工具进程'],
              '5 个进程 · 实测 447 MB(Netcatty 1.1.90)',
              ['Dart AOT 应用', 'Flutter 引擎'],
              '1 个进程 · 实测 131 MB(sshairy 0.1.0)'),
    ),
}


def font(size, weight='regular', zh=False):
    if zh:
        name = 'msyhbd.ttc' if weight in ('bold', 'semibold') else 'msyh.ttc'
    else:
        name = {'regular': 'segoeui.ttf', 'bold': 'segoeuib.ttf', 'semibold': 'seguisb.ttf'}[weight]
    return ImageFont.truetype(str(FONTS / name), size)


def fit(draw, text, size, width, weight, zh, minimum=18):
    while size > minimum and draw.textlength(text, font=font(size, weight, zh)) > width:
        size -= 2
    return size


def wrap(draw, text, size, width, weight, zh):
    words = text.split(' ') if ' ' in text else list(text)
    joiner = ' ' if ' ' in text else ''
    lines, line = [], ''
    for word in words:
        candidate = f'{line}{joiner}{word}' if line else word
        if draw.textlength(candidate, font=font(size, weight, zh)) <= width:
            line = candidate
        else:
            lines.append(line)
            line = word
    return lines + [line]


def logo(path, height):
    image = Image.open(path).convert('RGBA')
    image = image.crop(image.getchannel('A').getbbox())
    width = round(image.width * height / image.height)
    return image.resize((width, height), Image.Resampling.LANCZOS)


def hero(theme, lang, t):
    W, H = 2400, 880
    image = Image.new('RGB', (W, H), theme['bg'])
    draw = ImageDraw.Draw(image)
    draw.ellipse((-380, 90, 1420, 1890), fill=theme['wash'])
    mascot = logo(BRAND / 'poses' / 'speed.png', 600)
    image.paste(mascot, (W - mascot.width - 170, (H - mascot.height) // 2 + 20), mascot)
    wordmark = 'dark/logos/wordmark.png' if theme is DARK else 'logos/wordmark.png'
    mark = logo(BRAND / wordmark, 132)
    image.paste(mark, (150, 148), mark)
    size = fit(draw, t['tagline'], 76, 1120, 'bold', lang == 'zh')
    draw.text((150, 330), t['tagline'], font=font(size, 'bold', lang == 'zh'), fill=theme['ink'])
    y = 470
    for line in wrap(draw, t['sub'], 38, 1050, 'regular', lang == 'zh'):
        draw.text((152, y), line, font=font(38, 'regular', lang == 'zh'), fill=theme['muted'])
        y += 56
    x = 150
    for chip in t['chips']:
        width = round(draw.textlength(chip, font=font(30, 'semibold', lang == 'zh'))) + 56
        draw.rounded_rectangle((x, y + 34, x + width, y + 110), radius=38, fill=theme['panel'],
                               outline=theme['border'], width=2)
        draw.text((x + width / 2, y + 72), chip, font=font(30, 'semibold', lang == 'zh'),
                  fill=theme['muted'], anchor='mm')
        x += width + 18
    return image


def tiles(theme, lang, t):
    W, H = 2400, 460
    image = Image.new('RGB', (W, H), theme['bg'])
    draw = ImageDraw.Draw(image)
    for index, (number, label, caption) in enumerate(t['tiles']):
        x = 40 + index * 580
        draw.rounded_rectangle((x, 30, x + 560, 430), radius=36, fill=theme['panel'],
                               outline=theme['border'], width=2)
        draw.text((x + 52, 76), number, font=font(104, 'bold'), fill=theme['accent'])
        draw.text((x + 52, 226), label, font=font(38, 'semibold', lang == 'zh'), fill=theme['ink'])
        size = fit(draw, caption, 28, 460, 'regular', lang == 'zh')
        draw.text((x + 52, 296), caption, font=font(size, 'regular', lang == 'zh'), fill=theme['muted'])
    return image


def step_for(maximum):
    raw = maximum / 4
    magnitude = 10 ** max(0, len(str(int(raw))) - 1)
    for step in (magnitude / 2, magnitude, magnitude * 2, magnitude * 5, magnitude * 10):
        if maximum / step <= 6:
            return max(step, 1)
    return maximum / 4


def chart(theme, folder, name, mode, lang, title, subtitle, rows, unit, footnote, decimals=1):
    row = 112
    top = 250
    bottom = top + row * len(rows) + 70
    H = bottom + 110
    W = 2400
    image = Image.new('RGB', (W, H), theme['bg'])
    draw = ImageDraw.Draw(image)
    draw.text((140, 64), title, font=font(56, 'bold', lang == 'zh'), fill=theme['ink'])
    draw.text((140, 146), subtitle, font=font(30, 'regular', lang == 'zh'), fill=theme['muted'])
    step = step_for(max(value for _, value, _ in rows))
    tick_max = step * (int(max(value for _, value, _ in rows) / step) + 1)
    left, right = 620, 2070
    scale = (right - left) / tick_max
    for tick in range(0, int(tick_max) + 1, int(step)):
        x = left + tick * scale
        draw.line((x, top - 40, x, bottom - 40), fill=theme['border'], width=1)
        draw.text((x, bottom - 10), f'{tick:g}', font=font(24, 'regular', lang == 'zh'),
                  fill=theme['soft'], anchor='mt')
    for index, (label, value, hero_row) in enumerate(rows):
        y = top + index * row + 40
        end = left + value * scale
        ink = theme['ink'] if hero_row else theme['muted']
        draw.rounded_rectangle((left, y - 12, end, y + 12), radius=12,
                               fill=theme['accent'] if hero_row else theme['bar'])
        draw.rectangle((left, y - 12, left + 12, y + 12),
                       fill=theme['accent'] if hero_row else theme['bar'])
        draw.text((left - 40, y), label, font=font(32, 'bold' if hero_row else 'regular', lang == 'zh'),
                  fill=ink, anchor='rm')
        value_text = f'{value:.{decimals}f} {unit}' if unit else f'{value:.{decimals}f}'
        draw.text((end + 22, y), value_text,
                  font=font(32, 'bold' if hero_row else 'regular', lang == 'zh'), fill=ink, anchor='lm')
    draw.text((140, H - 96), footnote, font=font(22, 'regular', lang == 'zh'), fill=theme['soft'])
    image.save(folder / f'{name}-{mode}.png', optimize=True)


def architecture(theme, folder, mode, lang, t):
    W, H = 2400, 980
    image = Image.new('RGB', (W, H), theme['bg'])
    draw = ImageDraw.Draw(image)
    title, left_title, right_title, boxes, left_note, own, right_note = t['arch']
    draw.text((140, 70), title, font=font(56, 'bold', lang == 'zh'), fill=theme['ink'])
    draw.rounded_rectangle((120, 220, 1180, 830), radius=40, fill=theme['panel'],
                           outline=theme['border'], width=2)
    draw.text((176, 268), left_title, font=font(32, 'semibold', lang == 'zh'), fill=theme['muted'])
    for index, box in enumerate(boxes):
        y = 350 + index * 78
        draw.rounded_rectangle((176, y, 1124, y + 58), radius=14, fill=theme['bar'])
        draw.text((206, y + 29), box, font=font(26, 'regular', lang == 'zh'),
                  fill=theme['ink'], anchor='lm')
    draw.text((176, 770), left_note, font=font(26, 'regular', lang == 'zh'), fill=theme['soft'])
    draw.rounded_rectangle((1220, 220, 2280, 830), radius=40, fill=theme['wash'],
                           outline=theme['accent'], width=3)
    draw.text((1276, 268), right_title, font=font(32, 'semibold', lang == 'zh'), fill=theme['muted'])
    for index, box in enumerate(own):
        y = 420 + index * 96
        draw.rounded_rectangle((1276, y, 2224, y + 72), radius=16, fill=theme['panel'],
                               outline=theme['border'], width=2)
        draw.text((1310, y + 36), box, font=font(30, 'semibold', lang == 'zh'),
                  fill=theme['ink'], anchor='lm')
    draw.text((1276, 770), right_note, font=font(26, 'regular', lang == 'zh'), fill=theme['soft'])
    image.save(folder / f'architecture-{mode}.png', optimize=True)


def main():
    for lang, folder in (('en', OUT), ('zh', OUT / 'zh')):
        folder.mkdir(parents=True, exist_ok=True)
        for mode, theme in (('light', LIGHT), ('dark', DARK)):
            t = TEXT[lang]
            hero(theme, lang, t).save(folder / f'hero-{mode}.png', optimize=True)
            tiles(theme, lang, t).save(folder / f'stats-{mode}.png', optimize=True)
            chart(theme, folder, 'start', mode, lang, *t['start'][:2], START, 's', t['start'][2], decimals=2)
            chart(theme, folder, 'memory', mode, lang, *t['memory'][:2], MEMORY, 'MB', t['memory'][2])
            chart(theme, folder, 'download', mode, lang, *t['download'][:2], DOWNLOAD, 'MB', t['download'][2])
            chart(theme, folder, 'inside', mode, lang, *t['inside'][:2], INSIDE, 'MB', t['inside'][2])
            architecture(theme, folder, mode, lang, t)


if __name__ == '__main__':
    main()

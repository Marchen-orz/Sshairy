// Timeline for film.html. seek(t) sets every animated value from the time alone, so frames can be
// rendered in any order. Scenes are cut on the bars of bgm.mp3 (109.96 BPM, first beat 17.46 s into the track).
(() => {
  const BAR = 240 / 109.96, B = BAR / 4, AUDIO_AT = 9.46, XF = 0.55, ASSETS = '../../site/assets';
  const THEMES = ['blue', 'green', 'violet', 'orange', 'deepSea', 'pink'];
  const TEXT = {
    en: {
      h1a: 'Lightweight SSH.', h1b: 'Powered by AI.', lede: 'A native SSH workspace for Windows, macOS and Linux.',
      sec: 's', proc: 'process', s0: 'to open', s1: 'at idle', s2: 'to download', s3: 'no browser engine',
      work: 'One window for <span class="k-serif">every</span> server.',
      f1: 'A host library that stays tidy', f1p: 'Groups, tags, pins and instant search.',
      f2: 'Completion with context', f2p: '1,453 shell specs, your history, and an AI suggestion on top.',
      f3: 'Dual-pane SFTP', f3p: 'Queues, resumable transfers, external editing.',
      f4: 'Metrics and tunnels', f4p: 'Live server stats over SSH. Local, remote and dynamic forwarding.',
      airy: 'Meet <span class="k-grad">Airy</span>.', airyLede: 'An assistant, right beside your terminal.',
      tiles: [['39', 'tools'], ['4', 'permission modes'], ['Your model', 'Anthropic or OpenAI-compatible']],
      modes: ['Observe', 'Confirm', 'Auto confirm', 'Full auto'],
      themes: 'Six ways to feel at home.',
      names: ['Ice Blue / Mint', 'Mint Green', 'Violet', 'Sunset Orange', 'Deep Sea Blue', 'Sakura Pink'],
      b1: 'Less waiting.', b2: 'More working.', tag: 'Lightweight SSH. Powered by AI.',
    },
    zh: {
      h1a: '轻量 SSH', h1b: '由 AI 驱动', lede: '面向 Windows、macOS、Linux 的原生 SSH 工作区',
      sec: '秒', proc: '个进程', s0: '启动', s1: '空闲内存', s2: '下载体积', s3: '无需浏览器内核',
      work: '所有服务器，一个窗口',
      f1: '井井有条的主机库', f1p: '分组、标签、置顶，随手搜索',
      f2: '懂命令的补全', f2p: '1,453 个 Shell 规格、命令历史，加一条 AI 建议',
      f3: '双栏 SFTP', f3p: '传输队列、断点续传、外部编辑',
      f4: '监控与隧道', f4p: '通过 SSH 查看服务器状态；本地、远程、动态端口转发',
      airy: '认识 <span class="k-grad">Airy</span>', airyLede: '终端旁边，多一个帮手',
      tiles: [['39', '个工具'], ['4', '档权限'], ['自选模型', 'Anthropic 或 OpenAI 兼容接口']],
      modes: ['观察', '确认', '自动确认', '全自动'],
      themes: '六种配色，换个心情',
      names: ['冰蓝薄荷', '薄荷绿', '紫罗兰', '落日橙', '深海蓝', '樱花粉'],
      b1: '少一点等待', b2: '多一点专注', tag: '轻量 SSH，由 AI 驱动',
    },
  };
  const q = new URLSearchParams(location.search);
  const lang = q.get('lang') === 'zh' ? 'zh' : 'en', t = TEXT[lang];
  const $ = (sel, root = document) => root.querySelector(sel), $$ = (sel, root = document) => [...root.querySelectorAll(sel)];
  const clamp = (x) => Math.min(1, Math.max(0, x));
  const out = (x) => 1 - (1 - clamp(x)) ** 4;
  const back = (x) => 1 + 2.4 * (clamp(x) - 1) ** 3 + 1.4 * (clamp(x) - 1) ** 2;
  const bob = (l, speed = 1.7, amp = 12) => Math.sin(l * speed) * amp;
  const num = (el, p) => (el.textContent = (el.dataset.count * out(p)).toFixed(el.dataset.digits));

  document.documentElement.lang = lang;
  $$('[data-t]').forEach((el) => (el.innerHTML = t[el.dataset.t]));
  $('#tiles').innerHTML = t.tiles.map(([n, label], i) => `<div class="tile" data-in="${[2, 4, 6][i] * B}" data-fx="pop" data-d="0.5"><b>${n}</b><span>${label}</span></div>`).join('');
  $('#modes').innerHTML = t.modes.map((mode, i) => `<span class="${i === 1 ? 'on' : ''}">${mode}</span>`).join('');
  $('#modes').dataset.in = 9 * B;
  $('#pals').innerHTML = THEMES.map((theme) => `<img data-theme="${theme}" data-brand="default" alt="">`).join('');
  $('#cmp').innerHTML = SshairyMock.term([SshairyMock.prompt('deploy', 'web-01') + '@@{cur|}']).replace('@@', '<span id="typed"></span>') + SshairyMock.part('completion', lang, { style: ' ' });
  SshairyMock.mount(document, ASSETS);
  SshairyCharts.mount(document, lang);
  const marks = THEMES.map((theme) => Object.assign(new Image(), { src: `${ASSETS}/brand/${theme}/mark.webp` }));

  // Headings rise word by word (character by character in Chinese); gradient text stays whole so its fill survives.
  $$('h1 [data-fx],h2[data-fx]').forEach((el) => {
    if (el.matches('.k-grad') || el.querySelector('.k-grad')) return;
    el.dataset.fx = 'words';
    const split = (node) => [...node.childNodes].forEach((child) => {
      if (child.nodeType !== 3) return split(child);
      const frag = document.createDocumentFragment();
      for (const piece of child.textContent.match(lang === 'zh' ? /\s+|./gu : /\s+|\S+/g) || []) {
        frag.append(/^\s+$/.test(piece) ? piece : Object.assign(document.createElement('span'), { className: 'w', textContent: piece }));
      }
      child.replaceWith(frag);
    });
    split(el);
  });
  const motes = Array.from({ length: 12 }, (_, i) => {
    const m = Object.assign(new Image(), { src: `${ASSETS}/brand/blue/${i % 3 ? 'sparkle' : 'cloud'}.svg`, className: 'mote' });
    $('#stage').insertBefore(m, $('#fade'));
    return m;
  });

  const scenes = $$('.scene');
  let END = 0;
  for (const s of scenes) {
    s._at = END;
    END += s.dataset.len ? +s.dataset.len : s.dataset.bars * BAR;
    s._end = END;
    s._fx = $$('[data-in]', s);
  }

  // Scenes cut with a camera move instead of a dissolve: slides alternate sides, 'zoom' scenes push through.
  function move(s, k, time, l) {
    const zoom = s.dataset.tr === 'zoom', e = s._at ? out((time - s._at) / XF) : 1;
    const enter = zoom ? `scale(${1.22 - 0.22 * e})` : `translateX(${(1 - e) * (k % 2 ? -100 : 100)}%)`;
    const next = scenes[k + 1], p = next ? out((time - s._end) / XF) : 0;
    let exit = '', fade = 1;
    if (next && time > s._end) {
      if (next.dataset.tr === 'zoom') { exit = `scale(${1 - 0.14 * p})`; fade = 1 - p; }
      else exit = `translateX(${p * ((k + 1) % 2 ? 32 : -32)}%) scale(${1 - 0.06 * p})`;
    }
    s.style.transform = `${exit} ${enter} scale(${1 + (0.035 * l) / (s._end - s._at)})`;
    s.style.opacity = (zoom ? e : 1) * fade;
    s.style.filter = (zoom && e < 1) || fade < 1 ? `blur(${Math.max(1 - e, 1 - fade) * 16}px)` : '';
  }

  function fx(el, l) {
    const raw = clamp((l - el.dataset.in) / (el.dataset.d || 0.7)), p = out(raw), kind = el.dataset.fx;
    if (kind === 'words') {
      el.style.opacity = l >= el.dataset.in ? 1 : 0;
      $$('.w', el).forEach((w, i) => {
        const r = clamp((l - el.dataset.in - i * (lang === 'zh' ? 0.035 : 0.07)) / 0.55), q = out(r);
        w.style.opacity = clamp(r * 2.5);
        w.style.transform = `translateY(${(1 - q) * 0.8}em) rotate(${(1 - q) * 7}deg)`;
        w.style.filter = q < 1 ? `blur(${(1 - q) * 8}px)` : '';
      });
      return;
    }
    el.style.opacity = clamp(raw * 3);
    el.style.transform = kind === 'up' ? `translateY(${(1 - p) * 50}px)`
      : kind === 'rise' ? `perspective(1800px) translateY(${(1 - p) * 120}px) rotateX(${(1 - p) * 26}deg) rotateY(${Math.sin(l * 0.7) * 2.2}deg) scale(${0.9 + 0.1 * p})`
      : kind === 'pop' ? `scale(${0.6 + 0.4 * back(raw)}) rotate(${(1 - p) * -8}deg)` : kind === 'blur' ? `scale(${1.1 - 0.1 * p})` : '';
    if (kind === 'blur') el.style.filter = `blur(${(1 - p) * 18}px)`;
  }

  const perf = (l, s) => {
    num($('[data-count]', s), (l - 0.05) / 0.8);
    $$('.k-bar', s).forEach((row, i) => {
      const a = 0.2 + i * 0.07, raw = clamp((l - a) / 0.5);
      row.style.opacity = clamp(raw * 3);
      row.style.transform = `translateX(${(1 - out(raw)) * -34}px)`;
      row.style.setProperty('--grow', out((l - a) / 0.9));
      const versus = $('.x', row);
      if (versus) versus.style.opacity = s.id === 'p1' ? clamp((l - 5 * B - i * 0.05) / 0.3) : 0;
    });
  };
  const U = {
    intro(l, s) {
      $('.air', s).style.transform = `scale(${1.1 - 0.1 * clamp(l / 8)})`;
      const p = out((l - 0.3) / 1.6), m = $('.mascot', s);
      m.style.opacity = clamp((l - 0.3) * 2);
      m.style.transform = `translate(${(1 - p) * 420}px,${bob(l) - (1 - p) * 60}px) rotate(${(1 - p) * 10}deg)`;
    },
    stats(l, s) {
      $$('.big', s).forEach((el, i) => {
        const a = i * 2 * B, raw = clamp((l - a) / 0.45), p = out(raw), gone = i < 3 ? clamp((l - a - 2 * B + 0.16) / 0.16) : 0;
        el.style.opacity = clamp(raw * 3) * (1 - gone);
        el.style.transform = `translateY(${-gone * 70}px) scale(${1.3 - 0.3 * p})`;
        el.style.filter = `blur(${(1 - p) * 16}px)`;
        const n = $('[data-count]', el);
        if (n) num(n, (l - a) / 0.5);
      });
      $('.zoom', s).style.transform = `translate(${-380 + 2500 * clamp(l / (2 * BAR))}px,${bob(l, 6, 7)}px)`;
    },
    work(l, s) {
      $$('.sa-term', s).forEach((pane, k) => [...pane.children].forEach((row, i) => (row.style.visibility = l >= [0.5 + i * 0.07, 0.9 + i * 0.3, 1.4 + i * 0.13][k] ? '' : 'hidden')));
      $('.que .sa-q u i', s).style.width = `${64 * out((l - 3.0) / 1.2)}%`;
      $$('.mon .sa-bar i', s).forEach((bar) => (bar.style.transform = `scaleX(${out((l - 2.3) / 0.8)})`));
    },
    f1(l, s) {
      $$('.sa-card', s).forEach((card, i) => {
        const raw = clamp((l - 0.3 - i * 0.05) / 0.4);
        card.style.opacity = clamp(raw * 3);
        card.style.transform = `scale(${0.8 + 0.2 * back(raw)})`;
        card.classList.toggle('on', i === 1 && l >= 2 * B);
      });
    },
    f2(l, s) {
      $('#typed').textContent = 'systemctl '.slice(0, Math.round(clamp((l - 0.25) / 0.6) * 10));
      const pop = $('.sa-pop', s), raw = clamp((l - 1.0) / 0.35);
      pop.style.opacity = clamp(raw * 3);
      pop.style.transform = `translateY(${(1 - out(raw)) * 16}px)`;
      // The selection starts on the first spec entry, then moves up to the AI suggestion.
      $$('.sa-cmp > div', s).forEach((row, i) => row.classList.toggle('on', i === (l < 3 * B ? 1 : 0)));
    },
    f3(l, s) {
      $$('.sa-fr', s).forEach((row, i) => (row.style.opacity = clamp((l - 0.3 - (i % 8) * 0.04) / 0.25)));
      $$('.sa-q u i', s).forEach((bar, i) => (bar.style.width = `${[64, 100][i] * out((l - 0.4) / [1.7, 1][i])}%`));
    },
    f4(l, s) {
      $$('.sa-bar i', s).forEach((bar) => (bar.style.transform = `scaleX(${out((l - 0.3) / 0.9)})`));
      $$('.spark', s).forEach((spark) => (spark.style.clipPath = `inset(0 ${(1 - out((l - 0.3) / 1.1)) * 100}% 0 0)`));
      $$('.sa-fw', s).forEach((row, i) => {
        const raw = clamp((l - 0.45 - i * 0.2) / 0.5);
        row.style.opacity = clamp(raw * 3);
        row.style.transform = `translateY(${(1 - out(raw)) * 20}px)`;
      });
    },
    airy(l, s) {
      // Two renders of the panel: waiting for approval, then after it ran. The cut is on beat 12.
      const [ask, done] = $$('.panel .sa-part', s), flip = l >= 12 * B;
      ask.style.visibility = flip ? 'hidden' : '';
      done.style.visibility = flip ? '' : 'hidden';
      const reveal = (root, beats) => [...$('.sa-chat', root).children].forEach((step, i) => {
        const raw = clamp((l - beats[i] * B) / 0.3);
        step.style.display = l >= beats[i] * B ? '' : 'none';
        step.style.opacity = clamp(raw * 2.5);
        step.style.transform = `translateY(${(1 - out(raw)) * 14}px)`;
      });
      reveal(ask, [1, 3, 4, 6, 8]);
      reveal(done, [0, 0, 0, 0, 12, 13]);
      const press = Math.sin(Math.PI * clamp((l - 11 * B) / 0.3));
      $('.sa-ok .sa-btn:not(.ghost)', ask).style.transform = `scale(${1 - 0.09 * press})`;
      $$('.mascot', s).forEach((m, i) => {
        m.style.opacity = i ? +flip : +!flip;
        m.style.transform = `translateY(${bob(l, 1.8, 10)}px) scale(${i ? 0.8 + 0.2 * back((l - 12 * B) / 0.5) : 1})`;
      });
    },
    themes(l, s) {
      // A new theme every two beats; the second beat shows its dark side.
      const k = Math.min(5, Math.floor(l / (2 * B))), dark = Math.floor(l / B) % 2, key = k * 2 + dark;
      if (s._key !== key) {
        s._key = key;
        s.dataset.theme = THEMES[k];
        $('.sa', s).dataset.mode = dark ? 'dark' : 'light';
        $('#themeName').textContent = t.names[k];
        SshairyMock.paint(s, ASSETS);
      }
      $('.win', s).style.transform += ` scale(${1 + 0.014 * Math.exp(-7 * ((l % B) / B))})`;
      $$('.pals img', s).forEach((img, i) => {
        img.style.opacity = i === k ? 1 : 0.38;
        img.style.transform = i === k ? `translateY(-16px) scale(${1 + 0.28 * back((l - k * 2 * B) / 0.4)})` : '';
      });
    },
    p1: perf, p2: perf, p3: perf,
    outro(l, s) {
      const m = $('.mascot', s), raw = clamp(l / 0.6);
      m.style.opacity = clamp(raw * 3);
      m.style.transform = `translateY(${bob(l, 2, 10)}px) scale(${0.7 + 0.3 * back(raw)})`;
    },
  };

  function seek(time) {
    for (const s of scenes) {
      const on = time >= s._at && time < s._end + XF;
      s.style.visibility = on ? 'visible' : 'hidden';
      if (!on) continue;
      // A scene holds its last frame while the next one moves in over it.
      const l = Math.min(time, s._end - 0.001) - s._at;
      move(s, scenes.indexOf(s), time, l);
      for (const el of s._fx) fx(el, l);
      U[s.id]?.(l, s);
    }
    $('#fade').style.opacity = clamp((time - END + 0.8) / 0.7);
    // Sparkles drift across every cut, so the camera never feels parked.
    motes.forEach((m, i) => {
      const x = ((i * 0.137 + time * (0.018 + (i % 4) * 0.007)) % 1.2) - 0.1;
      m.style.transform = `translate(${x * 1920}px,${(0.08 + ((i * 0.381) % 0.86)) * 1080 + Math.sin(time * 0.9 + i) * 30}px) rotate(${time * (i % 2 ? 40 : -30)}deg) scale(${0.5 + (i % 3) * 0.3})`;
    });
  }

  window.FILM = { end: END, audioAt: AUDIO_AT, marks };
  window.seek = async (time) => {
    seek(time);
    await Promise.all([...document.images].filter((img) => !img.complete).map((img) => img.decode().catch(() => {})));
  };

  const stage = $('#stage');
  const fit = () => (stage.style.transform = `scale(${Math.min(innerWidth / 1920, innerHeight / 1080)})`);
  addEventListener('resize', fit);
  fit();
  if (q.has('t') || q.has('render')) seek(+q.get('t') || 0);
  else {
    seek(7.5);
    const audio = new Audio('bgm.mp3');
    stage.style.cursor = 'pointer';
    stage.onclick = () => {
      if (!audio.paused) return audio.pause();
      const now = audio.currentTime - AUDIO_AT;
      if (now < 0 || now >= END) audio.currentTime = AUDIO_AT;
      audio.play();
      const tick = () => {
        seek(audio.currentTime - AUDIO_AT);
        if (audio.currentTime - AUDIO_AT >= END) audio.pause();
        if (!audio.paused) requestAnimationFrame(tick);
      };
      requestAnimationFrame(tick);
    };
  }
})();

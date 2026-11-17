// Landing page behaviour: language, theme, the interface tour, the Airy demo and the charts.
(() => {
  // Every outbound link is built from this one line.
  const REPO = 'https://github.com/Marchen-orz/sshairy';
  const THEMES = ['blue', 'green', 'violet', 'orange', 'deepSea', 'pink'];
  const TOUR = ['terminal', 'hosts', 'files', 'monitor', 'completion', 'inline', 'palette', 'forwards'];
  const T = {
    en: {
      title: 'Sshairy · Lightweight SSH. Powered by AI.',
      nTour: 'Tour', nPerf: 'Performance', nDocs: 'Docs', nGet: 'Download',
      h1a: 'Lightweight SSH.', h1b: 'Powered by AI.',
      lede: 'Terminals, SFTP, tunnels and server monitoring in one modern native window with clean, fluid tabs, splits and panels; AI is part of the workflow.',
      dl: { win: 'Download for Windows', mac: 'Download for macOS', linux: 'Download for Linux' }, src: 'View source',
      fine: 'Preview 0.2.0 · Windows, macOS and Linux · MIT License',
      stats: [['0.62', 's', 'to open'], ['131', 'MiB', 'at idle'], ['27', 'MiB', 'to download'], ['1', 'process', 'no browser engine']],
      tourH: 'One window for <span class="k-serif">every</span> server.',
      tabs: ['Terminals', 'Hosts', 'Files', 'Monitor', 'Completion', 'Inline AI', 'Palette', 'Forwarding'],
      feats: [
        ['server', 'Connect', 'Hosts in groups with tags, pins and search. Password and key sign-in, Ed25519 keys, jump hosts and proxies.'],
        ['term', 'Work', 'Tabbed terminals, draggable splits, local shells, search, reconnect and restored layouts.'],
        ['files', 'Move files', 'Dual-pane SFTP, transfer queues, resumable transfers, conflict handling and external editing.'],
        ['log', 'Keep watch', 'CPU, memory, disk and processes over SSH, with nothing to install on the server.'],
        ['route', 'Reach further', 'Local, remote and dynamic port forwarding. Snippets and 1,453 shell completion specs.'],
        ['shield', 'Stay in control', 'Modern native interface with fluid tabs, splits and panels; host-key verification, OS-backed credential storage, English and Chinese, custom shortcuts.'],
      ],
      airyH: 'Meet <span class="k-grad">Airy</span>.',
      airyP: 'The AI assistant beside your terminal, with 39 tools for hosts, remote files, commands, sessions, layouts and settings. Bring your own Anthropic or OpenAI-compatible model.',
      ways: [['Agent', 'Describe a task and Airy works through it step by step.'], ['Inline commands', 'A plain-language request becomes a command you can edit before it runs.'], ['AI completion', 'Suggestions as you type, next to shell specs and your history.']],
      modes: ['Observe', 'Confirm', 'Auto confirm', 'Full auto'],
      hints: ['Read-only tools, and you approve each read.', 'You approve every read and every command. The default.', 'A separate model reviews each action and asks you when unsure.', 'Reads, runs and shares results without asking.'],
      replay: 'Replay', themesH: 'Six ways to feel at home.', light: 'Light', dark: 'Dark', theme: 'Theme',
      names: ['Ice Blue / Mint', 'Mint Green', 'Violet', 'Sunset Orange', 'Deep Sea Blue', 'Sakura Pink'],
      perfH: 'Less waiting. More working.',
      perfP: 'Against nine other popular SSH clients, Sshairy starts faster and uses less memory.',
      sec: 's', startup: 'to open', memory: 'at idle', download: 'to download', unpacked: 'unpacked',
      parts: ['Shell completions', 'Flutter engine', 'App code · AOT', 'Brand artwork', 'Other files'],
      pills: ['One app process', 'No Chromium', 'No WebView'],
      tableS: 'Full comparison', cols: ['Client', 'Startup', 'Idle memory', 'Download'],
      filmH: 'Fifty-seven seconds of Sshairy.',
      getH: 'Get Sshairy.', winP: 'Installer or single-file portable app for 64-bit Windows.', winB: 'Download · 27 MiB',
      macP: 'Universal DMG for Apple silicon and Intel. Early build.', linuxP: 'AppImage and .deb for x64. Early build.', osB: 'Download →', getB: 'Download',
      copy: 'Copy', copied: 'Copied', or: '# or macos, linux',
      docsH: 'Docs.', read: 'Read', soon: 'Coming soon',
      docs: [['Getting started', 'Install, add your first host and open a session.'], ['Build from source', 'Toolchain, commands and Windows packaging.'], ['Guides', 'Airy, permissions, themes and shortcuts.']],
      foot: 'Lightweight SSH. Powered by AI.', scheme: 'Dark mode', rel: 'Releases', issues: 'Issues', buddy: 'Next theme',
    },
    zh: {
      title: 'Sshairy · 轻量 SSH，AI 加持',
      nTour: '导览', nPerf: '性能', nDocs: '文档', nGet: '下载',
      h1a: '轻量 SSH', h1b: 'AI 加持',
      lede: '终端、SFTP、端口转发和服务器监控收进同一个现代原生窗口：界面清爽，分屏、标签与面板切换顺手；AI 融进日常 SSH 工作流',
      dl: { win: '下载 Windows 版', mac: '下载 macOS 版', linux: '下载 Linux 版' }, src: '查看源码',
      fine: '预览版 0.2.0 · Windows、macOS 与 Linux · MIT 许可证',
      stats: [['0.62', '秒', '启动'], ['131', 'MiB', '空闲内存'], ['27', 'MiB', '下载体积'], ['1', '个进程', '无需浏览器内核']],
      tourH: '所有服务器，一个窗口',
      tabs: ['终端', '主机', '文件', '监控', '补全', '行内 AI', '命令面板', '端口转发'],
      feats: [
        ['server', '连接', '主机分组、标签、置顶、搜索；密码与密钥认证，生成 Ed25519 密钥，支持跳板与代理'],
        ['term', '终端', '多标签、拖放分屏、本地 Shell、搜索、重连与布局恢复'],
        ['files', '文件', '双栏 SFTP、传输队列、断点续传、冲突处理与外部编辑器'],
        ['log', '监控', '通过 SSH 查看 CPU、内存、磁盘与进程，服务器无需安装任何东西'],
        ['route', '工具', '本地、远程、动态端口转发；命令片段和 1,453 个 Shell 补全规格'],
        ['shield', '体验', '现代原生界面，分屏、标签与面板切换顺手；主机密钥校验、系统凭据存储、中英文界面与自定义快捷键'],
      ],
      airyH: '认识 <span class="k-grad">Airy</span>',
      airyP: 'Airy 就在终端旁边，是一位 AI 助手，配备 39 个工具，可管理主机、远端文件、命令、会话、布局与设置；接入你自己的 Anthropic 或 OpenAI 兼容模型',
      ways: [['Agent', '说出任务，Airy 一步步处理'], ['行内命令', '一句自然语言变成命令，运行前可以修改'], ['AI 补全', '边输入边给建议，和 Shell 规格、命令历史排在一起']],
      modes: ['观察', '确认', '自动确认', '全自动'],
      hints: ['只用只读工具，每次读取由你批准', '读取和命令都由你批准，默认模式', '由另一个模型审核每个操作，拿不准时再问你', '读取、执行、使用结果，全程不再询问'],
      replay: '重播', themesH: '六种配色，换个心情', light: '浅色', dark: '深色', theme: '主题',
      names: ['冰蓝薄荷', '薄荷绿', '紫罗兰', '落日橙', '深海蓝', '樱花粉'],
      perfH: '打开就用',
      perfP: '与另外九款常用 SSH 客户端对比，启动更快、占用更低',
      sec: '秒', startup: '启动', memory: '空闲内存', download: '下载体积', unpacked: '解压后',
      parts: ['Shell 补全规格', 'Flutter 引擎', 'AOT 应用代码', '品牌素材', '其余文件'],
      pills: ['单个应用进程', '无 Chromium', '无 WebView'],
      tableS: '完整对比', cols: ['客户端', '启动', '空闲内存', '下载体积'],
      filmH: '57 秒，看完 Sshairy',
      getH: '获取 Sshairy', winP: '64 位 Windows 安装包或单文件便携版', winB: '下载 · 27 MiB',
      macP: '通用 DMG，支持 Apple 芯片与 Intel，早期构建', linuxP: 'x64 的 AppImage 与 .deb，早期构建', osB: '下载 →', getB: '下载',
      copy: '复制', copied: '已复制', or: '# 或 macos、linux',
      docsH: '文档', read: '阅读', soon: '即将补充',
      docs: [['快速开始', '安装、添加第一台主机、打开会话'], ['从源码构建', '工具链、命令与 Windows 打包'], ['使用指南', 'Airy、权限、主题与快捷键']],
      foot: '轻量 SSH，AI 加持', scheme: '深色模式', rel: '发布', issues: '问题反馈', buddy: '换个主题',
    },
  };
  const DOC_LINKS = ['#readme', 'blob/main/README.md#get-sshairy', null];

  const root = document.documentElement;
  const $ = (sel, el = document) => el.querySelector(sel), $$ = (sel, el = document) => [...el.querySelectorAll(sel)];
  const still = matchMedia('(prefers-reduced-motion: reduce)').matches;
  const store = (key, value) => { try { if (value === undefined) return localStorage.getItem(key); localStorage.setItem(key, value); } catch { return null; } };
  const link = (path) => REPO + (!path ? '' : path[0] === '#' ? path : '/' + path);
  let lang = store('lang') || (navigator.language.startsWith('zh') ? 'zh' : 'en');
  let theme = THEMES.includes(store('theme')) ? store('theme') : 'blue';
  const platform = navigator.userAgentData?.platform || navigator.platform || '';
  const os = /mac/i.test(platform) ? 'mac' : /linux|x11/i.test(platform) && !/android/i.test(navigator.userAgent) ? 'linux' : 'win';
  // The head script already set data-scheme from the stored choice or the system.
  const night = matchMedia('(prefers-color-scheme: dark)');
  let scheme = root.dataset.scheme === 'dark' ? 'dark' : 'light';
  let tour = 0, mode = 1, dark = scheme === 'dark', toured = false, chatSeen = false, timers = [];
  root.classList.add('js');
  if (!still) root.classList.add('intro');
  root.dataset.theme = theme;

  const press = (box, on) => $$('button', box).forEach((button, i) => button.setAttribute(button.hasAttribute('aria-selected') ? 'aria-selected' : 'aria-pressed', on(button, i)));
  const fit = () => $$('.shot').forEach((shot) => ($('.k-win', shot).style.zoom = Math.max(0.5, Math.min(1.25, shot.clientWidth / 1280))));

  // One pill per tab strip or segmented control glides to the selected button.
  function slide(box, animate = true) {
    const on = $('[aria-selected="true"],[aria-pressed="true"]', box);
    let pill = $('.pill', box);
    if (!on) return;
    if (!pill) { pill = box.appendChild(document.createElement('i')); pill.className = 'pill'; animate = false; }
    box.classList.add('slid');
    if (!animate) pill.style.transition = 'none';
    Object.assign(pill.style, { width: on.offsetWidth + 'px', height: on.offsetHeight + 'px', translate: `${on.offsetLeft}px ${on.offsetTop}px` });
    if (!animate) { void pill.offsetWidth; pill.style.transition = ''; }
  }
  const slideAll = () => ['#tabs', '#modes', '#mode'].forEach((id) => slide($(id), false));

  // Theme and language changes reveal from the click as a growing circle; keyboard presses grow from the control.
  function spread(event, from, update) {
    if (still || !document.startViewTransition) return update();
    const box = from.getBoundingClientRect();
    const x = event.detail ? event.clientX : box.left + box.width / 2, y = event.detail ? event.clientY : box.top + box.height / 2;
    const r = Math.hypot(Math.max(x, innerWidth - x), Math.max(y, innerHeight - y));
    const shown = () => {
      update();
      // New theme artwork loads first so the circle never reveals empty images.
      const loading = $$('img').filter((img) => !img.complete && img.getBoundingClientRect().bottom > 0 && img.getBoundingClientRect().top < innerHeight);
      return Promise.race([Promise.all(loading.map((img) => img.decode().catch(() => {}))), new Promise((done) => setTimeout(done, 400))]);
    };
    document.startViewTransition(shown).ready.then(() => root.animate(
      { clipPath: [`circle(0 at ${x}px ${y}px)`, `circle(${r}px at ${x}px ${y}px)`] },
      { duration: 680, easing: 'cubic-bezier(.4,0,.2,1)', pseudoElement: '::view-transition-new(root)' },
    )).catch(() => {});
  }

  function windows() {
    const look = { mode: dark ? 'dark' : 'light' };
    $('#tourWin').innerHTML = SshairyMock.scene(TOUR[tour], lang, look);
    $('#themeWin').innerHTML = SshairyMock.scene('hosts', lang, { ...look, h: 500 });
    SshairyMock.paint(document);
  }

  function setTheme(next) {
    theme = next;
    root.dataset.theme = theme;
    store('theme', theme);
    press($('#dots'), (button) => button.dataset.theme === theme);
    press($('#pals'), (button) => button.dataset.theme === theme);
    SshairyMock.paint(document);
  }

  // The Airy panel plays its steps one by one; Approve once shows what happens next.
  function playChat(state) {
    timers.forEach(clearTimeout);
    timers = [];
    const box = $('#chat');
    box.innerHTML = SshairyMock.part('airy', lang, { state: chatSeen ? state : 'idle' });
    $('#airyMascot').dataset.brand = state === 'done' ? 'success' : 'thinking-ai';
    SshairyMock.paint($('#airy'));
    $$('.sa-ok .sa-btn', box).forEach((button) => { button.tabIndex = 0; button.setAttribute('role', 'button'); });
    if (still) return;
    [...$('.sa-chat', box).children].slice(state === 'done' ? 4 : 0).forEach((step, i) => {
      step.classList.add('wait', 'pre');
      timers.push(setTimeout(() => {
        step.classList.remove('wait');
        requestAnimationFrame(() => requestAnimationFrame(() => step.classList.remove('pre')));
      }, 350 + i * 750));
    });
  }

  function count(el) {
    const end = +el.dataset.n, digits = (el.dataset.n.split('.')[1] || '').length, from = performance.now();
    if (still || (end <= 1 && !digits)) return;
    const step = (now) => {
      const p = Math.min(1, (now - from) / 900);
      el.textContent = (end * (1 - (1 - p) ** 4)).toFixed(digits);
      if (p < 1) requestAnimationFrame(step);
    };
    requestAnimationFrame(step);
  }

  function render() {
    const t = T[lang], d = window.SSHAIRY_DATA;
    root.lang = lang === 'zh' ? 'zh-CN' : 'en';
    document.title = t.title;
    $$('[data-i]').forEach((el) => (el.innerHTML = t[el.dataset.i]));
    $('#lang').textContent = lang === 'zh' ? 'EN' : '中文';
    $('#dlLabel').textContent = t.dl[os];
    $$('img[data-brand^="wordmark"]').forEach((img) => (img.dataset.brand = scheme === 'dark' ? 'wordmark-dark' : 'wordmark'));
    $('#chat').dataset.mode = scheme;
    $('#scheme').setAttribute('aria-label', t.scheme);
    $('#scheme').setAttribute('aria-pressed', scheme === 'dark');
    $('meta[name="theme-color"]').content = scheme === 'dark' ? '#0B0E13' : '#F1F7FF';
    $('#dots').setAttribute('aria-label', t.theme);
    $('#replay').setAttribute('aria-label', t.replay);
    $('#buddy').setAttribute('aria-label', t.buddy);
    $('#stats').innerHTML = t.stats.map(([n, unit, label]) => `<div class="stat"><b><span data-n="${n}">${n}</span><small>${unit}</small></b><span>${label}</span></div>`).join('');
    $('#tabs').innerHTML = t.tabs.map((label, i) => `<button type="button" role="tab" aria-selected="${i === tour}">${label}</button>`).join('');
    $('#feats').innerHTML = t.feats.map(([icon, title, text], i) => `<div class="feat" style="--i:${i}"><i>${SshairyMock.icon(icon, 20)}</i><h3>${title}</h3><p>${text}</p></div>`).join('');
    $('#ways').innerHTML = t.ways.map(([title, text]) => `<li><b>${title}</b><span>${text}</span></li>`).join('');
    $('#modes').innerHTML = t.modes.map((label, i) => `<button type="button" aria-pressed="${i === mode}">${label}</button>`).join('');
    $('#modeHint').textContent = t.hints[mode];
    $('#mode').innerHTML = [t.light, t.dark].map((label, i) => `<button type="button" aria-pressed="${!!i === dark}">${label}</button>`).join('');
    $('#dots').innerHTML = THEMES.map((name, i) => `<button type="button" data-theme="${name}" aria-pressed="${name === theme}" aria-label="${t.names[i]}" title="${t.names[i]}"></button>`).join('');
    $('#pals').innerHTML = THEMES.map((name, i) => `<button type="button" class="pal" style="--i:${i}" data-theme="${name}" aria-pressed="${name === theme}"><img data-brand="default" alt="">${t.names[i]}<i>${['primary', 'sky', 'accent'].map((k) => `<u style="background:var(--b-${k})"></u>`).join('')}</i></button>`).join('');
    $('#stack').innerHTML = d.contents.map((v, i) => `<i style="--v:${v};--o:${[1, 1, 0.72, 0.5, 0.34][i]}"></i>`).join('');
    $('#parts').innerHTML = d.contents.map((v, i) => `<div><u style="opacity:${[1, 1, 0.72, 0.5, 0.34][i]}"></u><span>${t.parts[i]}</span><em>${v.toFixed(1)} MiB</em></div>`).join('');
    $('#pills').innerHTML = t.pills.map((pill) => `<span>${pill}</span>`).join('');
    const find = (rows, name) => rows.find((row) => row[0] === name)?.[1];
    $('#table').innerHTML = `<table><tr>${t.cols.map((col) => `<th>${col}</th>`).join('')}</tr>${d.startup.map(([name, s]) => {
      const size = find(d.download, name);
      return `<tr class="${name === 'Sshairy' ? 'me' : ''}"><td>${name}</td><td>${s.toFixed(2)} ${t.sec}</td><td>${find(d.memory, name).toFixed(1)} MiB</td><td>${size ? size.toFixed(1) + ' MiB' : '–'}</td></tr>`;
    }).join('')}</table>`;
    $('#docCards').innerHTML = t.docs.map(([title, text], i) => DOC_LINKS[i]
      ? `<a class="doc" style="--i:${i}" href="${link(DOC_LINKS[i])}"><b>${title}</b><span>${text}</span><em>${t.read} →</em></a>`
      : `<div class="doc" style="--i:${i}"><b>${title}</b><span>${text}</span><em>${t.soon}</em></div>`).join('');
    // The visitor's platform leads the download cards.
    const latest = link('releases/latest');
    $('#osCards').innerHTML = [['win', 'Windows', t.winP], ['mac', 'macOS', t.macP], ['linux', 'Linux', t.linuxP]]
      .sort((a, b) => (b[0] === os) - (a[0] === os))
      .map(([key, name, text], i) => key === os
        ? `<article class="os main" style="--i:${i}"><h3>${name}</h3><p>${text}</p><a class="btn big" href="${latest}">${key === 'win' ? t.winB : t.getB}</a></article>`
        : `<article class="os" style="--i:${i}"><h3>${name}</h3><p>${text}</p><a class="more" href="${latest}">${t.osB}</a></article>`).join('');
    $('#steps').innerHTML = `git clone ${REPO}.git\ncd sshairy\nflutter pub get\nflutter run -d windows  <span class="c">${t.or}</span>`;
    $('#copy').textContent = t.copy;
    const video = $('#video'), film = `media/sshairy-${lang}.mp4`;
    if (video.getAttribute('src') !== film) {
      video.poster = `media/poster-${lang}.jpg`;
      video.src = film;
    }
    $$('[data-href]').forEach((a) => (a.href = link(a.dataset.href)));
    SshairyCharts.mount(document, lang);
    windows();
    playChat('ask');
    fit();
    slideAll();
  }

  const pick = (id, act) => $(id).addEventListener('click', (event) => {
    const button = event.target.closest('button');
    if (button) act($$('button', $(id)).indexOf(button), button, event);
  });
  pick('#tabs', (i) => { tour = i; toured = true; press($('#tabs'), (_, k) => k === tour); slide($('#tabs')); windows(); });
  pick('#modes', (i) => { mode = i; press($('#modes'), (_, k) => k === mode); slide($('#modes')); $('#modeHint').textContent = T[lang].hints[mode]; });
  pick('#mode', (i, button, event) => {
    if (!!i === dark) return;
    dark = !!i;
    press($('#mode'), (_, k) => !!k === dark);
    slide($('#mode'));
    spread(event, button, windows);
  });
  const themeAt = (_, button, event) => { if (button.dataset.theme !== theme) spread(event, button, () => setTheme(button.dataset.theme)); };
  pick('#dots', themeAt);
  pick('#pals', themeAt);
  $('#lang').onclick = (event) => spread(event, event.currentTarget, () => { lang = lang === 'zh' ? 'en' : 'zh'; store('lang', lang); render(); });
  $('#buddy').onclick = (event) => spread(event, event.currentTarget, () => setTheme(THEMES[(THEMES.indexOf(theme) + 1) % THEMES.length]));
  $('#replay').onclick = () => playChat('ask');
  const answer = (event) => {
    const button = event.target.closest('.sa-ok .sa-btn');
    if (button && (event.type === 'click' || event.key === 'Enter' || event.key === ' ')) {
      event.preventDefault();
      playChat(button.classList.contains('ghost') ? 'ask' : 'done');
    }
  };
  $('#chat').addEventListener('click', answer);
  $('#chat').addEventListener('keydown', answer);
  let copied;
  $('#copy').onclick = async () => {
    try { await navigator.clipboard.writeText($('#steps').textContent); } catch { return; }
    $('#copy').textContent = T[lang].copied;
    clearTimeout(copied);
    copied = setTimeout(() => ($('#copy').textContent = T[lang].copy), 1600);
  };
  addEventListener('resize', () => { fit(); slideAll(); });
  // A choice that matches the system is forgotten, so the page follows the system again.
  function setScheme(next) {
    scheme = next;
    dark = next === 'dark';
    root.dataset.scheme = next;
    try { (next === 'dark') === night.matches ? localStorage.removeItem('scheme') : localStorage.setItem('scheme', next); } catch {}
    render();
  }
  $('#scheme').onclick = (event) => spread(event, event.currentTarget, () => setScheme(scheme === 'dark' ? 'light' : 'dark'));
  night.addEventListener('change', () => { if (!store('scheme')) setScheme(night.matches ? 'dark' : 'light'); });
  document.fonts.ready.then(slideAll);

  render();
  $$('#stats [data-n]').forEach(count);
  setTimeout(() => root.classList.remove('intro'), 1800);

  // The hero artwork drifts slightly against the pointer.
  const hero = $('.hero');
  if (!still && matchMedia('(pointer: fine)').matches) {
    let frame = 0;
    hero.addEventListener('pointermove', (event) => {
      cancelAnimationFrame(frame);
      frame = requestAnimationFrame(() => {
        hero.style.setProperty('--px', (event.clientX / innerWidth * 2 - 1).toFixed(3));
        hero.style.setProperty('--py', (event.clientY / innerHeight * 2 - 1).toFixed(3));
      });
    });
    hero.addEventListener('pointerleave', () => { hero.style.setProperty('--px', 0); hero.style.setProperty('--py', 0); });
  }

  // Elements entering together arrive one after another.
  const reveal = new IntersectionObserver((entries) => entries.filter((entry) => entry.isIntersecting).forEach((entry, i) => {
    const el = entry.target;
    if (i) { el.style.transitionDelay = `${i * 90}ms`; setTimeout(() => (el.style.transitionDelay = ''), 1400); }
    el.classList.add('in');
    reveal.unobserve(el);
    $$('[data-n]', el).forEach(count);
    if (el.classList.contains('chat')) { chatSeen = true; playChat('ask'); }
  }), { threshold: 0.12 });
  $$('.rv,.stg').forEach((el) => reveal.observe(el));

  // The companion in the corner changes pose with the section in the middle of the screen.
  let touring = false;
  const middle = new IntersectionObserver((entries) => entries.forEach((entry) => {
    if (entry.target.id === 'tour') touring = entry.isIntersecting;
    if (!entry.isIntersecting) return;
    $$('.nav nav a').forEach((a) => (a.getAttribute('href') === '#' + entry.target.id ? a.setAttribute('aria-current', 'true') : a.removeAttribute('aria-current')));
    const buddy = $('#buddy'), img = $('img', buddy);
    if (img.dataset.brand === entry.target.dataset.pose) return;
    img.dataset.brand = entry.target.dataset.pose;
    SshairyMock.paint(buddy);
    buddy.classList.remove('pop');
    void buddy.offsetWidth;
    buddy.classList.add('pop');
  }), { rootMargin: '-45% 0px -45% 0px' });
  $$('section[data-pose],footer[data-pose]').forEach((el) => middle.observe(el));

  if (!still) setInterval(() => {
    if (!touring || toured || document.hidden) return;
    tour = (tour + 1) % TOUR.length;
    press($('#tabs'), (_, k) => k === tour);
    slide($('#tabs'));
    windows();
  }, 4500);
})();
